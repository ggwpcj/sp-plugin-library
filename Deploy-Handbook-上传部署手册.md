# SP-谷歌网盘下载 上传部署手册（Deploy Handbook）

> **用途（必读）**：本手册是**发布/部署（打包、上传 GitHub Release、更新在线清单、提交 PR）的唯一权威步骤**。收录的是**经实测验收合格、SP 能正确检测并安装**的完整流程。
> 每次发布前必须先读：《铁律手册 Iron-Rules.md》（先看禁忌）+ 本手册（再按步骤执行）。
> 代码修改本身由《开发操作手册 DevOps-Handbook.md》负责，发布部署由本手册负责。

---

## 〇、本次发布前快照（模板表格，每轮复制一份填写）

```
发布轮次  : v1.4 第 3 轮（并行解析）→ 第 4 次上传 ✅ 2026-09 已完成
版本      : v1.4（不许升版本）
包名      : sp-gdrive-downloader-v1.4.pkg
sha256    : c7c01c8fad7540705711f3e810b5350af59149a03181718c3971cd513021a429 ✅
打包输出  : E:\yuanma\gugechajian-0905\release-v1.4-r4（全新目录）
Release ID: 384015546
旧asset ID: 549685100（已删）
新asset ID: 551686576 ✅
SAULT : source_files=10（含 3 手册）
推送    : 源码 8c3d285；PR #3 分支 a919000（open，待上游合并）
```

```
发布轮次  : v1.4 第 4 轮（表格交互修复：勾选框/单击折叠/双击进入）→ 第 5 次上传 ✅ 2026-09 已完成
版本      : v1.4（不许升版本）
包名      : sp-gdrive-downloader-v1.4.pkg
sha256    : e8bfaf0b6348f5220e3da252dd1c2ca865bdca3ce869e4cbe1817e729e1899ed ✅
打包输出  : E:\yuanma\gugechajian-0905\release-v1.4-r5（全新目录）
Release ID: 384015546
旧asset ID: 551686576（已删）
新asset ID: 552339492 ✅
SAULT : source_files=10（含 3 手册）
推送    : 源码 39c3f87→6f0ecdf；PR #3 分支 fcc9197（open，待上游合并）
```

```
发布轮次  : v1.5 重发（补最低SP版本+目录契约字段；排除cache产物）✅ 2026-09 已完成
版本      : v1.5
包名      : sp-gdrive-downloader-v1.5.pkg
sha256    : d0624f6326bd79e4a2476c3f46f55798aaaaecb46a4869c49352909979565c37 ✅
打包输出  : C:\SPdrive-buildw\pkg-v1.5-r2（新打包器，5项校验全过含plugin-api-capabilities）
Release ID: 388129300
新asset ID: 563356585 ✅（562469028 已删；旧sha 3e4c7339 作废）
SAULT : source_files=12（含 3 手册 + GDriveFileTable.qml + .sp-package-ignore；不含 cache/sqlite 产物）
推送    : 源码 20b46fb；PR #4 分支 bf5c9c7（open，待上游合并）
```

```
发布轮次  : v1.6 第 1 轮（勾选文件夹一键递归下载整个文件夹）✅ 2026-09 已完成
版本      : v1.6
包名      : sp-gdrive-downloader-v1.6.pkg
sha256    : f40d3defb23db9b4ce2e79300d5f10e9e3b3259919ae8fc023744130ac81a744 ✅
打包输出  : C:\SPdrive-buildw\pkg-v1.6-r1（新打包器，5项校验全过含plugin-api-capabilities）
Release ID: 395527811
新asset ID: 585613860 ✅ HASH_MATCH=YES
SAULT : source_files=12（新打包器 package-report.json：sha f40d3def…a744，36430B）
推送    : 源码 55eb759（功能+手册）→ 6887236（lists.yaml 落库）；PR #4 分支 310fd28（open，待上游合并）
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
5. 商城 PR fork：`C:\SPdrive-buildw\pluginfork`（分支 `update-gdrive-v1.x`，对应 PR #4）。**注意：pluginfork 是插件专用的编译/发布工作区（产物统一存放于 `C:\SPdrive-buildw\`），若已被清理则发布前需重新 clone fork**：`git -C C:\SPdrive-buildw clone https://github.com/ggwpcj/plugins.git pluginfork`（origin 指向 fork `ggwpcj/plugins`，勿指向上游 `spworker2026/plugins`，见铁律 F-09）。

---

## 三、完整部署步骤（按顺序执行，禁止跳步）

### 步骤 1：确认开发阶段已验收（哥哥）
回到《开发操作手册》勾完「四、验收清单」全项；源码已 commit。**未验收不发版。**

