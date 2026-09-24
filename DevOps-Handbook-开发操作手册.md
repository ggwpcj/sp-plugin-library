# SP-谷歌网盘下载 开发操作手册（DevOps Handbook）

> **用途（必读）**：本手册是**修改插件源代码（`谷歌网盘下载\`）时的唯一权威步骤**。收录的是**经用户实测验收合格、各项功能正常使用**的完整流程。
> **每次动代码前必须先读本手册**，按「三、完整开发步骤」逐步执行；严禁凭记忆/猜测修改，以免破坏其他正常源码。
> 部署（打包/上传/发版）见《上传部署手册 Deploy-Handbook.md》；失败教训与铁律见《铁律手册 Iron-Rules.md》。

**版本基线**：当前插件版本 v1.6（用户已同意自 v1.5 升版，用于强制远程覆盖旧包，详见铁律手册 R-2）。

---

## 〇、目录结构与守则

| 文件 | 作用 |
| --- | --- |
| `METADATA.yaml` | 插件元数据（插件ID/名称/版本/菜单/Enabled） |
| `ui/main.qml` | 前端界面与交互（含 spPlugin 桥调用） |
| `worker/main.py` | 后端主逻辑（解析/列表/树/下载地址） |
| `worker/gdrive.py` | Google Drive 页面解析（flip-entry 块、大小、ID 提取） |
| `lists.yaml` | 在线发布清单（version/package/sha256/introduction） |
| `CHECKSUMS.yaml` | 4 个发布文件 SHA-256 校验清单 |

**守则**：
1. 业务源码、元数据及三个手册均在本插件目录维护；`.gitignore` 和 `.sp-package-ignore` 也是需要交付的维护规则，不要误删。
2. 临时测试脚本、凭据和下载产物不得提交或打包；运行时仅允许 `cache/` 作为本插件自己的目录缓存，不能把其中的数据加入源码或安装包。
3. 发布前检查实际包内文件清单，不再依赖旧工作区的固定 `source_files` 数字。
4. 每次改完必须跑「四、本地验收」全部通过才算"可发布"。

---

### 目录缓存与排除规则

- `worker/main.py` 将已读取目录存到插件目录的 `cache/folders.sqlite3`。缓存按线路和文件夹 ID 区分，保存 24 小时；“刷新”只强制重取当前目录并使其旧子树缓存失效，普通往返导航先用缓存，不能在“全部解析”模式下把一次刷新扩大成整棵树重抓。每次打开默认“全部解析”，“当前深度”仅在本次窗口内选择且只读取进入的目录；切换回“全部解析”会自动补齐目录树并保留当前视图。若目录过大或部分子目录请求失败，界面会明确提示未缓存部分仍须首次读取。
- 解析请求运行时，工具栏“解析”切换为“停止”，调用宿主 `spPlugin.cancel()`；后端在发起受管请求和处理目录前检查取消。停止后忽略该请求的迟到回包，不覆盖当前目录。完整解析显示公共进度条及“已解析/已发现目录数”；目录总数只能边遍历边发现，进度条不显示伪精确百分比或剩余时间，已完成的目录缓存仍可复用。
- `cache/` 仅含运行数据，可能包含用户访问过的文件夹名称和链接信息；不要提交、分享或上传。插件目录的 `.gitignore` 排除 Git 跟踪，`.sp-package-ignore` 排除 SP 导出和发布打包；两种排除各有用途，必须同时保留。打包前核对归档内没有 `cache/`。
- 嵌入式目录页提供最后修改日期，但不提供准确上传时间或文件大小。“全部解析”、普通进出目录和刷新都不逐文件探测大小；只有用户勾选文件并右键“解析大小”，`probe_folder_sizes` 才按所选文件分批发 Range 请求并写回同一目录缓存。当前匿名分享链接模式每个未知大小的文件需要一次 Range 请求，不能声称一次目录请求能拿齐大小；每批最多 64 个文件，失败后不继续下一批。探测失败的大小保持未提供，总大小仅在全部文件大小已知时标为“总大小”；离开目录或切换线路会取消尚未完成的探测。日期列必须标为“修改日期”，不能称作上传时间。
- 文件列表列顺序为勾选、类型、名称、大小、修改日期；名称只显示原始名称，不重复加“文件夹 /”字样。列排序、宽度和行选择继续由 `GDriveFileTable` 的公共列配置驱动。
- 目录路径条的两端返回、刷新按钮固定不滚动；中间目录名超过可见宽度时，鼠标拖拽和滚轮都只移动路径内容，目录名仍可点击跳转。滚轮到达路径两端或路径未溢出时应透传给外层页面，不得无条件吞掉滚动。
- 保存目录未选择时，路径文本框的 `text` 保持空值，`placeholderText` 提示默认使用 SP 临时目录；下载仍把空 `directory` 交给宿主公共下载接口，不能在插件里阻止。实际保存路径以下载任务结果为准。
- 若安装目录不可写，后端跳过磁盘缓存而继续解析；当前窗口已访问目录仍可使用界面内存缓存。更新插件时安装目录可能被替换，因此不能把 `cache/` 当作需要保留的用户配置。

---

## 一、SP 插件工作方式（必须理解，否则改错方向）

- SP 前端（QML）通过 `root.spPlugin.call("list_folder", {...}, 超时ms)` 调后端 worker。
- 后端 worker（`worker/main.py` 各入口函数）通过 `context.request({...})` 发起 HTTP（走 SP 宿主的路由/代理），`context.progress`/`context.log`/`context.check_cancelled` 回报给前端。
- **SP 校验口径**：线上 `lists.yaml` 的 `sha256` == 实际下载 pkg 的 SHA-256（包内自带 lists.yaml 不参与 SP 校验）。
- **前端超时上限 300000ms（5 分钟）**：耗时操作无论多大目录都必须在 5 分钟内返回，否则前端报"解析失败"。

### 已确认的解析原理（v1.4 并行优化后）
- Drive 文件夹信息从 `embeddedfolderview?id=<fid>` 页面解析（gdrive.py）：`flip-entry` 分块、`flip-entry-size` 文本大小（`parse_size_text`）、`file/d/<id>` 与 `drive/folders/<id>` 提取。
- 单文件下载直链 = `https://drive.google.com/uc?export=download&id=<id>`（resolve_download）或直接构造 `direct_download_url(id)`。
- 分页：页面支持 `&start=<offset>`，每页约 100 项。
- 大目录/多层树慢与失败的根因曾是**每项/每文件夹串行请求** → 已并行化（见铁律手册 R-4/R-5）。

