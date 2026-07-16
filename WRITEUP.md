# 0717 CI/CD Demo 技術文件（作業提交版）

本文件記錄如何依照 [DevOps 綜合 Workshop](https://hackmd.io/@yillkid/S1llE_naZx)，在 [`Graylee0128/0717-cicd-demo`](https://github.com/Graylee0128/0717-cicd-demo) 建立 FastAPI → GitHub Actions → GHCR → GitOps → Argo CD → Minikube → `se218.net` 的 CI/CD。

> GitHub、GHCR 與 GitOps 自動化已完成並驗證。se218 主機上的 Minikube、Argo CD Application、Nginx upstream 與 TLS 必須由我登入主機後手動 bootstrap；做完一次後，後續版本才會由 Argo CD 自動部署。

可套用到其他專案的版本見 [WRITEUP-GENERIC.md](./WRITEUP-GENERIC.md)。

## 1. 目標與目前狀態

```text
PR
 -> pytest + coverage
 -> merge main
 -> build image
 -> push GHCR（commit SHA + latest）
 -> 更新 gitops branch 的 image SHA
 -> Argo CD auto-sync
 -> se218 Minikube rolling update
 -> Nginx / TLS 對外提供 se218.net
```

| 項目 | 狀態 | 證據 |
|---|---|---|
| GitHub repo | 完成 | `Graylee0128/0717-cicd-demo`，Public |
| PR test / coverage gate | 完成 | Actions run `29477431979`：`test` success |
| Docker build / GHCR push | 完成 | 同一 run：`build-and-update-manifest` success |
| GHCR public pull | 完成 | anonymous manifest request HTTP 200；digest `sha256:1546583e...` |
| GitOps image SHA 更新 | 完成 | `gitops/k8s/deployment.yaml` 已指向 main SHA `6a796481...` |
| main branch protection | 完成 | Required status check：`test` |
| se218 Minikube / Argo CD | 待手動 | 需要 se218 operator access |
| Nginx / HTTPS | 待手動 | 2026-07-16 外部實測仍為 HTTP 504、TLS hostname mismatch |

## 2. 架構決策

本題只要求一個 repo，所以不另外建立 config repo，而是在同 repo 使用兩個 branch：

- `main`：應用程式、測試、Dockerfile、workflow、部署檔來源；受 branch protection 保護。
- `gitops`：Argo CD 實際追蹤的 desired state；workflow 只更新這裡的 image SHA。

```text
Developer -> PR -> main -> GitHub Actions -> GHCR:<SHA>
                          |
                          +-> commit image SHA -> gitops
                                                   |
                                                   v
                                                Argo CD
                                                   |
                                                   v
Internet -> se218 Nginx -> Minikube :30080 -> Service -> 2 Pods
```

這樣可避免 build job 直接 push 受保護的 `main`，也保留每次部署的 Git 歷史。

## 3. Repository 內容

```text
0717-cicd-demo/
├── .github/workflows/ci.yml
├── app/main.py
├── tests/test_main.py
├── Dockerfile
├── requirements.txt
├── k8s/
│   ├── namespace.yaml
│   ├── deployment.yaml
│   └── service.yaml
├── argocd/application.yaml
├── README.md
├── WRITEUP.md
└── WRITEUP-GENERIC.md
```

## 4. Step-by-step：應用程式與本機測試

### Step 4.1：FastAPI endpoints

`app/main.py` 提供：

- `GET /`：回傳 service 與版本。
- `GET /health`：回傳 `{"status":"ok"}`，供測試與 Kubernetes probes 使用。

### Step 4.2：安裝與測試

```bash
git clone https://github.com/Graylee0128/0717-cicd-demo.git
cd 0717-cicd-demo
python -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
python -m pytest -v --cov=app --cov-fail-under=70
```

Windows PowerShell 啟用環境請用：

```powershell
.venv\Scripts\Activate.ps1
```

必須用 `python -m pytest`，避免 runner 的 `pytest` entrypoint 找不到 repo root 下的 `app`。

### Step 4.3：Docker smoke test

```bash
docker build -t 0717-cicd-demo:local .
docker run --rm -p 8000:8000 0717-cicd-demo:local
curl --fail http://127.0.0.1:8000/health
```

預期回傳：

```json
{"status":"ok"}
```

## 5. Step-by-step：GitHub Actions CI/CD

Workflow：`.github/workflows/ci.yml`。

### Step 5.1：PR / main 測試

```yaml
test:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v6
    - uses: actions/setup-python@v6
      with:
        python-version: "3.11"
        cache: pip
    - run: pip install -r requirements.txt
    - run: python -m pytest -v --cov=app --cov-fail-under=70
```

branch protection 要求 `test` 成功，因此壞掉的 PR 不能 merge。

### Step 5.2：Build 並 push GHCR

只有 `main` push 且 `test` 成功後才執行：

```yaml
permissions:
  contents: write
  packages: write
```

使用 `GITHUB_TOKEN` 登入 `ghcr.io`，再推兩個 tag：

```text
ghcr.io/graylee0128/0717-cicd-demo:<FULL_COMMIT_SHA>
ghcr.io/graylee0128/0717-cicd-demo:latest
```

Kubernetes 使用不可變 SHA tag；`latest` 只方便人工查看。

### Step 5.3：更新 `gitops` branch

build 成功後，workflow checkout `gitops` 到子目錄，將 Deployment image 改成 `${{ github.sha }}`，commit 後 push：

```bash
git commit -m "chore: deploy <SHA> [skip ci]"
git push origin gitops
```

Argo CD Application 的關鍵設定：

```yaml
source:
  repoURL: https://github.com/Graylee0128/0717-cicd-demo.git
  targetRevision: gitops
  path: k8s
```

### Step 5.4：Action 版本

GitHub runner 已提示 Node.js 20 runtime 淘汰，因此目前使用：

```yaml
actions/checkout@v6
actions/setup-python@v6
docker/login-action@v4
docker/build-push-action@v7
```

## 6. Step-by-step：se218 Minikube 手動 CD bootstrap

以下全部在 se218 主機執行，不是在 Windows 或 GitHub runner 執行。

### Step 6.1：確認 Minikube

```bash
minikube status
minikube start
kubectl config use-context minikube
kubectl get nodes -o wide
```

若 Minikube 已是 Running，`minikube start` 可略過。節點必須為 `Ready` 才繼續。

### Step 6.2：安裝或確認 Argo CD

```bash
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=Available deployment --all -n argocd --timeout=300s
kubectl get pods -n argocd
```

### Step 6.3：套用 Application

```bash
git clone https://github.com/Graylee0128/0717-cicd-demo.git
cd 0717-cicd-demo
kubectl apply -f argocd/application.yaml
kubectl get applications -n argocd
kubectl describe application cicd-demo -n argocd
kubectl wait --for=condition=Available deployment/cicd-demo -n cicd-demo --timeout=300s
kubectl get pods -n cicd-demo -o wide
```

Argo CD 應顯示 `Synced / Healthy`，Deployment 應有兩個 Ready Pods。

### Step 6.4：直測 Minikube NodePort

```bash
MINIKUBE_IP=$(minikube ip)
echo "$MINIKUBE_IP"
kubectl get service cicd-demo -n cicd-demo
curl --fail "http://${MINIKUBE_IP}:30080/health"
```

只有這一步回 `{"status":"ok"}` 後，才繼續改 Nginx。

### Step 6.5：Nginx 指向 Minikube

先執行 `minikube ip`，把下方 `<MINIKUBE_IP>` 換成實際 IP：

```nginx
server {
    listen 80;
    server_name se218.net;

    location / {
        proxy_pass http://<MINIKUBE_IP>:30080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

不要用 `127.0.0.1:30080`；Minikube NodePort 應使用 `minikube ip` 的結果。

```bash
sudo nginx -t
sudo systemctl reload nginx
curl --fail http://se218.net/health
```

### Step 6.6：修正 TLS

HTTP 成功後再更新憑證：

```bash
sudo certbot --nginx -d se218.net
sudo nginx -t
sudo systemctl reload nginx
curl --fail https://se218.net/health
```

檢查憑證主體、簽發者與效期：

```bash
openssl s_client -connect se218.net:443 -servername se218.net </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
```

## 7. 端到端驗收

### GitHub / GHCR

- [x] Repo 已建立並 push。
- [x] `test` job 成功。
- [x] Docker build / push 成功。
- [x] GHCR 可匿名 pull。
- [x] `gitops` manifest 自動使用 main commit SHA。
- [x] `main` required status check 為 `test`。

### se218（登入主機後勾選）

```bash
kubectl get applications -n argocd
kubectl get deployment,pods,service -n cicd-demo -o wide
kubectl rollout status deployment/cicd-demo -n cicd-demo --timeout=300s
kubectl get deployment cicd-demo -n cicd-demo \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
curl --fail "http://$(minikube ip):30080/health"
curl --fail http://se218.net/health
curl --fail https://se218.net/health
```

- [ ] Argo CD `Synced / Healthy`。
- [ ] 兩個 Pods Ready。
- [ ] NodePort health 成功。
- [ ] HTTP health 成功。
- [ ] HTTPS health 成功且憑證 hostname 正確。

## 8. Rollback

從 `gitops` 找上一個已知健康 SHA，改回 Deployment image：

```bash
git switch gitops
git pull --ff-only origin gitops
# 編輯 k8s/deployment.yaml，將 image tag 改為 <LAST_GOOD_SHA>
git add k8s/deployment.yaml
git commit -m "rollback: deploy <LAST_GOOD_SHA>"
git push origin gitops
kubectl rollout status deployment/cicd-demo -n cicd-demo --timeout=300s
```

不要只依賴 `kubectl rollout undo`：Argo CD 啟用 self-heal，Git 沒改時可能把叢集再次同步回壞版本。

## 9. Debug 紀錄

### Debug 1：本機沒有可用 Python / Docker / kubectl

- 症狀：Windows `python.exe` 是 Store placeholder；Docker、kubectl 不存在。
- 影響：無法在本機執行 pytest、image build 與 manifest dry-run。
- 處理：讓 GitHub-hosted runner 執行 pytest 與 Docker build；Minikube 驗證留給 se218 operator。
- 原則：未執行的檢查不能宣稱成功。

### Debug 2：第一次 CI 找不到 `app`

- Run：`29476880214`。
- Log：`ModuleNotFoundError: No module named 'app'`。
- 根因：`pytest` console entrypoint 的 import path 沒包含 repo root。
- 修正：`pytest ...` 改為 `python -m pytest ...`。
- 驗證：run `29476990881` 成功。

### Debug 3：branch protection 擋 manifest push

- Run：`29477176940`。
- Log：`Protected branch update failed`、required check `test` expected。
- 根因：workflow build 後直接把 manifest commit push 回受保護的 `main`。
- 沒採用：關閉 branch protection，因為會破壞「紅燈不能 merge」要求。
- 修正：建立 `gitops` branch；workflow 改 push `gitops`；Argo CD 改追蹤 `gitops`。
- 驗證：run `29477431979` 的兩個 jobs 都成功，manifest 更新為 `6a796481...`。

### Debug 4：Actions Node.js 20 deprecation

- 症狀：runner 警告舊 action runtime 被強制轉到 Node.js 24。
- 修正：升級到 checkout v6、setup-python v6、login-action v4、build-push-action v7。
- 驗證：run `29477431979` 不再出現該 warning。

### Debug 5：se218 HTTP 504 / HTTPS hostname mismatch

- 日期：2026-07-16。
- DNS：`se218.net -> 114.37.200.155`。
- HTTP：Nginx 回 `504 Gateway Time-out`。
- HTTPS：certificate hostname 不符合 `se218.net`。
- 判讀：edge/Nginx 有回應，但 upstream 與 TLS 尚未完成；不能宣稱 Minikube workload 已上線。
- 下一步：依第 6 節完成 NodePort 直測、Nginx `<MINIKUBE_IP>:30080` 與 Certbot。

## 10. 最終交付界線

目前已完成：repo、CI、coverage gate、GHCR、immutable SHA、GitOps branch、自動 manifest commit、Argo CD manifests、branch protection、兩版技術文件。

仍需我在 se218 手動完成：Minikube 狀態確認、Argo CD bootstrap/Application、NodePort health、Nginx upstream、TLS，以及公網 end-to-end 驗收。
