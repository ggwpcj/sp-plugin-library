# SP-谷歌网盘下载 开发操作手册（DevOps Handbook）

> **用途（必读）**：本手册是**修改插件源代码（`谷歌网盘下载\`）时的唯一权威步骤**。收录的是**经用户实测验收合格、各项功能正常使用**的完整流程。
> **每次动代码前必须先读本手册**，按「三、完整开发步骤」逐步执行；严禁凭记忆/猜测修改，以免破坏其他正常源码。
> 部署（打包/上传/发版）见《上传部署手册 Deploy-Handbook.md》；失败教训与铁律见《铁律手册 Iron-Rules.md》。

**版本基线**：当前插件版本 v1.4（**不许擅自升版本**，详见铁律手册 R-2）。

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
1. 只改上述 6 个文件 + 本手册 3 个 `.md`（位于 `E:\yuanma\gugechajian-0905\`）。
2. 任何其他文件（含临时 test*.py）**禁止**留在源码目录 `谷歌网盘下载\` 内。
3. 三个手册放在工作区根 `E:\yuanma\gugechajian-0905\`（不放进源码目录，避免进包干扰 source_files）。
4. 每次改完必须跑「四、本地验收」全部通过才算"可发布"。

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
提交前 `git status` 确认**没有杂散文件**（临时脚本、.pyc 等不应被加入）。

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
- 状态：**已完成（2026-09 第 6 次发布）**，待部署。
  - new worker/main.py SHA=`45033911…`、worker/gdrive.py SHA=`2D1D39AD…`（CHECKSUMS 已更新）。

---

## 七、验收后交付

发布动作由《上传部署手册 Deploy-Handbook.md》负责，本手册只管到"验收合格"。验收通过、代码提交后，转部署手册。