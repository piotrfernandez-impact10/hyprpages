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
              font.pixelSize: Style.font.small
            }

            Text {
              text: root.busy ? "working..." : (root.dirty ? "unsaved - Enter to apply" : "saved")
              color: root.foreground
              opacity: 0.6
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.small
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
                  font.pixelSize: Style.font.small
                }
                MouseArea {
                  anchors.fill: parent
                  onClicked: root.currentPage = pageChip.page
                }
              }
            }
            Item { Layout.fillWidth: true }
          }

          // One column per monitor -----------------------------------------
          RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Style.spacing.md

            Repeater {
              model: root.monitorNames()

              Rectangle {
                id: column
                required property string modelData
                Layout.fillWidth: true
                Layout.fillHeight: true
                radius: Style.cornerRadius / 2
                color: dropTarget.containsDrag ? root.selectedBackground : "transparent"
                border.width: 1
                border.color: root.border

                DropArea {
                  id: dropTarget
                  anchors.fill: parent
                  onDropped: function (drop) {
                    var payload = JSON.parse(drop.text)
                    root.place(payload.cls, root.currentPage, column.modelData,
                               payload.floating, payload.size)
                    drop.accept()
                  }
                }

                ColumnLayout {
                  anchors.fill: parent
                  anchors.margins: Style.spacing.sm
                  spacing: Style.spacing.sm

                  Text {
                    text: root.monitorLabel(column.modelData)
                    color: root.foreground
                    opacity: 0.7
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                    font.family: Style.font.menuFamily
                    font.pixelSize: Style.font.small
                  }

                  ListView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    spacing: Style.spacing.sm
                    model: root.windowsAt(root.currentPage, column.modelData)

                    delegate: WindowCard {
                      required property var modelData
                      width: ListView.view.width
                      entry: modelData
                      foreground: root.foreground
                      surface: root.background
                      outline: root.border
                      pad: Style.spacing.sm
                      radiusPx: Style.cornerRadius / 2
                      fontFamily: Style.font.menuFamily
                      fontBody: Style.font.body
                      fontSmall: Style.font.small
                    }
                  }
                }
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
            font.pixelSize: Style.font.small
          }
        }
      }
    }
  }
}
