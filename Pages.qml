// Visual editor for pages. Pure UI: every fact comes from `hyprpages state`
// and every change leaves through `hyprpages apply --stdin`, so the process
// walking and config writing stay in Python where they can be tested.
//
// Surface tokens are borrowed from [menu], so a theme that styles the Omarchy
// menu styles this too.

import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Wayland._ToplevelManagement
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

Item {
  id: root

  property var shell: null
  property var manifest: null

  // Installed via `omarchy plugin add`, nothing puts the CLI on PATH, so the
  // copy shipped inside this plugin is used when it is there. A PATH install
  // still wins for people running from a clone.
  readonly property string cli: {
    var bundled = Quickshell.env("HOME")
      + "/.config/omarchy/plugins/kvark.hyprpages/bin/hyprpages"
    return root.bundledCliExists ? bundled : "hyprpages"
  }
  property bool bundledCliExists: false

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
  // Set once per open, then left alone so a refresh cannot yank the user off
  // the page they are working on.
  property bool followActivePage: false

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
    // A caller may name the page: `omarchy-shell shell summon kvark.hyprpages
    // '{"page": 3}'`. Otherwise open on the page you are actually on, since
    // the editor is usually reached to adjust what is in front of you.
    var requested = 0
    try {
      var payload = JSON.parse(String(payloadJson || "{}"))
      requested = parseInt(payload.page, 10) || 0
    } catch (e) {
      requested = 0
    }
    if (requested >= 1 && requested <= (root.config.pages || 10)) {
      root.currentPage = requested
      root.followActivePage = false
    } else {
      root.followActivePage = true
    }
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
    appsProcess.running = false
    launchProcess.running = false
    closeProcess.running = false
    root.confirmEntry = null
    refreshAfterLaunch.stop()
    root.closePicker()
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
      root.shell.hide((root.manifest && root.manifest.id) || "kvark.hyprpages")
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

  // Windows are positioned in logical coordinates, so the miniature must be
  // drawn in them too; on a scaled monitor the mode's pixel size is larger.
  function logicalWidth(m) { return m.logicalWidth || m.width }
  function logicalHeight(m) { return m.logicalHeight || m.height }

  // The page the desktop is showing right now, from the focused monitor's
  // workspace, falling back to any monitor that is on a recognisable page.
  function activePage() {
    var names = root.monitorNames()
    var offset = root.config.offset || 10
    var best = 0
    for (var i = 0; i < root.monitors.length; i++) {
      var m = root.monitors[i]
      var index = names.indexOf(m.name)
      if (index < 0) continue
      var id = parseInt(m.active_workspace, 10)
      if (isNaN(id)) continue
      var page = id - offset * index
      if (page >= 1 && page <= (root.config.pages || 10)) {
        if (m.focused) return page
        if (!best) best = page
      }
    }
    return best
  }

  // Pair a window with the Wayland toplevel that represents it.
  //
  // The two come from different protocols: windows from hyprctl, which knows
  // addresses, and toplevels from wlr-foreign-toplevel-management, which does
  // not. So they are matched on what both expose - the app id against the
  // class, and the title to tell two windows of one app apart, which is
  // exactly the case of four terminals side by side.
  function toplevelFor(entry) {
    if (!entry || !entry.class) return null
    var list = ToplevelManager.toplevels ? ToplevelManager.toplevels.values : []
    var sameApp = []
    for (var i = 0; i < list.length; i++) {
      var t = list[i]
      if (!t) continue
      if (String(t.appId || "") === String(entry.class)) sameApp.push(t)
    }
    if (!sameApp.length) return null
    if (sameApp.length === 1) return sameApp[0]
    for (var j = 0; j < sameApp.length; j++) {
      if (String(sameApp[j].title || "") === String(entry.title || "")) return sameApp[j]
    }
    // Ambiguous: showing the wrong window's content would be worse than
    // showing none, so fall back to the icon.
    return null
  }

  function toggleLiveView() {
    root.config = Object.assign({}, root.config, {
      live_view: !root.config.live_view
    })
    root.dirty = true
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
      maxX = Math.max(maxX, m.x + root.logicalWidth(m))
      maxY = Math.max(maxY, m.y + root.logicalHeight(m))
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
        apps[i] = Object.assign({}, apps[i], {
          page: page,
          monitor: monitor,
          float: !!floating,
          size: floating && size ? size : ""
        })
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

  // Linked screens are a choice, not a law: some people want one page across
  // the whole desk, others want each monitor switching on its own. Both are
  // reasonable, so it is a toggle rather than a built-in assumption.
  function togglePairing() {
    root.config = Object.assign({}, root.config, {
      pair_monitors: !root.config.pair_monitors
    })
    root.dirty = true
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
  // Whether new windows of an app join the ones already open. Per-app, because
  // it matches on class and so cannot tell a dialog from a genuinely new
  // window: right for qBittorrent's preview, wrong for a second browser window.
  function setTogether(windowClass, together) {
    var pattern = root.patternFor(windowClass)
    var apps = (root.config.apps || []).slice()
    for (var i = 0; i < apps.length; i++) {
      if (apps[i].pattern === pattern) {
        apps[i] = Object.assign({}, apps[i], { together: together })
        root.config = Object.assign({}, root.config, { apps: apps })
        root.dirty = true
        return
      }
    }
    // No monitor, so workspace_for returns nothing and no placement rule is
    // emitted: grouping an app must not silently pin it to a page as well.
    apps.push({
      pattern: pattern,
      page: root.currentPage,
      monitor: "",
      float: false,
      size: "",
      together: together,
      label: windowClass
    })
    root.config = Object.assign({}, root.config, { apps: apps })
    root.dirty = true
  }

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

  // "Add something here". The editor stays open and offers the choice in
  // place: being thrown at a workspace to pick an app loses the context you
  // were arranging, which is the whole point of the editor.
  property bool pickerOpen: false
  property string pickerMonitor: ""
  property string pickerFilter: ""
  property int pickerIndex: 0
  property var apps: []

  // `near` is a window address: the new app opens beside that window rather
  // than wherever the layout would otherwise drop it.
  property string pickerNear: ""

  function addTo(page, monitor, near) {
    if (!monitor) return
    root.pickerNear = near || ""
    root.pickerMonitor = monitor
    root.pickerFilter = ""
    root.pickerIndex = 0
    root.pickerOpen = true
    if (!root.apps.length) appsProcess.running = true
  }

  // Closing a window can lose work, so it asks first. Every other action here
  // is reversible by dragging something back; this one is not.
  property var confirmEntry: null

  function askClose(entry) {
    root.confirmEntry = entry
  }

  function confirmClose() {
    var entry = root.confirmEntry
    root.confirmEntry = null
    if (!entry || !entry.address) return
    closeProcess.command = [root.cli, "close", entry.address]
    closeProcess.running = true
  }

  function closePicker() {
    root.pickerOpen = false
    root.pickerFilter = ""
  }

  function filteredApps() {
    var needle = root.pickerFilter.toLowerCase()
    if (!needle) return root.apps
    return root.apps.filter(function (a) {
      return a.name.toLowerCase().indexOf(needle) >= 0
    })
  }

  function launchPicked() {
    var list = root.filteredApps()
    if (!list.length) return
    var app = list[Math.max(0, Math.min(root.pickerIndex, list.length - 1))]
    var args = [root.cli, "launch", app.id,
                "--page", String(root.currentPage),
                "--monitor", root.pickerMonitor]
    if (root.pickerNear) args = args.concat(["--near", root.pickerNear])
    launchProcess.command = args
    launchProcess.running = true
    root.closePicker()
  }

  // Move the live windows of a class, so a drag has a visible effect at once.
  // The rule it also records is what makes the placement stick next time.
  // `address` moves just that window; without it every window of the class
  // moves, which is right for the menu ("send this app to page 4") and wrong
  // for a drag ("put this window there").
  function moveLive(windowClass, page, monitor, address) {
    if (!root.opened || !windowClass || !monitor) return
    var args = [root.cli, "move", windowClass, "--page", String(page), "--monitor", monitor]
    if (address) args = args.concat(["--address", address])
    moveProcess.command = args
    moveProcess.running = true
  }

  function apply() {
    if (!root.opened) return
    root.busy = true
    root.error = ""
    // The payload is handed over in onStarted: Process.write before the
    // process is running goes nowhere, and `hyprpages apply --stdin` then
    // blocks forever on a pipe that is open but never written.
    applyProcess.payload = JSON.stringify(root.config)
    applyProcess.running = true
  }

  // --- processes -----------------------------------------------------------

  Process {
    id: stateProcess
    command: [root.cli, "state"]
    stdout: StdioCollector {
      onStreamFinished: {
        root.busy = false
        try {
          var parsed = JSON.parse(String(text || "{}"))
          root.monitors = parsed.monitors || []
          root.windows = parsed.windows || []

          if (root.followActivePage) {
            root.followActivePage = false
            var active = root.activePage()
            if (active > 0) root.currentPage = active
          }
          // Unsaved edits win: a refresh fires after every move, launch and
          // `r`, and taking the on-disk config back would quietly undo what the
          // user just did while the header still read "unsaved".
          if (!root.dirty) {
            root.config = parsed.config || root.config
            if (root.config.apps === undefined) root.config.apps = []
          }
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

  // Checked once at startup rather than guessed: a missing bundled CLI and a
  // missing PATH one need different advice.
  FileView {
    path: Quickshell.env("HOME") + "/.config/omarchy/plugins/kvark.hyprpages/bin/hyprpages"
    onLoaded: root.bundledCliExists = true
  }

  Process {
    id: appsProcess
    command: [root.cli, "apps"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          root.apps = JSON.parse(String(text || "[]"))
        } catch (e) {
          root.error = "could not read the application list"
        }
      }
    }
  }

  Process {
    id: closeProcess
    stdout: StdioCollector {
      // The window takes a moment to go; look again once it has.
      onStreamFinished: refreshAfterLaunch.start()
    }
    stderr: StdioCollector {
      onStreamFinished: {
        var message = String(text || "").trim()
        if (message) root.error = message
      }
    }
  }

  Process {
    id: launchProcess
    stdout: StdioCollector {
      // A new window takes a moment to map, so look again shortly after.
      onStreamFinished: refreshAfterLaunch.start()
    }
    stderr: StdioCollector {
      onStreamFinished: {
        var message = String(text || "").trim()
        if (message) root.error = message
      }
    }
  }

  Timer {
    id: refreshAfterLaunch
    interval: 900
    onTriggered: root.refresh()
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
    command: [root.cli, "apply", "--stdin"]
    stdinEnabled: true
    property string payload: ""
    onStarted: {
      write(applyProcess.payload)
      applyProcess.payload = ""
      stdinEnabled = false  // closing the pipe is what lets the CLI finish
    }
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
    WlrLayershell.namespace: "kvark-hyprpages"
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
      readonly property real plateRoom: Style.space(28)

      width: Math.min(Style.space(1400), panel.width - Style.gapsOut * 4)
      height: Math.min(panel.height - Style.gapsOut * 4,
                       content.implicitHeight + card.padding * 2 + Style.spacing.sm)
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        // BorderSurface's own `padding` only insets children that ask for it;
        // filling the surface ignores it, which put every edge of text hard
        // against the border.
        anchors.margins: card.padding
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function (event) {
          // The confirmation is modal: it answers first, so Escape cancels the
          // close rather than shutting the whole editor.
          if (root.confirmEntry !== null) {
            if (event.key === Qt.Key_Escape) {
              root.confirmEntry = null
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              root.confirmClose()
            }
            event.accepted = true
            return
          }

          // While the picker is open it takes the keyboard: typing filters,
          // Escape backs out of the picker rather than the whole editor.
          if (root.pickerOpen) {
            if (event.key === Qt.Key_Escape) {
              root.closePicker()
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              root.launchPicked()
            } else if (event.key === Qt.Key_Down) {
              root.pickerIndex = Math.min(root.pickerIndex + 1,
                                          root.filteredApps().length - 1)
            } else if (event.key === Qt.Key_Up) {
              root.pickerIndex = Math.max(0, root.pickerIndex - 1)
            } else if (event.key === Qt.Key_Backspace) {
              root.pickerFilter = root.pickerFilter.slice(0, -1)
              root.pickerIndex = 0
            } else if (event.text && event.text.length === 1 && event.text >= " ") {
              root.pickerFilter += event.text
              root.pickerIndex = 0
            }
            event.accepted = true
            return
          }

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
          } else if (event.key === Qt.Key_L) {
            root.togglePairing()
            event.accepted = true
          } else if (event.key === Qt.Key_V) {
            root.toggleLiveView()
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
              text: "Pages"
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

            // Linked or independent screens.
            Rectangle {
              visible: root.monitors.length > 1
              Layout.preferredWidth: pairingLabel.implicitWidth + Style.spacing.md * 2
              Layout.preferredHeight: Style.space(22)
              radius: Style.cornerRadius / 2
              color: pairingHover.hovered ? Qt.lighter(root.background, 1.3) : "transparent"
              border.width: 1
              border.color: root.config.pair_monitors
                ? root.selectedText
                : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.25)

              Behavior on color { ColorAnimation { duration: 90 } }
              HoverHandler { id: pairingHover }

              Text {
                id: pairingLabel
                anchors.centerIn: parent
                text: root.config.pair_monitors ? "screens linked" : "screens independent"
                color: root.config.pair_monitors ? root.selectedText : root.mutedText
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                anchors.fill: parent
                onClicked: root.togglePairing()
              }
            }

            // Live view: real window content instead of icons.
            Rectangle {
              Layout.preferredWidth: liveLabel.implicitWidth + Style.spacing.md * 2
              Layout.preferredHeight: Style.space(22)
              radius: Style.cornerRadius / 2
              color: liveHover.hovered ? Qt.lighter(root.background, 1.3) : "transparent"
              border.width: 1
              border.color: root.config.live_view
                ? root.selectedText
                : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.25)

              Behavior on color { ColorAnimation { duration: 90 } }
              HoverHandler { id: liveHover }

              Text {
                id: liveLabel
                anchors.centerIn: parent
                text: "live view"
                color: root.config.live_view ? root.selectedText : root.mutedText
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                anchors.fill: parent
                onClicked: root.toggleLiveView()
              }
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
                width: Math.max(1, root.logicalWidth(m) * canvas.fit - canvas.gap * 2),
                height: Math.max(1, root.logicalHeight(m) * canvas.fit - canvas.gap * 2)
              }
            }

            // Windows are placed within the inset screen, scaled by the same
            // factor, so the picture stays proportional and nothing overhangs.
            function windowRect(w, m) {
              var r = canvas.screenRect(m)
              // The area windows may occupy: the screen minus its own outline.
              var innerW = Math.max(1, r.width - canvas.inset * 2)
              var innerH = Math.max(1, r.height - canvas.inset * 2)
              var kx = innerW / (root.logicalWidth(m) * canvas.fit)
              var ky = innerH / (root.logicalHeight(m) * canvas.fit)
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

                z: 0  // screens at the back
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

                // Name plate, below the screen like a label on the bezel. It
                // carries the workspace number too, so the picture ties back to
                // what Hyprland actually calls this space.
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  anchors.top: parent.bottom
                  anchors.topMargin: Style.spacing.xs
                  text: screen.modelData.name + "  ·  " + screen.modelData.width
                        + "×" + screen.modelData.height
                        + (screen.modelData.scale && screen.modelData.scale !== 1
                           ? " @" + screen.modelData.scale + "×" : "")
                        + "  ·  ws " + root.workspaceFor(root.currentPage,
                                                         screen.modelData.name)
                  color: screen.targeted ? root.selectedText : root.foreground
                  opacity: screen.targeted ? 1 : 0.75
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }
              }
            }

            // Windows sit above the screens so they can be dragged between them.
            Repeater {
              model: root.windowsOnPage(root.currentPage)

              WindowCard {
                id: tile
                required property var modelData
                z: 1  // windows sit inside their screen

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
                grouped: {
                  var rule = root.ruleFor(tile.modelData.class)
                  return !!(rule && rule.together)
                }
                iconSource: tile.modelData.icon
                  ? Quickshell.iconPath(tile.modelData.icon, true) : ""
                liveView: root.config.live_view === true
                toplevel: root.config.live_view === true
                  ? root.toplevelFor(tile.modelData) : null
                onContextRequested: function (gx, gy) { root.openMenu(tile.modelData, gx, gy) }
                onAddRequested: root.addTo(root.currentPage, tile.modelData.onMonitor,
                                           tile.modelData.address)
                onCloseRequested: root.askClose(tile.modelData)

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
                    root.moveLive(tile.modelData.class, root.currentPage,
                                  canvas.snap.monitor, tile.modelData.address)
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

            // Add buttons, above the windows so a maximised one cannot bury
            // them. Their own repeater rather than a child of each screen,
            // because a screen sits below every window in draw order.
            Repeater {
              model: root.monitors

              Rectangle {
                id: addButton
                required property var modelData
                z: 10  // always reachable, whatever fills the screen
                readonly property var rect: canvas.screenRect(addButton.modelData)

                width: Style.space(24)
                height: Style.space(24)
                x: addButton.rect.x + addButton.rect.width - width - Style.spacing.sm
                y: addButton.rect.y + addButton.rect.height - height - Style.spacing.sm
                radius: width / 2

                color: addHover.hovered ? root.selectedText : Qt.rgba(0, 0, 0, 0.55)
                border.width: 1
                border.color: addHover.hovered ? root.selectedText : root.screenEdge

                Behavior on color { ColorAnimation { duration: 90 } }
                HoverHandler { id: addHover }

                Text {
                  anchors.centerIn: parent
                  text: "+"
                  color: addHover.hovered ? root.background : root.screenEdge
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                }

                MouseArea {
                  anchors.fill: parent
                  onClicked: root.addTo(root.currentPage, addButton.modelData.name, "")
                }
              }
            }

            // Where the dragged tile will land. Drawn last so it sits above the
            // tiles, and only while a drag is in flight.
            Rectangle {
              z: 20  // the drop preview is the most important thing on screen
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
                  + "·   1-0 page   ·   L link screens   ·   V live view   ·   R refresh   "
                  + "·   Enter apply   ·   Esc close"
            color: root.mutedText
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }

    // Close confirmation. Above everything, because it is the one action here
    // that cannot be undone by dragging something back.
    MouseArea {
      anchors.fill: parent
      visible: root.confirmEntry !== null
      enabled: root.confirmEntry !== null
      onClicked: root.confirmEntry = null
      z: 300
    }

    BorderSurface {
      id: confirmDialog
      visible: root.confirmEntry !== null
      z: 301

      anchors.centerIn: parent
      width: Style.space(320)
      height: confirmColumn.implicitHeight + Style.spacing.panelPadding * 2
      color: root.background
      radius: root.cornerRadius
      borderSpec: root.borderSpec

      MouseArea { anchors.fill: parent; onClicked: {} }

      ColumnLayout {
        id: confirmColumn
        anchors.fill: parent
        anchors.margins: Style.spacing.panelPadding
        spacing: Style.spacing.sm

        Text {
          Layout.fillWidth: true
          text: "Close " + ((root.confirmEntry && root.confirmEntry.class) || "this window") + "?"
          color: root.foreground
          wrapMode: Text.WordWrap
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        Text {
          Layout.fillWidth: true
          // Said plainly: this asks the application to close, so anything with
          // unsaved work will put its own dialog up rather than lose it.
          text: "The application is asked to close, so it can still prompt you "
                + "about unsaved work."
          color: root.mutedText
          wrapMode: Text.WordWrap
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.caption
        }

        RowLayout {
          Layout.fillWidth: true
          Layout.topMargin: Style.spacing.sm
          spacing: Style.spacing.sm

          Item { Layout.fillWidth: true }

          Repeater {
            model: [
              { label: "Cancel", danger: false },
              { label: "Close it", danger: true }
            ]

            Rectangle {
              id: confirmButton
              required property var modelData

              Layout.preferredWidth: Style.space(96)
              Layout.preferredHeight: Style.space(28)
              radius: Style.cornerRadius / 2
              color: confirmHover.hovered
                ? (confirmButton.modelData.danger ? Color.urgent : root.selectedBackground)
                : "transparent"
              border.width: 1
              border.color: confirmButton.modelData.danger
                ? Color.urgent
                : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.3)

              Behavior on color { ColorAnimation { duration: 90 } }
              HoverHandler { id: confirmHover }

              Text {
                anchors.centerIn: parent
                text: confirmButton.modelData.label
                color: confirmHover.hovered && confirmButton.modelData.danger
                  ? root.background : root.foreground
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.bodySmall
              }

              MouseArea {
                anchors.fill: parent
                onClicked: {
                  if (confirmButton.modelData.danger) root.confirmClose()
                  else root.confirmEntry = null
                }
              }
            }
          }
        }
      }
    }

    // Application picker. Sits over the card so the arrangement stays visible
    // behind it - you are choosing what to add to a specific screen, and that
    // screen should still be on screen.
    MouseArea {
      anchors.fill: parent
      visible: root.pickerOpen
      enabled: root.pickerOpen
      onClicked: root.closePicker()
      z: 200
    }

    BorderSurface {
      id: picker
      visible: root.pickerOpen
      z: 201

      anchors.centerIn: parent
      width: Style.space(420)
      height: Math.min(panel.height - Style.gapsOut * 6, Style.space(460))
      color: root.background
      radius: root.cornerRadius
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      MouseArea { anchors.fill: parent; onClicked: {} }

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: Style.spacing.panelPadding
        spacing: Style.spacing.sm

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.sm

          Text {
            text: "Add to " + root.pickerMonitor
            color: root.foreground
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }

          Item { Layout.fillWidth: true }

          Text {
            text: "page " + root.currentPage
            color: root.mutedText
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
          }
        }

        // The filter is the typing itself; a focused text field would fight
        // the overlay's exclusive keyboard grab for no gain.
        Text {
          Layout.fillWidth: true
          text: root.pickerFilter.length ? root.pickerFilter : "type to filter…"
          color: root.pickerFilter.length ? root.foreground : root.mutedText
          elide: Text.ElideRight
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.body
        }

        PanelSeparator { Layout.fillWidth: true }

        ListView {
          id: appList
          Layout.fillWidth: true
          Layout.fillHeight: true
          clip: true
          model: root.filteredApps()
          currentIndex: root.pickerIndex
          highlightMoveDuration: 90
          // Keep the keyboard selection in view as it moves.
          onCurrentIndexChanged: appList.positionViewAtIndex(appList.currentIndex,
                                                             ListView.Contain)

          delegate: Rectangle {
            id: appRow
            required property var modelData
            required property int index

            width: appList.width
            height: Style.space(30)
            radius: Style.cornerRadius / 2
            color: appRow.index === root.pickerIndex ? root.selectedBackground
                 : rowHover.hovered ? Qt.lighter(root.background, 1.25)
                 : "transparent"

            HoverHandler { id: rowHover }

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.spacing.sm
              anchors.rightMargin: Style.spacing.sm
              spacing: Style.spacing.sm

              Image {
                source: appRow.modelData.icon
                  ? Quickshell.iconPath(appRow.modelData.icon, true) : ""
                visible: source !== ""
                sourceSize.width: Style.font.body + 6
                sourceSize.height: Style.font.body + 6
                Layout.preferredWidth: Style.font.body + 6
                Layout.preferredHeight: Style.font.body + 6
                fillMode: Image.PreserveAspectFit
                asynchronous: true
              }

              Text {
                Layout.fillWidth: true
                text: appRow.modelData.name
                color: appRow.index === root.pickerIndex ? root.selectedText
                                                         : root.foreground
                elide: Text.ElideRight
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.body
              }
            }

            MouseArea {
              anchors.fill: parent
              onClicked: {
                root.pickerIndex = appRow.index
                root.launchPicked()
              }
            }
          }
        }

        Text {
          Layout.fillWidth: true
          text: "enter opens it here   ·   esc cancels"
          color: root.mutedText
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.caption
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
            { label: (contextMenu.rule && contextMenu.rule.together)
                ? "Let its windows scatter" : "Keep its windows together",
              action: "together" },
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
                } else if (actionRow.modelData.action === "together") {
                  root.setTogether(contextMenu.windowClass,
                                   !(contextMenu.rule && contextMenu.rule.together))
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
