# 0717-cicd-demo Cheatsheet（push-triggered 版）

流程：`edit → push main → Actions(test+build+push GHCR) → 更新 gitops → Argo CD 自動同步 → VM NodePort 驗證`
VM 沒有獨立 `kubectl`，一律用 `minikube kubectl -- ...`（`--` 不能少）。

---

## 0. 一次性：拆掉 main 保護（push-triggered 前提）
直推 main 會被 branch protection 擋（Debug 3）。solo demo 直接砍掉保護：
```bash
gh api -X DELETE repos/Graylee0128/0717-cicd-demo/branches/main/protection
```
> 之後想恢復「紅燈不能 merge」再回 Settings→Branches 加回即可。

---

## 1. 本機 sanity（Windows，可跳過）
```powershell
python -m venv .venv; .venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
python -m pytest -v --cov=app --cov-fail-under=70
```

## 2. VM bootstrap（重灌後才做一次，Linux）
```bash
minikube start
minikube kubectl -- get nodes -o wide          # Ready 才往下

# 裝 Argo CD（先讓叢集認識 kind: Application）
minikube kubectl -- create namespace argocd --dry-run=client -o yaml | minikube kubectl -- apply -f -
minikube kubectl -- apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
minikube kubectl -- wait --for=condition=Established crd/applications.argoproj.io --timeout=180s
minikube kubectl -- wait --for=condition=Available deployment --all -n argocd --timeout=300s

# 套用 Application
cd ~/0717-cicd-demo && git pull --ff-only
minikube kubectl -- apply -f argocd/application.yaml
minikube kubectl -- get applications -n argocd  # 期望 Synced / Healthy
```

## 3. 出新版本 demo loop（push-triggered，無 PR，以 v7 為例）
```bash
git switch main && git pull --ff-only origin main
# 改兩處 build marker： app/main.py 的 "build":"v7"  +  tests/test_main.py 的 == "v7"
python -m pytest -q
git add app/main.py tests/test_main.py          # 別用 git add .
git commit -m "feat: upgrade app to v7"
git push origin main                            # ← 這一 push 觸發整條 pipeline
```
到 GitHub Actions 確認：`test` ✅ → build/push GHCR ✅ → `gitops/k8s/deployment.yaml` image SHA 自動更新 ✅。

## 4. VM 驗證自動 CD
```bash
minikube kubectl -- get application cicd-demo -n argocd
minikube kubectl -- rollout status deployment/cicd-demo -n argocd --timeout=300s
minikube kubectl -- get deployment cicd-demo -n argocd \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
curl "http://$(minikube ip):30080/health"       # {"status":"ok"}
curl "http://$(minikube ip):30080/"             # 含 "build":"v7"，image 為新 commit SHA
```

## 5. Rollback（Argo self-heal 開著，必須改 Git，不能只 rollout undo）
```bash
git switch gitops && git pull --ff-only origin gitops
# 改 k8s/deployment.yaml image tag 回上一個健康 SHA
git commit -am "rollback: deploy <LAST_GOOD_SHA>" && git push origin gitops
```

---

## 常踩雷
- VM 命令漏 `--`：要 `minikube kubectl -- -n argocd get pods`。
- 部署用 immutable commit-SHA image tag，不是 `:v7`；別手改 deployment.yaml 繞過 pipeline。
- 本機 `gitops` 分支是舊快照，動它前先 `git fetch origin`。
- `app/main.py` 與 `tests/test_main.py` 的 build marker 必須同步改，否則 CI 紅。
