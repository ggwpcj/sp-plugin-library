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

    function loadFolders(url) {
        linkField.text = url
        root.statusText = "正在获取文件夹内容..."
        root.requestId = root.spPlugin.call("list_folder", {"url": url, "route": root.route}, 120000)
    }

    function loadFile(url) {
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
        navModel.clear()
        if (/\/drive\/folders\//.test(link)) {
            navModel.append({"name": "网盘根目录", "url": link})
            root.loadFolders(link)
        } else {
            navModel.append({"name": "文件下载", "url": link})
            root.loadFile(link)
        }
    }

    function openRow(row) {
        if (!row)
            return
        if (row.type === "folder") {
            var url = "https://drive.google.com/drive/folders/" + String(row.id || "")
            navModel.append({"name": String(row.name || "文件夹"), "url": url})
            root.loadFolders(url)
        } else if (row.type === "file") {
            root.startDownload(row)
        }
    }

    function goUp() {
        if (navModel.count > 1) {
            navModel.remove(navModel.count - 1)
            root.loadCurrent()
        }
    }

    function goToBreadcrumb(index) {
        if (index < 0 || index >= navModel.count - 1)
            return
        navModel.remove(index + 1, navModel.count - index - 1)
        root.loadCurrent()
    }

    function loadCurrent() {
        if (navModel.count > 0)
            root.loadFolders(String(navModel.get(navModel.count - 1).url))
    }

    function refreshCurrent() {
        if (navModel.count > 0 && /drive\/folders\//.test(String(navModel.get(navModel.count - 1).url)))
            root.loadCurrent()
        else
            root.parseLink()
    }

    function startDownload(entry) {
        if (!entry || !entry.downloadUrl)
            return
        var key = "gdrive-" + String(entry.id || entry.name || "")
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
        found.status = "retrying"
        root.spPlugin.controlDownload("retry", String(found.taskId), false)
    }

    function contextActions(row) {
        var actions = []
        if (row && row.type === "folder")
            actions.push({"text": "进入文件夹", "action": "open-folder"})
        if (row && row.type === "file")
            actions.push({"text": "下载该文件", "action": "download-one"})
        actions.push({"separator": true})
        if (navModel.count > 1)
            actions.push({"text": "返回上级目录", "action": "go-up"})
        actions.push({"text": "刷新当前文件夹", "action": "refresh"})
        actions.push({"separator": true})
        actions.push({"text": "下载选中项", "action": "download-selected"})
        return actions
    }

    function handleContextAction(action) {
        var row = root.contextRowData
        if (action === "open-folder") {
            root.openRow(row)
        } else if (action === "download-one") {
            root.startDownload(row)
        } else if (action === "go-up") {
            root.goUp()
        } else if (action === "refresh") {
            root.refreshCurrent()
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
                        "entry": result
                    })
                }
            }
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
            queueStatusDirty()
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
                if (root.autoRetry && info.retries < 3 && info.taskId.length > 0) {
                    info.retries++
                    info.status = "retrying"
                    root.spPlugin.log("下载失败，自动重试 " + info.retries + "/3：" + String(info.name))
                    root.spPlugin.controlDownload("retry", info.taskId, false)
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
            queueStatusDirty()
        }

        function onDownloadControlFinished(requestId, response) {
            queueStatusDirty()
        }
    }

    function queueStatusDirty() {
        var running = 0
        var done = 0
        var fail = 0
        for (var id in root.queueByTask) {
            var info = root.queueByTask[id]
            var s = String(info.status)
            if (s === "running")
                running++
            else if (s === "completed")
                done++
            else if (s === "failed")
                fail++
        }
        queueCountText.text = "队列：进行中 " + running + " · 完成 " + done + " · 失败 " + fail + "（自动重试开）"
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
            visible: navModel.count > 0

            Text {
                text: "位置："
                color: PluginTheme.mutedText
                font.pixelSize: PluginTheme.smallFontSize
                anchors.verticalCenter: parent.verticalCenter
            }

            Repeater {
                model: navModel
                delegate: AppButton {
                    text: String(model.name || "网盘根目录")
                    outlineGhost: false
                    anchors.verticalCenter: parent.verticalCenter
                    onClicked: root.goToBreadcrumb(model.index)
                }
            }

            AppButton {
                text: "刷新"
                anchors.verticalCenter: parent.verticalCenter
                enabled: root.requestId.length === 0
                onClicked: root.refreshCurrent()
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
                             - queueCountText.implicitHeight - hintText.implicitHeight
                             - parent.spacing * 7)
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
                    table.standardSelectRow(row, modifiers)
                }
                onRowContextRequested: function(row, data, sourceItem, x, y) {
                    table.standardSelectContextRow(row)
                    root.contextRowIndex = row
                    root.contextRowData = data
                    menu.openForActionsAtItem(root.contextActions(data), sourceItem, x, y)
                }

                CheckBox {
                    id: checkBox
                    anchors.left: parent.left
                    anchors.leftMargin: PluginTheme.dp(4)
                    anchors.verticalCenter: parent.verticalCenter
                    width: PluginTheme.dp(24)
                    height: PluginTheme.dp(24)
                    checked: rowsModel.get(index) ? rowsModel.get(index).checked : false
                    onToggled: function() {
                        if (index >= 0 && index < rowsModel.count) {
                            rowsModel.setProperty(index, "checked", checked)
                        }
                    }
                }
                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: colCheck + PluginTheme.dp(8)
                    anchors.verticalCenter: parent.verticalCenter
                    width: colName - PluginTheme.dp(8)
                    elide: Text.ElideMiddle
                    text: name
                    color: PluginTheme.text
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
                    text: type === "folder" ? "进入" : "下载"
                    outlineGhost: false
                    onClicked: {
                        if (type === "folder") {
                            root.openRow(rowsModel.get(index))
                        } else {
                            root.startDownload(rowsModel.get(index))
                        }
                    }
                }
            }
        }

        Text {
            id: queueCountText
            width: parent.width
            text: "队列：进行中 0 · 完成 0 · 失败 0（自动重试开）"
            color: PluginTheme.primary
            font.pixelSize: PluginTheme.smallFontSize
            wrapMode: Text.Wrap
        }

        Text {
            id: hintText
            width: parent.width
            text: "提示：勾选文件后点\"开始下载\"加入队列；点\"进入\"进入子文件夹；右键菜单可进入/下载/刷新/返回上级。"
            color: PluginTheme.mutedText
            font.pixelSize: PluginTheme.smallFontSize
            wrapMode: Text.Wrap
        }
    }

    ListModel { id: rowsModel }

    ListModel { id: navModel }

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