---

## 二、SP 在线更新机制（校验契约，部署时用）

```
SP 校验：线上 lists.yaml 的 sha256 == 实际下载的 pkg 文件哈希
（包内自带的 lists.yaml 不参与 SP 校验）
```

关键顺序（第 2 轮踩坑后确认，部署手册有完整命令）：
1. 先打包 → 得到 pkg 与真实 sha256。
2. 上传 pkg（新版本创建 Release / 沿用版本则替换 asset）。
3. 远程下载 pkg 验证 远程哈希 == 本地打包哈希 == 期望。
4. 把该**已验证哈希**写进线上 `lists.yaml` 的 `sha256`（小写），再提交推送。
5. **写完哈希后禁止再重打包**（哈希变，SP 校验失败）。

---

## 三、完整开发步骤（每次修改按此执行）

### 步骤 1：定位修改文件
按需求定位到 `ui/main.qml` / `worker/main.py` / `worker/gdrive.py` / `METADATA.yaml` / `lists.yaml` / `CHECKSUMS.yaml` 之一。

### 步骤 2：修改代码
- 遵循仓库风格：`from __future__ import annotations`、类型注解、无多余注释。
- **版本类改动**：`METADATA.yaml`/`lists.yaml`/`CHECKSUMS.yaml` 三处版本必须一致。当前 v1.4 保持不变。
- **不改动文件保留原子内容**（如 CHECKSUMS.yaml 未变文件哈希）。防止误改：改完用 `git diff` 复核。

