# SP-谷歌网盘下载 铁律手册（Iron Rules）

> **用途（每次执行前必读）**：本手册收录**历次踩过的失败教训与不可违反的铁律**。开发前/发布前第一件事就是读本手册。凡是"错误 → 教训 → 正确做法"的经验，统一收纳于此，绝不遗漏。

---

## 铁律总表

| 编号 | 铁律 | 说明/后果 |
| --- | --- | --- |
| R-1 | **写完 lists.yaml 的 sha256 后禁止重打包** | SP 校验线上 lists.yaml sha256 == 实际 pkg 哈希；重打包哈希会变 → 校验失败 → SP 检测不到。 |
| R-2 | **版本号不许擅自递增** | 当前 v1.8（2026-10 用户明确同意升版，新增下载完成提示层）。自 v1.5 起每轮功能修复均需用户同意升版。改版本需用户同意；三个文件（METADATA/lists.yaml/CHECKSUMS.yaml）版本必须一致。**已实际安装过的版本不要用同版本号覆盖重发**——SP 可能判定"无需更新"；确需覆盖时必须提醒用户清更新缓存。 |
| R-3 | **sha256 一律小写** | lists.yaml 写大写哈希 → SP 校验不匹配。 |
| R-4 | **禁止"每文件/每文件夹串行请求"做列表/树** | 5000 文件=5000 请求→几分钟→超 300s 前端上限→"解析失败"。必须并行。 |
| R-5 | **禁止递归嵌套线程池** | 外层线程池每个 worker 再开线程池 → 并发满时死锁 + 线程爆炸。改用**广度优先 + 单一线程池**（BFS）。 |
| R-6 | **真实并发在途 HTTP 必须限流** | 不加信号量，树+分页嵌套可打到 64 并发 → 对 Google/宿主洪峰。用 `threading.BoundedSemaphore(8)` 包 `context.request`。 |
| R-7 | **git remote 带 token 推送后立即还原** | token 泄入 origin 是安全事故。推完回设 `https://github.com/...`。 |
| R-8 | **token 绝不写入文件/提交/包/聊天** | 只存在于 `E:\yuanma\gugechajian-0905\GITHUB_TOKEN.txt` 临时读取。 |
| R-9 | **临时/杂散文件禁止留源码目录** | test*.py、旧手册 md、.pyc 等进包 → source_files 变化、哈希漂移。临时脚本放 `C:\SPdrive-buildw\`（插件编译/发布专用目录，产物统一存放于此，勿放公有 Temp）。 |
| R-10 | **打包 --output 必须用全新不存在目录** | 打包器拒绝覆盖（FileExistsError）。 |
| R-11 | **改动必须先在本地验收（py_compile/qmlcheck/单测）再提交** | 跳过验收的发布 = 无效发布或破坏其他源码。 |
| R-12 | **改完同步更新三个手册** | 正确步骤补进开发手册；新教训补进铁律手册。保证"步骤不遗漏、教训全记录"。 |
| R-13 | **发布后必须远程下载验证哈希（HASH_MATCH）** | 不验证=可能已损坏/上传错文件。 |
| R-14 | **不要修改 spworker2026/plugins 仓库** | 无写权限，只能通过 PR 合并（当前 PR #4）；官方目录未合并前 SP 默认源看不到新版。 |
| R-15 | **PowerShell 内联 python -c 写正则会报 cmdlet 错误** | 校验逻辑写成独立 .py 文件再执行（qmlcheck2.py 模式）。 |
| R-16 | **QML append/push 块键必须齐全** | 缺键（rowId name size type downloadUrl checked depth hasChildren expanded entry/path）→ 行不渲染/崩溃。 |
| R-17 | **mock 测试页必须用真实 HTML 结构**（`flip-entry` id、`file/d/`、`drive/folders/`） | 结构不对 → 正则不匹配 → 测试假通过/假失败。 |
| R-18 | **超时上限是前端 `spPlugin.call` 第三参数 ≤300000ms** | 超过 → 前端报"解析失败"，与后端无关。给足超时 + 后端并行提速双管齐下。 |
| R-19 | **同一文件夹 id 只解析一次（循环目录守卫）** | Drive 目录理论上无环，但自指/软链/同名会死循环爆请求。用 node_by_id 去重。 |
| R-20 | **改代码前必须先读三个手册（开发/部署/铁律）** | 防止凭记忆破坏正常源码。 |
| R-21 | **超宽路径的滚轮只由路径视口接管** | `Flickable.HorizontalFlick` 仅保证拖拽，不会自动把竖向鼠标滚轮变成横向滚动；只在内容可移动时消费滚轮，边界透传，不能覆盖目录点击和固定图标按钮。 |
| R-22 | **新打包器契约（维护者更新后）**：`METADATA.yaml` 必须含 `最低SP版本`（API1→`3.0-beta-1`、API2→`3.0-beta-2`、API3→`3.0-beta-3`，API1 不得填晚于 `3.0-beta-1`）；全部 `spPlugin.*`/QML 组件必须在 API 合约登记（缺失报 `Missing manifest field`/`unregistered spPlugin capability`）；在线 lists.yaml 条目必须含 `api_version`+`minimum_sp_version` 且与包内一致；打包禁用 `cache/`（sqlite 产物曾混入 v1.5-r1）。 |
| R-23 | **`open?id=` 等歧义分享链接不得靠 URL 形态猜类型** | `https://drive.google.com/open?id=ID` 对文件和文件夹都合法，页面标题也会误导。必须轻量请求（≤256KiB）跟随 302，用**响应的最终 URL** 判定 file/folder；不要用文件名 `[]`、ID 含 `-`/`_` 之类的表象猜类型。 |
| R-24 | **下载直链必须带 `confirm=t`；HTTP 200 不等于下载成功** | 加密/分卷压缩包（`.7z`/`.rar`/分卷 `.zip` 等）在 `export=download` 时返回 200 + `text/html` 的病毒扫描确认页，宿主会存下 HTML。**所有**下载直链统一带 `confirm=t`（用幂等的 `with_download_confirm()` 收口，不要各处手拼）。校验下载链路必须同时看 `Content-Type` 与首字节。 |
| R-25 | **状态必须有出口：计数要渲染、信号要兜底、提示要合并** | "下载完成无任何提示"不是少写一行 toast，而是三个独立缺陷叠加：①`finishedCount`/`failedCount` 只累加、**页面上没有任何地方渲染**，等于白算；②`onDownloadProgress` 里 `queueByTask` 查不到就 `return`，页面刷新/重新解析后映射丢失 → 任务**永久静默**；③完成分支无幂等守卫，重复事件重复计数；④`showToast` 合并键按 `taskId` 拼接 → 每个文件一个独立 toast，刷屏等于没提示。规则：任何"完成了/失败了"的状态都必须**渲染到用户可见处**；映射表未命中必须**兜底重建**（用 `displayName`/`fileName`）而不是静默丢弃；同一终态**幂等**；提示按**批次**合并成一次，不逐文件弹。 |
| R-26 | **业务状态提示不得直接赋值给宿主布局属性** | `PluginWorkspacePage.statusText` 一旦写成绑定（如 `statusText: activityText.length>0 ? ... : downloadStatusText()`），任何 `root.statusText = "..."` 赋值都会**破坏该绑定**，页脚计数此后永久失效。必须引入自己的 `activityText` 通道 + `setActivity()`/`clearActivity()`，所有临时提示走它。 |
| R-27 | **提功能前先查权威 API 手册，不要假设宿主能力** | SP 当前**没有任何打开系统资源管理器的 API**：`openExternalUrl()` 原文限定"只接受含有效主机名的 `https://` 地址；不接受 HTTP、本地文件或脚本协议"（`file:///` 必被拒）；`startProcess()` 原文限定"不能传入系统命令或任意路径"，只能跑清单 `执行程序` 声明的自带程序（`explorer.exe` 不行）；`runAction()` 可绑定宿主能力里也没有打开目录。正确做法：查 `sp-plugin-packager\plugin_development.md` 的 4.2 方法总表与 5.3 context 方法，确认做不到就给替代方案（显示路径 + `copyText`），**不要**为了"看起来能用"去新增执行程序或塞 `file://`。 |

