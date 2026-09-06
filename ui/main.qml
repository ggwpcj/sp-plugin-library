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
    property var savedLinks: []
    property int lastPressRow: -1
    property int lastPressTime: 0

    Component.onCompleted: {
        root.loadSavedLinks()
        root.reloadLinkPool()
        if (depthBox) depthBox.currentIndex = (root.depthMode === "current") ? 1 : 0
        if (storageBox) storageBox.currentIndex = (root.storageMode === "parent") ? 1 : (root.storageMode === "current") ? 2 : 0
        if (root.route === "auto") {
            root.route = "second"
            root.spPlugin.set("route", root.route)
        }
    }

    function loadSavedLinks() {
        var raw = root.spPlugin.get("savedLinks", "")
        root.savedLinks = []
        var saved = []
        if (typeof raw === "string" && raw.length > 0) {
            try {
                saved = JSON.parse(raw)
            } catch (error) {
                saved = []
            }
        } else if (Array.isArray(raw)) {
            saved = raw
        }
        if (Array.isArray(saved)) {
            for (var i = 0; i < saved.length; i++) {
                var item = saved[i]
                root.savedLinks.push({
                    "url": String(item && item.url ? item.url : item || ""),
                    "name": String(item && item.name ? item.name : (item && item.url ? item.url : item || ""))
                })
            }
        }
    }

    function linkPoolNames() {
        var names = []
        for (var i = 0; i < root.savedLinks.length; i++) {
            names.push(root.savedLinks[i].name)
        }
        return names
    }

    function reloadLinkPool() {
        var names = root.linkPoolNames()
        if (linkPoolBox)
            linkPoolBox.model = names
        linkPoolBox.currentIndex = -1
    }

    function persistLinks() {
        var json = ""
        try {
            json = JSON.stringify(root.savedLinks)
        } catch (error) {
            json = ""
        }
        root.spPlugin.set("savedLinks", json)
    }

    function linkPoolIndexOf(url) {
        for (var i = 0; i < root.savedLinks.length; i++) {
            if (root.savedLinks[i].url === url)
                return i
        }
        return -1
    }

    function autoLinkName(url) {
        var clean = String(url || "").trim()
        if (clean.length === 0)
            return "谷歌网盘链接"
        var last = clean.replace(/\/+$/, "").split("/").pop() || ""
        var short = String(last || clean)
        if (short.length > 40)
            short = short.substring(0, 40)
        return short
    }

    function ensureLinkSaved() {
        var link = linkField.text.trim()
        if (link.length === 0)
            return
        if (root.linkPoolIndexOf(link) >= 0)
            return
        root.savedLinks.push({"url": link, "name": root.autoLinkName(link)})
        root.persistLinks()
        root.reloadLinkPool()
    }

    function saveCurrentLink() {
        var link = linkField.text.trim()
        if (link.length === 0) {
            root.spPlugin.showToast("请先粘贴分享链接再保存", "warning", "gdrive-save-empty")
            return
        }
        var index = root.linkPoolIndexOf(link)
        var name = root.renameText.text.trim()
        if (name.length === 0)
            name = root.autoLinkName(link)
        if (index >= 0) {
            root.savedLinks[index].name = name
            root.persistLinks()
            root.reloadLinkPool()
            root.spPlugin.showToast("已更新该链接的名称", "success", "gdrive-save-renamed")
            return
        }
        root.savedLinks.push({"url": link, "name": name})
        root.persistLinks()
        root.reloadLinkPool()
        root.spPlugin.showToast("链接已保存到链接池", "success", "gdrive-save-ok")
    }

    function deleteCurrentLink() {
        var index = linkPoolBox.currentIndex
        if (index < 0 || index >= root.savedLinks.length)
            return
        root.savedLinks.splice(index, 1)
        root.persistLinks()
        root.reloadLinkPool()
        root.spPlugin.showToast("已从链接池删除", "success", "gdrive-save-deleted")
    }

    function useSelectedLink() {
        var index = linkPoolBox.currentIndex
        if (index < 0 || index >= root.savedLinks.length)
            return
        var url = root.savedLinks[index].url
        linkField.text = url
        root.parseLink()
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

    function loadFolderTree(url) {
        linkField.text = url
        if (root.depthMode === "current") {
            root.statusText = "正在获取当前目录内容..."
            root.requestId = root.spPlugin.call("list_folder", {"url": url, "route": root.route}, 120000)
        } else {
            root.statusText = "正在获取完整目录树..."
            root.requestId = root.spPlugin.call("list_folder_tree", {"url": url, "route": root.route}, 300000)
        }
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
                "path": String(node.path || ""),
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
            root.statusText = "共显示 " + rows.length + " 项；单击选中，双击文件夹展开，勾选文件后点\"开始下载\""
        }
    }

    function toggleRow(row) {
        if (!row)
            return
        if (row.type !== "folder")
            return
        if (root.depthMode === "current") {
            var folderId = String(row.rowId || row.id || "")
            if (!folderId || folderId.indexOf("row-") === 0 || folderId.indexOf("node-") === 0)
                return
            root.loadFolderTree("https://drive.google.com/drive/folders/" + folderId)
            return
        }
        var id = String(row.rowId || row.id || "")
        if (!id || id.indexOf("row-") === 0 || id.indexOf("node-") === 0)
            return
        if (root.expandedSet[id])
            delete root.expandedSet[id]
        else
            root.expandedSet[id] = true
        root.renderTree()
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
        if (!entry || !entry.downloadUrl)
            return
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
                root.statusText = "目录树共 " + Number(result.totalFiles || 0) + " 个文件，总大小 " + root.totalSizeText + extra + "；单击选中，双击文件夹展开，勾选文件后点\"开始下载\""
                root.ensureLinkSaved()
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
                    "path": String(item.path || ""),
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
                        "path": "",
                        "checked": false,
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
            root.ensureLinkSaved()
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
            id: renameRow
            width: parent.width
            spacing: root.sectionSpacing

            AppTextField {
                id: renameText
                width: parent.width - saveButton.width - parent.spacing
                placeholderText: "（可选）给这个链接起个名字，便于识别"
            }

            AppButton {
                id: saveButton
                text: "保存到链接池"
                outlineGhost: false
                onClicked: root.saveCurrentLink()
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
            id: optionsRow
            width: parent.width
            spacing: root.sectionSpacing

            AppFormRow {
                label: "链接池"
                width: parent.width * 0.34
                AppSelect {
                    id: linkPoolBox
                    anchors.fill: parent
                    model: root.linkPoolNames()
                    onActivated: function() {
                        root.useSelectedLink()
                    }
                }
            }

            AppButton {
                text: "删除"
                outlineGhost: true
                anchors.verticalCenter: parent.verticalCenter
                onClicked: root.deleteCurrentLink()
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
                text: "类型"
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
                    var isFolder = (data && String(data.type || "") === "folder")
                    var now = (new Date()).getTime()
                    if (isFolder && row === root.lastPressRow && (now - root.lastPressTime) < 450) {
                        root.lastPressRow = -1
                        root.lastPressTime = 0
                        root.toggleRow(data)
                    } else {
                        root.lastPressRow = row
                        root.lastPressTime = now
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