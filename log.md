# 0717 CI/CD 操作錯誤與除錯紀錄

## 1. 文件目的

本文件記錄 `0717-cicd-demo` 實作期間實際發生的環境、Git、Pull Request、CI/CD 與 Argo CD 操作問題，包含：

- 畫面上看到的錯誤或異常狀態。
- 真正原因。
- 當時採取的修復方式。
- 下次可直接照做的正確步驟。

敏感資訊（Argo CD 密碼、GitHub token、SSH private key）不記錄在本文件中。

## 2. 最終成功狀態

- Repository：`Graylee0128/0717-cicd-demo`
- Kubernetes namespace：統一使用既有的 `argocd`
- 成功版本：V6
- 成功 PR：[PR #8](https://github.com/Graylee0128/0717-cicd-demo/pull/8)
- PR 測試：成功
- 合併後 CI/CD：[Actions run 29554626916](https://github.com/Graylee0128/0717-cicd-demo/actions/runs/29554626916) 成功
- GitOps image：`ghcr.io/graylee0128/0717-cicd-demo:b935e700cfe161c5f717b5d38227126af66d87f6`

## 3. 錯誤紀錄

### 3.1 Argo CD `Application` CRD 尚未安裝

錯誤畫面：

```text
resource mapping not found for name: "cicd-demo" namespace: "argocd"
no matches for kind "Application" in version "argoproj.io/v1alpha1"
ensure CRDs are installed first
```

原因：

- `argocd/application.yaml` 使用的是 Argo CD 自訂資源 `Application`。
- Kubernetes 尚未安裝 Argo CD CRD，因此無法辨識 `kind: Application`。

修復：

```bash
minikube kubectl -- apply --server-side -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

minikube kubectl -- wait --for=condition=Established \
  crd/applications.argoproj.io --timeout=180s

minikube kubectl -- apply -f argocd/application.yaml
```

預防方式：先確認 CRD，再套用 Application。

```bash
minikube kubectl -- get crd applications.argoproj.io
```

### 3.2 系統找不到 `kubectl`

錯誤畫面：

```text
Command 'kubectl' not found
```

原因：VM 沒有獨立安裝 `kubectl`，但 Minikube 已提供內建 kubectl。

錯誤命令：

```bash
minikube kubectl -n argocd get pods
```

這會讓 Minikube 自己解析 `-n`，產生：

```text
unknown shorthand flag: 'n' in -n
```

正確命令：

```bash
minikube kubectl -- -n argocd get pods
```

關鍵是 `--`：它會把後面的參數交給 kubectl。

### 3.3 Argo CD 初始密碼出現在終端或截圖

問題：查詢初始 admin 密碼後，密碼曾直接顯示在終端畫面中。

風險：若截圖、聊天紀錄或文件被分享，其他人可能取得管理權限。

處理方式：

1. 不將密碼寫進 Git、Markdown 或截圖。
2. 登入 Argo CD 後立即至使用者設定更新密碼。
3. 若密碼曾公開，視為已洩漏並立刻更換。

### 3.4 `git commit` 缺少 `-m`

錯誤命令：

```bash
git commit "V3"
```

錯誤訊息：

```text
error: pathspec 'V3' did not match any file(s) known to git
```

原因：Git 把 `V3` 當成檔案路徑，而不是 commit message。

正確命令：

```bash
git commit -m "feat: upgrade app to v3"
```

### 3.5 Git 作者身分未設定

錯誤訊息：

```text
Author identity unknown
fatal: unable to auto-detect email address
```

原因：VM 尚未設定 Git commit 使用者名稱與 email。

修復：

```bash
git config --global user.name "Graylee0128"
git config --global user.email "125956961+Graylee0128@users.noreply.github.com"
```

驗證：

```bash
git config --global user.name
git config --global user.email
```

### 3.6 每次 HTTPS push 都要求 GitHub 帳號

症狀：

```text
Username for 'https://github.com':
```

原因：Git remote 仍使用 HTTPS，且 VM 沒有可重用的 GitHub credential。

採用的修復方式：改用 SSH。

```bash
ssh-keygen -t ed25519 -C "gray@se218"
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
cat ~/.ssh/id_ed25519.pub
```

將完整 public key 加到 GitHub SSH keys 後驗證：

```bash
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -T git@github.com
```

最後修改 remote：

```bash
git remote set-url origin git@github.com:Graylee0128/0717-cicd-demo.git
git remote -v
```

注意：只能上傳 `.pub` public key，不能分享 `~/.ssh/id_ed25519` private key。

### 3.7 使用 `git add .` 誤加無關檔案

錯誤操作：

```bash
git add .
```

因此 V5 PR 曾包含下列與本次 CI/CD 版本修改無關的檔案：

```text
argocd-pf.log
deploy-elk-dai.sh
docker-compose.yml
logstash/config/logstash.yml
logstash/pipeline/logstash.conf
```

影響：

- PR 出現 436 行無關變更。
- 增加 review 難度。
- log 可能包含環境資訊。
- 但這些是新增檔案，不是本次 merge conflict 的直接原因。

正確方式：只加入本次真正修改的檔案。

```bash
git add app/main.py tests/test_main.py
git diff --cached
```

若已經誤 stage，可先取消 staging；檔案內容不會被刪除。

```bash
git restore --staged .
git add app/main.py tests/test_main.py
```

### 3.8 PR 方向開反

錯誤 PR #4：

```text
base: feat/v3  ←  compare: main
```

這代表把 `main` 合併進 `feat/v3`，不是把 V3 合併進 `main`。

結果：

- PR #4 雖然顯示 merged，但 `main` 仍是 V2。
- 後續 PR #5 沒有可部署的 V3 差異。
- 「Merge 成功」不等於「功能分支已進 main」，仍需確認 base 與 compare。

正確方向：

```text
base: main  ←  compare: feat/v3
```

GitHub 畫面應理解為：把右邊 compare 分支的內容送進左邊 base 分支。

### 3.9 從過期的 main 建立功能分支

當時狀態：

```text
main:    v1 → v2
feat/v5: v1 → v5
```

原因：建立 `feat/v5` 前沒有先切回 `main` 並 pull 最新版本。

兩個分支都修改相同兩行：

- `app/main.py` 的 build marker。
- `tests/test_main.py` 的預期 build marker。

Git 無法自行判斷應保留 V2 或 V5，因此 PR #6 顯示 merge conflict。

正確順序：

```bash
git switch main
git pull --ff-only origin main
git status --short
git switch -c feat/v5
```

只有確認 working tree 乾淨、main 最新後，才能建立下一版分支。

### 3.10 Merge conflict 與 CI failure 被混為一談

PR #6 的實際狀況：

- GitHub 顯示 merge conflict。
- 沒有新的 Actions checks。
- 這不是 pytest 執行後失敗，而是 GitHub 無法先產生 PR merge commit。

判讀方式：

- `test: failure`：CI 已經執行，但測試失敗。
- `CONFLICTING`／`DIRTY`：分支無法合併，先處理 Git 衝突。
- `no checks reported`：檢查可能尚未觸發，不能直接判定為測試失敗。

### 3.11 把 PR 階段的 CD job `skipped` 當成失敗

PR #5 當時顯示：

```text
test                         pass
build-and-update-manifest    skipped
```

這是正常設計：

- Pull Request：只跑測試。
- 合併並 push 到 `main`：才 build image、push GHCR、更新 `gitops` manifest。

因此 PR 中的 CD job `skipped` 不是 failure。真正需要確認的是 `test` 是否通過。

### 3.12 修 V5 時，main 已經前進到 V6

處理 V5 conflict 期間，PR #8 已成功把 V6 合併進 `main`。

此時狀態變成：

```text
main:          v6
舊 V5 branch: v5
```

後續再合併 V5 會造成降版，因此 V5 PR 已失去必要性。PR #6 與清理用 PR #9 最後均關閉。

教訓：修 conflict 前、push 前、按 Merge 前，都應再次確認遠端 main 是否有新 commit。

```bash
git fetch origin
git log --oneline --decorate --graph -10 --all
```

### 3.13 歷史 CI 紅燈是刻意建立的失敗範例

[Actions run 29478761936](https://github.com/Graylee0128/0717-cicd-demo/actions/runs/29478761936) 的錯誤：

```text
assert response.status_code == 999
E assert 200 == 999
```

這是 `demo/ci-failure` 分支刻意把正確的 HTTP 200 寫成 999，用來證明 CI 能阻擋錯誤程式碼，不是 V6 的實際故障。

### 3.14 App build marker 與 container image tag 混淆

`"build": "v6"` 是 API 回應中的展示版本；正式部署使用的是 immutable Git commit SHA image tag，例如：

```text
ghcr.io/graylee0128/0717-cicd-demo:b935e700cfe161c5f717b5d38227126af66d87f6
```

不需要手動建立或部署 `:v6` image，也不應手動修改 `k8s/deployment.yaml` 來繞過 pipeline。

正確流程是：合併 main 後，由 GitHub Actions build SHA image 並更新 `gitops` branch，Argo CD 再自動同步。

## 4. 最終正確操作 SOP

以下以建立 V7 為例。

### Step 1：同步最新 main

```bash
cd ~/0717-cicd-demo
git switch main
git pull --ff-only origin main
git status --short
```

`git status --short` 應沒有輸出。

### Step 2：從最新 main 建立分支

```bash
git switch -c feat/v7
git branch --show-current
```

預期目前分支：

```text
feat/v7
```

### Step 3：同時修改程式與測試

`app/main.py`：

```python
return {"service": "0717-cicd-demo", "version": VERSION, "build": "v7"}
```

`tests/test_main.py`：

```python
assert response.json()["build"] == "v7"
```

### Step 4：本機檢查並選擇性 stage

```bash
python -m pytest -q
git status --short
git add app/main.py tests/test_main.py
git diff --cached
```

確認 diff 只有兩個檔案。

### Step 5：Commit 與 push

```bash
git commit -m "feat: upgrade app to v7"
git push -u origin feat/v7
```

### Step 6：建立正確方向的 PR

```text
base: main  ←  compare: feat/v7
```

建立 PR 後等待 `test` 通過。`build-and-update-manifest` 在 PR 階段顯示 skipped 是正常的。

### Step 7：合併前再次檢查 main

確認 PR 顯示：

- `Able to merge` 或 `MERGEABLE`。
- `test` 綠燈。
- Files changed 只有預期檔案。

然後才能按 `Merge pull request`。

### Step 8：確認 main CI/CD

合併後到 GitHub Actions 確認 main workflow：

1. pytest 成功。
2. image build/push 成功。
3. `gitops/k8s/deployment.yaml` image SHA 更新成功。

### Step 9：在 Minikube VM 驗證 CD

```bash
minikube kubectl -- get application cicd-demo -n argocd

minikube kubectl -- rollout status deployment/cicd-demo \
  -n argocd --timeout=300s

minikube kubectl -- get deployment cicd-demo -n argocd \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

curl "http://$(minikube ip):30080/health"
curl "http://$(minikube ip):30080/"
```

預期：

- Argo CD Application 為 `Synced`／`Healthy`。
- Deployment rollout 成功。
- image 為本次 main commit SHA。
- `/health` 回傳 `{"status":"ok"}`。
- `/` 回傳本次 build marker。

## 5. 操作前快速檢查表

- [ ] 目前位於 repo 根目錄。
- [ ] `main` 已執行 `git pull --ff-only origin main`。
- [ ] 功能分支從最新 main 建立。
- [ ] 程式與測試的 build marker 一致。
- [ ] 使用選擇性 `git add`，沒有使用 `git add .`。
- [ ] `git diff --cached` 只有預期檔案。
- [ ] PR 方向是 `feature → main`。
- [ ] PR test 通過。
- [ ] 合併前再次確認 main 沒有前進。
- [ ] main workflow 成功更新 GitOps image SHA。
- [ ] Argo CD 已同步，VM API 顯示新版本。