### 步骤 2：生成/核对源码校验（若代码改动）
```powershell
python -m py_compile "E:\yuanma\gugechajian-0905\谷歌网盘下载\worker\main.py"
python -m py_compile "E:\yuanma\gugechajian-0905\谷歌网盘下载\worker\gdrive.py"
python "C:\SPdrive-buildw\qmlcheck2.py" "E:\yuanma\gugechajian-0905\谷歌网盘下载\ui\main.qml"
python -c "import hashlib, os; base=r'E:\yuanma\gugechajian-0905\谷歌网盘下载';
for f in ['METADATA.yaml','ui/main.qml','worker/main.py','worker/gdrive.py']:
    h=hashlib.file_digest(open(os.path.join(base, f.replace('/','\\')),'rb'),'sha256').hexdigest().upper(); print(f, h)"
```
- 已改文件更新 `CHECKSUMS.yaml`；未改保留原哈希。
- **注意**：源码目录内的 `cache/` 是运行数据，可能含用户访问过的目录信息。保留 `.gitignore` 和 `.sp-package-ignore`，提交前确认 Git 未跟踪 `cache/`，打包后确认归档不含 `cache/`；临时脚本和凭据同样不得入包。

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
  --output "C:\SPdrive-buildw\pkg-vX.Y-rN" `
  --release-url "https://github.com/ggwpcj/sp-plugin-library/releases/download/vX.Y" `
  --author "ggwpcj" `
  --introduction "<本次功能介绍>" `
  --seven-zip "C:\Program Files\7-Zip\7z.exe"
```
- `--output` 每次用**全新不存在的目录**（不存在否则 FileExistsError）。
- 记录输出 JSON：`file`、`sha256`、`bytes`、`source_files`。
- `source_files` 以 `package-report.json` 的实际清单为准，不沿用旧版 7/10 的固定数量。三个手册和 `.sp-package-ignore` 是预期文件；逐项核对包内没有 `cache/`、凭据、临时测试文件或下载产物。
- verification 应含 `manifest, plugin-api-capabilities, python-syntax, archive-round-trip, all-file-hashes`（新打包器）。
- **新打包器（2026-09 维护者更新后）必查**：打包前确认 `METADATA.yaml` 含 `最低SP版本`（API1→`3.0-beta-1`、API2→`3.0-beta-2`、API3→`3.0-beta-3`，且 API1 不得填晚于 `3.0-beta-1` 的值）；所有 `spPlugin.*` 与 QML 组件必须在 API 合约已登记能力内，否则打包直接失败 `Missing manifest field`/`unregistered spPlugin capability`。`source_files` 以 `package-report.json` 为准；逐项核对包内没有 `cache/`、凭据、临时测试文件或下载产物（`cache/folders.sqlite3` 曾混入 v1.5-r1，由 `.sp-package-ignore` 排除）。`--release-url` 必须是固定版本 HTTPS 目录、不带 latest/凭据/查询参数。

### 步骤 5：上传/替换 GitHub Release asset
```powershell
$token = (Get-Content -LiteralPath "E:\yuanma\gugechajian-0905\GITHUB_TOKEN.txt" -Raw).Trim()
$headers = @{ Authorization = "token $token"; Accept = "application/vnd.github+json" }
# 沿用版本 → 先删旧 asset
Invoke-RestMethod -Method Delete -Uri "https://api.github.com/repos/ggwpcj/sp-plugin-library/releases/assets/<旧ASSET_ID>" -Headers $headers
# 上传新包
$uploadUrl = "https://uploads.github.com/repos/ggwpcj/sp-plugin-library/releases/<RELEASE_ID>/assets?name=sp-gdrive-downloader-v1.5.pkg"
$data = [System.IO.File]::ReadAllBytes("E:\yuanma\gugechajian-0905\谷歌网盘下载\..\release-vX.Y-rZ\sp-gdrive-downloader-v1.5.pkg")
$resp = Invoke-RestMethod -Method Post -Uri $uploadUrl -Headers $headers -ContentType "application/octet-stream" -Body $data
# 记录 $resp.id（新 asset id）
```
> 新版本首次发布：用 `Invoke-RestMethod -Method Post` 创建 Release（tag_name=name=vX.Y），再上传 asset。

### 步骤 6：远程下载验证哈希（必做，HASH_MATCH）
```powershell
Invoke-WebRequest -Uri "https://github.com/ggwpcj/sp-plugin-library/releases/download/vX.Y/sp-gdrive-downloader-v1.5.pkg" -OutFile "C:\SPdrive-buildw\remote-v1.5.pkg"
$remote = (Get-FileHash -LiteralPath "C:\SPdrive-buildw\remote-v1.5.pkg" -Algorithm SHA256).Hash
$local  = (Get-FileHash -LiteralPath "<打包输出目录>\sp-gdrive-downloader-v1.5.pkg" -Algorithm SHA256).Hash
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
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/ggwpcj/sp-plugin-library/main/lists.yaml" -OutFile "C:\SPdrive-buildw\my-lists.yaml"
# 确认 raw 内容：version=1.4 且 sha256=新哈希
```
> 顺序注意：先步骤 4 打包 → 上传 → 验证 → **最后**填哈希。填完哈希后**不再重打包**（铁律 R-1）。

### 步骤 9：同步商城 PR #4 分支（fork）
```powershell
# 工作目录 C:\SPdrive-buildw\pluginfork，分支 update-gdrive-v1.x（PR #4）
# 若临时目录已被清理，先重新 clone fork：git clone https://github.com/ggwpcj/plugins.git pluginfork（见 F-09）
# 可先 rebase 到 upstream/main（避免 PR 冲突），再将本地 lists.yaml 的（version/package/sha256/introduction）同步到 fork 的 lists.yaml
# 在 fork 内: git commit → token push 到 update-gdrive-v1.x
# 确认 PR #4 mergeable=YES（head 更新为最新提交）
```

### 步骤 9b：回填手册真实发布数字（必做，漏了会留占位符——见 F-14）
在拿到 Release/asset/PR head 的**当下**立即编辑三本手册，把所有 `<部署后回填>`/`<提交号>`/`<head>` 占位符替换为真实值：
```powershell
# 1. Deploy-Handbook：本次发布快照框（sha256/打包输出/Release ID/新asset ID/推送/PR head）+ 版本历史 v1.x 行
# 2. DevOps-Handbook：「六、修改记录」新条目 状态行（sha/asset id/提交号/PR head）
# 3. Iron-Rules：R-2 当前版本号、自检清单版本/PR 引用
git add -A; git commit -m "手册回填 vX.Y 发布数字（sha/Release/asset/PR head）"
# token push main → 还原 remote（见步骤 7 的 remote set-url 还原）
```
> 铁律：占位符换成真实值必须趁数据还热时做；三本手册都回填完再宣布发布完成。

### 步骤 10：SP 端验证
- SP 自定义清单源已指向 `https://raw.githubusercontent.com/ggwpcj/sp-plugin-library/main/lists.yaml`。
- 刷新/检查更新 → 应检测到 v1.4 且能安装。
- 若仍旧版：查 raw 是否更新（缓存可能延迟）；勿动 `spworker2026/plugins`。

