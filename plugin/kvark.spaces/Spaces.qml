// Visual editor for pages. Pure UI: every fact comes from `hypr-spaces state`
// and every change leaves through `hypr-spaces apply --stdin`, so the process
// walking and config writing stay in Python where they can be tested.
//
// Surface tokens are borrowed from [menu], so a theme that styles the Omarchy
// menu styles this too.

import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  property bool busy: false
  property string error: ""

  // Live desktop, straight from the CLI.
  property var monitors: []
  property var windows: []
  // Working copy of the configuration. Edits mutate this and nothing else
  // until Apply, so Escape is always a safe way out.
  property var config: ({ pages: 10, offset: 10, monitors: [], apps: [], pair_monitors: true })
  property bool dirty: false
  property int currentPage: 1

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  readonly property int cornerRadius: Style.cornerRadius

  function open(payloadJson) {
    root.opened = true
    root.error = ""
    root.dirty = false
    root.refresh()
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "kvark.spaces")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function refresh() {
    root.busy = true
    stateProcess.running = true
  }

  // --- model helpers -------------------------------------------------------

  function monitorNames() {
    return (root.config.monitors && root.config.monitors.length)
      ? root.config.monitors
      : root.monitors.map(function (m) { return m.name })
  }

  function monitorLabel(name) {
    for (var i = 0; i < root.monitors.length; i++) {
      if (root.monitors[i].name === name) {
        var m = root.monitors[i]
        return m.name + "  " + m.width + "x" + m.height + "@" + m.refresh
      }
    }
    return name
  }

  // Windows currently on a page/monitor, so the editor shows reality rather
  // than only what has been configured.
  function windowsAt(page, monitor) {
    return root.windows.filter(function (w) {
      return w.page === page && w.monitor === monitor
    })
  }

  // Everything on this page, wherever it physically is. The canvas draws each
  // window on the monitor it actually occupies, not the one a rule pins it to.
  function windowsOnPage(page) {
    return root.windows.filter(function (w) { return w.page === page })
  }

  function monitorByName(name) {
    for (var i = 0; i < root.monitors.length; i++)
      if (root.monitors[i].name === name) return root.monitors[i]
    return null
  }

  // Bounding box of the whole desktop in compositor coordinates. The canvas is
  // this box scaled down, so the miniature keeps each screen's real proportions
  // and their real relative placement.
  function desktopBounds() {
    if (!root.monitors.length) return { x: 0, y: 0, width: 1, height: 1 }
    var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity
    for (var i = 0; i < root.monitors.length; i++) {
      var m = root.monitors[i]
      minX = Math.min(minX, m.x)
      minY = Math.min(minY, m.y)
      maxX = Math.max(maxX, m.x + m.width)
      maxY = Math.max(maxY, m.y + m.height)
    }
    return { x: minX, y: minY, width: Math.max(1, maxX - minX), height: Math.max(1, maxY - minY) }
  }

  function appsAt(page, monitor) {
    return (root.config.apps || []).filter(function (a) {
      return a.page === page && a.monitor === monitor
    })
  }

  // Placing a window means creating or moving its rule. Keyed on the class
  // pattern, because that is what Hyprland actually matches on.
  function place(windowClass, page, monitor, floating, size) {
    var pattern = "^" + windowClass.replace(/[.^$*+?()[\]{}|\\]/g, "\\$&") + "$"
    var apps = (root.config.apps || []).slice()
    for (var i = 0; i < apps.length; i++) {
      if (apps[i].pattern === pattern) {
        apps[i] = Object.assign({}, apps[i], { page: page, monitor: monitor })
        root.config = Object.assign({}, root.config, { apps: apps })
        root.dirty = true
        return
      }
    }
    apps.push({
      pattern: pattern,
      page: page,
      monitor: monitor,
      float: !!floating,
      size: floating && size ? size : "",
      label: windowClass
    })
    root.config = Object.assign({}, root.config, { apps: apps })
    root.dirty = true
  }

  // Context menu state. The menu edits the same working copy as drag and drop,
  // so nothing reaches Hyprland until Apply.
  property var menuEntry: null
  property bool menuOpen: false
  property real menuX: 0
  property real menuY: 0

  function openMenu(entry, x, y) {
    root.menuEntry = entry
    root.menuX = x
    root.menuY = y
    root.menuOpen = true
  }

  function closeMenu() {
    root.menuOpen = false
    root.menuEntry = null
  }

  function patternFor(windowClass) {
    return "^" + windowClass.replace(/[.^$*+?()[\]{}|\\]/g, "\\$&") + "$"
  }

  function ruleFor(windowClass) {
    var pattern = root.patternFor(windowClass)
    var apps = root.config.apps || []
    for (var i = 0; i < apps.length; i++)
      if (apps[i].pattern === pattern) return apps[i]
    return null
  }

  // Float/tile is a property of the rule, not of the live window: the editor
  // describes what should happen next time, and Apply makes it so.
  function setFloating(windowClass, floating) {
    var entry = root.menuEntry
    var page = entry && entry.page ? entry.page : root.currentPage
    var monitor = entry && entry.onMonitor ? entry.onMonitor : ""
    root.place(windowClass, page, monitor, floating,
               entry && entry.size && entry.size.length === 2
                 ? entry.size[0] + " " + entry.size[1] : "")
  }

  function forget(pattern) {
    root.config = Object.assign({}, root.config, {
      apps: (root.config.apps || []).filter(function (a) { return a.pattern !== pattern })
    })
    root.dirty = true
  }

  // Move the live windows of a class, so a drag has a visible effect at once.
  // The rule it also records is what makes the placement stick next time.
  function moveLive(windowClass, page, monitor) {
    if (!windowClass || !monitor) return
    moveProcess.command = ["hypr-spaces", "move", windowClass,
                           "--page", String(page), "--monitor", monitor]
    moveProcess.running = true
  }

  function apply() {
    root.busy = true
    root.error = ""
    applyProcess.write(JSON.stringify(root.config))
    applyProcess.running = true
  }

  // --- processes -----------------------------------------------------------

  Process {
    id: stateProcess
    command: ["hypr-spaces", "state"]
    stdout: StdioCollector {
      onStreamFinished: {
        root.busy = false
        try {
          var parsed = JSON.parse(String(text || "{}"))
          root.monitors = parsed.monitors || []
          root.windows = parsed.windows || []
          root.config = parsed.config || root.config
          if (root.config.apps === undefined) root.config.apps = []
        } catch (e) {
          root.error = "could not read desktop state: " + e
        }
      }
    }
    stderr: StdioCollector {
      onStreamFinished: {
        var message = String(text || "").trim()
        if (message) root.error = message
      }
    }
  }

  Process {
    id: moveProcess
    stdout: StdioCollector {
      onStreamFinished: root.refresh()   // redraw from reality, not assumption
    }
    stderr: StdioCollector {
      onStreamFinished: {
        var message = String(text || "").trim()
        if (message) root.error = message
      }
    }
  }

  Process {
    id: applyProcess
    command: ["hypr-spaces", "apply", "--stdin"]
    stdinEnabled: true
    stdout: StdioCollector {
      onStreamFinished: {
        root.busy = false
        root.dirty = false
        root.refresh()
      }
    }
    stderr: StdioCollector {
      onStreamFinished: {
        var message = String(text || "").trim()
        if (message) {
          root.error = message
          root.busy = false
        }
      }
    }
  }

  // --- window --------------------------------------------------------------

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "kvark-spaces"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: root.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    // Right-click menu. A sibling of the card rather than a child of a tile,
    // so it is not clipped by the small box that opened it.
    MouseArea {
      anchors.fill: parent
      visible: root.menuOpen
      enabled: root.menuOpen
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: root.closeMenu()
      z: 100
    }

    BorderSurface {
      id: card
      width: Math.min(Style.space(1200), panel.width - Style.gapsOut * 4)
      height: Math.min(Style.space(760), panel.height - Style.gapsOut * 4)
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function (event) {
          if (event.key === Qt.Key_Escape) {
            root.dismiss()
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (root.dirty) root.apply()
            event.accepted = true
          } else if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
            root.currentPage = event.key - Qt.Key_0
            event.accepted = true
          } else if (event.key === Qt.Key_0) {
            root.currentPage = 10
            event.accepted = true
          } else if (event.key === Qt.Key_R) {
            root.refresh()
            event.accepted = true
          }
        }

        ColumnLayout {
          anchors.fill: parent
          spacing: Style.spacing.md

          // Header ---------------------------------------------------------
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.md

            Text {
              text: "Spaces"
              color: root.foreground
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              text: "page " + root.currentPage
              color: root.foreground
              opacity: 0.6
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.body
            }

            Item { Layout.fillWidth: true }

            Text {
              visible: root.error !== ""
              text: root.error
              color: root.foreground
              opacity: 0.9
              elide: Text.ElideRight
              Layout.maximumWidth: Style.space(420)
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              text: root.busy ? "working..." : (root.dirty ? "unsaved - Enter to apply" : "saved")
              color: root.foreground
              opacity: 0.6
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          // Page selector --------------------------------------------------
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.sm
            Repeater {
              model: root.config.pages || 10
              Rectangle {
                id: pageChip
                required property int index
                readonly property int page: pageChip.index + 1
                readonly property bool current: pageChip.page === root.currentPage
                width: Style.space(34)
                height: Style.space(28)
                radius: Style.cornerRadius / 2
                color: pageChip.current ? root.selectedBackground : "transparent"
                border.width: 1
                border.color: root.border
                Text {
                  anchors.centerIn: parent
                  text: pageChip.page === 10 ? "0" : String(pageChip.page)
                  color: pageChip.current ? root.selectedText : root.foreground
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.bodySmall
                }
                MouseArea {
                  anchors.fill: parent
                  onClicked: root.currentPage = pageChip.page
                }
              }
            }
            Item { Layout.fillWidth: true }
          }

          // Scale miniature of the desktop ---------------------------------
          //
          // Not a list of columns: each monitor keeps its true aspect ratio and
          // its real position relative to the others, and every window is drawn
          // where it actually sits. One uniform scale factor for both axes, so
          // nothing is stretched.
          Item {
            id: canvas
            Layout.fillWidth: true
            Layout.fillHeight: true

            readonly property var bounds: root.desktopBounds()
            readonly property real fit: Math.min(width / bounds.width, height / bounds.height)
            // Centred, so an asymmetric desk does not hug one edge.
            readonly property real offsetX: (width - bounds.width * fit) / 2
            readonly property real offsetY: (height - bounds.height * fit) / 2

            function px(worldX) { return canvas.offsetX + (worldX - canvas.bounds.x) * canvas.fit }
            function py(worldY) { return canvas.offsetY + (worldY - canvas.bounds.y) * canvas.fit }

            // Snap preview. While a tile is dragged, this is the screen it
            // would land on and the box it would occupy there; null when the
            // pointer is over no screen, which is also how a drop is refused.
            property var snap: null

            function screenAt(canvasX, canvasY) {
              for (var i = 0; i < root.monitors.length; i++) {
                var m = root.monitors[i]
                var left = canvas.px(m.x), top = canvas.py(m.y)
                if (canvasX >= left && canvasX <= left + m.width * canvas.fit
                    && canvasY >= top && canvasY <= top + m.height * canvas.fit)
                  return m
              }
              return null
            }

            // Hit-test the tile's centre rather than the pointer: dragging by a
            // corner should still target the screen the tile is mostly over.
            function updateSnap(tile) {
              var cx = tile.x + tile.width / 2
              var cy = tile.y + tile.height / 2
              var screen = canvas.screenAt(cx, cy)
              if (!screen) {
                canvas.snap = null
                return
              }
              var left = canvas.px(screen.x), top = canvas.py(screen.y)
              var w = screen.width * canvas.fit, h = screen.height * canvas.fit
              // Clamped inside the target screen, so the preview always shows a
              // box that could really exist there.
              canvas.snap = {
                monitor: screen.name,
                x: Math.max(left, Math.min(tile.x, left + w - tile.width)),
                y: Math.max(top, Math.min(tile.y, top + h - tile.height)),
                width: tile.width,
                height: tile.height
              }
            }

            Repeater {
              model: root.monitors

              Rectangle {
                id: screen
                required property var modelData

                x: canvas.px(screen.modelData.x)
                y: canvas.py(screen.modelData.y)
                width: screen.modelData.width * canvas.fit
                height: screen.modelData.height * canvas.fit

                radius: Style.cornerRadius / 2
                color: (canvas.snap && canvas.snap.monitor === screen.modelData.name)
                       ? root.selectedBackground : "transparent"
                border.width: 1
                border.color: root.border

                // The bar's reserved strip, drawn so the miniature matches what
                // the eye sees rather than the raw output rectangle.
                Rectangle {
                  x: 0
                  y: 0
                  width: parent.width
                  height: (screen.modelData.reserved && screen.modelData.reserved.length > 1
                           ? screen.modelData.reserved[1] : 0) * canvas.fit
                  color: root.foreground
                  opacity: 0.08
                }

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  anchors.bottom: parent.bottom
                  anchors.bottomMargin: 2
                  text: screen.modelData.name + "  " + screen.modelData.width + "x" + screen.modelData.height
                  color: root.foreground
                  opacity: 0.35
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }

            // Windows sit above the screens so they can be dragged between them.
            Repeater {
              model: root.windowsOnPage(root.currentPage)

              WindowCard {
                id: tile
                required property var modelData

                readonly property var screenOf: root.monitorByName(tile.modelData.onMonitor)
                readonly property bool placeable: !!tile.screenOf
                          && tile.modelData.at && tile.modelData.at.length === 2
                          && tile.modelData.size && tile.modelData.size.length === 2

                visible: tile.placeable
                homeX: tile.placeable ? canvas.px(tile.modelData.at[0]) : 0
                homeY: tile.placeable ? canvas.py(tile.modelData.at[1]) : 0
                x: tile.homeX
                y: tile.homeY
                width: tile.placeable ? tile.modelData.size[0] * canvas.fit : 0
                height: tile.placeable ? tile.modelData.size[1] * canvas.fit : 0

                entry: tile.modelData
                iconSource: tile.modelData.icon
                  ? Quickshell.iconPath(tile.modelData.icon, true) : ""
                onContextRequested: function (gx, gy) { root.openMenu(tile.modelData, gx, gy) }

                // Live preview while dragging, and the drop itself on release.
                onXChanged: if (tile.dragging) canvas.updateSnap(tile)
                onYChanged: if (tile.dragging) canvas.updateSnap(tile)
                onDraggingChanged: if (tile.dragging) canvas.updateSnap(tile)
                onDragFinished: {
                  if (canvas.snap && canvas.snap.monitor !== tile.modelData.onMonitor) {
                    root.place(tile.modelData.class, root.currentPage, canvas.snap.monitor,
                               tile.modelData.floating,
                               tile.modelData.size && tile.modelData.size.length === 2
                                 ? tile.modelData.size[0] + " " + tile.modelData.size[1] : "")
                    root.moveLive(tile.modelData.class, root.currentPage, canvas.snap.monitor)
                  }
                  canvas.snap = null
                }
                foreground: root.foreground
                surface: root.background
                outline: root.border
                pad: Style.spacing.sm
                radiusPx: Style.cornerRadius / 2
                fontFamily: Style.font.menuFamily
                fontBody: Style.font.body
                fontSmall: Style.font.bodySmall
              }
            }

            // Where the dragged tile will land. Drawn last so it sits above the
            // tiles, and only while a drag is in flight.
            Rectangle {
              visible: canvas.snap !== null
              x: canvas.snap ? canvas.snap.x : 0
              y: canvas.snap ? canvas.snap.y : 0
              width: canvas.snap ? canvas.snap.width : 0
              height: canvas.snap ? canvas.snap.height : 0
              radius: Style.cornerRadius / 2
              color: root.selectedBackground
              border.width: 2
              border.color: root.selectedText
              opacity: 0.9

              Text {
                anchors.centerIn: parent
                visible: parent.height > 30
                text: canvas.snap ? canvas.snap.monitor : ""
                color: root.selectedText
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
          }

          // Footer ----------------------------------------------------------
          Text {
            Layout.fillWidth: true
            text: "drag a window to another screen  ·  1-0 switch page  ·  R refresh  ·  Enter apply  ·  Esc close"
            color: root.foreground
            opacity: 0.45
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.bodySmall
          }
        }
      }
    }

    BorderSurface {
      id: contextMenu
      visible: root.menuOpen
      z: 101

      readonly property var entry: root.menuEntry || ({})
      readonly property string windowClass: contextMenu.entry.class || ""
      readonly property var rule: root.ruleFor(contextMenu.windowClass)

      // Kept on screen: a right-click near the bottom edge would otherwise
      // open a menu that runs off it.
      x: Math.max(0, Math.min(root.menuX, panel.width - width))
      y: Math.max(0, Math.min(root.menuY, panel.height - height))
      width: Style.space(230)
      height: menuColumn.implicitHeight + Style.spacing.md * 2

      color: root.background
      radius: root.cornerRadius
      borderSpec: root.borderSpec
      padding: Style.spacing.md

      MouseArea { anchors.fill: parent; onClicked: {} }

      ColumnLayout {
        id: menuColumn
        anchors.fill: parent
        anchors.margins: Style.spacing.md
        spacing: Style.spacing.xs

        Text {
          Layout.fillWidth: true
          text: contextMenu.windowClass
          color: root.foreground
          elide: Text.ElideRight
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.bodySmall
          opacity: 0.6
        }

        Rectangle {
          Layout.fillWidth: true
          Layout.preferredHeight: 1
          color: root.border
          opacity: 0.3
        }

        Text {
          text: "Send to page"
          color: root.foreground
          opacity: 0.6
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.bodySmall
        }

        // Pages as a grid of numbers rather than a submenu: one click, and the
        // current page is visible at a glance.
        GridLayout {
          Layout.fillWidth: true
          columns: 5
          rowSpacing: Style.spacing.xs
          columnSpacing: Style.spacing.xs

          Repeater {
            model: root.config.pages || 10

            Rectangle {
              id: pageCell
              required property int index
              readonly property int page: pageCell.index + 1
              readonly property bool here: contextMenu.entry.page === pageCell.page

              Layout.fillWidth: true
              Layout.preferredHeight: Style.space(24)
              radius: Style.cornerRadius / 2
              color: pageCell.here ? root.selectedBackground : "transparent"
              border.width: 1
              border.color: root.border

              Text {
                anchors.centerIn: parent
                text: pageCell.page === 10 ? "0" : String(pageCell.page)
                color: pageCell.here ? root.selectedText : root.foreground
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.bodySmall
              }

              MouseArea {
                anchors.fill: parent
                onClicked: {
                  var monitor = contextMenu.entry.onMonitor || ""
                  root.place(contextMenu.windowClass, pageCell.page, monitor,
                             contextMenu.entry.floating, "")
                  root.moveLive(contextMenu.windowClass, pageCell.page, monitor)
                  root.closeMenu()
                }
              }
            }
          }
        }

        Text {
          visible: root.monitors.length > 1
          text: "Send to screen"
          color: root.foreground
          opacity: 0.6
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.bodySmall
        }

        Repeater {
          model: root.monitors.length > 1 ? root.monitors : []

          Rectangle {
            id: screenRow
            required property var modelData
            readonly property bool here: contextMenu.entry.onMonitor === screenRow.modelData.name

            Layout.fillWidth: true
            Layout.preferredHeight: Style.space(24)
            radius: Style.cornerRadius / 2
            color: screenRow.here ? root.selectedBackground : "transparent"

            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter
              text: screenRow.modelData.name + "  " + screenRow.modelData.width
                    + "x" + screenRow.modelData.height
              color: screenRow.here ? root.selectedText : root.foreground
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.bodySmall
            }

            MouseArea {
              anchors.fill: parent
              onClicked: {
                var page = contextMenu.entry.page || root.currentPage
                root.place(contextMenu.windowClass, page, screenRow.modelData.name,
                           contextMenu.entry.floating, "")
                root.moveLive(contextMenu.windowClass, page, screenRow.modelData.name)
                root.closeMenu()
              }
            }
          }
        }

        Rectangle {
          Layout.fillWidth: true
          Layout.preferredHeight: 1
          color: root.border
          opacity: 0.3
        }

        Repeater {
          model: [
            { label: contextMenu.entry.floating ? "Tile it" : "Let it float",
              action: "float" },
            { label: "Forget this rule", action: "forget" }
          ]

          Rectangle {
            id: actionRow
            required property var modelData

            Layout.fillWidth: true
            Layout.preferredHeight: Style.space(24)
            radius: Style.cornerRadius / 2
            color: actionHover.containsMouse ? root.selectedBackground : "transparent"
            // Nothing to forget when no rule exists for this window yet.
            opacity: (actionRow.modelData.action === "forget" && !contextMenu.rule) ? 0.35 : 1

            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.sm
              anchors.verticalCenter: parent.verticalCenter
              text: actionRow.modelData.label
              color: root.foreground
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.bodySmall
            }

            MouseArea {
              id: actionHover
              anchors.fill: parent
              hoverEnabled: true
              onClicked: {
                if (actionRow.modelData.action === "float") {
                  root.setFloating(contextMenu.windowClass, !contextMenu.entry.floating)
                } else if (contextMenu.rule) {
                  root.forget(contextMenu.rule.pattern)
                }
                root.closeMenu()
              }
            }
          }
        }
      }
    }
  }
}