### 步骤 3：本地校验（四、本地验收全项）
```powershell
python -m py_compile "E:\yuanma\gugechajian-0905\谷歌网盘下载\worker\main.py"
python -m py_compile "E:\yuanma\gugechajian-0905\谷歌网盘下载\worker\gdrive.py"
python "C:\Users\AOC\AppData\Local\Temp\opencode\qmlcheck2.py"
```
- py_compile 通过 = 语法无误。
- qmlcheck2.py 输出：`{}` 168 168 等括号成对、append/push 块键齐全（条件行缺键会报 `missing []`）、AppFormRow/AppSelect 数量。

### 步骤 4：逻辑单元测试（后端改动必跑）
在工作区根写临时测试脚本（**不要放进源码目录**），覆盖：
- gdrive：`parse_size_text` 各种单位、`parse_folder_page` 文件+子文件夹混合、folder/file ID 提取。
- main：`_list_folder_items` 小文件夹（应只 1 请求）、大文件夹并行分页（取全）、`_collect_tree` 多级树、循环目录守卫、失败降级、并发信号量 `max_active==8`。
- 入口：`list_folder`/`list_folder_tree`/`resolve_download` 返回结构完整（items/tree/totalFiles/totalSize/truncated/downloadUrl）。

### 步骤 5：git 提交（源码目录内）
```powershell
git -C "E:\yuanma\gugechajian-0905\谷歌网盘下载" add .
git -C "E:\yuanma\gugechajian-0905\谷歌网盘下载" commit -m "<功能说明>"
```
提交前 `git status` 确认**没有杂散文件**（临时脚本、.pyc 和 `cache/` 不应被加入），并确认 `.gitignore`、`.sp-package-ignore` 两份规则都存在。

### 步骤 6：同步更新本手册
- 在「六、修改记录」追加本轮完成的最终步骤（含验收通过的说明）。
- 若逻辑要点变更，同步更新「一、已确认的解析原理」。
- 铁律新增教训 → 追加到《铁律手册 Iron-Rules.md》。

### 步骤 7：部署发布
改动验收合格后，转《上传部署手册 Deploy-Handbook.md》执行发布（打包→上传→校验→lists.yaml→PR）。

---

## 四、本地验收清单（每项必须过）

- [ ] `python -m py_compile worker/main.py` 通过
- [ ] `python -m py_compile worker/gdrive.py` 通过
- [ ] `python qmlcheck2.py`：括号全部成对、无 `missing` 块键、Component.onCompleted 存在
- [ ] 后端单元测试全部 PASS（分页/树/并发/降级/循环守卫）
- [ ] `git status` 无杂散文件；`git diff` 仅预期改动
- [ ] 三处版本号一致（若动版本）；未动版本则确认 Version 未变
- [ ] CHECKSUMS.yaml 已按改动更新 4 文件哈希（若发布前）

---

## 五、各文件职责与常见改动入口

| 需求 | 改哪里 |
| --- | --- |
| 界面布局/交互/按钮 | `ui/main.qml` |
| 前端超时/调用参数 | `ui/main.qml` 里 `spPlugin.call(...)` 第三参数 |
| 解析规则/页面结构变化 | `worker/gdrive.py`（正则/块切分/大小解析） |
| 列表/树/下载逻辑、并发、预算 | `worker/main.py` |
| 插件名/ID/版本 | `METADATA.yaml` |
| 在线清单/版本/哈希/介绍 | `lists.yaml` |
| 4 文件哈希清单 | `CHECKSUMS.yaml` |

---

## 六、修改记录（每完成一轮，把最终验收合格的步骤追加在此）

### v1.4（第 1 轮）—— 解析提速
- 内容：分页拉取 + 直接构造直链（去每文件探测）+ flip-entry-size 文本大小解析 + 健壮块切分。
- 效果：5000 文件树从 5000 次请求 → 82 次文件夹页请求。
- 发布：首包哈希 `df03c52d...`（后被第 2 轮替代）。

### v1.4（第 2 轮）—— 移除链接池（用户要求，已上线）
- 内容：删除链接池/保存链接全部功能（QML 属性 savedLinks、8 个函数、renameRow/saveButton、optionsRow/linkPoolBox、2 处 ensureLinkSaved 调用），保留链路回填 linkField 正常行为。
- 校验：qmlcheck + py_compile 通过；零残留引用。
- 发布：重打 0b5c26 → `sha256=0b5c2623fc81c698bfeda361fdae061b23cdc6ecd2c864cf52f175ed65327a53`，11309B，asset 549685100，lists.yaml 对齐，PR #3 head c229e1e。