---

## 一、历次失败教训详情（错误→根因→正确做法）

### F-01 SP 一直检测不到新版本（第 1 轮）
- **现象**：包发了，SP 在线商店仍显示旧版/检测不到。
- **根因**：线上 `lists.yaml` 校验的 sha256 与实际 pkg 不一致（或 lists.yaml 没更新/指向旧链接）。SP 只读线上总目录或自定义清单源的 `sha256` 与 pkg 文件哈希。
- **正确**：按部署手册步骤：打包→上传→**远程下载验证哈希**→把该哈希写 `lists.yaml`（小写）→ push → 抓 raw 确认。

### F-02 写完哈希后又重打包（第 2 轮，差点破坏）
- **现象**：把上一 pkg 哈希写进 lists.yaml 后，又改包内容重打 → 哈希对不上已写的 lists.yaml。
- **根因**：不理解"SP 校验 = 线上 lists.yaml sha256 vs 实际下载 pkg 哈希；包内 lists.yaml 不参与校验"。一旦 lists.yaml 落了一个哈希，就锁定了必须是那个 pkg。
- **正确**：R-1。所有内容改动在打包前完成；上传验证后只填哈希、不再动包。

### F-03 小文件夹也发 8 个分页请求（第 3 轮）
- **现象**：并行分页每文件夹固定发 start=0..700 共 8 请求，绝大多数文件夹 <100 项也浪费。
- **根因**：无自适应：先并行探测 8 页才发现空。
- **正确**：自适应——先单请求首页；首页 <page_size 立即返回；首页满才并行扩展。小文件夹=1 请求。

