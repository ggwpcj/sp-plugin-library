# SP-谷歌网盘下载 上传部署手册（Deploy Handbook）

> **用途（必读）**：本手册是**发布/部署（打包、上传 GitHub Release、更新在线清单、提交 PR）的唯一权威步骤**。收录的是**经实测验收合格、SP 能正确检测并安装**的完整流程。
> 每次发布前必须先读：《铁律手册 Iron-Rules.md》（先看禁忌）+ 本手册（再按步骤执行）。
> 代码修改本身由《开发操作手册 DevOps-Handbook.md》负责，发布部署由本手册负责。

---

## 〇、本次发布前快照（模板表格，每轮复制一份填写）

```
发布轮次  : v1.4 第 3 轮（并行解析）→ 第 4 次上传
版本      : v1.4（不许升版本）
包名      : sp-gdrive-downloader-v1.4.pkg
期望sha256: <打完包装后填>
打包输出  : E:\yuanma\gugechajian-0905\release-v1.4-rX-rY（全新目录）
Release ID: 384015546（沿用）
旧asset ID: 549685100（本轮删除）
新asset ID: <上传后记录>
```

---

## 一、SP 在线更新机制与校验契约（部署铁律）

```
SP 校验：线上 lists.yaml 的 sha256 == 实际下载的 pkg 文件哈希
（包内自带的 lists.yaml 不参与 SP 校验）
```

**必须遵守的顺序（第 2 轮踩坑结论）：**
1. 先打包 → 得 pkg + 真实 sha256。
2. 上传 pkg（新版本=创建 Release；沿用版本=删旧 asset→重传同名）。
3. 远程下载 pkg → 验证 远程哈希 == 本地打包哈希 == 期望（三处一致）。
4. 把该**已验证哈希**写进线上 `lists.yaml` 的 `sha256`（**小写**），提交推送。
5. **写完哈希后禁止重打包**（哈希会变 → SP 校验失败）。

---

## 二、前置条件

1. Python 3.10+，`python` 可用。
2. 7-Zip：`C:\Program Files\7-Zip\7z.exe`。
3. Token：`E:\yuanma\gugechajian-0905\GITHUB_TOKEN.txt`（敏感，仅临时 remote/API 用，推后立即还原；绝不写入任何文件/提交/包/聊天）。
4. 源码仓库：`E:\yuanma\gugechajian-0905\谷歌网盘下载\` = `origin https://github.com/ggwpcj/sp-plugin-library.git`。
5. 商城 PR fork：`C:\Users\AOC\AppData\Local\Temp\opencode\pluginfork`（分支 `update-gdrive-v1.4`，对应 PR #3）。

---

## 三、完整部署步骤（按顺序执行，禁止跳步）

### 步骤 1：确认开发阶段已验收（哥哥）
回到《开发操作手册》勾完「四、验收清单」全项；源码已 commit。**未验收不发版。**

### 步骤 2：生成/核对源码校验（若代码改动）
```powershell
python -m py_compile "E:\yuanma\gugechajian-0905\谷歌网盘下载\worker\main.py"
python -m py_compile "E:\yuanma\gugechajian-0905\谷歌网盘下载\worker\gdrive.py"
python "C:\Users\AOC\AppData\Local\Temp\opencode\qmlcheck2.py"
python -c "import hashlib, os; base=r'E:\yuanma\gugechajian-0905\谷歌网盘下载';
for f in ['METADATA.yaml','ui/main.qml','worker/main.py','worker/gdrive.py']:
    h=hashlib.file_digest(open(os.path.join(base, f.replace('/','\\')),'rb'),'sha256').hexdigest().upper(); print(f, h)"
```
- 已改文件更新 `CHECKSUMS.yaml`；未改保留原哈希。
- **注意**：源码目录 `谷歌网盘下载\` 内不得有杂散文件（临时脚本/旧 md），否则 source_files 不符预期。

### 步骤 3：确认 lists.yaml 为待发布版本内容
编辑 `E:\yuanma\gugechajian-0905\谷歌网盘下载\lists.yaml`：
```yaml
- name: SP-谷歌网盘下载
  version: '1.4'
  package: https://github.com/ggwpcj/sp-plugin-library/releases/download/v1.4/sp-gdrive-downloader-v1.4.pkg
  sha256: <占位，步骤 8 再填真实哈希>
  author: ggwpcj
  introduction: <本次功能介绍>