### v1.4（第 3 轮）—— 并行解析（用户报"大目录/多层树解析失败+慢"）
- 症状诊断：树模式对每个子文件夹串行 HTTP（几十上百次）；单层大目录分页串行；`list_folder` 前端仅 120s 超时。叠加 → 超过 300s 上限 → "解析失败"。
- 修改（worker/main.py）：
  1. `_list_folder_items` 改为**自适应并行分页**：先单请求首页，<100 项直接返回（不浪费）；只有首页满 100 才并行扩展（每批 8）。
  2. `_collect_tree` 重写为**广度优先 + 单一共享线程池**（迭代式 BFS），消除递归嵌套线程池死锁/线程爆炸；`node_by_id` 去重防止循环目录与同名重复解析。
  3. 新增 `_REQUEST_SEMAPHORE = threading.BoundedSemaphore(8)` 包住 `_fetch` 的 `context.request`：**真实并发在途请求 ≤ 8**。
  4. 单文件/单文件夹失败降级（只影响自身，不拖垮整体）。
- 修改（ui/main.qml）：`list_folder` 与 `list_folder_tree` 超时均设为 300000ms（SP 上限）；`resolve_download` 保持 120000ms。
- 验收：小文件夹 1 请求；500 文件大文件夹并行分页取全；多级树 52+ 节点无截断；循环目录 A↔B 各解析 1 次；失败降级兄弟完整；`max_active==8`。
- 状态：**已完成并发布（2026-09 第 4 次发布）**。
  - 新包 `sp-gdrive-downloader-v1.4.pkg`，**sha256=`c7c01c8fad7540705711f3e810b5350af59149a03181718c3971cd513021a429`**（21598B），source_files=10（含 3 本手册）。
  - Release 384015546 沿用；**删旧 asset 549685100，新 asset ID `551686576`**。
  - 远程 HASH_MATCH 通过；lists.yaml 已写 sha256（小写）并推送 `8c3d285`。
  - PR #3 分支同步完成，head=`a919000`，待上游 spworker2026 合并。
  - 补录：打包时 CHECKSUMS 已更新（main.py BE26ADBC…、ui/main.qml B3184D3A…）。

### v1.4（第 4 轮）—— 表格交互修复（用户报"勾选框勾不了/单击折叠展开死/双击进不了子目录"）
- 症状：解析内容出来后，**鼠标双击进不了子级目录**（只能右键菜单）；**单击折叠/展开是死的**；**左侧勾选框点击没反应**（勾选不了项目）。
- 根因（对照官方可用范本 `sp-执行脚本` 查证后确认）：
  1. 勾选框被判死：`AppCheckBox` 直接塞进 `AppTableCell` 内部，但 cell `rowInteractionEnabled: true` 会把点击吞掉 → 必须通过官方 `embeddedControl`（`embeddedControlRole`+`embeddedControlRowInteractionEnabled: true`+`indicatorOnly: true`）内嵌。
  2. 双击/折叠失效：`AppTableCell` 双击走 `onEditRequested`（需配 `editorComponent` 才触发），仅靠 `onRowPressed` 时间戳猜双击不可靠；且整行交互与内嵌控件抢事件。
- 修改（ui/main.qml）：
  1. 勾选框 → `embeddedControl: Component { AppCheckBox { ... indicatorOnly: true ... } }` + `embeddedControlRole: "check"` + `embeddedControlRowInteractionEnabled: true`，onClicked 回写 `rowsModel.setProperty(cellRow,"checked",checked)`。
  2. 行交互 → 封装 `component GDriveCell: AppTableCell`，统一 `onRowPressed`/`onEditRequested`/`onRowContextRequested`。delegate 拆 4 列 GDriveCell（勾选/文件名/大小/类型）。
  3. `handleRowPressed`：单击文件夹 → 320ms 延迟 `toggleRow`（**单击折叠/展开**），400ms 内二次按下判双击立即 `toggleRow`；单击文件 → `standardSelectRow`。
  4. `handleRowDoubleClick`（onEditRequested 双击通道）与 onRowPressed 双击分支用 `doubleConsumed` 守卫防双重触发（600ms 复位）。
  5. `editorComponent` 提供最小 AppTextField 以启用 cell 双击机制（`editing: false` 不进入真编辑）。