### F-04 大目录/多层树"解析失败"（第 3 轮用户反馈）
- **现象**：内容少的链接能解析；内容多、层级多的目录解析失败、非常慢。
- **根因**：树模式对每个子文件夹串行 HTTP；单层大目录分页串行；`list_folder` 前端仅 120s 超时；总耗时超 300s → 前端报失败。
- **正确**：并行化（列表分页并行、树 BFS 单线程池）+ 信号量限流 8 + 前端超时拉满 300000ms + 失败降级。

### F-05 递归嵌套线程池死锁（第 3 轮设计缺陷）
- **现象**：测试 max_active 飙到 48~64，深树时可能死锁。
- **根因**：每个子文件夹递归又开线程池，外层等内层、并发占满 → 死锁；线程爆炸。
- **正确**：R-5。BFS 单线程池统一调度 + R-6 全局信号量限制实际在途请求。

### F-06 循环目录自指无限请求（第 3 轮 mock 暴露）
- **现象**：mock 里子文件夹内容含自身 → 同一文件夹被请求 500+ 次。
- **根因**：入队未查重。真实 Drive 偶发同名/软链循环也会这样。
- **正确**：R-19。`node_by_id` 已存在则标记 `_reused` 不入队。

### F-07 测试断言/结构假阳性（第 3 轮多次）
- **现象**：mock 用 `entry=xxx` 而非 `entry-xxx`；id 拼成 `n-n_1` 而非 `n_1`；`count("d")` 误判层级——导致断言不触发或假过。
- **根因**：mock 与真实正则结构不符；测试逻辑自洽但偏离真实。
- **正确**：R-17。mock 严格对照真实页面结构；用显式层级 id；断言应命中真实路径。

### F-08 发布后忘了同步 PR（第 2 轮后）
- **现象**：线上清单已更新，PR #3 分支还指向旧 sha256 → 总目录若合并不含新哈希。
- **正确**：部署步骤 9：同步 fork 分支 → PR mergeable=clean。

### F-09 fork 的 git origin 拼错导致 push 403/推错仓库（第 3 轮发布）
- **现象**：本地 `pluginfork` 的 `origin` 是 `spworker2026/plugins`（上游），push 报 `Permission to spworker2026 denied to ggwpcj`；正确 fork 是 `ggwpcj/plugins`。
- **根因**：clone 时把 fork 仓库 URL 填成上游，或 previous session 用了错误 remote。
- **正确**：
  ```powershell
  git remote set-url origin "https://github.com/ggwpcj/plugins.git"
  # 推送时临时带 token，推完还原
  git push origin update-gdrive-v1.4
  # push 卡住超时不代表失败：git 输出写到 stderr，用 git log 远端分支 SHA 比对确认
  ```
  验证：`git ls-remote origin update-gdrive-v1.4` 或 GitHub API branches SHA == 本地 `git log -1`。

### F-10 push 输出全到 stderr，PowerShell 误判为错误
- **现象**：`git push` 成功但 `$LASTEXITCODE` 却被 `2>&1` 合并导致红字；必须读 `EXIT=0`。
- **正确**：push 后看 `$LASTEXITCODE`（0=成功）与输出里的 `head..head` 行；再用 API / `git ls-remote` 二次确认远端 SHA 已变。

