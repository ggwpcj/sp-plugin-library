import QtQuick 2.15
import QtQuick.Controls 2.15
import SP.Plugin 1.0

PluginWorkspacePage {
    id: root
    toolbarUsesFloatingPlaceholder: true

    property string requestId: ""
    property string saveDirectory: String(root.spPlugin.get("saveDirectory", ""))
    property string route: String(root.spPlugin.get("route", "second"))
    property string depthMode: String(root.spPlugin.get("depthMode", "tree"))
    property string storageMode: String(root.spPlugin.get("storageMode", "original"))
    property var contextRowData: null
    property string totalSizeText: ""
    property var queueByRequest: ({})
    property var queueByTask: ({})
    property int queuedCount: 0
    property int finishedCount: 0
    property int failedCount: 0
    property bool autoRetry: true
    property var pendingRetry: ({})
    property var driveRows: []
    property string treeRootUrl: ""
    property var pathStack: []

    Component.onCompleted: {
        if (depthBox) depthBox.currentIndex = (root.depthMode === "current") ? 1 : 0
        if (storageBox) storageBox.currentIndex = (root.storageMode === "parent") ? 1 : (root.storageMode === "current") ? 2 : 0
        if (root.route === "auto") {
            root.route = "second"
            root.spPlugin.set("route", root.route)
        }
    }

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
        if (root.route === "managed_direct") {
            try {
                var label = root.spPlugin.routeLabel("managed_direct", "核心内直连")
                return String(label || "核心内直连")
            } catch (error) {
                return "核心内直连"
            }
        }
        return "二级代理"
    }

    function chooseRoute(routeName) {
        root.route = String(routeName || "second")
        root.spPlugin.set("route", root.route)
        if (root.route === "front" || root.route === "second")
            root.spPlugin.checkProxy(root.route, "解析谷歌网盘")
        routeButton.text = "线路：" + root.routeLabelText()
    }

    function routeMenuActions() {
        var directLabel = ""
        try {
            directLabel = root.spPlugin.routeLabel("managed_direct", "核心内直连")
        } catch (error) {
            directLabel = "核心内直连"
        }
        return [
            {"text": directLabel, "action": "managed_direct"},
            {"text": "一级代理", "action": "front"},
            {"text": "二级代理", "action": "second"}
        ]
    }

    function handleRouteAction(action) {
        root.chooseRoute(action)
    }

    function folderIdFor(row) {
        return String((row && (row.id || row.folderId)) || "")
    }

    function isFolderRow(row) {
        return !!(row && String(row.type || "") === "folder")
    }

    function resolveFolderTree(url) {
        if (!/\/drive\/folders\//.test(url))
            return ""
        var m = url.match(/\/drive\/folders\/([^/?#]+)/)
        return (m && m[1]) || ""
    }

    function loadFolder(url) {
        linkField.text = url
        root.statusText = "正在获取目录内容..."
        root.requestId = root.spPlugin.call("list_folder", {"url": url, "route": root.route}, 300000)
    }

    function loadFileUrl(url) {
        linkField.text = url
        root.statusText = "正在获取文件下载地址..."
        root.requestId = root.spPlugin.call("resolve_download", {"url": url, "route": root.route}, 120000)
    }

    function openFolder(row) {
        if (!root.isFolderRow(row))
            return
        var fid = root.folderIdFor(row)
        if (!fid)
            return
        var next = root.pathStack.slice()
        next.push({"id": fid, "name": String(row.name || "")})
        root.pathStack = next
        root.loadFolder("https://drive.google.com/drive/folders/" + fid)
    }

    function goUp() {
        if (root.pathStack.length <= 1)
            return
        var next = root.pathStack.slice(0, root.pathStack.length - 1)
        root.pathStack = next
        if (next.length > 0) {
            var parent = next[next.length - 1]
            root.loadFolder("https://drive.google.com/drive/folders/" + String(parent.id || ""))
        } else {
            root.parseLink()
        }
    }

    function goToRoot() {
        root.pathStack = []
        root.parseLink()
    }

    function breadcrumbText() {
        var names = root.pathStack.map(function(row) { return String(row.name || "") })
        return "/" + names.join("/")
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
        root.driveRows = []
        root.pathStack = []
        root.treeRootUrl = link
        if (/\/drive\/folders\//.test(link)) {
            var fid = root.resolveFolderTree(link)
            if (fid)
                root.pathStack = [{"id": fid, "name": ""}]
            root.loadFolder(link)
        } else {
            root.loadFileUrl(link)
        }
    }

    function buildSaveDirectory(entry) {
        var base = String(root.saveDirectory || "").replace(/[\\/]+$/, "")
        if (base.length === 0)
            return ""
        if (root.storageMode === "current")
            return base
        var path = String(entry && entry.path ? entry.path : "").replace(/\\/g, "/").replace(/^\/+/, "").replace(/\/+$/, "")
        if (path.length === 0)
            return base
        var parts = path.split("/").filter(function(p) { return p && p.length > 0 })
        if (root.storageMode === "parent") {
            if (parts.length > 0)
                return base + "/" + parts[parts.length - 1]
            return base
        }
        var safe = []
        for (var i = 0; i < parts.length; i++) {
            var part = parts[i]
            var cleaned = part.replace(/[\\/:*?"<>|]/g, "_").trim()
            if (cleaned && cleaned !== "." && cleaned !== "..")
                safe.push(cleaned)
        }
        return base + (safe.length > 0 ? "/" + safe.join("/") : "")
    }

    function startDownload(entry) {
        if (!entry || !entry.downloadUrl) {
            root.spPlugin.log("跳过下载：条目无 downloadUrl → " + String(entry && entry.name ? entry.name : "(空)"))
            return
        }
        var key = "gdrive-" + String(entry.rowId || entry.id || entry.name || "")
        var directory = root.buildSaveDirectory(entry)
        if (directory.length === 0) {
            root.spPlugin.showToast("请先选择保存目录", "warning", "gdrive-no-directory")
            return
        }
        var requestId = root.spPlugin.download({
            "url": String(entry.downloadUrl),
            "directory": directory,
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

    function itemsWithUrl() {
        var selected = table.selectedItems()
        if (!selected || selected.length === 0)
            return []
        return selected.filter(function(row) {
            return root.isFolderRow(row) ? false : (row && row.downloadUrl && String(row.downloadUrl).length > 0)
        })
    }

    function downloadSelected() {
        var targets = root.itemsWithUrl()
        if (targets.length === 0) {
            root.spPlugin.showToast("请先选中要下载的文件", "warning", "gdrive-no-selection")
            return
        }
        for (var i = 0; i < targets.length; i++)
            root.startDownload(targets[i])
        root.spPlugin.showToast("已加入下载队列 " + targets.length + " 个任务", "success", "gdrive-download-queued")
    }

    function contextActions(row) {
        var actions = []
        if (row && row.type === "folder")
            actions.push({"text": "打开", "action": "open"})
        if (row && row.type === "file")
            actions.push({"text": "下载该文件", "action": "download-one"})
        actions.push({"separator": true})
        actions.push({"text": "回到根目录", "action": "go-root"})
        actions.push({"text": "刷新当前链接", "action": "refresh"})
        actions.push({"separator": true})
        actions.push({"text": "下载选中项", "action": "download-selected"})
        return actions
    }

    function handleContextAction(action, row) {
        var current = row || root.contextRowData
        root.spPlugin.log("上下文动作 action=" + String(action || "") + " 类型=" + String((current && current.type) || ""))
        if (action === "open") {
            root.openFolder(current)
        } else if (action === "download-one") {
            root.startDownload(current)
        } else if (action === "download-selected") {
            root.downloadSelected()
        } else if (action === "refresh") {
            if (root.pathStack.length > 0) {
                var cur = root.pathStack[root.pathStack.length - 1]
                root.loadFolder("https://drive.google.com/drive/folders/" + String(cur.id || ""))
            } else if (root.treeRootUrl.length > 0) {
                root.loadFolder(root.treeRootUrl)
            } else {
                root.parseLink()
            }
        } else if (action === "go-root") {
            root.goToRoot()
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
            if (result.items) {
                root.driveRows = result.items
                root.pathStack = root.pathStack || []
                if (root.pathStack.length > 0 && !String(root.pathStack[0].name || "").length) {
                    var top = root.pathStack[0]
                    top.name = String(result.folderName || result.name || top.name || "")
                    root.pathStack = root.pathStack.slice()
                }
                root.totalSizeText = root.formatBytes(Number(result.totalSize || 0))
                root.statusText = "共 " + result.items.length + " 项，总大小 " + root.totalSizeText
                            + "；单击选中，双击文件夹进入，点\"开始下载\"下载选中文件"
                return
            }
            var singleUrl = String(result.url || "")
            var singleItem = null
            if (singleUrl && singleUrl.length > 0) {
                singleItem = {
                    "id": "file-0",
                    "name": String(result.fileName || "文件"),
                    "size": "",
                    "type": "file",
                    "downloadUrl": singleUrl,
                    "path": "",
                    "checked": false
                }
                root.driveRows = [singleItem]
                root.totalSizeText = root.formatBytes(Number(result.totalSize || 0))
                root.statusText = "单文件解析完成；单击选中，点\"开始下载\"下载"
            } else {
                root.driveRows = []
                root.totalSizeText = ""
                root.statusText = "未解析到内容"
            }
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
            id: depthStorageRow
            width: parent.width
            spacing: root.sectionSpacing

            AppFormRow {
                label: "检索深度"
                width: parent.width * 0.3
                AppSelect {
                    id: depthBox
                    anchors.fill: parent
                    model: ["全部解析", "当前深度"]
                    onActivated: function() {
                        root.depthMode = (currentIndex === 1) ? "current" : "tree"
                        root.spPlugin.set("depthMode", root.depthMode)
                    }
                }
            }

            AppFormRow {
                label: "目录存储"
                width: parent.width * 0.3
                AppSelect {
                    id: storageBox
                    anchors.fill: parent
                    model: ["原始层级", "仅使用父级", "当前目录"]
                    onActivated: function() {
                        var modes = ["original", "parent", "current"]
                        root.storageMode = (currentIndex >= 0 && currentIndex < modes.length) ? modes[currentIndex] : "original"
                        root.spPlugin.set("storageMode", root.storageMode)
                    }
                }
            }
        }

        Row {
            id: navRow
            width: parent.width
            spacing: root.sectionSpacing
            visible: root.driveRows.length > 0 || root.pathStack.length > 0

            AppButton {
                id: upButton
                text: "上一级"
                enabled: root.pathStack.length > 1 && root.requestId.length === 0
                onClicked: root.goUp()
            }
            AppButton {
                id: rootButton
                text: "根目录"
                enabled: root.requestId.length === 0 && root.driveRows.length > 0
                onClicked: root.goToRoot()
            }
            Text {
                width: parent.width - upButton.width - rootButton.width - refreshButton.width - parent.spacing * 4
                elide: Text.ElideMiddle
                verticalAlignment: Text.AlignVCenter
                text: root.breadcrumbText()
                color: PluginTheme.text
                font.pixelSize: PluginTheme.smallFontSize
                anchors.verticalCenter: parent.verticalCenter
            }
            AppButton {
                id: refreshButton
                text: "刷新"
                enabled: root.requestId.length === 0
                onClicked: {
                    if (root.pathStack.length > 0) {
                        var cur = root.pathStack[root.pathStack.length - 1]
                        root.loadFolder("https://drive.google.com/drive/folders/" + String(cur.id || ""))
                    } else if (root.treeRootUrl.length > 0) {
                        root.loadFolder(root.treeRootUrl)
                    } else {
                        root.parseLink()
                    }
                }
            }
        }

        PluginDataTable {
            id: table
            width: parent.width
            height: Math.max(120, parent.height
                             - linkRow.implicitHeight - pathRow.implicitHeight
                             - depthStorageRow.implicitHeight - navRow.implicitHeight
                             - parent.spacing * 5)
            rows: root.driveRows
            identityProvider: function(row, index) {
                return String((row || {}).id || index)
            }
            columns: [
                {"title": "名称", "weight": 3, "key": "name", "align": "left",
                 "formatter": function(row) { return row.type === "folder" ? "文件夹 / " + String(row.name || "") : String(row.name || "") }},
                {"title": "大小", "weight": 1,
                 "formatter": function(row) {
                     if (row.type === "folder")
                         return ""
                     return String(row.sizeDisplay || root.formatBytes(Number(row.sizeBytes || row.size || 0)))
                 }},
                {"title": "类型", "width": PluginTheme.dp(70),
                 "formatter": function(row) { return row.type === "folder" ? "文件夹" : "文件" }},
                {"title": "", "weight": 1}
            ]
            contextActionsProvider: function(selectedRows, currentRow) {
                return root.contextActions(currentRow)
            }
            onRowActivated: function(row) {
                var rtype = String((row && row.type) || "")
                var rname = String((row && row.name) || "")
                var rid = String((row && (row.id || row.folderId)) || "")
                root.spPlugin.log("双击/激活行 type=" + rtype + " name=" + rname + " id=" + rid)
                if (root.isFolderRow(row))
                    root.openFolder(row)
                else
                    root.startDownload(row)
            }
            onActionRequested: function(action, row) {
                root.handleContextAction(action, row)
            }
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
        enabled: root.requestId.length === 0 && root.driveRows.length > 0
        onClicked: root.downloadSelected()
    }
}