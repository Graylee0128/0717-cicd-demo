# 0717 CI/CD Demo

依照 [DevOps 綜合 Workshop](https://hackmd.io/@yillkid/S1llE_naZx) 建立的最小完整 pipeline：

```text
PR -> pytest -> merge main -> build image -> GHCR
   -> 更新 k8s image SHA -> ArgoCD sync -> K8s rolling update -> se218.net
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
- workflow：把 `k8s/deployment.yaml` 更新為不可變 SHA tag 並 push。
- ArgoCD：偵測 manifest commit，自動 sync、self-heal、prune。
- K8s：兩個 replica 搭配 readiness/liveness probe 做 rolling update。
- Nginx：把 `se218.net` 流量轉到 K8s NodePort `30080`。

## 需要你手動操作（一次性）

### 1. GitHub branch protection

Repo → **Settings → Branches → Add branch protection rule**：

- Branch name pattern：`main`
- 勾選 **Require status checks to pass before merging**
- Required check：`test`

完成後，故意讓 `tests/test_main.py` 斷言失敗並開 PR，確認紅燈時不能 merge；驗證後還原測試。

### 2. GHCR image 公開權限

第一次 main workflow 成功後，進入 GitHub 個人頁 → **Packages → 0717-cicd-demo → Package settings → Change visibility → Public**。否則 K8s 會出現 `ImagePullBackOff`；若必須保持 private，改在 cluster 建 `imagePullSecret`。

### 3. 在 se218.net 的 K8s 套用 ArgoCD Application

在能操作該 cluster 的主機執行：

```bash
kubectl get nodes
kubectl get pods -n argocd
kubectl apply -f argocd/application.yaml
kubectl get applications -n argocd
kubectl get pods -n cicd-demo -w
curl http://127.0.0.1:30080/health
```

如果尚未安裝 ArgoCD，先依 workshop 的「安裝 ArgoCD」章節完成安裝，再執行上面指令。

### 4. 修正 se218.net 的 Nginx upstream

2026-07-16 實測：DNS 指向 `114.37.200.155`、80/443 已開啟，但 HTTP 回 `504 Gateway Time-out`，HTTPS 憑證主體與 `se218.net` 不符。先確認 NodePort 健康，再在 Nginx 的 `se218.net` server block 設定：

```nginx
location / {
    proxy_pass http://127.0.0.1:30080;
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

如果 Nginx 與 K8s node 不在同一台主機，把 `127.0.0.1` 改成能連到該 NodePort 的 node IP。

### 5. 修正 HTTPS 憑證

確認 HTTP 已正常後，依主機既有憑證工具更新 `se218.net` 憑證；若既有環境使用 Certbot：

```bash
sudo certbot --nginx -d se218.net
curl https://se218.net/health
```

## 驗收

- [ ] PR 自動測試，紅燈不能 merge
- [ ] merge main 後 GHCR 同時有 SHA 與 latest tag
- [ ] `k8s/deployment.yaml` 自動換成該 commit SHA
- [ ] ArgoCD 顯示 `Synced / Healthy`
- [ ] `kubectl rollout status deployment/cicd-demo -n cicd-demo` 成功
- [ ] `https://se218.net/health` 回傳 `{"status":"ok"}`