### F-11 AppTableCell 内嵌勾选框/双击必须用官方机制（第 4 轮用户二次报障）
- **现象**：解析内容出来后**勾选框点了没反应**、**单击折叠/展开死**、**双击进不了子级目录**，只能在右键菜单操作。
- **根因**：
  1. `AppCheckBox` 直接作为 `AppTableCell` 的子项，而 cell `rowInteractionEnabled: true` 会把鼠标事件吞掉 → 勾选框永远点不到。**必须**通过 `embeddedControl:`（Component 内 `AppCheckBox { indicatorOnly: true }`）+ `embeddedControlRole` + `embeddedControlRowInteractionEnabled: true` 内嵌。
  2. `AppTableCell` 的双击走 `onEditRequested` 信号，且**需要配置 `editorComponent` 才启用**；只靠 `onRowPressed` 时间戳猜双击不可靠。双击业务应在 `onEditRequested` 里处理；想阻止编辑器出现就保持 `editing: false`。
  3. 整行交互与内嵌控件抢事件：行事件统一封装进 `component XxxCell: AppTableCell`，每列一个 cell，`onRowPressed/onEditRequested/onRowContextRequested` 统一转发到页面函数。
- **正确**：照官方唯一可用范本 `sp-执行脚本\ui\main.qml`（embeddedControl 勾选/下拉 + editorComponent 双击 + AutomaticCell 封装）改；不要自己发明"直接把控件塞进 cell"的写法。
- 附：单击文件夹行想折叠/展开，用延迟 Timer（~320ms）区分单击与双击；双击通道与 onRowPressed 时间戳双通道共存时用 `doubleConsumed` 标志+600ms 复位防重复 toggle。
- **v1.5 定论**：不再用自研折叠折叠树（depthMode 固定 `tree`），表格封装为 `GDriveFileTable.qml`（基于 `AppTableView`+`AppTableRowPointer` 整行单选 + `onRowDoubleClicked` 双击行触发 `rowActivated` + 勾选框 `indicatorOnly` 仅显示），双击文件夹→openFolder、双击文件→startDownload、右键→contextActionsProvider。官方 PluginDataTable 仅存在于 sp-网盘管理 旧版参考，本插件最终迭代采用 AppTableView 范本。

### F-12 维护者更新打包器后 v1.5 必经重发（第 5 轮）
- **现象**：发布 v1.5-r1 后维护者换了独立打包器，新增 `最低SP版本` 必填、`plugin-api-capabilities` 扫描校验、在线目录 `api_version`+`minimum_sp_version` 契约；试跑新打包器报 `Missing manifest field: 最低SP版本`。且 r1 意外打包了运行时 `cache/folders.sqlite3`（237KB）。
- **正确**：METADATA 补 `最低SP版本: 3.0-beta-1`（API1 基线）；CHECKSUMS 同步新哈希；新打包器重打（5 项校验含 plugin-api-capabilities）；删旧 asset→传新→HASH_MATCH→更新 main/fork lists.yaml（加两键+新 sha）→force 更新 PR#4。清单比对确认 cache 已排除。
- **教训**：R-22。契约更新属于 R-1"禁止重打包"的合法例外，但必须完整走发布链重发而非只改文件。

### F-13 勾选文件夹后"开始下载"无反应（第 6 轮用户报障）
- **现象**：用户勾选文件夹点"开始下载"**什么都没发生**，必须进到文件夹里逐个勾选文件才能下载；文件夹文件多时极繁琐。
- **根因**：`itemsWithUrl()` 用 `isFolderRow(row)` 把文件夹行**全部过滤**——勾选生效（selectedItems 能取到文件夹行）但下载阶段静默丢弃。这是逻辑遗漏，不是 UI 勾选问题。
- **正确**：下载阶段对勾选的文件夹行递归展开后代（v1.6：`collectFolderFiles`，DFS+去重+未解析提示），对文件行照旧；任何"不该下载文件夹"的判断都要在下一次发布时复查，防止回归。