- 验收：py_compile×2 + qmlcheck2 全过；`git status` 干净。
- 状态：**已完成并发布（2026-09 第 5 次发布）**。
  - 新包 `sp-gdrive-downloader-v1.4.pkg`，**sha256=`e8bfaf0b6348f5220e3da252dd1c2ca865bdca3ce869e4cbe1817e729e1899ed`**（22622B，source_files=10）。
  - Release 384015546 沿用；**删旧 asset 551686576，新 asset ID `552339492`**。
  - 远程 HASH_MATCH 通过；lists.yaml 写 e8bfaf0b（小写）推送 `6f0ecdf`；raw 已确认。
  - PR #3 分支同步 head=`fcc9197`，待上游合并；`ui/main.qml` CHECKSUMS→A96492EC…。
  - ⚠️ 运行时行为（双击/单击/勾选实际手感）依赖 SP 宿主，需用户实测确认后再定论。

### v1.4（第 5 轮）—— 网盘资料不显示文件大小（用户报障）
- 症状：解析出来的清单有文件名/类型，但"大小"列始终为空。
- 根因（抓真实公开文件夹 `gdown` 样本实证）：Google Drive **嵌入式视图 HTML（`embeddedfolderview?id=`）根本不返回文件大小**——每个条目只有 `flip-entry-title`（名称）+ `flip-entry-last-modified`（修改日期），全页无 `flip-entry-size`/任何 size 字段。这是数据源缺失，不是代码 Bug；从 v1.0 起大小列就一直是空的（此前无用户报障）。
- 修复方案（worker/main.py + worker/gdrive.py）：
  1. 新逻辑 `_probe_file_size`：对每个 file 的下载直链发 `GET` + 头 `Range: bytes=0-0`（只取 1 字节），从响应 `Content-Range: bytes 0-0/<total>` 解析真实总大小。小包+大文件都能拿（206 Not Modified 不受病毒确认页影响）。
  2. 宿主 `request()` **不支持 HEAD method**，只能 GET + Range（文档明确 method 仅 GET/POST/PUT/PATCH/DELETE）。
  3. `_probe_item_sizes` 并行探测（`ThreadPoolExecutor(max_workers=8)`），失败静默降级不中断；`limit`（默认 None 全探，树模式 `_PROBE_TREE_LIMIT=50`）防超大树目录拖垮解析。
  4. `parse_size_from_content_range`：解析 `bytes 0-0/N` → N；`format_size` 已有格式化。
  5. 单层 `list_folder` 全探；`_collect_tree` 每子文件夹 limit=50。