```
> `version` 必须与 `METADATA.yaml` 的 `插件版本` 一致。

### 步骤 4：打包装（sp-plugin-packager）
```powershell
python "E:\yuanma\gugechajian-0905\sp-plugin-packager\package_plugin.py" `
  --source "E:\yuanma\gugechajian-0905\谷歌网盘下载" `
  --output "E:\yuanma\gugechajian-0905\release-v1.4-rX-rY" `
  --release-url "https://github.com/ggwpcj/sp-plugin-library/releases/download/v1.4" `
  --author "ggwpcj" `
  --introduction "<本次功能介绍>" `
  --seven-zip "C:\Program Files\7-Zip\7z.exe"
```
- `--output` 每次用**全新不存在的目录**（不存在否则 FileExistsError）。
- 记录输出 JSON：`file`、`sha256`、`bytes`、`source_files`。
- `source_files`：**7**（6 个发布文件 + 1）。**2026-09 起用户要求三个手册（DevOps-Handbook / Deploy-Handbook / Iron-Rules）也放源码目录 → source_files 基线=10**。每次打包以 `package-report.json` 实际输出的 `source_files` 为准记录，不做硬断言；但上传前必须确认包内多出的只有 3 个手册 md，别无杂散文件。
- verification 应含 `manifest, python-syntax, archive-round-trip, all-file-hashes`。

### 步骤 5：上传/替换 GitHub Release asset
```powershell
$token = (Get-Content -LiteralPath "E:\yuanma\gugechajian-0905\GITHUB_TOKEN.txt" -Raw).Trim()
$headers = @{ Authorization = "token $token"; Accept = "application/vnd.github+json" }
# 沿用版本 → 先删旧 asset
Invoke-RestMethod -Method Delete -Uri "https://api.github.com/repos/ggwpcj/sp-plugin-library/releases/assets/<旧ASSET_ID>" -Headers $headers
# 上传新包
$uploadUrl = "https://uploads.github.com/repos/ggwpcj/sp-plugin-library/releases/<RELEASE_ID>/assets?name=sp-gdrive-downloader-v1.4.pkg"
$data = [System.IO.File]::ReadAllBytes("E:\yuanma\gugechajian-0905\release-v1.4-rX-rY\sp-gdrive-downloader-v1.4.pkg")
$resp = Invoke-RestMethod -Method Post -Uri $uploadUrl -Headers $headers -ContentType "application/octet-stream" -Body $data
# 记录 $resp.id（新 asset id）
```
> 新版本首次发布：用 `Invoke-RestMethod -Method Post` 创建 Release（tag_name=name=vX.Y），再上传 asset。

### 步骤 6：远程下载验证哈希（必做，HASH_MATCH）
```powershell
Invoke-WebRequest -Uri "https://github.com/ggwpcj/sp-plugin-library/releases/download/v1.4/sp-gdrive-downloader-v1.4.pkg" -OutFile "C:\Users\AOC\AppData\Local\Temp\opencode\remote-v1.4.pkg"
$remote = (Get-FileHash -LiteralPath "C:\Users\AOC\AppData\Local\Temp\opencode\remote-v1.4.pkg" -Algorithm SHA256).Hash
$local  = (Get-FileHash -LiteralPath "E:\yuanma\gugechajian-0905\release-v1.4-rX-rY\sp-gdrive-downloader-v1.4.pkg" -Algorithm SHA256).Hash
# 要求: $remote -eq $local -eq 步骤4 的 sha256
```

### 步骤 7：提交并推送源码（含 CHECKSUMS.yaml、lists.yaml 占位）
```powershell
git -C "E:\yuanma\gugechajian-0905\谷歌网盘下载" add .
git -C "E:\yuanma\gugechajian-0905\谷歌网盘下载" commit -m "<说明>"

