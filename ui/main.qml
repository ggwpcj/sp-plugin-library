import QtQuick 2.15
import SP.Plugin 1.0

PluginWorkspacePage {
    id: root
    toolbarUsesFloatingPlaceholder: true

    property string requestId: ""
    property string saveDirectory: String(root.spPlugin.get("saveDirectory", ""))
    property string route: String(root.spPlugin.get("route", "auto"))
    property int contextRowIndex: -1
    property var contextRowData: null

    function chooseDirectory() {
        root.spPlugin.chooseDirectory("选择保存目录", root.saveDirectory)
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
        root.spPlugin.download({
            "url": String(entry.downloadUrl),
            "directory": root.saveDirectory,
            "fileName": String(entry.name || "file"),
            "displayName": String(entry.name || "file"),
            "taskKey": "gdrive-" + String(entry.id || entry.name || ""),
            "kind": "gdrive",
            "route": root.route,
            "autoRename": true,
            "showProgressToast": true
        })
    }

    function downloadSelected() {
        var rows = selection.selectedRowArray()
        var started = 0
        for (var i = 0; i < rows.length; i++) {
            var row = Number(rows[i])
            if (row >= 0 && row < rowsModel.count) {
                var data = rowsModel.get(row)
                if (data && data.downloadUrl && data.downloadUrl.length > 0) {
                    root.startDownload(data)
                    started++
                }
            }
        }
        if (rows.length === 0) {
            root.spPlugin.showToast("请先选择要下载的文件", "warning", "gdrive-no-selection")
        } else if (started > 0) {
            root.spPlugin.showToast("已创建 " + started + " 个下载任务", "success", "gdrive-download-queued")
        } else {
            root.spPlugin.showToast("所选项目中没有可下载的文件", "warning", "gdrive-no-downloadable")
        }
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
            root.statusText = "共 " + rowsModel.count + " 项，双击文件夹进入，右键选择操作，选中后点击\"开始下载\""
        }

        function onDirectorySelected(requestId, path, completed) {
            if (completed && path.length > 0) {
                root.saveDirectory = path
                root.spPlugin.set("saveDirectory", path)
            }
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

        AppTableView {
            id: table
            width: parent.width
            height: Math.max(80, parent.height
                             - linkRow.implicitHeight - pathRow.implicitHeight
                             - breadcrumbRow.implicitHeight - hintText.implicitHeight
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

                property var lastPressTime: 0
                property int lastPressRow: -1

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
                    var now = new Date().getTime()
                    if (now - lastPressTime < 350 && lastPressRow === row) {
                        lastPressTime = 0
                        root.openRow(data)
                    } else {
                        lastPressTime = now
                        lastPressRow = row
                    }
                }
                onRowContextRequested: function(row, data, sourceItem, x, y) {
                    table.standardSelectContextRow(row)
                    root.contextRowIndex = row
                    root.contextRowData = data
                    menu.openForActionsAtItem(root.contextActions(data), sourceItem, x, y)
                }

                Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: PluginTheme.dp(8)
                    width: table.width * 0.56
                    elide: Text.ElideMiddle
                    text: name
                    color: PluginTheme.text
                    font.pixelSize: PluginTheme.smallFontSize
                }
                Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: table.width * 0.56 + PluginTheme.dp(8)
                    width: table.width * 0.22
                    elide: Text.ElideRight
                    text: size
                    color: PluginTheme.mutedText
                    font.pixelSize: PluginTheme.smallFontSize
                }
                Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: table.width * 0.78 + PluginTheme.dp(8)
                    text: type === "folder" ? "文件夹" : "文件"
                    color: type === "folder" ? PluginTheme.primary : PluginTheme.mutedText
                    font.pixelSize: PluginTheme.smallFontSize
                }
            }
        }

        Text {
            id: hintText
            width: parent.width
            text: "提示：单击行选中，双击文件夹进入，双击文件下载；右键菜单可进入/下载/刷新/返回上级。"
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