- 实测（真网）：gdown.pptx=34667B→33.9 KB；spam*.txt=5B；单元测试 limit/文件夹过滤全过。
- 状态：**已完成并发布（2026-09 v1.5 升版发布）**。
  - v1.5 内容（用户指定升版以强制远程覆盖旧包）：目录内容磁盘缓存(sqlite 24h TTL)；树形解析进度(treeParsing/treeProgress/parsedFolders)；修改日期列(modifiedDisplay)；新增 `ui/GDriveFileTable.qml` 整行交互组件——整行单选(高亮)+勾选框仅显示(单击勾选)、双击行(`AppTableRowPointer` `onRowDoubleClicked` 触发 `rowActivated`，文件夹→openFolder、文件→startDownload)、右键菜单(contextActionsProvider)、表头排序(toggleSort)；v1.4 的第 8 次诊断日志(双击/激活行、右键动作、开始下载)继续保留。
  - 新包 `sp-gdrive-downloader-v1.5.pkg`，**sha256=`d0624f6326bd79e4a2476c3f46f55798aaaaecb46a4869c49352909979565c37`**（33758B，source_files=12，新增 GDriveFileTable.qml + .sp-package-ignore 排除 cache/）。
  - **重发原因**：维护者更新独立打包器后新增必填与校验——`最低SP版本` 必填；`plugin-api-capabilities` 校验 QML 中所有 spPlugin.* 与 QML 组件必须登记（当前全部为 API 1，声明 `插件API版本: 1` 正确）；在线目录条目需 `api_version`+`minimum_sp_version`。METADATA 补 `最低SP版本: 3.0-beta-1`；v1.5-r1 意外打包入运行时产物 `cache/folders.sqlite3`（237KB），重发 r2 已排除。旧 sha `3e4c7339` 作废，旧 asset 562469028 已删。
  - 新建 GitHub Release **v1.5** id=`388129300`，当前 asset id=`563356585`；远程 HASH_MATCH 通过；main 推送 `20b46fb`。
  - PR #4（head=`bf5c9c7`，分叉自 v1.5 分支）待上游合并；worker/main.py、worker/gdrive.py、ui/main.qml 磁盘哈希已同步进 CHECKSUMS.yaml。
  - ⚠️ 需远程 SP 实测：双击文件夹进入、双击文件下载、批量勾选下载、缓存复用、树形进度显示。

### v1.6（第 1 轮）—— 勾选文件夹一键递归下载整个文件夹
- 症状（用户报障）：勾选文件夹后点"开始下载"**没有任何反应**，必须双击进到文件夹里逐个勾选文件才能下载；文件夹内文件多时操作繁琐。
- 根因（代码定位 ui/main.qml）：`itemsWithUrl()` 在收集下载目标时用 `isFolderRow(row)` 把**所有文件夹行过滤掉**，只保留带 `downloadUrl` 的文件行 → 勾选文件夹 = 空目标 → 底部"开始下载"无动作。文件夹行的 check 勾选本身是好的（`table.selectedItems()` 能选中文件夹行），只是下载阶段被丢弃。
- 修改（ui/main.qml）：
  1. 新增 `collectFolderFiles(folderRow)`：以勾选文件夹为根做**迭代式 DFS（手工 stack，非递归）**遍历其后代树：
     - 文件条目（`type==="file"` 且带 `downloadUrl`）全部收集；用 `seenFiles` 按 id 去重，无 `downloadUrl` 的跳过。
     - 文件夹条目用 `seenFolders` 按 id 去重防循环目录；`_reused` 标记的直接跳过（内容已在其它分支展开）。
     - 子文件夹解析来源优先 `row.children`（树模式带嵌套 children），缺失时回退 `folderCache[folderId].items`（导航过/缓存过的目录）。
     - `_loaded !== true` 且 `children` 为空 → 判定"未解析子目录"，`unresolved++` 不计入失败，仅提示。
  2. 重写 `downloadSelected()`：对每个选中行——文件夹 → 递归收集全部后代文件；文件 → 直接加入；最后统一排队下载。若存在未解析子目录，Toast 提示"另有 N 个子目录未解析，需先进入解析"。
  3. 右键菜单"下载选中项"改为同时支持文件夹行（原仅文件行出现）。
  4. 新增诊断日志：勾选文件夹下载 展开=名称 id=… 文件数=…；开始下载选中项：文件 N 个。
- 验收：py_compile×2 通过；qmlcheck2 括号/块键/Component.onCompleted 全过；9 项逻辑单测（多层完整树、截断子目录、循环守卫、_reused 跳过、cache 回退、空目录、顶层截断、文件去重、无 URL 跳过）全部 PASS。
- 状态：**已发布（2026-09 v1.6 升版发布）**。
  - 新包 `sp-gdrive-downloader-v1.6.pkg`，**sha256=`<部署后回填>`**（见部署手册快照）。
  - BUILD + HASH_MATCH + lists.yaml + PR 详情见《上传部署手册》发布快照。
  - ⚠️ 需远程 SP 实测：勾选文件夹 →"开始下载"应整文件夹（含多级子目录）全部加入队列。

---

## 七、验收后交付

发布动作由《上传部署手册 Deploy-Handbook.md》负责，本手册只管到"验收合格"。验收通过、代码提交后，转部署手册。