$token = (Get-Content -LiteralPath "E:\yuanma\gugechajian-0905\GITHUB_TOKEN.txt" -Raw).Trim()
git -C "E:\yuanma\gugechajian-0905\谷歌网盘下载" remote set-url origin "https://x-access-token:$token@github.com/ggwpcj/sp-plugin-library.git"
git -C "E:\yuanma\gugechajian-0905\谷歌网盘下载" push origin main
git -C "E:\yuanma\gugechajian-0905\谷歌网盘下载" remote set-url origin "https://github.com/ggwpcj/sp-plugin-library.git"
Write-Output "REMOTE_RESTORED"
```

### 步骤 8：把验证哈希写进 lists.yaml 并推送（关键，漏掉 SP 检测不到）
编辑 `lists.yaml` 的 `sha256:` 为步骤 6 的**小写**哈希（64 位），再次 git 提交推送 + 抓 raw 验证：
```powershell
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/ggwpcj/sp-plugin-library/main/lists.yaml" -OutFile "C:\Users\AOC\AppData\Local\Temp\opencode\my-lists.yaml"
# 确认 raw 内容：version=1.4 且 sha256=新哈希
```
> 顺序注意：先步骤 4 打包 → 上传 → 验证 → **最后**填哈希。填完哈希后**不再重打包**（铁律 R-1）。

### 步骤 9：同步商城 PR #3 分支（fork）
```powershell
# 工作目录 C:\Users\AOC\AppData\Local\Temp\opencode\pluginfork，分支 update-gdrive-v1.4
# 将本地 lists.yaml 的（version/package/sha256/introduction）同步到 fork 的 lists.yaml
# 在 fork 内: git commit → token push 到 update-gdrive-v1.4
# 确认 PR #3 mergeable=clean（head 更新为最新提交）
```

### 步骤 10：SP 端验证
- SP 自定义清单源已指向 `https://raw.githubusercontent.com/ggwpcj/sp-plugin-library/main/lists.yaml`。
- 刷新/检查更新 → 应检测到 v1.4 且能安装。
- 若仍旧版：查 raw 是否更新（缓存可能延迟）；勿动 `spworker2026/plugins`。

---

## 四、部署验收清单（每次全过）

- [ ] 代码已 py_compile/qmlcheck 通过；CHECKSUMS.yaml 已同步
- [ ] lists.yaml 为待发布版本内容（哈希占位已预留）
- [ ] pkg 已打包：source_files 符合预期（7 或 10），verification 全过
- [ ] Release/asset 上传或替换完成（记录新 asset id）
- [ ] 远程下载哈希 == 本地 == 期望（HASH_MATCH）
- [ ] 源码已 push；token remote 已还原
- [ ] lists.yaml sha256 已写入并 push；raw 已确认
- [ ] PR #3 分支已同步、mergeable=clean
- [ ] SP 自测通过
- [ ] 手册已同步更新（DevOps 手册「六、修改记录」+ 部署快照 + 铁律）

---

## 五、版本历史（结合开发手册六）

- v1.0：初始发布（官方总目录收录）
- v1.1：树形目录浏览
- v1.2：连接池、检索深度、目录存储、表格交互、线路——官方 PR #1（open）
- v1.4 第 1 轮：解析提速（分页+直链）——首包 df03c52d（已被替代）
- v1.4 第 2 轮：移除链接池——上线 0b5c26，asset 549685100，PR #3 head c229e1e（open）
- v1.4 第 3 轮：并行解析——**本轮待发布**（逐步 9 后补录结果）