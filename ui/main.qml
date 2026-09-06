import QtQuick 2.15
import QtQuick.Controls 2.15
import SP.Plugin 1.0

PluginWorkspacePage {
    id: root
    toolbarUsesFloatingPlaceholder: true

    property string requestId: ""
    property string saveDirectory: String(root.spPlugin.get("saveDirectory", ""))
    property string route: String(root.spPlugin.get("route", "auto"))
    property int contextRowIndex: -1
    property var contextRowData: null
    property string totalSizeText: ""
    property var queueByRequest: ({})
    property var queueByTask: ({})
    property int queuedCount: 0
    property int finishedCount: 0
    property int failedCount: 0
    property bool autoRetry: true
    property var pendingRetry: ({})
    property var treeData: []
    property bool treeLoaded: false
    property string treeRootUrl: ""
    property var expandedSet: ({})

    function chooseDirectory() {
        root.spPlugin.chooseDirectory("选择保存目录", root.saveDirectory)
    }

    function formatBytes(bytes) {
        var size = Number(bytes || 0)
        if (!(size > 0))
            return "未知"
        var units = ["B", "KB", "MB", "GB", "TB"]
        var value = size
        var index = 0
        while (value >= 1024 && index < units.length - 1) {
            value /= 1024
            index++
        }
        return (index === 0 ? String(Math.round(value)) : (Math.round(value * 10) / 10).toFixed(1)) + " " + units[index]
    }

    function routeLabelText() {
        if (root.route === "front")
            return "一级代理"
        if (root.route === "second")
            return "二级代理"
        return "自动选路"
    }

    function chooseRoute(routeName) {
        root.route = String(routeName || "auto")
        root.spPlugin.set("route", root.route)
        if (root.route !== "auto")
            root.spPlugin.checkProxy(root.route, "解析谷歌网盘")
        routeButton.text = "线路：" + root.routeLabelText()
    }

    function routeMenuActions() {
        return [
            {"text": "自动选路", "action": "auto"},
            {"text": "一级代理", "action": "front"},
            {"text": "二级代理", "action": "second"}
        ]
    }

    function handleRouteAction(action) {
        root.chooseRoute(action)
    }

    function loadFolderTree(url) {
        linkField.text = url
        root.statusText = "正在获取完整目录树..."
        root.requestId = root.spPlugin.call("list_folder_tree", {"url": url, "route": root.route}, 300000)
    }

    function loadFileUrl(url) {
        linkField.text = url
        root.statusText = "正在获取文件下载地址..."
        root.requestId = root.spPlugin.call("resolve_download", {"url": url, "route": root.route}, 120000)
    }

    function parseLink() {
        var link = linkField.text.trim()
        if (link.length === 0) {
            root.spPlugin.showToast("请输入谷歌网盘分享链接", "warning", "gdrive-empty-link")
            return
        }
        if (!/^https:\/\/drive\.google\.com\//.test(link)) {
            root.spPlugin.showToast("链接必须以 https://drive.google.com/ 开头", "warning", "gdrive-bad-link")
            return
        }
        root.treeData = []
        root.treeLoaded = false
        root.treeRootUrl = link
        if (/\/drive\/folders\//.test(link)) {
            root.loadFolderTree(link)
        } else {
            root.loadFileUrl(link)
        }
    }

    function flattenTree(nodes, depth, expandedSet, rows) {
        for (var i = 0; i < nodes.length; i++) {
            var node = nodes[i]
            var isFolder = String(node.type || "file") === "folder"
            rows.push({
                "rowId": String(node.id || ("node-" + rows.length)),
                "name": String(node.name || ""),
                "size": String(node.size || ""),
                "type": isFolder ? "folder" : "file",
                "downloadUrl": String(node.downloadUrl || ""),
                "checked": false,
                "depth": depth,
                "hasChildren": isFolder && (node.children || []).length > 0,
                "expanded": expandedSet.indexOf(String(node.id || "")) >= 0,
                "entry": node
            })
            if (isFolder && expandedSet.indexOf(String(node.id || "")) >= 0) {
                flattenTree(node.children || [], depth + 1, expandedSet, rows)
            }
        }
    }

    function renderTree() {
        rowsModel.clear()
        var expandedSet = []
        for (var id in root.expandedSet) {
            expandedSet.push(id)
        }
        var rows = []
        if (root.treeData && root.treeData.length > 0) {
            flattenTree(root.treeData, 0, expandedSet, rows)
        }
        for (var i = 0; i < rows.length; i++) {
            rowsModel.append(rows[i])
        }
        if (rows.length === 0) {
            root.statusText = "目录为空或已全部折叠"
            root.totalSizeText = ""
        } else {
            root.statusText = "共显示 " + rows.length + " 项；单击文件夹行展开/折叠，勾选文件后点\"开始下载\""
        }
    }

    function toggleRow(row) {
        if (!row)
            return
        if (row.type === "folder") {
            var id = String(row.rowId || row.id || "")
            if (!id || id.indexOf("row-") === 0 || id.indexOf("node-") === 0)
                return
            if (root.expandedSet[id])
                delete root.expandedSet[id]
            else
                root.expandedSet[id] = true
            root.renderTree()
        } else if (row.type === "file") {
            if (row.downloadUrl)
                root.startDownload(row)
        }
    }

    function startDownload(entry) {
        if (!entry || !entry.downloadUrl)
            return
        var key = "gdrive-" + String(entry.rowId || entry.id || entry.name || "")
        var requestId = root.spPlugin.download({
            "url": String(entry.downloadUrl),
            "directory": root.saveDirectory,
            "fileName": String(entry.name || "file"),
            "displayName": String(entry.name || "file"),
            "taskKey": key,
            "kind": "gdrive",
            "route": root.route,
            "autoRename": true,
            "showProgressToast": true
        })
        root.queueByRequest[String(requestId)] = {
            "key": key,
            "name": String(entry.name || "file"),
            "taskId": "",
            "status": "submitted",
            "retries": 0
        }
        root.queuedCount++
    }

    function downloadSelected() {
        var rows = selection.selectedRowArray()
        var started = 0
        var source = []
        for (var i = 0; i < rowsModel.count; i++) {
            if (rowsModel.get(i).checked) {
                source.push(i)
            }
        }
        if (source.length === 0) {
            for (var j = 0; j < rows.length; j++) {
                var row = Number(rows[j])
                if (row >= 0 && row < rowsModel.count)
                    source.push(row)
            }
        }
        if (source.length === 0) {
            root.spPlugin.showToast("请先勾选要下载的文件", "warning", "gdrive-no-selection")
            return
        }
        for (var k = 0; k < source.length; k++) {
            var data = rowsModel.get(source[k])
            if (data && data.downloadUrl && data.downloadUrl.length > 0) {
                root.startDownload(data)
                started++
            }
        }
        if (started > 0) {
            root.spPlugin.showToast("已加入下载队列 " + started + " 个任务", "success", "gdrive-download-queued")
        } else {
            root.spPlugin.showToast("所选项目中没有可下载的文件", "warning", "gdrive-no-downloadable")
        }
    }

    function retryTask(key) {
        var found = null
        for (var id in root.queueByTask) {
            if (id === key || root.queueByTask[id].key === key) {
                found = root.queueByTask[id]
                break
            }
        }
        if (!found || !found.taskId)
            return
        found.status = "resuming"
        root.spPlugin.log("手动续传：" + String(found.name))
        root.spPlugin.controlDownload("resume", String(found.taskId), false)
    }

    function contextActions(row) {
        var actions = []
        if (row && row.type === "folder")
            actions.push({"text": "展开/折叠该文件夹", "action": "toggle-folder"})
        if (row && row.type === "file")
            actions.push({"text": "下载该文件", "action": "download-one"})
        actions.push({"separator": true})
        actions.push({"text": "展开全部目录", "action": "expand-all"})
        actions.push({"text": "折叠全部目录", "action": "collapse-all"})
        actions.push({"text": "刷新当前链接", "action": "refresh"})
        actions.push({"separator": true})
        actions.push({"text": "下载选中项", "action": "download-selected"})
        return actions
    }

    function expandNodeRecursive(node, set) {
        if (!node || node.type !== "folder")
            return
        var id = String(node.id || "")
        if (id && id.indexOf("row-") !== 0 && id.indexOf("node-") !== 0)
            set[id] = true
        var children = node.children || []
        for (var i = 0; i < children.length; i++) {
            expandNodeRecursive(children[i], set)
        }
    }

    function handleContextAction(action) {
        var row = root.contextRowData
        if (action === "toggle-folder") {
            root.toggleRow(row)
        } else if (action === "download-one") {
            root.startDownload(row)
        } else if (action === "expand-all") {
            root.expandedSet = ({})
            for (var i = 0; i < root.treeData.length; i++) {
                expandNodeRecursive(root.treeData[i], root.expandedSet)
            }
            root.renderTree()
            root.spPlugin.showToast("已展开全部目录", "info", "gdrive-expand-all")
        } else if (action === "collapse-all") {
            root.expandedSet = ({})
            root.renderTree()
            root.spPlugin.showToast("已折叠全部目录", "info", "gdrive-collapse-all")
        } else if (action === "refresh") {
            if (root.treeRootUrl.length > 0)
                root.loadFolderTree(root.treeRootUrl)
            else
                root.parseLink()
        } else if (action === "download-selected") {
            root.downloadSelected()
        }
    }

    Connections {
        target: root.spPlugin

        function onBackendProgress(requestId, method, progress) {
            if (requestId !== root.requestId)
                return
            if (progress && progress.message)
                root.statusText = String(progress.message)
        }

        function onBackendFinished(requestId, method, response) {
            if (requestId !== root.requestId)
                return
            root.requestId = ""
            if (!response.ok) {
                root.statusText = "解析失败"
                root.totalSizeText = ""
                root.spPlugin.showToast(String(response.error || "解析失败"), "error", "gdrive-resolve-fail")
                return
            }
            var result = response.result || {}
            if (result.tree) {
                root.treeData = result.tree
                root.treeLoaded = true
                root.expandedSet = ({})
                for (var ti = 0; ti < root.treeData.length; ti++) {
                    expandNodeRecursive(root.treeData[ti], root.expandedSet)
                }
                root.renderTree()
                root.totalSizeText = root.formatBytes(Number(result.totalSize || 0))
                var extra = result.truncated ? "；部分目录因内容过多已截断" : ""
                root.statusText = "目录树共 " + Number(result.totalFiles || 0) + " 个文件，总大小 " + root.totalSizeText + extra + "；单击文件夹行展开/折叠，勾选文件后点\"开始下载\""
                return
            }
            var items = result.items || []
            rowsModel.clear()
            for (var i = 0; i < items.length; i++) {
                var item = items[i]
                rowsModel.append({
                    "rowId": String(item.id || ("row-" + i)),
                    "name": String(item.name || ""),
                    "size": String(item.size || item.sizeDisplay || ""),
                    "type": String(item.type || "file"),
                    "downloadUrl": String(item.downloadUrl || ""),
                    "checked": false,
                    "depth": 0,
                    "hasChildren": false,
                    "expanded": false,
                    "entry": item
                })
            }
            if (items.length === 0) {
                var singleUrl = String(result.url || "")
                if (singleUrl && singleUrl.length > 0) {
                    rowsModel.append({
                        "rowId": "file-0",
                        "name": String(result.fileName || "文件"),
                        "size": "",
                        "type": "file",
                        "downloadUrl": singleUrl,
                        "depth": 0,
                        "hasChildren": false,
                        "expanded": false,
                        "entry": result
                    })
                }
            }
            root.treeData = []
            root.treeLoaded = false
            root.totalSizeText = root.formatBytes(Number(result.totalSize || 0))
            root.statusText = "共 " + rowsModel.count + " 项，总大小 " + root.totalSizeText + "；勾选文件后点击\"开始下载\""
        }

        function onDirectorySelected(requestId, path, completed) {
            if (completed && path.length > 0) {
                root.saveDirectory = path
                root.spPlugin.set("saveDirectory", path)
            }
        }

        function onDownloadStarted(requestId, response) {
            var info = root.queueByRequest[String(requestId)]
            if (!info) {
                info = {"key": "", "name": "下载任务", "taskId": "", "status": "submitted", "retries": 0}
                root.queueByRequest[String(requestId)] = info
            }
            var taskId = ""
            if (response) {
                taskId = String(response.taskId || response.task_id || response.id || "")
            }
            info.taskId = taskId
            if (response && response.ok === false) {
                info.status = "failed"
                root.failedCount++
                root.queuedCount = Math.max(0, root.queuedCount - 1)
                root.spPlugin.showToast("任务创建失败：" + String(info.name), "error", "gdrive-queue-fail")
                return
            }
            if (taskId.length > 0) {
                root.queueByTask[String(taskId)] = info
            }
            info.status = "queued"
        }

        function onDownloadProgress(task) {
            if (!task)
                return
            var taskId = String(task.taskId || task.task_id || task.id || "")
            if (taskId.length === 0)
                return
            var info = root.queueByTask[String(taskId)]
            if (!info)
                return
            var state = String(task.state || task.status || "")
            var bytesReceived = Number(task.receivedBytes || task.completedBytes || task.bytesReceived || 0)
            var bytesTotal = Number(task.totalBytes || task.total || 0)
            var isDone = /^done$|^completed$|^finished$/.test(state)
            var isFailed = /fail|error|abort|interrupt|timeout/i.test(state)
            if (isDone || (bytesTotal > 0 && bytesReceived >= bytesTotal)) {
                info.status = "completed"
                root.finishedCount++
                root.queuedCount = Math.max(0, root.queuedCount - 1)
                root.spPlugin.showToast("下载完成：" + String(info.name), "success", "gdrive-done-" + taskId)
            } else if (isFailed) {
                if (root.autoRetry && info.retries < 5 && info.taskId.length > 0) {
                    info.retries++
                    info.status = "resuming"
                    root.spPlugin.log("下载中断，自动续传 " + info.retries + "/5：" + String(info.name))
                    root.spPlugin.controlDownload("resume", info.taskId, false)
                } else {
                    info.status = "failed"
                    root.failedCount++
                    root.queuedCount = Math.max(0, root.queuedCount - 1)
                    root.spPlugin.showToast("下载失败：" + String(info.name), "error", "gdrive-fail-" + taskId)
                }
            } else {
                info.status = "running"
                root.queuedCount = Math.max(0, root.queuedCount - 1)
            }
        }

        function onDownloadControlFinished(requestId, response) {
        }
    }

    Column {
        anchors.fill: parent
        spacing: root.sectionSpacing

        Row {
            id: linkRow
            width: parent.width
            spacing: root.sectionSpacing

            AppTextField {
                id: linkField
                width: parent.width - routeButton.width - parseButton.width - parent.spacing * 2
                placeholderText: "粘贴分享链接（文件或文件夹）"
            }

            AppButton {
                id: routeButton
                text: "线路：" + root.routeLabelText()
                onClicked: routeMenu.openForActionsAtItem(root.routeMenuActions(), routeButton, 0, routeButton.height)
            }

            AppButton {
                id: parseButton
                text: root.requestId.length === 0 ? "解析" : "解析中..."
                enabled: root.requestId.length === 0
                onClicked: root.parseLink()
            }
        }

        Row {
            id: pathRow
            width: parent.width
            spacing: root.sectionSpacing

            AppTextField {
                id: pathField
                width: parent.width - selectButton.width - parent.spacing
                text: root.saveDirectory.length > 0
                      ? root.saveDirectory : "公共临时下载目录"
                readOnly: true
            }

            AppButton {
                id: selectButton
                text: "选择..."
                onClicked: root.chooseDirectory()
            }
        }

        Row {
            id: breadcrumbRow
            width: parent.width
            spacing: root.sectionSpacing
            visible: root.treeLoaded

            Text {
                text: "目录："
                color: PluginTheme.mutedText
                font.pixelSize: PluginTheme.smallFontSize
                anchors.verticalCenter: parent.verticalCenter
            }

            Text {
                width: parent.width - expandAllButton.width - collapseAllButton.width - refreshButton.width - parent.spacing * 4 - 40
                elide: Text.ElideMiddle
                text: root.treeRootUrl
                color: PluginTheme.text
                font.pixelSize: PluginTheme.smallFontSize
                anchors.verticalCenter: parent.verticalCenter
            }

            AppButton {
                id: expandAllButton
                text: "展开全部"
                outlineGhost: false
                anchors.verticalCenter: parent.verticalCenter
                enabled: root.requestId.length === 0
                onClicked: {
                    root.expandedSet = ({})
                    for (var i = 0; i < root.treeData.length; i++) {
                        expandNodeRecursive(root.treeData[i], root.expandedSet)
                    }
                    root.renderTree()
                }
            }

            AppButton {
                id: collapseAllButton
                text: "折叠全部"
                outlineGhost: false
                anchors.verticalCenter: parent.verticalCenter
                enabled: root.requestId.length === 0
                onClicked: {
                    root.expandedSet = ({})
                    root.renderTree()
                }
            }

            AppButton {
                id: refreshButton
                text: "刷新"
                anchors.verticalCenter: parent.verticalCenter
                enabled: root.requestId.length === 0
                onClicked: {
                    if (root.treeRootUrl.length > 0)
                        root.loadFolderTree(root.treeRootUrl)
                    else
                        root.parseLink()
                }
            }
        }

        Row {
            id: headerRow
            width: table.width
            height: PluginTheme.controlHeight
            visible: rowsModel.count > 0

            Item {
                width: table.width * 0.09
                height: parent.height
            }
            Text {
                width: table.width * 0.44
                height: parent.height
                verticalAlignment: Text.AlignVCenter
                text: "文件名"
                color: PluginTheme.mutedText
                font.pixelSize: PluginTheme.smallFontSize
                font.bold: true
            }
            Text {
                width: table.width * 0.18
                height: parent.height
                verticalAlignment: Text.AlignVCenter
                text: "大小"
                color: PluginTheme.mutedText
                font.pixelSize: PluginTheme.smallFontSize
                font.bold: true
            }
            Text {
                width: table.width - table.width * 0.09 - table.width * 0.44 - table.width * 0.18
                height: parent.height
                verticalAlignment: Text.AlignVCenter
                text: "类型 / 操作"
                color: PluginTheme.mutedText
                font.pixelSize: PluginTheme.smallFontSize
                font.bold: true
            }
        }

        AppTableView {
            id: table
            width: parent.width
            height: Math.max(80, parent.height
                             - linkRow.implicitHeight - pathRow.implicitHeight
                             - breadcrumbRow.implicitHeight - headerRow.implicitHeight
                             - parent.spacing * 5)
            model: rowsModel
            selectionController: selection
            standardSelectionEnabled: true
            rowHeight: PluginTheme.controlHeight

            delegate: AppTableCell {
                required property int index
                required property string rowId
                required property string name
                required property string size
                required property string type
                required property int depth
                required property bool expanded
                required property bool hasChildren

                property real colCheck: table.width * 0.09
                property real colName: table.width * 0.44
                property real colSize: table.width * 0.18

                width: table.width
                height: table.rowHeight
                text: ""
                rowInteractionEnabled: true
                listView: table
                eventTarget: table.pointerTarget
                rowIndex: index
                rowData: rowsModel.get(index)
                rightClickOnRelease: true

                onRowPressed: function(row, data, modifiers) {
                    if (data && String(data.type || "") === "folder") {
                        root.toggleRow(data)
                    } else {
                        table.standardSelectRow(row, modifiers)
                    }
                }
                onRowContextRequested: function(row, data, sourceItem, x, y) {
                    table.standardSelectContextRow(row)
                    root.contextRowIndex = row
                    root.contextRowData = data
                    menu.openForActionsAtItem(root.contextActions(data), sourceItem, x, y)
                }

                AppCheckBox {
                    id: checkBox
                    anchors.left: parent.left
                    anchors.leftMargin: PluginTheme.dp(4)
                    anchors.verticalCenter: parent.verticalCenter
                    width: PluginTheme.dp(24)
                    height: PluginTheme.dp(24)
                    enabled: type !== "folder"
                    checked: rowsModel.get(index) ? rowsModel.get(index).checked : false
                    onToggled: function() {
                        if (index >= 0 && index < rowsModel.count) {
                            rowsModel.setProperty(index, "checked", checked)
                        }
                    }
                }
                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: colCheck + depth * PluginTheme.dp(16) + PluginTheme.dp(8)
                    anchors.verticalCenter: parent.verticalCenter
                    width: colName - depth * PluginTheme.dp(16) - PluginTheme.dp(8)
                    elide: Text.ElideMiddle
                    text: (type === "folder" ? (expanded ? "▼ " : "▶ ") : "  ") + name
                    color: type === "folder" ? PluginTheme.primary : PluginTheme.text
                    font.pixelSize: PluginTheme.smallFontSize
                }
                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: colCheck + colName + PluginTheme.dp(8)
                    anchors.verticalCenter: parent.verticalCenter
                    width: colSize - PluginTheme.dp(8)
                    elide: Text.ElideRight
                    text: size
                    color: PluginTheme.mutedText
                    font.pixelSize: PluginTheme.smallFontSize
                }
                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: colCheck + colName + colSize + PluginTheme.dp(8)
                    anchors.verticalCenter: parent.verticalCenter
                    width: table.width - colCheck - colName - colSize - PluginTheme.dp(8)
                    elide: Text.ElideRight
                    text: type === "folder" ? "文件夹" : "文件"
                    color: type === "folder" ? PluginTheme.primary : PluginTheme.mutedText
                    font.pixelSize: PluginTheme.smallFontSize
                }
                AppButton {
                    anchors.right: parent.right
                    anchors.rightMargin: PluginTheme.dp(8)
                    anchors.verticalCenter: parent.verticalCenter
                    text: type === "folder" ? (expanded ? "折叠" : "展开") : "下载"
                    outlineGhost: false
                    onClicked: {
                        if (type === "folder") {
                            root.toggleRow(rowsModel.get(index))
                        } else {
                            root.startDownload(rowsModel.get(index))
                        }
                    }
                }
            }
        }
    }

    ListModel { id: rowsModel }

    AppTableSelectionController {
        id: selection
        rowIdentityAt: function(row) {
            return row >= 0 && row < rowsModel.count ? String(rowsModel.get(row).rowId || "") : ""
        }
    }

    AppContextMenu {
        id: menu
        onActionTriggered: function(action) {
            root.handleContextAction(action)
        }
    }

    AppContextMenu {
        id: routeMenu
        onActionTriggered: function(action) {
            root.handleRouteAction(action)
        }
    }

    footerActions: AppButton {
        text: "开始下载"
        primary: true
        enabled: root.requestId.length === 0 && rowsModel.count > 0
        onClicked: root.downloadSelected()
    }
}