---

## 四、部署验收清单（每次全过）

- [ ] 代码已 py_compile/qmlcheck 通过；CHECKSUMS.yaml 已同步
- [ ] 实际 SP 中验证长目录路径可滚轮横移、点击各级目录有效、到边界后外层页面仍可滚动
- [ ] lists.yaml 为待发布版本内容（哈希占位已预留）
- [ ] pkg 已打包：逐项核对文件清单不含 `cache/` 等运行数据，verification 全过
- [ ] Release/asset 上传或替换完成（记录新 asset id）
- [ ] 远程下载哈希 == 本地 == 期望（HASH_MATCH）
- [ ] 源码已 push；token remote 已还原
- [ ] lists.yaml sha256 已写入并 push；raw 已确认
- [ ] PR #4 分支已同步、mergeable=YES
- [ ] SP 自测通过
- [ ] 手册已同步更新（DevOps 手册「六、修改记录」+ 部署快照 + 铁律），发布数字已回填**非占位符**（步骤 9b）

---

## 五、版本历史（结合开发手册六）

- v1.0：初始发布（官方总目录收录）
- v1.1：树形目录浏览
- v1.2：连接池、检索深度、目录存储、表格交互、线路——官方 PR #1（open）
- v1.4 第 1 轮：解析提速（分页+直链）——首包 df03c52d（已被替代）
- v1.4 第 2 轮：移除链接池——上线 0b5c26，asset 549685100，PR #3 head c229e1e（open）
- v1.5 第 1 轮：勾选文件夹一键递归下载整个文件夹——**已发布**（sha d0624f63，asset 563356585，PR #4 head bf5c9c7 open，待上游合并）
- v1.6 第 1 轮：勾选文件夹一键递归下载整个文件夹（collectFolderFiles 重写，下载阶段文件夹递归展开）——**已发布**（sha f40d3def，asset 585613860，PR #4 head 310fd28 open，待上游合并）
