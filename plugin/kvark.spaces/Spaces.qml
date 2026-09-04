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

  function forget(pattern) {
    root.config = Object.assign({}, root.config, {
      apps: (root.config.apps || []).filter(function (a) { return a.pattern !== pattern })
    })
    root.dirty = true
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
                color: screenDrop.containsDrag ? root.selectedBackground : "transparent"
                border.width: 1
                border.color: root.border

                DropArea {
                  id: screenDrop
                  anchors.fill: parent
                  onDropped: function (drop) {
                    var payload = JSON.parse(drop.text)
                    root.place(payload.cls, root.currentPage, screen.modelData.name,
                               payload.floating, payload.size)
                    drop.accept()
                  }
                }

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
  }
}
