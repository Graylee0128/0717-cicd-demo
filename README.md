# 0717 CI/CD Demo

依照 [DevOps 綜合 Workshop](https://hackmd.io/@yillkid/S1llE_naZx) 建立的最小完整 pipeline：

```text
PR -> pytest -> merge main -> build image -> GHCR
   -> 更新 gitops branch 的 image SHA -> ArgoCD sync -> 本機 VM 的 Minikube rolling update
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
- 本機 VM：直接用 Minikube NodePort `30080` 驗證 V1 → V2。

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

### 0. 確認目前就在正確 repo

如果 prompt 已顯示 `~/0717-cicd-demo (main)`，不要再次執行 `git clone`，否則會產生 `0717-cicd-demo/0717-cicd-demo` 巢狀目錄。先檢查：

```bash
pwd
git remote get-url origin
git log -1 --oneline
```

`origin` 應為 `https://github.com/Graylee0128/0717-cicd-demo.git`。只有主機上尚未存在 repo 時，才從 home directory clone。

### 1. 在本機 VM 啟動 Minikube

登入本機 VM 後執行：

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
kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=120s
kubectl get crd applications.argoproj.io
kubectl wait --for=condition=Available deployment --all -n argocd --timeout=300s
kubectl get pods -n argocd
```

若先套用 `argocd/application.yaml` 時看到 `no matches for kind "Application"`，代表 Argo CD CRD 尚未安裝；完成本步驟並確認 `applications.argoproj.io` 存在後再繼續。

### 3. 套用本 repo 的 ArgoCD Application

```bash
git pull --ff-only
kubectl apply -f argocd/application.yaml
kubectl get applications -n argocd
kubectl wait --for=condition=Available deployment/cicd-demo -n argocd --timeout=300s
kubectl get pods -n argocd -l app=cicd-demo
```

`cicd-demo` 是 Application／Deployment／Service 名稱；這些 workload 與 Argo CD control plane 共用既有的 `argocd` namespace，不建立額外 namespace。

### 4. 截圖 V1 baseline

```bash
kubectl get application cicd-demo -n argocd
kubectl get deployment/cicd-demo service/cicd-demo -n argocd -o wide
kubectl get pods -n argocd -l app=cicd-demo -o wide
kubectl get deployment cicd-demo -n argocd \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
MINIKUBE_IP=$(minikube ip)
curl --fail "http://${MINIKUBE_IP}:30080/health"
curl --fail "http://${MINIKUBE_IP}:30080/"
```

V1 的 `/` 預期包含 `"build":"v1"`。截圖需同時保留命令、`Synced / Healthy`、兩個 Ready Pods、SHA image 與 curl 結果。

### 5. 合併 V2 PR 並觀察 rolling update

先在 VM 開啟監看：

```bash
kubectl get pods -n argocd -l app=cicd-demo -w
```

合併把 `build` 改為 `v2` 的 PR 後，GitHub Actions 會 build 新的 commit-SHA image、更新 `gitops`，Argo CD 再自動 rolling update。完成後截圖：

```bash
kubectl rollout status deployment/cicd-demo -n argocd --timeout=300s
kubectl get application cicd-demo -n argocd
kubectl get deployment cicd-demo -n argocd \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
curl --fail "http://$(minikube ip):30080/"
```

V2 的 `/` 預期包含 `"build":"v2"`；實際部署仍使用不可變的 commit SHA，不使用可變的 `:v2` image tag。

### 6. 故障演練

故意讓 `tests/test_main.py` 的斷言失敗並開 PR，確認 `test` 紅燈時不能 merge；驗證後還原測試。

## 驗收

- [ ] PR 自動測試，紅燈不能 merge
- [ ] merge main 後 GHCR 同時有 SHA 與 latest tag
- [ ] `gitops` branch 的 `k8s/deployment.yaml` 自動換成該 commit SHA
- [ ] ArgoCD 顯示 `Synced / Healthy`
- [ ] `kubectl rollout status deployment/cicd-demo -n argocd` 成功
- [ ] `kubectl get namespace cicd-demo` 回 `NotFound`
- [ ] 本機 VM NodePort `/health` 回傳 `{"status":"ok"}`
- [ ] V1 與 V2 截圖顯示不同 SHA，V2 `/` 回傳 `"build":"v2"`
