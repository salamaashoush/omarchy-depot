import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar icon plus the repo panel. Every color and metric here comes from the
// Color/Style singletons, so the widget re-themes with `omarchy theme set`
// without knowing anything about which theme is on.
Panel {
  id: root
  moduleName: "sashoush.depot"
  ipcTarget: "sashoush.depot"
  manageIpc: false

  // A user plugin can't lean on $OMARCHY_PATH the way a first-party one does,
  // so resolve the helper scripts relative to this file.
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")

  property string filterText: ""
  property int selectedRow: -1
  property bool cursorActive: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property int maxRows: 1000
  readonly property var filtered: Model.filter(service.repos, filterText, maxRows)
  readonly property var rowModel: Model.rows(filtered, filterText === "")
  readonly property var selectedRepo: {
    if (selectedRow < 0 || selectedRow >= rowModel.length) return null
    var row = rowModel[selectedRow]
    return row && !row.isHeader ? row.repo : null
  }

  readonly property int rowHeight: Style.space(46)
  readonly property int headerHeight: Style.space(30)
  readonly property string badge: Model.barBadge(service.counts)

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ------------------------------------------------------------ selection

  function isSelectable(index) {
    return index >= 0 && index < rowModel.length && !rowModel[index].isHeader
  }

  function firstSelectable() {
    for (var i = 0; i < rowModel.length; i++) if (!rowModel[i].isHeader) return i
    return -1
  }

  function step(from, delta) {
    var i = from + delta
    while (i >= 0 && i < rowModel.length) {
      if (!rowModel[i].isHeader) return i
      i += delta
    }
    return from
  }

  function move(delta) {
    if (!rowModel.length) return
    if (!cursorActive || !isSelectable(selectedRow)) {
      cursorActive = true
      selectedRow = firstSelectable()
    } else {
      selectedRow = step(selectedRow, delta > 0 ? 1 : -1)
      // Repeat for multi-row jumps (page up/down).
      for (var n = 1; n < Math.abs(delta); n++) selectedRow = step(selectedRow, delta > 0 ? 1 : -1)
    }
    list.positionViewAtIndex(selectedRow, ListView.Contain)
  }

  function selectRow(index) {
    if (!isSelectable(index)) return
    cursorActive = true
    selectedRow = index
  }

  function setFilter(next) {
    filterText = next
    // A new result set invalidates the old cursor position; drop back to the
    // top match so Enter always means "the thing highlighted".
    Qt.callLater(function() {
      root.selectedRow = root.firstSelectable()
      root.cursorActive = root.filterText.length > 0
      list.positionViewAtBeginning()
    })
  }

  // -------------------------------------------------------------- actions

  function activate() {
    var repo = selectedRepo
    if (repo) service.primary(repo)
  }

  onOpenedChanged: if (opened) {
    filterText = ""
    selectedRow = firstSelectable()
    cursorActive = false
    service.scan(false)
    Qt.callLater(function() {
      keyCatcher.forceActiveFocus()
      list.positionViewAtBeginning()
    })
  }

  Service {
    id: service
    settings: root.settings
    pluginDir: root.pluginDir
    panelOpen: root.opened
  }

  Connections {
    target: service
    function onReposChanged() {
      if (!root.isSelectable(root.selectedRow)) root.selectedRow = root.firstSelectable()
      // The scan that runs on open lands after the panel has already reset
      // its scroll, and ListView preserves contentY across a model swap — so
      // the panel opened three rows down. Re-pin to the top whenever the list
      // is refilled and nobody has started navigating it yet.
      if (root.opened && root.filterText === "" && !root.cursorActive) {
        Qt.callLater(function() { list.positionViewAtBeginning() })
      }
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { service.refresh(); return "ok" }
    function status(): string { return Model.summary(service.counts) }
  }

  // ------------------------------------------------------------ bar icon

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        Text {
          id: barGlyph
          anchors.centerIn: parent
          text: "󰊤"
          color: root.barForeground
          opacity: service.counts.dirty || service.counts.sessions ? 1.0 : 0.75
          font.family: root.fontFamily
          font.pixelSize: Style.bar.iconFont
        }

        // A dot, not a number: the bar is not the place to read a count, only
        // to notice there is one. The panel spells it out.
        Rectangle {
          visible: root.badge !== ""
          width: Style.space(5)
          height: width
          radius: width / 2
          color: service.counts.sessions ? root.accent : root.urgent
          anchors.horizontalCenter: barGlyph.horizontalCenter
          anchors.horizontalCenterOffset: Style.space(7)
          anchors.top: barGlyph.top
          anchors.topMargin: -Style.space(1)
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) service.refresh()
      else root.toggle()
    }
  }

  // -------------------------------------------------------------- panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(500))
    contentHeight: panel.fittedContentHeight(
      hero.implicitHeight + filterRow.height + separator.height + list.height
        + footerSeparator.height + (statusLine.visible ? statusLine.height + Style.space(10) : 0)
        + hints.height + Style.space(46),
      Style.space(640))

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
        var repo = root.selectedRepo

        if (event.key === Qt.Key_Escape) {
          if (root.filterText) root.setFilter("")
          else root.close()
          event.accepted = true
        } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
          root.switchPanel((event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab ? -1 : 1)
          event.accepted = true
        } else if (ctrl && event.key === Qt.Key_R) {
          service.refresh()
          event.accepted = true
        } else if (ctrl && event.key === Qt.Key_E) {
          service.openEditor(repo); event.accepted = true
        } else if (ctrl && event.key === Qt.Key_T) {
          service.openTerminal(repo); event.accepted = true
        } else if (ctrl && event.key === Qt.Key_G) {
          service.openLazygit(repo); event.accepted = true
        } else if (ctrl && event.key === Qt.Key_O) {
          service.browse(repo); event.accepted = true
        } else if (ctrl && event.key === Qt.Key_D) {
          if (repo && !repo.cloned) service.clone(repo, false)
          event.accepted = true
        } else if (ctrl && (event.key === Qt.Key_N || event.key === Qt.Key_J)) {
          root.move(1); event.accepted = true
        } else if (ctrl && (event.key === Qt.Key_P || event.key === Qt.Key_K)) {
          root.move(-1); event.accepted = true
        } else if (Util.editsFilter(event, root.filterText)) {
          root.setFilter(Util.editedFilter(event, root.filterText))
          event.accepted = true
        } else if (event.key === Qt.Key_Down) {
          root.move(1); event.accepted = true
        } else if (event.key === Qt.Key_Up) {
          root.move(-1); event.accepted = true
        } else if (event.key === Qt.Key_PageDown) {
          root.move(6); event.accepted = true
        } else if (event.key === Qt.Key_PageUp) {
          root.move(-6); event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          if (!root.cursorActive) { root.cursorActive = true; root.selectedRow = root.firstSelectable() }
          else root.activate()
          event.accepted = true
        } else if (event.text && event.text.length === 1
                   && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127
                   && (event.modifiers === Qt.NoModifier || event.modifiers === Qt.ShiftModifier)) {
          root.setFilter(root.filterText + event.text)
          event.accepted = true
        }
      }

      Column {
        anchors.fill: parent
        spacing: Style.space(10)

        // Hand-rolled rather than PanelHero: that component pins its `detail`
        // pill to the trailing edge, which left the workspace path floating in
        // dead space instead of reading as a qualifier on the title.
        Item {
          id: hero
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, refreshButton.implicitHeight)

          Text {
            id: heroIcon
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "󰊤"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: refreshButton.left
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Row {
              spacing: Style.space(8)

              Text {
                text: "Depot"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
              }

              // The workspace the counts below are about, sitting with the
              // title it qualifies.
              BorderSurface {
                id: workspacePill
                implicitWidth: workspaceText.implicitWidth + Style.space(10)
                implicitHeight: workspaceText.implicitHeight + Style.space(4)
                anchors.verticalCenter: parent.verticalCenter
                color: "transparent"
                radius: Style.cornerRadius
                borderSpec: Border.controlSpec("normal", root.foreground, root.accent)

                Text {
                  id: workspaceText
                  anchors.centerIn: parent
                  text: Model.shortPath(service.workspace, root.homePath)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }

            Text {
              width: parent.width
              text: (service.loading && !service.everLoaded ? "Scanning…" : Model.summary(service.counts)).toUpperCase()
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
            }
          }

          PanelActionButton {
            id: refreshButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰑐"
            tooltipText: "Refresh from GitHub"
            foreground: root.foreground
            fontFamily: root.fontFamily
            enabled: !service.refreshingRemote
            opacity: service.refreshingRemote ? 0.45 : 1.0
            onClicked: service.refresh()
          }
        }


        // Filter line. Deliberately not a TextField: the whole panel is one
        // key-handling surface, so typing filters and the arrows still move
        // the cursor without a focus fight. The caret supplies the affordance
        // a real input would have given.
        Item {
          id: filterRow
          width: parent.width
          height: Style.spacing.controlHeight

          Row {
            id: filterContent
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: matchCount.left
            anchors.rightMargin: Style.space(8)
            spacing: Style.space(8)

            Text {
              text: "󰍉"
              color: root.filterText ? root.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              anchors.verticalCenter: parent.verticalCenter
            }

            // The query and its caret are one unit: their own tight row, so
            // the outer spacing separates the search glyph from the text
            // without also pushing the caret off the end of it.
            Row {
              spacing: Style.space(2)
              anchors.verticalCenter: parent.verticalCenter

              Text {
                id: filterLabel
                width: Math.min(implicitWidth, filterContent.width - Style.space(34))
                text: root.filterText || "Search repos…"
                color: root.filterText ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                elide: Text.ElideLeft
                anchors.verticalCenter: parent.verticalCenter
              }

              Rectangle {
                width: Math.max(1, Style.space(1))
                height: Style.font.subtitle
                color: root.accent
                anchors.verticalCenter: parent.verticalCenter
              // Only blink while the panel is up; a caret ticking away behind
              // a closed popup is wasted animation.
              SequentialAnimation on opacity {
                running: root.opened
                loops: Animation.Infinite
                NumberAnimation { to: 0.15; duration: 520; easing.type: Easing.InOutQuad }
                NumberAnimation { to: 1.0; duration: 520; easing.type: Easing.InOutQuad }
                }
              }
            }
          }

          Text {
            id: matchCount
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: root.filterText !== ""
            text: root.filtered.length + (root.filtered.length === root.maxRows ? "+" : "")
                  + (root.filtered.length === 1 ? " match" : " matches")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        PanelSeparator {
          id: separator
          foreground: root.foreground
        }

        Item {
          id: listFrame
          width: parent.width
          height: list.height

        ListView {
          id: list
          width: parent.width
          readonly property int pitch: root.rowHeight + spacing
          height: {
            var wanted = Math.min(Style.space(400), contentHeight)
            var whole = Math.max(3, Math.floor(wanted / pitch)) * pitch - spacing
            return Math.min(whole, contentHeight)
          }
          snapMode: ListView.SnapToItem
          model: root.rowModel
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height
          spacing: Style.space(2)
          cacheBuffer: root.rowHeight * 6
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          delegate: Item {
            id: rowItem
            required property var modelData
            required property int index
            width: list.width
            height: modelData.isHeader ? root.headerHeight : root.rowHeight

            PanelSectionHeader {
              visible: rowItem.modelData.isHeader
              anchors.left: parent.left
              anchors.bottom: parent.bottom
              anchors.bottomMargin: Style.space(2)
              text: rowItem.modelData.isHeader
                    ? rowItem.modelData.title + "  ·  " + rowItem.modelData.count
                    : ""
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            RepoRow {
              anchors.fill: parent
              visible: !rowItem.modelData.isHeader
              repo: rowItem.modelData.isHeader ? null : rowItem.modelData.repo
              rowIndex: rowItem.index
            }
          }

          // Nothing matched, or nothing exists yet — say which.
          Text {
            anchors.centerIn: parent
            visible: root.rowModel.length === 0
            width: parent.width - Style.space(24)
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            text: {
              if (service.loading && !service.everLoaded) return "Scanning your repos…"
              if (root.filterText) return "No repo matches “" + root.filterText + "”"
              if (service.remoteError) return "No repos found.\n" + service.remoteError
              return "No repos found. Is gh signed in?"
            }
          }
        }

          // Scroll-edge fades, painted in the card's own background so a row
          // crossing the boundary dissolves rather than getting guillotined.
          Rectangle {
            anchors.top: listFrame.top
            anchors.left: listFrame.left
            anchors.right: listFrame.right
            height: Style.space(30)
            visible: !list.atYBeginning
            gradient: Gradient {
              GradientStop { position: 0.0; color: Color.popups.background }
              GradientStop { position: 1.0; color: Qt.rgba(Color.popups.background.r, Color.popups.background.g, Color.popups.background.b, 0) }
            }
          }

          Rectangle {
            anchors.bottom: listFrame.bottom
            anchors.left: listFrame.left
            anchors.right: listFrame.right
            height: Style.space(30)
            visible: !list.atYEnd
            gradient: Gradient {
              GradientStop { position: 0.0; color: Qt.rgba(Color.popups.background.r, Color.popups.background.g, Color.popups.background.b, 0) }
              GradientStop { position: 1.0; color: Color.popups.background }
            }
          }
        }

        PanelSeparator {
          id: footerSeparator
          foreground: root.foreground
          opacity: 0.6
        }

        Text {
          id: statusLine
          width: parent.width
          leftPadding: Style.space(3)
          visible: text !== ""
          text: {
            if (service.actionStatus) return service.actionStatus
            if (service.lastError) return service.lastError
            if (service.remoteError) return service.remoteError
            if (!service.workspaceExists) return service.workspace + " does not exist yet — cloning will create it"
            if (service.remoteTruncated.length)
              return "Showing the first " + service.repoLimit + " repos for "
                     + service.remoteTruncated.join(", ") + " — raise repoLimit to see the rest"
            return ""
          }
          color: service.actionFailed || service.lastError ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Text {
          id: hints
          width: parent.width
          leftPadding: Style.space(3)
          color: root.dim
          opacity: 0.8
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          text: {
            var repo = root.selectedRepo
            if (!repo) return "type to search · ↑↓ move · ⏎ open"
            if (!repo.cloned) return "⏎ clone + Claude · ^D clone · ^O web"
            return "⏎ Claude · ^E nvim · ^T term · ^G git · ^O web · ^R sync"
          }
        }
      }
    }
  }

  readonly property string homePath: Quickshell.env("HOME")

  // ------------------------------------------------------------- repo row

  component RepoRow: CursorSurface {
    id: surface
    property var repo: null
    property int rowIndex: -1

    readonly property bool busy: repo !== null && service.busyRepo === repo.name
    readonly property bool cloned: repo !== null && repo.cloned === true
    readonly property bool live: repo !== null && repo.session

    hasCursor: root.cursorActive && root.selectedRow === rowIndex
    foreground: root.foreground

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton
      onEntered: root.selectRow(surface.rowIndex)
      onClicked: function(mouse) {
        if (!surface.repo) return
        root.selectRow(surface.rowIndex)
        if (mouse.button === Qt.MiddleButton) service.browse(surface.repo)
        else service.primary(surface.repo)
      }
    }

    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(9)

      Text {
        text: Model.glyph(surface.repo)
        color: surface.live ? root.accent
             : (surface.repo && surface.repo.conflicts ? root.urgent
             : (surface.repo && surface.repo.dirty ? root.foreground : root.dim))
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      // Identity column: what this repo is.
      ColumnLayout {
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignVCenter
        spacing: Style.space(2)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          Text {
            text: surface.repo ? surface.repo.short : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
            Layout.maximumWidth: Style.space(190)
          }

          // Two repos can share a short name across owners, so the owner
          // stays on the row — dimmed, since it is rarely what you read.
          Text {
            visible: surface.repo && surface.repo.owner !== ""
            text: surface.repo ? surface.repo.owner : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            Layout.fillWidth: true
          }
        }

        Text {
          Layout.fillWidth: true
          visible: text !== ""
          text: {
            if (!surface.repo) return ""
            if (surface.busy) return service.busyVerb === "clone" ? "Cloning…" : "Starting Claude…"
            var session = Model.sessionLabel(surface.repo)
            return session ? session : Model.detailLine(surface.repo)
          }
          color: surface.live ? root.accent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      // Status column: where the repo stands. Right-aligned so the branch
      // names and timestamps form a column you scan down rather than a
      // sentence you read across.
      ColumnLayout {
        visible: !(surface.hasCursor && !surface.busy)
        Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
        spacing: Style.space(2)

        RowLayout {
          Layout.alignment: Qt.AlignRight
          spacing: Style.space(5)

          Text {
            visible: surface.repo && surface.repo.private
            text: "󰌾"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            visible: text !== ""
            text: Model.trailingPrimary(surface.repo)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideLeft
            Layout.maximumWidth: Style.space(130)
          }

          Text {
            visible: text !== ""
            text: Model.statusText(surface.repo)
            color: surface.repo && surface.repo.conflicts ? root.urgent : root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          Layout.alignment: Qt.AlignRight
          visible: text !== ""
          text: Model.trailingTime(surface.repo)
          color: root.dim
          opacity: 0.75
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // Row actions take the status column's place on the active row, so the
      // row never grows and nothing shifts under the pointer.
      Row {
        spacing: Style.space(2)
        visible: surface.hasCursor && !surface.busy && surface.repo !== null
        Layout.alignment: Qt.AlignRight | Qt.AlignVCenter

        PanelActionButton {
          visible: surface.cloned
          iconText: "󰏫"
          tooltipText: "Open in editor"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: service.openEditor(surface.repo)
        }
        PanelActionButton {
          visible: surface.cloned
          iconText: "󰘬"
          tooltipText: "lazygit"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: service.openLazygit(surface.repo)
        }
        PanelActionButton {
          visible: surface.repo !== null && surface.repo.url !== ""
          iconText: "󰊤"
          tooltipText: "Open on GitHub"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: service.browse(surface.repo)
        }
      }
    }
  }
}
