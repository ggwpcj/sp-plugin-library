# SP-谷歌网盘下载 铁律手册（Iron Rules）

> **用途（每次执行前必读）**：本手册收录**历次踩过的失败教训与不可违反的铁律**。开发前/发布前第一件事就是读本手册。凡是"错误 → 教训 → 正确做法"的经验，统一收纳于此，绝不遗漏。

---

## 铁律总表

| 编号 | 铁律 | 说明/后果 |
| --- | --- | --- |
| R-1 | **写完 lists.yaml 的 sha256 后禁止重打包** | SP 校验线上 lists.yaml sha256 == 实际 pkg 哈希；重打包哈希会变 → 校验失败 → SP 检测不到。 |
| R-2 | **版本号不许擅自递增** | 当前 v1.6（2026-09 用户明确同意升版，用于强制远程覆盖旧包；自 v1.5 起每轮功能修复均需用户同意升版）。改版本需用户同意；三个文件（METADATA/lists.yaml/CHECKSUMS.yaml）版本必须一致。 |
| R-3 | **sha256 一律小写** | lists.yaml 写大写哈希 → SP 校验不匹配。 |
| R-4 | **禁止"每文件/每文件夹串行请求"做列表/树** | 5000 文件=5000 请求→几分钟→超 300s 前端上限→"解析失败"。必须并行。 |
| R-5 | **禁止递归嵌套线程池** | 外层线程池每个 worker 再开线程池 → 并发满时死锁 + 线程爆炸。改用**广度优先 + 单一线程池**（BFS）。 |
| R-6 | **真实并发在途 HTTP 必须限流** | 不加信号量，树+分页嵌套可打到 64 并发 → 对 Google/宿主洪峰。用 `threading.BoundedSemaphore(8)` 包 `context.request`。 |
| R-7 | **git remote 带 token 推送后立即还原** | token 泄入 origin 是安全事故。推完回设 `https://github.com/...`。 |
| R-8 | **token 绝不写入文件/提交/包/聊天** | 只存在于 `E:\yuanma\gugechajian-0905\GITHUB_TOKEN.txt` 临时读取。 |
| R-9 | **临时/杂散文件禁止留源码目录** | test*.py、旧手册 md、.pyc 等进包 → source_files 变化、哈希漂移。临时脚本放 `C:\Users\AOC\AppData\Local\Temp\opencode\`。 |
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

---

## 二、发布前 3 分钟自检清单

1. ☐ 读本手册（铁律 R-1~R-22 过一遍）
2. ☐ 读《开发操作手册》确认验收全过
3. ☐ `git status` 干净、无杂散文件
4. ☐ 版本是否被要求保持/升版（当前 v1.6，用户已同意升版）
5. ☐ 打包 --output 全新目录
6. ☐ 上传后一定做远程哈希验证
7. ☐ lists.yaml 写**小写**哈希后再 push；不重打包
8. ☐ PR #4 分支同步、mergeable=YES
9. ☐ 三个手册已同步更新，且发布数字（sha/Release/asset/PR head）已回填**非占位**（F-14）

---

## 三、新增铁律记录区（以后发现新教训追加于此）

- （暂无，后续追加）