### F-14 发布完成忘了回填手册占位符（第 7 轮发布收尾）
- **现象**：v1.6 发布时手册快照/修改记录先写占位符（`<部署后回填>`、`<提交号>`、`<head>`），打包上传 HASH_MATCH 全部做完后**忘了回填**，用户追问"内容日志是否按手册添加"才发现。
- **正确**：发布完成后**立即回填**三本手册真实数字：sha256（小写）/打包输出目录/Release ID/新 asset ID/提交号/PR head，并在改动记录状态注明，然后提交推送 main。回填动作属于发布链**必需步骤**，不是可选项（见部署手册步骤 8 后补充的回填步）。
- **教训**：占位符换成真实值要趁数据还热时做（Release/asset ID、PR head 刚拿到的当下）；等会话后再回填容易漏。自检清单第 9 条"三个手册已同步更新"应包含"发布数字已回填非占位"。

### F-16 加密/分卷压缩包下载到的是病毒扫描确认页 HTML（第 9 轮用户报障）
- **现象**：v1.7 发布后用户反馈"能解析出文件，但下载失败"。目标是 `NewNumbers_v1.9_beta1[测试版][20260929].7z`（37628353B）。
- **根因**：`direct_download_url()` 生成的是 `usercontent/download?id=..&export=download`，**缺 `confirm` 参数**。Google 对"加密或分卷压缩包"强制返回**病毒扫描确认页**：HTTP 200 + `text/html` + 2456B，`<title>Google Drive - Virus scan warning</title>`，页面文案 `Google Drive can't scan this file for viruses ... is encrypted or a multi-volume archive`。SP 宿主按此 URL 下载，存下的是 HTML 不是文件 → 表现为"下载失败"。
- **实测对照**（同一 file_id）：
  | 请求 | 结果 |
  | --- | --- |
  | `?id=..&export=download` | 200 `text/html` 2456B，确认页 |
  | `?id=..&export=download&confirm=t` | 200 `application/octet-stream` 37628353B，首字节 `7z\xbc\xaf'\x1c` |
  | `&confirm=t` + `Range: bytes=0-1` | 206，`Content-Range: bytes 0-1/37628353` |
- **正确**（R-24）：所有下载直链统一带 `confirm=t`。确认页表单里本来就有 `name="confirm" value="t"`（有时还带 `uuid`），`extract_confirm_token()` 一直能解析到，只是目录列表路径**不走** `resolve_download` 而直接把裸 URL 交给宿主，绕过了该逻辑。新增幂等的 `with_download_confirm()` 统一收口，避免各处重复拼串。
- **教训**：
  1. **返回 200 不代表成功**——必须看 `Content-Type` 与首字节。确认页是 200，`Content-Type: text/html`；文件本体是 `application/octet-stream`。
  2. 压缩包类文件（`.7z` / `.rar` / 分卷 `.zip` / 加密 PDF / 加密视频）都要考虑确认页，不要只在"文件能解析出来"时就认为下载链路 OK。
  3. 单测要覆盖**每个 URL 构造分支**都带 confirm，且幂等函数不能重复追加、不能覆盖已有 `uuid`/非 `t` 的 confirm 值。

### F-15 歧义分享链接按形态猜类型导致文件夹被当文件下载（第 8 轮用户报障）
- **现象**：用户粘贴 `https://drive.google.com/open?id=11xcFop_CLN6-F9mDlgTaFV0E5_4bQGrE`，页面明明显示文件夹标题 `NewNumbers[自动监控号码]`，插件却按文件去下载，解析失败、拿不到内部文件。
- **根因**：`open?id=` 对文件和文件夹**都合法**，单看 URL 无法区分；而前端把"非 `/folders/` 形态"一律当文件，后端也没提供类型探测接口 → 必然误判。顺带排查掉的假线索：ID 里的 `-`/`_`、文件名里的 `[]` 都不是原因（`folder_id_from_url` 对这些字符一直正常）。
- **正确**（R-23）：新增 `probe_link` 后端接口，≤256KiB 轻量请求跟随 302，用**最终 URL** 判定 file/folder 再分流；`folder_id_from_url` 补齐 `open?id=`、`/drive/u/N/folders/`、`folder=`、`folderview?id=` 四种形态。
- **附带教训**：判定类型前先**实测**，别靠猜。本次实测确认：302 → `/drive/folders/ID`（真文件夹）；`uc?export=download&id=<文件夹ID>` 返回 HTTP 500；而 `embeddedfolderview` 仍可用、现有 `parse_folder_page()` 已能解析出内部文件 → 因此**没有**新增 `_DRIVE_ivd` 解析器，避免过度设计。

