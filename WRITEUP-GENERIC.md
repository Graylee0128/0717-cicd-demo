# 可重用的 GitHub Actions + GHCR + Argo CD + Minikube CI/CD 教學

本文件將 [DevOps 綜合 Workshop](https://hackmd.io/@yillkid/S1llE_naZx) 整理成可重用的 step-by-step 教學。實際作業成果、Actions run 證據與 debug 時間線請看 [WRITEUP.md](./WRITEUP.md)。

> 重要：GitHub/GHCR/GitOps 可以自動化；Minikube 與 Argo CD bootstrap 仍需由具備部署主機權限的操作者完成。只做本機 VM demo 時，NodePort 驗證即可；Nginx、DNS 與 TLS 是選用的公網延伸。

## 1. 目標與驗收條件

目標流程：

```text
Pull Request
  -> pytest / coverage
  -> merge main
  -> build container image
  -> push GHCR（commit SHA + latest）
  -> 更新 gitops branch 的 Deployment image SHA
  -> Argo CD 偵測差異並同步
  -> Minikube rolling update
  -> VM NodePort 驗證（選用：Nginx / TLS 對外服務）
```

完成時應符合：

- [ ] PR 必須通過 `test`，失敗時不能 merge。
- [ ] merge／push 到 `main` 後，GHCR 同時出現不可變的 commit SHA tag 與方便查看的 `latest` tag。
- [ ] workflow 自動把 `gitops` branch 的 `k8s/deployment.yaml` 更新成該 commit SHA。
- [ ] `main` 的 branch protection 不會被部署 manifest 的自動更新繞過。
- [ ] Argo CD 顯示 Application 為 `Synced`、`Healthy`。
- [ ] Kubernetes Deployment rollout 成功，兩個 Pod Ready。
- [ ] NodePort health check 回傳 `{"status":"ok"}`。
- [ ] 本機 VM demo 可由 NodePort 驗證 V1 → V2；若需要公網，再驗證 `https://<DOMAIN>/health`。

本教學使用下列 placeholders：

| Placeholder | 含義 |
|---|---|
| `<GITHUB_USER>` | GitHub 帳號 |
| `<github_user_lowercase>` | GHCR 使用的小寫帳號 |
| `<REPO>` | repository 名稱 |
| `<DOMAIN>` | 選用的對外網域 |
| `<K8S_NAMESPACE>` | Kubernetes namespace；可使用已存在的 `argocd` |
| `<APP_NAME>` | Deployment、Service、Argo CD Application 名稱 |
| `<NODE_PORT>` | 30000–32767 範圍內的 NodePort |
| `<MINIKUBE_IP>` | 在部署主機執行 `minikube ip` 的結果 |

下列命令中的 `<...>` 都要先換成實際值；不要原樣貼進 shell，因為 `<`、`>` 可能被 shell 當成重新導向符號。

## 2. 架構與 branch 設計

```text
開發者 -> PR -> main -----------------> GitHub Actions
                 |                         | pytest
                 |                         | docker build/push
                 |                         v
                 |                      GHCR:<SHA>
                 |                         |
                 +-- workflow commit ----> gitops branch
                                              |
                                              v
                                           Argo CD
                                              |
                                              v
                 VM terminal -------> Minikube NodePort -> Service -> Pods
                 Internet -> Nginx --^（選用）
```

`main` 放應用程式、測試、Dockerfile、workflow 與宣告式部署檔的開發版本；它受 branch protection 保護。`gitops` 是實際部署來源，workflow 只修改其中的 image tag。Argo CD 的 `targetRevision` 指向 `gitops`，因此應用程式碼版本與叢集 desired state 分離。

這個設計也解決了一個實際問題：若 workflow build 完後直接回推 `main` 的 manifest，branch protection 會拒絕 push；改推專用 `gitops` branch，既保留 `main` 保護，也保留完整部署 commit 歷史。

## 3. Repository 結構

```text
<REPO>/
├── .github/workflows/ci.yml   # test、build、push、更新 gitops
├── app/main.py                # FastAPI 服務與 health endpoint
├── tests/test_main.py         # API tests
├── k8s/
│   ├── deployment.yaml        # GHCR image、2 replicas、probes
│   └── service.yaml           # NodePort
├── argocd/application.yaml    # Argo CD 追蹤 gitops/k8s
├── Dockerfile
├── requirements.txt
├── README.md
└── WRITEUP.md
```

## 4. 前置條件與責任分工

### 自動化負責

- GitHub Actions：安裝 Python dependencies、pytest、coverage gate。
- GitHub Actions：建置並推送 GHCR image。
- GitHub Actions：用 commit SHA 更新 `gitops` branch。
- Argo CD：在已完成 bootstrap 的叢集中自動 sync、prune、self-heal。
- Kubernetes：readiness/liveness probe 與 rolling update。

### 操作者必須手動負責

- 建立 GitHub repo、確認 Actions 權限、設定 branch protection、設定 GHCR package visibility。
- 登入部署 VM，安裝／啟動 Minikube 與 Argo CD。
- 將 Argo CD Application 套用到該叢集。
- 取得實際 `<MINIKUBE_IP>` 並直測 NodePort。
- 若需要公網，再設定 Nginx、DNS、80/443 firewall 與 TLS 憑證。
- 完成端到端驗收與故障演練。

需要的工具：Git、GitHub 帳號、Python 3.11、Docker；部署 VM 另需 `kubectl`、`minikube`，公網延伸才需要 Nginx 與 Certbot。開始前確認：

```bash
git --version
python --version
docker --version
kubectl version --client
minikube version
nginx -v
```

## 5. Step-by-step：應用程式、測試與容器

### Step 5.1：建立 FastAPI health endpoint

`app/main.py` 的最小服務：

```python
import os

from fastapi import FastAPI

VERSION = os.getenv("APP_VERSION", "dev")
app = FastAPI(title="<REPO>")


@app.get("/")
def root():
    return {"service": "<REPO>", "version": VERSION}


@app.get("/health")
def health():
    return {"status": "ok"}
```

### Step 5.2：建立可執行的 API test

`tests/test_main.py` 驗證 health、HTTP status 與 root 基本資訊。安裝並執行：

```bash
python -m venv .venv
# Linux/macOS
source .venv/bin/activate
# Windows PowerShell 改用：.venv\Scripts\Activate.ps1

python -m pip install -r requirements.txt
python -m pytest -v --cov=app --cov-fail-under=70
```

刻意使用 `python -m pytest`，讓 Python 以專案根目錄解析 `app` package，避免某些 runner 使用 `pytest` console entry point 時發生 import path 差異。

### Step 5.3：建置並測試 Docker image

Dockerfile 使用 Python slim image、非 root 使用者，並只暴露應用程式的 8000 port：

```bash
docker build -t <REPO>:local .
docker run --rm -p 8000:8000 <REPO>:local
```

另一個 terminal 驗證：

```bash
curl --fail http://127.0.0.1:8000/health
```

預期：

```json
{"status":"ok"}
```

## 6. Step-by-step：GitHub Actions CI 與 GHCR

### Step 6.1：測試 job

`.github/workflows/ci.yml` 在 PR 與 `main` push 觸發。核心設定：

```yaml
on:
  pull_request:
    branches: [main]
  push:
    branches: [main]
    paths-ignore:
      - k8s/deployment.yaml

jobs:
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

`test` job 名稱就是 branch protection 要求的 status check 名稱。

### Step 6.2：登入 GHCR，build 並 push

build job 需在 test 成功後、且事件是 push 時才執行：

```yaml
  build-and-update-manifest:
    needs: test
    if: github.event_name == 'push'
    runs-on: ubuntu-latest
    permissions:
      contents: write
      packages: write
    steps:
      - uses: actions/checkout@v6
      - uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/build-push-action@v7
        with:
          context: .
          push: true
          tags: |
            ghcr.io/<github_user_lowercase>/<REPO>:${{ github.sha }}
            ghcr.io/<github_user_lowercase>/<REPO>:latest
```

SHA tag 是可追溯、可回滾的部署依據；`latest` 只供人類方便查看，不應當成 GitOps desired state。

在 repository 的 **Settings → Actions → General → Workflow permissions** 確認 workflow 允許寫入；workflow 本身仍應只宣告必要的 `contents: write` 與 `packages: write`。第一次成功後，到 GitHub 個人頁 **Packages → `<REPO>` → Package settings → Change visibility → Public**。若 image 必須 private，則要在 Kubernetes 建 `imagePullSecret`，並在 Deployment 引用它。

### Step 6.3：建立並更新 `gitops` branch

第一次建立：

```bash
git switch main
git branch gitops
git push -u origin gitops
```

這會從目前的 `main` 建立非破壞性的初始部署 branch；不需要刪除工作目錄。建立後，日常只由 workflow 更新 `gitops` branch 的 image：

```yaml
      - name: Checkout GitOps branch
        uses: actions/checkout@v6
        with:
          ref: gitops
          path: gitops

      - name: Update GitOps image tag
        working-directory: gitops
        run: |
          sed -i "s|image: ghcr.io/<github_user_lowercase>/<REPO>:.*|image: ghcr.io/<github_user_lowercase>/<REPO>:${{ github.sha }}|" k8s/deployment.yaml
          git config user.name github-actions
          git config user.email actions@github.com
          git add k8s/deployment.yaml
          git commit -m "chore: deploy ${{ github.sha }} [skip ci]"
          git push origin gitops
```

`gitops` branch 不應套用會阻擋 GitHub Actions push 的同一組規則；若組織政策要求保護它，改用 GitHub App／PAT 或以 PR promotion 取代直接 push。

### Step 6.4：設定 `main` branch protection

在 GitHub repo 進入 **Settings → Branches / Rules → Add branch protection rule**：

1. Branch name pattern 填 `main`。
2. 啟用 **Require a pull request before merging**（若 workshop 要求所有變更走 PR）。
3. 啟用 **Require status checks to pass before merging**。
4. 搜尋並加入 required check：`test`。
5. 建議啟用 **Require branches to be up to date before merging**。
6. 儲存後以一個故意失敗的 test PR 驗證紅燈時不能 merge，再還原測試。

## 7. Step-by-step：Kubernetes 與 Argo CD manifests

Deployment 使用 GHCR SHA image、兩個 replicas，以及 `/health` readiness/liveness probes；Service 使用固定 NodePort：

```yaml
apiVersion: v1
kind: Service
metadata:
  name: <APP_NAME>
  namespace: <K8S_NAMESPACE>
spec:
  type: NodePort
  selector:
    app: <APP_NAME>
  ports:
    - port: 8000
      targetPort: 8000
      nodePort: <NODE_PORT>
```

Argo CD Application 必須追蹤 `gitops`：

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <APP_NAME>
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/<GITHUB_USER>/<REPO>.git
    targetRevision: gitops
    path: k8s
  destination:
    server: https://kubernetes.default.svc
    namespace: <K8S_NAMESPACE>
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

`CreateNamespace=true` 適合建立獨立的 `<K8S_NAMESPACE>`。若 workload 要共用已存在的 `argocd` namespace，將 destination 與 workload manifests 都設為 `argocd`，並刪除 `CreateNamespace=true`；不要讓 Application 管理 Argo CD 自己的 Namespace manifest。

## 8. 部署主機手動 bootstrap（必須由操作者執行）

以下命令要在能控制 部署 Minikube 的主機上執行，不是在 GitHub runner 執行。

### Step 8.1：確認或啟動 Minikube

```bash
minikube status
minikube start
minikube status
kubectl config current-context
kubectl get nodes -o wide
```

若 Minikube 原本已是 Running，`minikube start` 可安全地確認／恢復既有 cluster。節點必須是 `Ready` 才繼續。

### Step 8.2：安裝並檢查 Argo CD

依 [Argo CD 官方 Getting Started](https://argo-cd.readthedocs.io/en/stable/getting_started/)：

```bash
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=120s
kubectl get crd applications.argoproj.io
kubectl wait --for=condition=Available deployment --all -n argocd --timeout=300s
kubectl get pods -n argocd
```

第一行是 idempotent namespace 建立方式。server-side apply 可避免大型 CRD 超過 client-side annotation 大小限制。`applications.argoproj.io` 必須 Established，所有必要 Pod 也應為 `Running`／Ready。

### Step 8.3：套用 Application

只有 deployment host 尚未存在 repo 時才 clone；如果 prompt 已在 repo 內，先檢查 `pwd` 與 `git remote get-url origin`，不要再次 clone 造成巢狀目錄：

```bash
pwd
git remote get-url origin
git pull --ff-only
kubectl apply -f argocd/application.yaml
kubectl get applications -n argocd
kubectl describe application <APP_NAME> -n argocd
kubectl get all -n <K8S_NAMESPACE>
kubectl rollout status deployment/<APP_NAME> -n <K8S_NAMESPACE> --timeout=300s
```

### Step 8.4：取得 Minikube IP 並直測 NodePort

```bash
minikube ip
MINIKUBE_IP=$(minikube ip)
curl --fail "http://${MINIKUBE_IP}:<NODE_PORT>/health"
kubectl get service <APP_NAME> -n <K8S_NAMESPACE>
```

預期回傳 `{"status":"ok"}`。本機 VM demo 到此即可完成；若這一步不通，先修 Kubernetes／網路，不要先改 Nginx。

### Step 8.5（選用）：設定 Nginx upstream

在 `<DOMAIN>` 的 Nginx HTTP server block 設定：

```nginx
server {
    listen 80;
    server_name <DOMAIN>;

    location / {
        proxy_pass http://<MINIKUBE_IP>:<NODE_PORT>;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Nginx upstream 應寫成 `http://<MINIKUBE_IP>:<NODE_PORT>`；`<MINIKUBE_IP>` 用上一節 `minikube ip` 的實際輸出替換。Minikube restart 後 IP 若改變，也要更新 Nginx。

```bash
sudo nginx -t
sudo systemctl reload nginx
curl --fail http://<DOMAIN>/health
```

### Step 8.6（選用）：DNS 與 TLS / Certbot

先確認 `<DOMAIN>` 的 DNS A/AAAA record 指向這台 Nginx，且 80/443 可從外部到達。HTTP health 成功後才申請憑證：

```bash
sudo certbot --nginx -d <DOMAIN>
sudo nginx -t
sudo systemctl reload nginx
curl --fail https://<DOMAIN>/health
```

也可用以下方式查看實際送出的憑證 hostname 與效期：

```bash
openssl s_client -connect <DOMAIN>:443 -servername <DOMAIN> </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -dates
```

Certbot 使用方式以 [Certbot 官方 instructions](https://certbot.eff.org/instructions) 與主機 Linux distribution 為準。

## 9. 端到端驗證

### GitHub / GHCR

1. 開 PR，確認 `test` 綠燈才可 merge。
2. 在 Actions 打開 `CI/CD` run，確認 `test`、`build-and-update-manifest` 成功。
3. 在 Packages 確認存在 `latest` 與完整 commit SHA tag。
4. 查看 `gitops` branch，確認 Deployment 的 image SHA 與本次 `github.sha` 相同。

### Argo CD / Kubernetes

```bash
kubectl get applications -n argocd
kubectl get deployment,pods,service -n <K8S_NAMESPACE> -o wide
kubectl rollout status deployment/<APP_NAME> -n <K8S_NAMESPACE>
kubectl get deployment <APP_NAME> -n <K8S_NAMESPACE> -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
MINIKUBE_IP=$(minikube ip)
curl --fail "http://${MINIKUBE_IP}:<NODE_PORT>/health"
```

### V1 → V2 rolling update

先讓 `/` 回傳可辨識的 `"build":"v1"` 並截圖，再開 PR 將同一欄位改為 `v2`。merge 後仍由 workflow 部署新的 commit-SHA image；不要把 GitOps image 改成可變的 `:v2` tag。

```bash
kubectl get pods -n <K8S_NAMESPACE> -l app=<APP_NAME> -w
kubectl rollout status deployment/<APP_NAME> -n <K8S_NAMESPACE> --timeout=300s
kubectl get application <APP_NAME> -n argocd
curl --fail "http://$(minikube ip):<NODE_PORT>/"
```

前後截圖應顯示不同 SHA、Pods 被替換、Application 回到 `Synced / Healthy`，最後 `/` 回傳 `"build":"v2"`。

### 公網（選用）

```bash
curl -i http://<DOMAIN>/health
curl -i https://<DOMAIN>/health
```

最終 HTTPS response 應為 200，body 為 `{"status":"ok"}`，且瀏覽器／`curl` 不應出現 hostname mismatch。

## 10. 回滾

GitOps 的正式回滾方式是把 `gitops` branch 的 image 改回上一個已知健康 SHA，讓 Git 成為唯一 desired-state source：

```bash
git switch gitops
git pull --ff-only origin gitops
# 將 k8s/deployment.yaml 的 image tag 改為 <LAST_GOOD_SHA>
git add k8s/deployment.yaml
git commit -m "rollback: deploy <LAST_GOOD_SHA>"
git push origin gitops
kubectl rollout status deployment/<APP_NAME> -n <K8S_NAMESPACE> --timeout=300s
```

`kubectl rollout undo deployment/<APP_NAME> -n <K8S_NAMESPACE>` 只適合緊急暫時止血；因 Argo CD 啟用 self-heal，它可能再次把叢集改回 Git 宣告的版本，所以仍要補上 `gitops` commit。

若錯誤來自應用程式碼，也可在 `main` revert 壞 commit，再由正常 pipeline 產生一個新的健康 SHA；不要重寫既有 image tag。

## 11. Troubleshooting 快查

### CI 出現 `ModuleNotFoundError: No module named 'app'`

確認 workflow 從 repo root 執行，並將 `pytest ...` 改為：

```bash
python -m pytest -v --cov=app --cov-fail-under=70
```

### workflow push 被 protected branch 拒絕

不要降低 `main` 保護。讓 build workflow checkout 並 push `gitops` branch，Argo CD 的 `targetRevision` 也改成 `gitops`。

### Actions 顯示 Node.js 20 runtime deprecation warning

更新 action major versions 並閱讀 release notes。建議使用目前維護中的版本，例如：

```yaml
actions/checkout@v6
actions/setup-python@v6
docker/login-action@v4
docker/build-push-action@v7
```

### Pod 為 `ImagePullBackOff`

```bash
kubectl describe pod -n <K8S_NAMESPACE> <POD_NAME>
```

確認 GHCR image 名稱全小寫、SHA 存在、package 是 Public；private package 則建立並引用 `imagePullSecret`。

### `no matches for kind "Application"`

完整訊息通常包含 `resource mapping not found` 與 `ensure CRDs are installed first`。這表示 Kubernetes API 尚未註冊 Argo CD Application CRD：

```bash
kubectl get crd applications.argoproj.io
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=120s
kubectl wait --for=condition=Available deployment --all -n argocd --timeout=300s
kubectl apply -f argocd/application.yaml
```

不要先改 `apiVersion` 或反覆套用 Application；先確認目前 kube context、CRD 與 Argo CD controllers。

### Argo CD 為 `OutOfSync` 或 `Degraded`

```bash
kubectl describe application <APP_NAME> -n argocd
kubectl get events -n <K8S_NAMESPACE> --sort-by=.lastTimestamp
kubectl logs deployment/<APP_NAME> -n <K8S_NAMESPACE> --tail=100
```

確認 repo 可讀、`targetRevision: gitops`、`path: k8s`，以及 namespace/image 設定正確。

### NodePort 不通

```bash
minikube status
minikube ip
kubectl get nodes,pods -A -o wide
kubectl get endpoints <APP_NAME> -n <K8S_NAMESPACE>
kubectl describe service <APP_NAME> -n <K8S_NAMESPACE>
curl -v "http://$(minikube ip):<NODE_PORT>/health"
```

如果 Service 沒有 endpoints，檢查 selector 與 Pod labels；如果 endpoints 正常但 curl 不通，檢查 Minikube driver、host route 與 firewall。

### Nginx 回 504

504 代表 Nginx 收到請求，但 upstream 沒有及時回應。先從 Nginx 主機直測 `http://<MINIKUBE_IP>:<NODE_PORT>/health`，再確認 `proxy_pass` 沒有誤用 `127.0.0.1` 或過期的 Minikube IP：

```bash
curl -v "http://$(minikube ip):<NODE_PORT>/health"
sudo nginx -T
sudo tail -n 100 /var/log/nginx/error.log
```

### HTTPS hostname mismatch

代表 443 已有服務，但送出的憑證不包含 `<DOMAIN>`。確認 Nginx `server_name`、SNI 與 certificate SAN，HTTP 正常後再用 Certbot 申請／更新正確憑證。

## 12. 延伸閱讀

本 repository 的實際代入值、GitHub Actions run ID、branch protection 問題、HTTP 504 與 TLS hostname mismatch 紀錄，集中在 [作業繳交版 WRITEUP](./WRITEUP.md)，避免把特定環境狀態混進可重用教學。
