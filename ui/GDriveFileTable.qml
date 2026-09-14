pragma ComponentBehavior: Bound

import QtQuick 2.15
import SP.Plugin 1.0

Item {
    id: table

    property var rows: []
    property var columns: []
    property var identityProvider: null
    property var contextActionsProvider: null
    property real headerHeight: PluginTheme.dp(31)
    property real rowHeight: PluginTheme.dp(30)
    property real checkColumnWidth: PluginTheme.dp(36)
    property int currentRow: -1
    readonly property var currentItem: layout.rowAt(currentRow)
    readonly property int selectedCount: selection.selectedCount
    readonly property alias tableController: layout

    signal rowActivated(var row)
    signal actionRequested(string action, var row)

    function selectedItems() {
        const result = []
        const indices = selection.selectedRowArray()
        for (let i = 0; i < indices.length; ++i) {
            const row = layout.rowAt(indices[i])
            if (row)
                result.push(row)
        }
        return result
    }

    function selectionSnapshot() {
        return {"identities": selection.selectedIdentityArray(),
                "currentIdentity": layout.identityAt(currentRow)}
    }

    function restoreSelection(snapshot) {
        if (!snapshot)
            return
        selection.selectedIdentities = snapshot.identities || []
        selection.restoreByIdentities(layout.rowCount, -1)
        currentRow = layout.viewIndexForIdentity(snapshot.currentIdentity)
    }

    function toggleSort(column) {
        const identities = selection.selectedIdentityArray()
        const currentIdentity = layout.identityAt(currentRow)
        if (!layout.toggleSort(column))
            return
        selection.selectedIdentities = identities
        selection.restoreByIdentities(layout.rowCount, -1)
        currentRow = layout.viewIndexForIdentity(currentIdentity)
    }

    function toggleCheck(row) {
        selection.toggle(row)
        currentRow = row
    }

    function toggleAll() {
        if (layout.rowCount > 0 && selection.selectedCount === layout.rowCount) {
            selection.clear()
            currentRow = -1
        } else {
            selection.selectAll(layout.rowCount)
            currentRow = selection.selectedRow
        }
    }

    function openMenu(sourceItem, x, y) {
        const actions = contextActionsProvider
                ? contextActionsProvider.call(table, selectedItems(), currentItem) : []
        menu.openForActionsAtItem(actions, sourceItem, x, y)
    }

    PluginTableController {
        id: layout
        rows: table.rows
        columns: table.columns
        availableWidth: header.width - table.checkColumnWidth
        identityProvider: table.identityProvider
    }

    AppTableSelectionController {
        id: selection
        rowIdentityAt: function(row) { return layout.identityAt(row) }
    }

    AppStableObjectList {
        id: presentationStore
        keyFunction: function(value, index) {
            return String((value || ({})).identity || index)
        }
    }

    Connections {
        target: layout
        function onViewRowsChanged() { presentationStore.sync(layout.viewRows) }
    }

    Rectangle {
        id: frame
        anchors.fill: parent
        color: "transparent"
        border.color: PluginTheme.border
        border.width: PluginTheme.physicalPixel
        radius: PluginTheme.dp(4)
        clip: true

        Row {
            id: header
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: table.headerHeight

            AppTableHeaderCell {
                id: selectHeader
                width: table.checkColumnWidth
                height: header.height
                column: -1
                sortable: false
                resizable: false

                AppCheckBox {
                    anchors.fill: parent
                    indicatorOnly: true
                    checked: layout.rowCount > 0 && selection.selectedCount === layout.rowCount
                    enabled: false
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: table.toggleAll()
                }
            }

            Repeater {
                model: table.columns
                delegate: AppTableHeaderCell {
                    required property int index
                    required property var modelData
                    width: layout.columnWidth(index)
                    height: header.height
                    column: index
                    showLeftLine: false
                    baseText: String(modelData.title || "")
                    sortColumn: layout.sortColumn
                    sortAscending: layout.sortAscending
                    sortable: layout.columnSortable(index)
                    resizable: layout.columnResizable(index)
                    dragRoot: frame
                    onSortRequested: function(column) { table.toggleSort(column) }
                    onResizeRequested: function(column, startWidth, delta) {
                        layout.setColumnWidthFromDrag(column, startWidth, delta)
                    }
                    onAutoFitRequested: function(column) { layout.autoFitColumn(column) }
                }
            }
        }

        AppTableView {
            id: list
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: header.bottom
            anchors.bottom: parent.bottom
            model: presentationStore.model
            rowHeight: table.rowHeight
            selectionController: selection
            standardSelectionEnabled: true
            rowSelectedAt: function(row) { return selection.rowSelected(row) }
            onBlankPressed: function() {
                selection.clear()
                table.currentRow = -1
            }
            onBlankContextRequested: function(x, y) { table.openMenu(list, x, y) }

            delegate: Item {
                id: rowItem
                required property int index
                readonly property var rowData: layout.rowAt(index) || ({})
                readonly property int sourceIndex: layout.sourceIndexAt(index)
                width: list.width
                height: list.rowHeight

                Row {
                    anchors.fill: parent

                    Item {
                        width: table.checkColumnWidth
                        height: rowItem.height

                        AppTableCell {
                            anchors.fill: parent
                            showRightLine: true
                        }
                        AppCheckBox {
                            anchors.fill: parent
                            indicatorOnly: true
                            checked: selection.rowSelected(rowItem.index)
                            enabled: false
                        }
                        MouseArea {
                            anchors.fill: parent
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            cursorShape: Qt.PointingHandCursor
                            onClicked: function(event) {
                                if (event.button === Qt.RightButton) {
                                    table.currentRow = rowItem.index
                                    list.standardSelectContextRow(rowItem.index)
                                    table.openMenu(this, event.x, event.y)
                                } else {
                                    table.toggleCheck(rowItem.index)
                                }
                            }
                        }
                    }

                    Repeater {
                        model: table.columns
                        delegate: Item {
                            id: cellDelegate
                            required property int index
                            required property var modelData
                            width: layout.columnWidth(index)
                            height: rowItem.height

                            AppTableCell {
                                anchors.fill: parent
                                text: layout.displayText(rowItem.rowData, cellDelegate.index,
                                                         rowItem.sourceIndex)
                                align: cellDelegate.modelData.align === "left"
                                       ? Text.AlignLeft : Text.AlignHCenter
                                horizontalPadding: cellDelegate.modelData.align === "left"
                                                   ? PluginTheme.dp(8) : 0
                                showRightLine: cellDelegate.index < table.columns.length - 1
                            }

                            AppTableRowPointer {
                                anchors.fill: parent
                                listView: list
                                rowIndex: rowItem.index
                                rowData: rowItem.rowData
                                pressSelectsRightButton: false
                                onRowPressed: function(row) { table.currentRow = row }
                                onRowDoubleClicked: function(row, data) {
                                    table.currentRow = row
                                    selection.selectSingle(row)
                                    table.rowActivated(data)
                                }
                                onContextRequested: function(row, data, sourceItem, x, y) {
                                    table.currentRow = row
                                    list.standardSelectContextRow(row)
                                    table.openMenu(sourceItem, x, y)
                                }
                            }
                        }
                    }
                }
            }
        }

        Text {
            anchors.centerIn: parent
            visible: layout.rowCount <= 0
            text: "没有记录。"
            color: PluginTheme.mutedText
            font.family: PluginTheme.fontFamily
            font.pixelSize: PluginTheme.controlFontSize
        }
    }

    AppContextMenu {
        id: menu
        onActionTriggered: function(action) {
            table.actionRequested(action, table.currentItem)
        }
    }

    onRowsChanged: {
        selection.clear()
        currentRow = -1
    }
    Component.onCompleted: presentationStore.sync(layout.viewRows)
}
