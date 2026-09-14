pragma ComponentBehavior: Bound

import QtQuick 2.15
import SP.Plugin 1.0

PluginWorkspacePage {
    id: root
    toolbarUsesFloatingPlaceholder: true
    toolbarHorizontalInset: 0

    property string requestId: ""
    property bool treeParsing: false
    property real treeProgress: 0
    property int parsedFolders: 0
    property int discoveredFolders: 0
    property string saveDirectory: String(root.spPlugin.get("saveDirectory", ""))
    property string route: String(root.spPlugin.get("route", "second"))
    property string depthMode: "tree"
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
    property var folderCache: ({})
    property var folderCacheOrder: []
    property bool treeCacheComplete: false
    property bool treeCacheTruncated: false
    property string pendingFolderId: ""
    property var pendingPathStack: []
    property var pendingRestorePath: []
    property bool pendingRefresh: false
    property string sizeRequestId: ""
    property string sizeFolderId: ""
    property var sizeQueueIds: []
    property var sizeBatchIds: []
    property int sizeCompleted: 0
    property int sizeTotal: 0
    property int sizeResolved: 0
    readonly property real actionButtonWidth: Math.max(parseButton.minWidth,
                                                       selectButton.minWidth)

    TextMetrics {
        id: depthOptionMetrics
        text: "全部解析"
        font.family: PluginTheme.fontFamily
        font.pixelSize: PluginTheme.controlFontSize
    }

    TextMetrics {
        id: storageOptionMetrics
        text: "仅使用父级"
        font.family: PluginTheme.fontFamily
        font.pixelSize: PluginTheme.controlFontSize
    }

    function selectFitWidth(metrics, control) {
        return Math.ceil(metrics.width) + control.horizontalPadding * 2
               + control.indicatorSize + PluginTheme.dp(8)
    }

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
        root.resetFolderCache()
        if (root.pathStack.length > 0)
            root.statusText = "线路已切换；目录缓存已清除，请刷新当前目录"
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

    function folderUrl(folderId) {
        return "https://drive.google.com/drive/folders/" + String(folderId || "")
    }

    function resetFolderCache() {
        root.cancelSizeRequest()
        root.folderCache = ({})
        root.folderCacheOrder = []
        root.treeCacheComplete = false
        root.treeCacheTruncated = false
    }

    function cancelSizeRequest() {
        if (root.sizeRequestId.length > 0)
            root.spPlugin.cancel(root.sizeRequestId)
        root.sizeRequestId = ""
        root.sizeFolderId = ""
        root.sizeQueueIds = []
        root.sizeBatchIds = []
        root.sizeCompleted = 0
        root.sizeTotal = 0
        root.sizeResolved = 0
    }

    function immediateSize(items) {
        var total = 0
        for (var i = 0; i < items.length; i++) {
            if (String(items[i].type || "") === "file")
                total += Number(items[i].sizeBytes || 0)
        }
        return total
    }

    function hasKnownSize(item) {
        return Number((item || {}).sizeBytes || 0) > 0
                || String((item || {}).sizeDisplay || (item || {}).size || "").trim().length > 0
    }

    function unknownSizeCount(items) {
        var count = 0
        for (var i = 0; i < items.length; i++) {
            if (String(items[i].type || "") === "file"
                    && !root.hasKnownSize(items[i]))
                count++
        }
        return count
    }

    function requestSelectedSizes() {
        if (root.requestId.length > 0 || root.sizeRequestId.length > 0) {
            root.spPlugin.showToast("请等待当前任务完成", "warning", "gdrive-size-busy")
            return
        }
        if (root.pathStack.length === 0)
            return
        var selected = table.selectedItems().filter(function(item) {
            return item && item.type === "file"
        })
        if (selected.length === 0) {
            root.spPlugin.showToast("请先勾选要解析大小的文件", "warning", "gdrive-size-select")
            return
        }
        if ((root.route === "front" || root.route === "second")
                && !root.spPlugin.checkProxy(root.route, "解析谷歌网盘文件大小"))
            return
        var ids = selected.filter(function(item) {
            return !root.hasKnownSize(item)
        }).map(function(item) { return String(item.id || "") }).filter(function(id) {
            return id.length > 0
        })
        if (ids.length === 0) {
            root.spPlugin.showToast("选中文件的大小已在缓存中", "success", "gdrive-size-cached")
            return
        }
        root.sizeFolderId = String(root.pathStack[root.pathStack.length - 1].id || "")
        root.sizeQueueIds = ids
        root.sizeTotal = ids.length
        root.sizeCompleted = 0
        root.sizeResolved = 0
        root.startNextSizeBatch()
    }

    function startNextSizeBatch() {
        if (root.sizeQueueIds.length === 0)
            return
        var batch = root.sizeQueueIds.slice(0, 64)
        var request = root.spPlugin.call("probe_folder_sizes",
                                         {"folderId": root.sizeFolderId,
                                          "fileIds": batch, "route": root.route}, 300000)
        if (!request) {
            root.spPlugin.showToast("文件大小解析任务无法启动", "error", "gdrive-size-start")
            root.cancelSizeRequest()
            return
        }
        root.sizeQueueIds = root.sizeQueueIds.slice(batch.length)
        root.sizeBatchIds = batch
        root.sizeRequestId = request
        root.statusText = "正在解析选中文件大小 " + root.sizeCompleted + "/" + root.sizeTotal
    }

    function rememberFolder(folderId, folderName, items) {
        var cache = ({})
        for (var key in root.folderCache)
            cache[key] = root.folderCache[key]
        var order = root.folderCacheOrder.slice()
        var oldIndex = order.indexOf(folderId)
        if (oldIndex >= 0)
            order.splice(oldIndex, 1)
        cache[folderId] = {"name": String(folderName || ""),
                           "items": items, "totalSize": root.immediateSize(items)}
        order.push(folderId)
        var limit = root.treeCacheComplete || root.treeCacheTruncated ? 5001 : 256
        while (order.length > limit)
            delete cache[order.shift()]
        root.folderCache = cache
        root.folderCacheOrder = order
    }

    function rememberTree(folderId, folderName, items) {
        var cache = ({})
        for (var key in root.folderCache)
            cache[key] = root.folderCache[key]
        var order = []
        var stack = [{"id": folderId, "name": folderName, "items": items}]
        var seen = ({})
        while (stack.length > 0) {
            var folder = stack.pop()
            var id = String(folder.id || "")
            if (!id || seen[id] || folder.loaded === false)
                continue
            seen[id] = true
            var children = folder.items || []
            cache[id] = {"name": String(folder.name || ""),
                         "items": children, "totalSize": root.immediateSize(children)}
            order.push(id)
            for (var i = children.length - 1; i >= 0; i--) {
                var child = children[i]
                if (String(child.type || "") === "folder" && !child._reused)
                    stack.push({"id": child.id, "name": child.name,
                                "items": child.children || [],
                                "loaded": child._loaded === true})
            }
        }
        var retained = root.folderCacheOrder.filter(function(id) { return !seen[id] })
        order = retained.concat(order)
        while (order.length > 5001)
            delete cache[order.shift()]
        root.folderCache = cache
        root.folderCacheOrder = order
    }

    function invalidateCacheBranch(folderId) {
        var cache = ({})
        for (var key in root.folderCache)
            cache[key] = root.folderCache[key]
        var pending = [folderId]
        var removed = ({})
        while (pending.length > 0) {
            var id = String(pending.pop() || "")
            if (!id || removed[id])
                continue
            removed[id] = true
            var entry = cache[id]
            if (entry) {
                var children = entry.items || []
                for (var i = 0; i < children.length; i++) {
                    if (String(children[i].type || "") === "folder")
                        pending.push(String(children[i].id || ""))
                }
            }
            delete cache[id]
        }
        root.folderCache = cache
        root.folderCacheOrder = root.folderCacheOrder.filter(function(id) {
            return !removed[id]
        })
        root.cancelSizeRequest()
        root.treeCacheComplete = false
        root.treeCacheTruncated = true
    }

    function showFolderSnapshot(folderId, nextPath) {
        var snapshot = root.folderCache[folderId]
        if (!snapshot)
            return false
        var path = nextPath.slice()
        if (path.length > 0 && !String(path[0].name || "").length
                && String(path[0].id || "") === folderId)
            path[0] = {"id": folderId, "name": snapshot.name || folderId}
        root.pathStack = path
        root.driveRows = snapshot.items
        root.totalSizeText = snapshot.totalSize > 0
                ? root.formatBytes(snapshot.totalSize) : "0 B"
        var unknown = root.unknownSizeCount(snapshot.items)
        root.statusText = "共 " + snapshot.items.length + " 项，"
                        + (unknown > 0 ? unknown + " 个文件大小未提供"
                                       + (snapshot.totalSize > 0
                                          ? "；已知大小 " + root.totalSizeText : "")
                                       : "总大小 " + root.totalSizeText)
                        + (root.treeCacheComplete ? "；完整层级已缓存"
                           : root.treeCacheTruncated ? "；部分层级已缓存，其余按需读取"
                           : "；已访问目录直接复用")
        return true
    }

    function loadFolder(url, nextPath, forceRefresh, prefetchAll, restorePath) {
        if (root.requestId.length > 0)
            return
        var folderId = root.resolveFolderTree(url)
        if (!folderId)
            return
        if (root.sizeRequestId.length > 0
                && (root.sizeFolderId !== folderId || forceRefresh || prefetchAll))
            root.cancelSizeRequest()
        if (!forceRefresh && !prefetchAll && root.folderCache[folderId]) {
            root.showFolderSnapshot(folderId, nextPath)
            return
        }
        if ((root.route === "front" || root.route === "second")
                && !root.spPlugin.checkProxy(root.route, "读取谷歌网盘目录"))
            return
        root.pendingFolderId = folderId
        root.pendingPathStack = nextPath.slice()
        root.pendingRestorePath = restorePath ? restorePath.slice() : []
        root.pendingRefresh = forceRefresh === true
        root.treeParsing = prefetchAll === true
        root.treeProgress = root.treeParsing ? 0.05 : 0
        root.parsedFolders = 0
        root.discoveredFolders = root.treeParsing ? 1 : 0
        root.statusText = prefetchAll ? "正在解析完整目录树..." : "正在获取目录内容..."
        var ancestors = nextPath.slice(0, -1).map(function(entry) {
            return String(entry.name || "")
        }).filter(function(name) { return name.length > 0 })
        root.requestId = root.spPlugin.call(
            prefetchAll ? "list_folder_tree" : "list_folder",
            {"url": url, "route": root.route,
             "forceRefresh": forceRefresh === true,
             "parentPath": "/" + ancestors.join("/")}, 300000)
    }

    function loadFileUrl(url) {
        linkField.text = url
        root.treeParsing = false
        root.statusText = "正在获取文件下载地址..."
        root.requestId = root.spPlugin.call("resolve_download", {"url": url, "route": root.route}, 120000)
    }

    function stopParsing() {
        var activeId = root.requestId
        if (!activeId)
            return
        if (!root.spPlugin.cancel(activeId)) {
            root.statusText = "解析任务正在完成，请稍候"
            return
        }
        root.requestId = ""
        root.treeParsing = false
        root.pendingFolderId = ""
        root.pendingPathStack = []
        root.pendingRestorePath = []
        root.pendingRefresh = false
        root.statusText = "解析已停止；已显示的目录保持不变"
    }

    function openFolder(row) {
        if (!root.isFolderRow(row) || root.requestId.length > 0)
            return
        var fid = root.folderIdFor(row)
        if (!fid)
            return
        if ((root.route === "front" || root.route === "second")
                && !root.spPlugin.checkProxy(root.route, "进入谷歌网盘文件夹")
                && !root.folderCache[fid])
            return
        var next = root.pathStack.slice()
        next.push({"id": fid, "name": String(row.name || "")})
        root.loadFolder(root.folderUrl(fid), next, false, false)
    }

    function goToPath(index) {
        if (root.requestId.length > 0 || index < 0 || index >= root.pathStack.length)
            return
        var next = root.pathStack.slice(0, index + 1)
        root.loadFolder(root.folderUrl(next[index].id), next, false, false)
    }

    function goUp() {
        root.goToPath(root.pathStack.length - 2)
    }

    function goToRoot() {
        root.goToPath(0)
    }

    function refreshCurrent() {
        if (root.requestId.length > 0)
            return
        if (root.pathStack.length <= 0) {
            root.parseLink()
            return
        }
        var current = root.pathStack[root.pathStack.length - 1]
        root.loadFolder(root.folderUrl(current.id), root.pathStack, true, false)
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
        root.resetFolderCache()
        if (/\/drive\/folders\//.test(link)) {
            var fid = root.resolveFolderTree(link)
            if (fid)
                root.loadFolder(link, [{"id": fid, "name": ""}], false,
                                root.depthMode === "tree")
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
        var safe = []
        for (var i = 0; i < parts.length; i++) {
            var cleaned = parts[i].replace(/[\\/:*?"<>|]/g, "_").trim()
            if (cleaned && cleaned !== "." && cleaned !== "..")
                safe.push(cleaned)
        }
        if (root.storageMode === "parent") {
            if (safe.length > 0)
                return base + "/" + safe[safe.length - 1]
            return base
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

    function contextActions(row, selectedRows) {
        var actions = []
        if (row && row.type === "folder")
            actions.push({"text": "打开", "action": "open"})
        if (selectedRows && selectedRows.some(function(item) {
                return item && item.type === "file"
            }))
            actions.push({"text": "下载选中项", "action": "download-selected"})
        if (root.pathStack.length > 0 && selectedRows && selectedRows.some(function(item) {
                return item && item.type === "file"
            })) {
            var missing = selectedRows.filter(function(item) {
                return item && item.type === "file" && !root.hasKnownSize(item)
            }).length
            actions.push({"text": "解析大小（" + missing + " 个）", "action": "probe-sizes"})
        }
        actions.push({"separator": true})
        if (root.pathStack.length > 0)
            actions.push({"text": "回到根目录", "action": "go-root"})
        actions.push({"text": "刷新当前链接", "action": "refresh"})
        return actions
    }

    function handleContextAction(action, row) {
        var current = row || root.contextRowData
        root.spPlugin.log("上下文动作 action=" + String(action || "") + " 类型=" + String((current && current.type) || ""))
        if (action === "open") {
            root.openFolder(current)
        } else if (action === "download-selected") {
            root.downloadSelected()
        } else if (action === "probe-sizes") {
            root.requestSelectedSizes()
        } else if (action === "refresh") {
            root.refreshCurrent()
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
            if (root.treeParsing && progress) {
                root.treeProgress = Math.max(0, Math.min(1, Number(progress.value || 0)))
                var details = progress.details || ({})
                if (details.completedFolders !== undefined)
                    root.parsedFolders = Number(details.completedFolders)
                if (details.discoveredFolders !== undefined)
                    root.discoveredFolders = Number(details.discoveredFolders)
            }
        }

        function onBackendFinished(requestId, method, response) {
            if (requestId === root.sizeRequestId) {
                var sizedFolderId = root.sizeFolderId
                root.sizeRequestId = ""
                var sizeResult = response.result || ({})
                if (!response.ok || String(sizeResult.folderId || "") !== sizedFolderId) {
                    root.spPlugin.showToast("文件大小解析失败，已停止后续请求", "error", "gdrive-size-failed")
                    root.cancelSizeRequest()
                    return
                }
                var snapshot = root.folderCache[sizedFolderId]
                if (snapshot) {
                    var sizes = sizeResult.sizes || ({})
                    var items = snapshot.items.map(function(item) {
                        var bytes = Number(sizes[String(item.id || "")] || 0)
                        if (!(bytes > 0))
                            return item
                        var copy = Object.assign({}, item)
                        copy.sizeBytes = bytes
                        copy.size = root.formatBytes(bytes)
                        return copy
                    })
                    root.rememberFolder(sizedFolderId, snapshot.name, items)
                }
                root.sizeCompleted += root.sizeBatchIds.length
                root.sizeResolved += Number(sizeResult.resolvedCount || 0)
                root.sizeBatchIds = []
                var currentId = root.pathStack.length > 0
                        ? String(root.pathStack[root.pathStack.length - 1].id || "") : ""
                if (currentId === sizedFolderId && root.folderCache[currentId]) {
                    var selectionState = table.selectionSnapshot()
                    root.showFolderSnapshot(currentId, root.pathStack)
                    table.restoreSelection(selectionState)
                }
                if (root.sizeQueueIds.length > 0)
                    root.startNextSizeBatch()
                else {
                    var complete = root.sizeResolved === root.sizeTotal
                    root.spPlugin.showToast(
                        "文件大小已获取 " + root.sizeResolved + "/" + root.sizeTotal + " 个",
                        complete ? "success" : "warning", "gdrive-size-complete")
                    root.cancelSizeRequest()
                }
                return
            }
            if (requestId !== root.requestId)
                return
            root.requestId = ""
            root.treeParsing = false
            if (!response.ok) {
                root.statusText = root.pendingRefresh ? "刷新失败，保留已有目录" : "解析失败"
                root.spPlugin.showToast(String(response.error || "解析失败"), "error", "gdrive-resolve-fail")
                root.pendingFolderId = ""
                root.pendingPathStack = []
                root.pendingRestorePath = []
                root.pendingRefresh = false
                return
            }
            var result = response.result || {}
            if (method === "list_folder" || method === "list_folder_tree") {
                var folderId = String(result.folderId || root.pendingFolderId || "")
                var path = root.pendingPathStack.slice()
                var folderName = String(result.folderName ||
                                        (path.length > 0 ? path[path.length - 1].name : "") || "")
                if (root.pendingRefresh)
                    root.invalidateCacheBranch(folderId)
                if (method === "list_folder_tree") {
                    root.rememberTree(folderId, folderName, result.tree || [])
                    if (path.length === 1) {
                        root.treeCacheComplete = result.truncated !== true
                        root.treeCacheTruncated = result.truncated === true
                    } else if (result.truncated === true) {
                        root.treeCacheComplete = false
                        root.treeCacheTruncated = true
                    }
                    if (result.truncated === true)
                        root.spPlugin.showToast("目录过大或部分子目录读取失败；未缓存的目录首次进入仍需解析",
                                                "warning", "gdrive-tree-incomplete")
                } else {
                    root.rememberFolder(folderId, folderName, result.items || [])
                }
                var restorePath = root.pendingRestorePath
                var restoreId = restorePath.length > 0
                                ? String(restorePath[restorePath.length - 1].id || "") : ""
                if (!restoreId || !root.showFolderSnapshot(restoreId, restorePath))
                    root.showFolderSnapshot(folderId, path)
                root.pendingFolderId = ""
                root.pendingPathStack = []
                root.pendingRestorePath = []
                root.pendingRefresh = false
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

    toolbar: Row {
        id: linkRow
        width: parent.width
        height: PluginTheme.controlHeight
        spacing: root.sectionSpacing

        AppTextField {
            id: linkField
            width: parent.width - routeButton.width - depthBox.width - parseButton.width - parent.spacing * 3
            placeholderText: "粘贴分享链接（文件或文件夹）"
        }

        AppButton {
            id: routeButton
            width: Math.min(implicitWidth, Math.max(PluginTheme.dp(85), parent.width * 0.23))
            enabled: root.requestId.length === 0
            constrainContentToAvailableWidth: true
            adaptContentPaddingToWidth: true
            text: "线路：" + root.routeLabelText()
            onClicked: routeMenu.openForActionsAtItem(root.routeMenuActions(), routeButton, 0, routeButton.height)
        }

        AppSelect {
            id: depthBox
            width: root.selectFitWidth(depthOptionMetrics, depthBox)
            height: PluginTheme.controlHeight
            enabled: root.requestId.length === 0
            model: ["全部解析", "当前深度"]
            onActivated: function() {
                root.depthMode = (currentIndex === 1) ? "current" : "tree"
                if (root.pathStack.length > 0 && root.depthMode === "tree"
                        && !root.treeCacheComplete) {
                    var currentPath = root.pathStack.slice()
                    var rootPath = [currentPath[0]]
                    root.loadFolder(root.folderUrl(rootPath[0].id), rootPath,
                                    false, true, currentPath)
                }
            }
        }

        AppButton {
            id: parseButton
            width: root.actionButtonWidth
            text: root.requestId.length > 0 ? "停止" : "解析"
            onClicked: {
                if (root.requestId.length > 0)
                    root.stopParsing()
                else
                    root.parseLink()
            }
        }
    }

    Column {
        anchors.fill: parent
        spacing: root.sectionSpacing

        Row {
            width: parent.width
            height: root.treeParsing ? PluginTheme.controlHeight : 0
            visible: root.treeParsing
            spacing: root.sectionSpacing

            AppProgressBar {
                requestedWidth: Math.max(0, parent.width - folderProgressLabel.width - parent.spacing)
                minimumWidth: 0
                maximumWidth: requestedWidth
                value: root.treeProgress * 100
                showPercentage: false
                anchors.verticalCenter: parent.verticalCenter
            }

            Text {
                id: folderProgressLabel
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, parent.width * 0.55)
                text: "已解析 " + root.parsedFolders + " / 已发现 "
                      + root.discoveredFolders + " 个目录"
                color: PluginTheme.mutedText
                font.family: PluginTheme.fontFamily
                font.pixelSize: PluginTheme.smallFontSize
                elide: Text.ElideRight
            }
        }

        Row {
            id: pathRow
            width: parent.width
            spacing: root.sectionSpacing

            AppFormRow {
                id: storageRow
                label: "目录存储"
                autoLabelWidth: true
                width: effectiveLabelWidth + rowSpacing
                       + root.selectFitWidth(storageOptionMetrics, storageBox)
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

            AppTextField {
                id: pathField
                width: parent.width - storageRow.width - selectButton.width - parent.spacing * 2
                text: root.saveDirectory
                placeholderText: "未选目录：默认保存到 SP 临时目录"
                readOnly: true
            }

            AppButton {
                id: selectButton
                width: root.actionButtonWidth
                text: "选择"
                onClicked: root.chooseDirectory()
            }
        }

        Row {
            id: navRow
            width: parent.width
            spacing: root.sectionSpacing
            visible: root.pathStack.length > 0

            IconButton {
                id: upButton
                iconName: "chevron-left"
                tooltip: "上一级"
                borderless: true
                enabled: root.pathStack.length > 1 && root.requestId.length === 0
                onClicked: root.goUp()
            }
            Flickable {
                id: breadcrumbView
                width: Math.max(0, parent.width - upButton.width
                                - refreshButton.width - parent.spacing * 2)
                height: upButton.height
                clip: true
                contentWidth: breadcrumbRow.implicitWidth
                contentHeight: height
                flickableDirection: Flickable.HorizontalFlick
                boundsBehavior: Flickable.StopAtBounds
                onContentWidthChanged: contentX = Math.max(0, contentWidth - width)

                function scrollByWheel(distance) {
                    const limit = Math.max(0, contentWidth - width)
                    const next = Math.max(0, Math.min(limit, contentX + distance))
                    if (limit <= 0 || next === contentX)
                        return false
                    contentX = next
                    return true
                }

                WheelHandler {
                    target: null
                    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                    onWheel: function(event) {
                        if (event.modifiers & Qt.ControlModifier) {
                            event.accepted = false
                            return
                        }
                        const pixelDelta = event.pixelDelta.x !== 0
                                ? event.pixelDelta.x : event.pixelDelta.y
                        const angleDelta = event.angleDelta.x !== 0
                                ? event.angleDelta.x : event.angleDelta.y
                        const distance = pixelDelta !== 0
                                ? -pixelDelta : -(angleDelta / 120.0) * PluginTheme.dp(48)
                        event.accepted = breadcrumbView.scrollByWheel(distance)
                    }
                }

                Row {
                    id: breadcrumbRow
                    height: breadcrumbView.height

                    Repeater {
                        model: root.pathStack
                        delegate: Row {
                            id: crumb
                            required property int index
                            required property var modelData
                            height: breadcrumbRow.height

                            Text {
                                text: "/"
                                height: crumb.height
                                verticalAlignment: Text.AlignVCenter
                                color: PluginTheme.mutedText
                                font.family: PluginTheme.fontFamily
                                font.pixelSize: PluginTheme.smallFontSize
                            }

                            Text {
                                id: crumbText
                                text: String(crumb.modelData.name || crumb.modelData.id || "目录")
                                height: crumb.height
                                verticalAlignment: Text.AlignVCenter
                                color: crumbMouse.containsMouse ? PluginTheme.primary
                                      : PluginTheme.text
                                font.family: PluginTheme.fontFamily
                                font.pixelSize: PluginTheme.smallFontSize

                                MouseArea {
                                    id: crumbMouse
                                    anchors.fill: parent
                                    enabled: root.requestId.length === 0
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.goToPath(crumb.index)
                                }
                            }
                        }
                    }
                }
            }
            IconButton {
                id: refreshButton
                iconName: "update"
                tooltip: "刷新当前目录"
                borderless: true
                opacity: 0.6
                enabled: root.requestId.length === 0
                onClicked: root.refreshCurrent()
            }
        }

        GDriveFileTable {
            id: table
            width: parent.width
            height: Math.max(120, parent.height - y)
            rows: root.driveRows
            identityProvider: function(row, index) {
                return String((row || {}).id || index)
            }
            columns: [
                {"title": "类型", "width": PluginTheme.dp(70),
                 "formatter": function(row) { return row.type === "folder" ? "文件夹" : "文件" }},
                {"title": "名称", "weight": 3, "key": "name", "align": "left",
                 "formatter": function(row) { return String(row.name || "") }},
                {"title": "大小", "weight": 1,
                 "formatter": function(row) {
                     if (row.type === "folder")
                         return ""
                     return String(row.sizeDisplay || row.size ||
                                   (Number(row.sizeBytes || 0) > 0
                                    ? root.formatBytes(Number(row.sizeBytes)) : "—"))
                 }},
                {"title": "修改日期", "weight": 1.3,
                 "formatter": function(row) { return String(row.modifiedDisplay || "") }}
            ]
            contextActionsProvider: function(selectedRows, currentRow) {
                return root.contextActions(currentRow, selectedRows)
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