### F-17 下载全部完成却毫无提示（第 10 轮用户报障）
- **现象**：批量下载跑完，插件不弹任何完成提示，用户不知道下载结束了、也不知道文件存到哪，只能自己去翻目录。
- **根因**：`onDownloadProgress` 里其实**早就写了** `showToast("下载完成：...")`，但用户看不到。是四个缺陷叠加（R-25）：
  1. `finishedCount`/`failedCount`/`queuedCount` 三个计数**只累加、全页面零处渲染** → 统计等于白算；
  2. `var info = root.queueByTask[String(taskId)]; if (!info) return` —— 页面刷新或重新解析后映射丢失，任务**永久静默**，此后所有进度事件直接被丢弃；
  3. 完成分支没有幂等守卫，`info.status` 已是 `completed` 还会被重复事件再次 `finishedCount++` 并重复弹 toast；
  4. `showToast(..., "gdrive-done-" + taskId)` 合并键按 `taskId` 拼 → **每个文件一个独立 toast**，下载 20 个文件就是 20 个一闪而过的提示，等于没有提示。
- **正确做法**（v1.8）：
  1. 页脚 `statusText` 改成绑定，经自己的 `activityText` 通道让路（**不能**直接 `root.statusText = ...`，会破坏绑定，见 R-26），常驻显示"进行中/已完成/失败/共 N 个任务"；
  2. 新增**批次**概念：`batchTotal`/`completedList`/`failedList`/`completionDirectory`，`resetBatch()` 在每次点"开始下载"时清零，单文件下载在上批次结束后自动开新批次；
  3. 映射未命中时**兜底重建** `info`（用 `task.displayName || task.fileName`），并写回 `queueByTask`、补记 `batchTotal`，只写一条 diagnostic 日志，绝不静默 return；
  4. 完成/失败进**幂等守卫**，同一终态重复事件只刷横幅不再计数；
  5. toast 改为**批次结束汇总一次**（合并键固定 `gdrive-batch-done`），完成用 `success`、有失败用 `warning`；
  6. 表格上方加**完成横幅**（`AppGroupBox`，`visible` 折叠时 `height: visible ? implicitHeight : 0`），显示成功/失败数、实际保存目录（中间省略 + `ElideMiddle`）、失败文件列表（`PluginTheme.danger`），提供**复制目录路径**、**复制文件清单**、**关闭**三个按钮。
- **教训**：
  1. **"有提示代码"≠"用户看得到提示"**。写完提示必须自问：它渲染在哪、什么时候消失、映射丢了还在不在。三个问题任一答不上就是没提示。
  2. **静默 `return` 是最贵的错误**。丢弃一个事件等于永久丢失一条用户可见状态；宁可兜底重建 + 记日志。
  3. **逐条提示在批量场景等于零提示**。用户要的是"这批东西好了，去哪拿"，不是 20 条流水账。
  4. **提功能前先查权威 API 手册**（`sp-plugin-packager\plugin_development.md`）。"打开下载目录"看着像基础能力，实际 SP 完全没提供：`openExternalUrl` 只收 `https`、`startProcess` 只收清单声明的自带程序、`runAction` 宿主能力里也没有打开目录（R-27）。给用户"显示完整路径 + `copyText` 一键复制"才是能落地的诚实方案，不要为了看起来能用而新增执行程序或硬塞 `file:///`。

---

## 二、发布前 3 分钟自检清单

1. ☐ 读本手册（铁律 R-1~R-27 过一遍）
2. ☐ 读《开发操作手册》确认验收全过
3. ☐ `git status` 干净、无杂散文件
4. ☐ 版本是否被要求保持/升版（当前 v1.8，用户已同意升版）
5. ☐ 打包 --output 全新目录
6. ☐ 上传后一定做远程哈希验证
7. ☐ lists.yaml 写**小写**哈希后再 push；不重打包
8. ☐ PR #4 分支同步、mergeable=YES
9. ☐ 三个手册已同步更新，且发布数字（sha/Release/asset/PR head）已回填**非占位**（F-14）
10. ☐ 本次新增的用户可见状态，都能在页面上找到渲染位置（R-25）

---

## 三、新增铁律记录区（以后发现新教训追加于此）

- （暂无，后续追加）
