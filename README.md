# 0717 CI/CD Demo

依照 [DevOps 綜合 Workshop](https://hackmd.io/@yillkid/S1llE_naZx) 建立的最小完整 pipeline：

```text
PR -> pytest -> merge main -> build image -> GHCR
   -> 更新 gitops branch 的 image SHA -> ArgoCD sync -> K8s rolling update -> se218.net
```

## 本機驗證

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python -m pytest -v --cov=app --cov-fail-under=70
docker build -t 0717-cicd-demo .
docker run --rm -p 8000:8000 0717-cicd-demo
curl http://localhost:8000/health
```

Windows PowerShell 啟用虛擬環境請改用 `.venv\Scripts\Activate.ps1`。

## 自動化內容

- PR：執行 pytest 與 coverage gate，未達 70% 失敗。
- main：測試通過才 build，推送 `latest` 與 commit SHA 到 GHCR。
- workflow：把 `gitops` branch 的 `k8s/deployment.yaml` 更新為不可變 SHA tag 並 push。
- ArgoCD：偵測 manifest commit，自動 sync、self-heal、prune。
- K8s：兩個 replica 搭配 readiness/liveness probe 做 rolling update。
- Nginx：把 `se218.net` 流量轉到 K8s NodePort `30080`。

本次作業提交與 debug 紀錄見 [WRITEUP.md](./WRITEUP.md)；可套用到其他專案的版本見 [WRITEUP-GENERIC.md](./WRITEUP-GENERIC.md)。

## 已完成的 GitHub 設定

### 1. GitHub branch protection

`main` 已設定 branch protection：

- Branch name pattern：`main`
- 已啟用 **Require status checks to pass before merging**
- Required check：`test`

### 2. CI/CD 與 GHCR

- Actions run `29477431979` 的 `test`、`build-and-update-manifest` 已通過。
- `gitops` branch 已自動更新為 main commit `6a79648...` 的 image tag。
- GHCR `latest` manifest 已用匿名 pull 驗證為 HTTP 200，不需 `imagePullSecret`。

## 需要你手動操作（一次性）

### 1. 在 se218.net 啟動 Minikube

SSH 登入 se218.net 後執行：

```bash
minikube status
minikube start
kubectl config use-context minikube
kubectl get nodes
```

`minikube start` 已在執行時可略過。

### 2. 安裝或確認 ArgoCD

```bash
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=Available deployment --all -n argocd --timeout=300s
kubectl get pods -n argocd
```

### 3. 套用本 repo 的 ArgoCD Application

```bash
git clone https://github.com/Graylee0128/0717-cicd-demo.git
cd 0717-cicd-demo
kubectl apply -f argocd/application.yaml
kubectl get applications -n argocd
kubectl wait --for=condition=Available deployment/cicd-demo -n cicd-demo --timeout=300s
kubectl get pods -n cicd-demo
MINIKUBE_IP=$(minikube ip)
curl "http://${MINIKUBE_IP}:30080/health"
```

### 4. 修正 se218.net 的 Nginx upstream

2026-07-16 實測：DNS 指向 `114.37.200.155`、80/443 已開啟，但 HTTP 回 `504 Gateway Time-out`，HTTPS 憑證主體與 `se218.net` 不符。先執行 `minikube ip` 取得實際位址，再把下方 `<MINIKUBE_IP>` 換掉：

```nginx
location / {
    proxy_pass http://<MINIKUBE_IP>:30080;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

然後檢查並 reload：

```bash
sudo nginx -t
sudo systemctl reload nginx
curl http://se218.net/health
```

不要直接照抄 `127.0.0.1`；Minikube NodePort 應使用 `minikube ip` 的結果。

### 5. 修正 HTTPS 憑證

確認 HTTP 已正常後，依主機既有憑證工具更新 `se218.net` 憑證；若既有環境使用 Certbot：

```bash
sudo certbot --nginx -d se218.net
curl https://se218.net/health
```

### 6. 故障演練

故意讓 `tests/test_main.py` 的斷言失敗並開 PR，確認 `test` 紅燈時不能 merge；驗證後還原測試。

## 驗收

- [ ] PR 自動測試，紅燈不能 merge
- [ ] merge main 後 GHCR 同時有 SHA 與 latest tag
- [ ] `gitops` branch 的 `k8s/deployment.yaml` 自動換成該 commit SHA
- [ ] ArgoCD 顯示 `Synced / Healthy`
- [ ] `kubectl rollout status deployment/cicd-demo -n cicd-demo` 成功
- [ ] `https://se218.net/health` 回傳 `{"status":"ok"}`
