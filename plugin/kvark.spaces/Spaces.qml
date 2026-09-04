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

  // Two depths carry the whole diagram: a screen is a well cut into the card,
  // a window is a surface resting inside it. Derived from the theme's own
  // colours so this follows whatever theme is active.
  readonly property color screenWell: Qt.darker(root.background, 1.45)
  readonly property color screenEdge: Qt.lighter(root.foreground, 1.6)
  readonly property color windowFill: Qt.lighter(root.background, 1.55)
  readonly property color windowEdge: Qt.rgba(root.foreground.r, root.foreground.g,
                                              root.foreground.b, 0.35)
  readonly property color mutedText: Qt.darker(root.foreground, 1.5)

  function open(payloadJson) {
    root.opened = true
    root.error = ""
    root.dirty = false
    root.refresh()
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    root.stopWork()
  }

  // Nothing may run while the editor is hidden: no subprocesses, no pending
  // state, no half-finished edit waiting to be applied by a later keystroke.
  // The overlay is declared keepLoaded:false so it unloads entirely, and this
  // makes the window between "hidden" and "unloaded" inert too.
  function stopWork() {
    stateProcess.running = false
    moveProcess.running = false
    applyProcess.running = false
    canvas_snapReset()
    root.closeMenu()
    root.busy = false
  }

  // Declared as a function rather than touching canvas directly: the canvas
  // lives inside the panel, which does not exist while the overlay is unloaded.
  function canvas_snapReset() {
    if (typeof canvas !== "undefined" && canvas) canvas.snap = null
  }

  function dismiss() {
    root.opened = false
    root.stopWork()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "kvark.spaces")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function refresh() {
    // Guarded so a late callback -- a move finishing after the user pressed
    // Escape -- cannot start another read of the desktop behind their back.
    if (!root.opened) return
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

  function windowsOnScreen(page, monitorName) {
    return root.windows.filter(function (w) {
      return w.page === page && w.onMonitor === monitorName
    })
  }

  // The workspace number a page maps to on a given screen, shown on the name
  // plate so the miniature ties back to the numbers Hyprland actually uses.
  function workspaceFor(page, monitorName) {
    var names = root.monitorNames()
    var index = names.indexOf(monitorName)
    if (index < 0) return "?"
    return page + (root.config.offset || 10) * index
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

  // "Add something here": focus the page's workspace on that screen, close the
  // editor, and hand over to Omarchy's own app launcher. Whatever is started
  // next opens on the focused workspace, so the launcher needs to know nothing
  // about pages, and the user gets the launcher they already know rather than
  // a second-rate copy of it.
  function addTo(page, monitor) {
    if (!monitor) return
    addProcess.command = ["sh", "-c",
      "hypr-spaces focus --page " + page + " --monitor '" + monitor
      + "' && omarchy-menu toggle apps"]
    root.dismiss()
    addProcess.running = true
  }

  // Move the live windows of a class, so a drag has a visible effect at once.
  // The rule it also records is what makes the placement stick next time.
  function moveLive(windowClass, page, monitor) {
    if (!root.opened || !windowClass || !monitor) return
    moveProcess.command = ["hypr-spaces", "move", windowClass,
                           "--page", String(page), "--monitor", monitor]
    moveProcess.running = true
  }

  function apply() {
    if (!root.opened) return
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
    id: addProcess
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
    Rectangle { anchors.fill: parent; color: "black"; opacity: 0.35 }
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
      readonly property real desktopAspect: {
        var b = root.desktopBounds()
        return b.height > 0 ? b.width / b.height : 1.777
      }
      // Name plates hang below each screen, so the canvas needs a little more
      // height than the screens themselves.
      readonly property real plateRoom: Style.space(18)

      width: Math.min(Style.space(1400), panel.width - Style.gapsOut * 4)
      height: Math.min(panel.height - Style.gapsOut * 4,
                       content.implicitHeight + card.padding * 2)
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
          id: content
          anchors.fill: parent
          spacing: Style.spacing.md

          // Header ---------------------------------------------------------
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.sm

            Item {
              Layout.preferredWidth: Style.space(16)
              Layout.preferredHeight: Style.space(12)

              Rectangle {
                width: parent.width * 0.55
                height: parent.height
                radius: 1
                color: "transparent"
                border.width: 1
                border.color: root.foreground
              }

              Rectangle {
                x: parent.width * 0.62
                y: parent.height * 0.15
                width: parent.width * 0.38
                height: parent.height * 0.7
                radius: 1
                color: "transparent"
                border.width: 1
                border.color: root.foreground
              }
            }

            Text {
              text: "Spaces"
              color: root.foreground
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.heading
              font.bold: true
            }

            Text {
              text: "page " + root.currentPage
              color: root.mutedText
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.body
            }

            Item { Layout.fillWidth: true }

            Text {
              visible: root.error !== ""
              text: root.error
              color: Color.urgent
              elide: Text.ElideRight
              Layout.maximumWidth: Style.space(360)
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.caption
            }

            // One status, three states, never two at once.
            Text {
              text: root.busy ? "working…" : root.dirty ? "unsaved · enter to apply" : "saved"
              color: root.dirty ? root.selectedText : root.mutedText
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.caption
              font.bold: root.dirty
            }
          }

          PanelSeparator { Layout.fillWidth: true }

          // Pages ------------------------------------------------------------
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.xs

            PanelSectionHeader {
              text: "PAGES"
              foreground: root.foreground
              fontFamily: Style.font.menuFamily
            }

            Item { Layout.preferredWidth: Style.spacing.sm }

            Repeater {
              model: root.config.pages || 10

              Rectangle {
                id: pageChip
                required property int index
                readonly property int page: pageChip.index + 1
                readonly property bool current: pageChip.page === root.currentPage
                // A page with nothing on it should not look like one that has
                // your terminals waiting on it.
                readonly property bool occupied: root.windowsOnPage(pageChip.page).length > 0

                Layout.preferredWidth: Style.space(26)
                Layout.preferredHeight: Style.space(24)
                radius: Style.cornerRadius / 2
                color: pageChip.current ? root.selectedBackground
                     : chipHover.hovered ? Qt.lighter(root.background, 1.3)
                     : "transparent"
                border.width: 1
                border.color: pageChip.current
                  ? root.selectedText
                  : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.25)

                Behavior on color { ColorAnimation { duration: 90 } }
                HoverHandler { id: chipHover }

                Text {
                  anchors.centerIn: parent
                  text: pageChip.page === 10 ? "0" : String(pageChip.page)
                  color: pageChip.current ? root.selectedText
                       : pageChip.occupied ? root.foreground : root.mutedText
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: pageChip.current
                }

                // A dot for "something lives here", so an unlabelled number is
                // never ambiguous.
                Rectangle {
                  visible: pageChip.occupied && !pageChip.current
                  width: 3
                  height: 3
                  radius: 1.5
                  color: root.foreground
                  opacity: 0.7
                  anchors.horizontalCenter: parent.horizontalCenter
                  anchors.bottom: parent.bottom
                  anchors.bottomMargin: 2
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
            // Derived, not filled: the miniature is exactly as tall as the
            // desktop's proportions require at this width.
            Layout.preferredHeight: Math.min(
              Style.space(560),
              canvas.width / card.desktopAspect + card.plateRoom)

            readonly property var bounds: root.desktopBounds()
            readonly property real drawHeight: Math.max(1, height - card.plateRoom)
            readonly property real fit: Math.min(width / bounds.width,
                                                 drawHeight / bounds.height)
            // Centred, so an asymmetric desk does not hug one edge.
            readonly property real offsetX: (width - bounds.width * fit) / 2
            readonly property real offsetY: (canvas.drawHeight - bounds.height * fit) / 2

            function px(worldX) { return canvas.offsetX + (worldX - canvas.bounds.x) * canvas.fit }
            function py(worldY) { return canvas.offsetY + (worldY - canvas.bounds.y) * canvas.fit }

            // Screens are drawn inset so neighbouring outlines never touch:
            // two rectangles sharing an edge read as one box with a divider
            // through it, which is the opposite of what the outline is for.
            readonly property real gap: Math.max(3, Style.space(5))
            // Windows are drawn over the screens, so a maximised one would
            // paint straight over the outline that says "this is a monitor".
            // Reserve the border's own width plus a hair inside every screen.
            readonly property real screenBorder: 2
            readonly property real inset: canvas.screenBorder + 1

            function screenRect(m) {
              return {
                x: canvas.px(m.x) + canvas.gap,
                y: canvas.py(m.y) + canvas.gap,
                width: Math.max(1, m.width * canvas.fit - canvas.gap * 2),
                height: Math.max(1, m.height * canvas.fit - canvas.gap * 2)
              }
            }

            // Windows are placed within the inset screen, scaled by the same
            // factor, so the picture stays proportional and nothing overhangs.
            function windowRect(w, m) {
              var r = canvas.screenRect(m)
              // The area windows may occupy: the screen minus its own outline.
              var innerW = Math.max(1, r.width - canvas.inset * 2)
              var innerH = Math.max(1, r.height - canvas.inset * 2)
              var kx = innerW / (m.width * canvas.fit)
              var ky = innerH / (m.height * canvas.fit)
              return {
                x: r.x + canvas.inset + (w.at[0] - m.x) * canvas.fit * kx,
                y: r.y + canvas.inset + (w.at[1] - m.y) * canvas.fit * ky,
                width: w.size[0] * canvas.fit * kx,
                height: w.size[1] * canvas.fit * ky
              }
            }

            // Snap preview. While a tile is dragged, this is the screen it
            // would land on and the box it would occupy there; null when the
            // pointer is over no screen, which is also how a drop is refused.
            property var snap: null

            function screenAt(canvasX, canvasY) {
              for (var i = 0; i < root.monitors.length; i++) {
                var m = root.monitors[i]
                var r = canvas.screenRect(m)
                if (canvasX >= r.x && canvasX <= r.x + r.width
                    && canvasY >= r.y && canvasY <= r.y + r.height)
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
              var r = canvas.screenRect(screen)
              var pad = canvas.inset
              // Clamped inside the target screen, so the preview always shows a
              // box that could really exist there - and never over the outline.
              canvas.snap = {
                monitor: screen.name,
                x: Math.max(r.x + pad, Math.min(tile.x, r.x + r.width - pad - tile.width)),
                y: Math.max(r.y + pad, Math.min(tile.y, r.y + r.height - pad - tile.height)),
                width: tile.width,
                height: tile.height
              }
            }

            Repeater {
              model: root.monitors

              Item {
                id: screen
                required property var modelData
                readonly property bool targeted:
                  canvas.snap && canvas.snap.monitor === screen.modelData.name

                readonly property var rect: canvas.screenRect(screen.modelData)
                x: screen.rect.x
                y: screen.rect.y
                width: screen.rect.width
                height: screen.rect.height

                // The screen itself: a well, darker than the card it sits in,
                // so windows read as resting inside it.
                Rectangle {
                  id: well
                  anchors.fill: parent
                  radius: Style.cornerRadius / 2
                  color: screen.targeted
                    ? Qt.lighter(root.screenWell, 1.5) : root.screenWell
                  border.width: canvas.screenBorder
                  border.color: screen.targeted ? root.selectedText : root.screenEdge

                  Behavior on color { ColorAnimation { duration: 90 } }

                  // The bar's reserved strip, so the miniature matches what the
                  // eye actually sees rather than the raw output rectangle.
                  Rectangle {
                    width: parent.width
                    height: (screen.modelData.reserved && screen.modelData.reserved.length > 1
                             ? screen.modelData.reserved[1] : 0) * canvas.fit
                    topLeftRadius: parent.radius
                    topRightRadius: parent.radius
                    color: root.foreground
                    opacity: 0.07
                  }

                  // Nothing here yet - said plainly rather than left ambiguous.
                  Text {
                    anchors.centerIn: parent
                    visible: root.windowsOnScreen(root.currentPage,
                                                  screen.modelData.name).length === 0
                    text: "empty"
                    color: root.mutedText
                    font.family: Style.font.menuFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                // Add an application to this page, on this screen.
                Rectangle {
                  id: addButton
                  anchors.right: parent.right
                  anchors.bottom: parent.bottom
                  anchors.margins: Style.spacing.xs
                  width: Style.space(22)
                  height: Style.space(22)
                  radius: width / 2
                  color: addHover.hovered ? root.selectedBackground
                                          : Qt.rgba(0, 0, 0, 0.35)
                  border.width: 1
                  border.color: addHover.hovered ? root.selectedText : root.screenEdge

                  Behavior on color { ColorAnimation { duration: 90 } }
                  HoverHandler { id: addHover }

                  Text {
                    anchors.centerIn: parent
                    text: "+"
                    color: addHover.hovered ? root.selectedText : root.foreground
                    font.family: Style.font.menuFamily
                    font.pixelSize: Style.font.subtitle
                    font.bold: true
                  }

                  MouseArea {
                    anchors.fill: parent
                    onClicked: root.addTo(root.currentPage, screen.modelData.name)
                  }
                }

                // Name plate, outside the screen like a label on the bezel.
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  anchors.top: parent.bottom
                  anchors.topMargin: Style.spacing.xxs
                  text: screen.modelData.name + "  ·  " + screen.modelData.width
                        + "×" + screen.modelData.height
                        + "  ·  ws " + root.workspaceFor(root.currentPage, screen.modelData.name)
                  color: screen.targeted ? root.selectedText : root.mutedText
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.caption
                  font.bold: screen.targeted
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
                readonly property var rect: tile.placeable
                  ? canvas.windowRect(tile.modelData, tile.screenOf)
                  : { x: 0, y: 0, width: 0, height: 0 }

                homeX: tile.rect.x
                homeY: tile.rect.y
                x: tile.homeX
                y: tile.homeY
                width: tile.rect.width
                height: tile.rect.height

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
                surface: root.windowFill
                outline: root.windowEdge
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
          PanelSeparator { Layout.fillWidth: true }

          Text {
            Layout.fillWidth: true
            text: "+ adds an app here   ·   drag a window between screens   ·   right-click for options   "
                  + "·   1-0 page   ·   R refresh   ·   Enter apply   ·   Esc close"
            color: root.mutedText
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
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
