// One window in a page column: what it is, and what is running inside it.
//
// The card is the drag source. It carries only the window class and its
// floating geometry, because that is all a placement rule needs -- titles and
// URLs stay on screen and never enter the configuration.

import QtQuick
import QtQuick.Layouts
import Quickshell.Wayland

Rectangle {
  id: card

  // Style values are injected rather than imported: qs.Ui resolves for a
  // plugin's entry point but not for the files it pulls in, so importing it
  // here leaves every Style reference undefined at runtime.
  property int pad: 6
  property int radiusPx: 6
  property string fontFamily: "monospace"
  property int fontBody: 13
  property int fontSmall: 11

  property var entry: ({})
  // Resolved by the parent, which has Quickshell in scope for icon lookup.
  property string iconSource: ""
  // Its windows are set to stay on one workspace together.
  property bool grouped: false
  property bool pinned: false
  // The letter that selects this window from the keyboard, and whether it is
  // the one currently held.
  property string hint: ""
  property bool held: false
  // Live view: the window's own content instead of its icon. `toplevel` is the
  // Wayland handle the capture reads from, matched by the parent; null when no
  // unambiguous match was found, in which case the icon stands in.
  property bool liveView: false
  property var toplevel: null
  // Only once a frame has arrived: flipping as soon as a toplevel matched hid
  // the icon before the capture had anything to show, so tiles went blank.
  readonly property bool wantsLive: liveView && toplevel !== null
  readonly property bool showingLive: wantsLive && livePreviewLoader.hasContent
  property color foreground: "white"
  property color surface: "black"
  property color outline: "gray"

  readonly property string kind: entry.kind || "window"
  readonly property var detail: entry.detail || ({})

  // The icon scales with the window it stands for, so a maximised browser
  // reads at a glance and a small floating player does not shout. Clamped at
  // both ends: past ~72px it is just a big picture, under ~14px it is mush.
  readonly property real iconSize: Math.max(14, Math.min(72, Math.min(width, height) * 0.3))
  // Text only earns its space once the tile is big enough to read it.
  readonly property bool showName: height > iconSize + card.fontBody + card.pad * 3
  readonly property bool showDetail: height > iconSize + card.fontBody * 3 + card.pad * 4

  signal contextRequested(real globalX, real globalY)
  signal dragFinished()
  signal closeRequested()

  // True while the left button is dragging this tile. The canvas watches it to
  // draw the snap preview.
  readonly property bool dragging: dragArea.drag.active

  // Size and position are set by the canvas from the window's real geometry,
  // so the card must not size itself. Content is clipped instead: a small
  // window gets a small box, exactly as on screen.
  clip: true
  radius: radiusPx
  color: dragArea.drag.active || card.held ? Qt.lighter(surface, 1.35)
       : hoverArea.hovered ? Qt.lighter(surface, 1.15)
       : surface
  border.width: card.held ? 2 : 1
  border.color: dragArea.drag.active || card.held ? foreground : outline
  // Lifted while dragging, so it reads as picked up rather than sliding.
  scale: dragArea.drag.active ? 1.03 : 1
  opacity: dragArea.drag.active ? 0.85 : 1

  Behavior on color { ColorAnimation { duration: 90 } }
  Behavior on scale { NumberAnimation { duration: 90 } }

  HoverHandler { id: hoverArea }

  // Where the canvas says this window lives. Dragging breaks the x/y bindings,
  // so the card is put back here on release rather than left mid-air claiming
  // a position the window does not have.
  property real homeX: 0
  property real homeY: 0

  MouseArea {
    id: dragArea
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    // Only the left button drags: a right-press that moved the tile would
    // fight the menu it is meant to open.
    drag.target: pressedButtons & Qt.LeftButton ? card : null
    cursorShape: Qt.OpenHandCursor
    onPressed: function (mouse) {
      if (mouse.button === Qt.RightButton) {
        var global = card.mapToItem(null, mouse.x, mouse.y)
        card.contextRequested(global.x, global.y)
        mouse.accepted = true
      }
    }
    onReleased: {
      // The canvas decides where this landed by hit-testing the tile against
      // the drawn screens; Qt's own drop machinery is not involved, so there
      // is no mime data or DropArea to misconfigure.
      card.dragFinished()
      card.x = card.homeX
      card.y = card.homeY
    }
  }

  // Always present, always the same size, always the same corner. A control
  // that only appears on hover, or that grows with its tile, has to be hunted
  // for; this one is in one place on every window so the hand learns it.
  readonly property real controlSize: 18
  // Nothing to close without a window address - a tile drawn from stale state,
  // or one the compositor did not give an address for. The button stays in
  // place and says it cannot act, rather than vanishing.
  readonly property bool canClose: !!(entry && entry.address)

  // The keyboard hint, top-left: the opposite corner from close, so the two
  // never fight for the same spot on a small tile. Always drawn rather than
  // behind a mode, because a letter you can see is one you do not have to know.
  Rectangle {
    id: hintBadge
    visible: card.hint !== "" && !card.dragging
             && card.width > card.controlSize * 2 + 12
             && card.height > card.controlSize + 8
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.margins: 4
    z: 5

    width: card.controlSize
    height: card.controlSize
    radius: 4
    color: card.held ? card.foreground : Qt.rgba(0, 0, 0, 0.45)
    border.width: 1
    border.color: card.held ? card.foreground : card.outline
    opacity: card.held ? 1 : 0.75

    Behavior on color { ColorAnimation { duration: 90 } }

    Text {
      anchors.centerIn: parent
      text: card.hint.toUpperCase()
      color: card.held ? card.surface : card.foreground
      font.family: card.fontFamily
      font.pixelSize: hintBadge.width * 0.6
      font.bold: true
    }
  }

  // Close, in every tile, in the same corner. Only the one control: it acts on
  // the window it sits in, which is the whole rule for controls here - adding
  // is a property of a screen, so its `+` lives on the screen.
  //
  // The opposite corner from the screen's `+` on purpose: a maximised window
  // covers its screen, and two buttons in one corner would be a coin toss.
  Rectangle {
    id: closeButton
    // Hidden only when the tile genuinely cannot hold it, and while dragging,
    // where it would be a target moving under the cursor.
    visible: !card.dragging
             && card.width > card.controlSize + 8
             && card.height > card.controlSize + 8
    anchors.top: parent.top
    anchors.right: parent.right
    anchors.margins: 4
    z: 5

    width: card.controlSize
    height: card.controlSize
    radius: width / 2

    // Shown in place rather than hidden when there is nothing to close, so the
    // corner does not change shape from tile to tile.
    readonly property bool disabled: !card.canClose

    color: buttonHover.hovered ? "#a55555" : Qt.rgba(0, 0, 0, 0.45)
    border.width: 1
    border.color: buttonHover.hovered ? "#a55555" : card.outline
    opacity: closeButton.disabled ? 0.3 : (buttonHover.hovered ? 1 : 0.75)

    Behavior on color { ColorAnimation { duration: 90 } }
    HoverHandler {
      id: buttonHover
      enabled: !closeButton.disabled
    }

    Text {
      anchors.centerIn: parent
      text: "−"
      color: buttonHover.hovered ? card.surface : card.foreground
      font.family: card.fontFamily
      font.pixelSize: closeButton.width * 0.6
      font.bold: true
    }

    MouseArea {
      anchors.fill: parent
      enabled: !closeButton.disabled
      cursorShape: closeButton.disabled ? Qt.ArrowCursor : Qt.PointingHandCursor
      onClicked: card.closeRequested()
    }
  }

  // The window's own content, filling the tile. Behind the controls and the
  // caption, and inset so the screen outline and this card's border stay
  // visible - a preview that reaches the edge looks like a hole in the page.
  // A Loader, so with live view off there is no capture session at all rather
  // than an idle one per window.
  Loader {
    id: livePreviewLoader
    active: card.wantsLive
    // Visible as soon as it is wanted, not once it has content: an invisible
    // ScreencopyView never captures, so gating visibility on hasContent left
    // it waiting for a frame it would never be asked to produce.
    visible: card.wantsLive
    anchors.fill: parent
    // Inset past the corner radius: clip() clips to the bounding box, not the
    // rounded shape, so a smaller inset lets the preview paint over the very
    // border it is meant to leave visible.
    anchors.margins: Math.max(2, card.radiusPx)
    z: 1

    readonly property bool hasContent: livePreviewLoader.item
      ? livePreviewLoader.item.hasContent : false

    sourceComponent: ScreencopyView {
      captureSource: card.toplevel
      // Streams only while the editor is showing this tile; a hidden editor
      // must not keep pulling frames.
      live: card.liveView && card.visible
      paintCursor: false
      // Without this the source is captured at its own resolution - a 4K
      // window streaming full-size buffers into a thumbnail.
      constraintSize: Qt.size(Math.max(1, card.width), Math.max(1, card.height))
    }
  }

  // A caption over the live view, so a preview is still identifiable when the
  // content itself is ambiguous - two empty terminals, say.
  Rectangle {
    // Its own budget, not the icon layout's: showName is derived from iconSize,
    // which does not apply in live view, and hid the caption on the small
    // tiles where a preview is least identifiable.
    visible: card.showingLive && card.height > card.fontSmall * 3
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.margins: 2
    height: caption.implicitHeight + 6
    color: Qt.rgba(0, 0, 0, 0.6)
    z: 2

    Text {
      id: caption
      anchors.centerIn: parent
      width: parent.width - 8
      text: card.entry.class || "?"
      color: card.foreground
      elide: Text.ElideRight
      horizontalAlignment: Text.AlignHCenter
      font.family: card.fontFamily
      font.pixelSize: card.fontSmall
      font.bold: true
    }
  }

  // Centred as a block: icon, then the name directly beneath it, then whatever
  // detail the tile is tall enough to carry.
  // Enough inset that a long path elides before it reaches the border rather
  // than merging into it. Clamped so a narrow tile still has usable width.
  readonly property real textInset: Math.min(12, Math.max(6, card.width * 0.06))

  ColumnLayout {
    id: content
    // Above the preview, and shown until the first frame lands, so a tile
    // shows its icon rather than a blank rectangle while the capture starts.
    z: 3
    visible: !card.showingLive
    anchors.centerIn: parent
    width: Math.max(20, parent.width - card.textInset * 2)
    spacing: Math.max(2, card.pad / 2)

    Item {
      Layout.alignment: Qt.AlignHCenter
      Layout.preferredWidth: card.iconSize
      Layout.preferredHeight: card.iconSize

      Image {
        anchors.fill: parent
        visible: card.iconSource !== ""
        source: card.iconSource
        sourceSize.width: card.iconSize
        sourceSize.height: card.iconSize
        fillMode: Image.PreserveAspectFit
        smooth: true
        asynchronous: true
      }

      // A shape standing for the window's kind, when no icon could be resolved.
      Text {
        anchors.centerIn: parent
        visible: card.iconSource === ""
        text: card.kind === "terminal" ? "▸" : card.kind === "browser" ? "●" : "■"
        color: card.foreground
        opacity: 0.6
        font.pixelSize: card.iconSize * 0.7
      }
    }

    Text {
      visible: card.showName
      Layout.fillWidth: true
      text: card.entry.class || "?"
      color: card.foreground
      elide: Text.ElideRight
      horizontalAlignment: Text.AlignHCenter
      font.family: card.fontFamily
      font.pixelSize: card.fontBody
      font.bold: true
    }

    // Badges sit under the name so the centred column stays a column.
    Text {
      visible: card.showName
               && (card.grouped || card.pinned || card.entry.floating === true)
      Layout.fillWidth: true
      text: [card.pinned ? "on every page" : "", card.grouped ? "grouped" : "",
             card.entry.floating === true ? "float" : ""]
        .filter(function (part) { return part !== "" }).join("  ·  ")
      color: card.foreground
      opacity: 0.5
      horizontalAlignment: Text.AlignHCenter
      font.family: card.fontFamily
      font.pixelSize: card.fontSmall
    }

    // Terminals: the directory, and the command actually running there.
    Text {
      visible: card.showDetail && card.kind === "terminal" && !!card.detail.cwd
      Layout.fillWidth: true
      text: card.detail.cwd || ""
      color: card.foreground
      opacity: 0.5
      elide: Text.ElideLeft
      horizontalAlignment: Text.AlignHCenter
      font.family: card.fontFamily
      font.pixelSize: card.fontSmall
    }

    Text {
      visible: card.showDetail && card.kind === "terminal" && !!card.detail.command
      Layout.fillWidth: true
      text: card.detail.command || ""
      color: card.foreground
      opacity: 0.75
      elide: Text.ElideRight
      horizontalAlignment: Text.AlignHCenter
      font.family: card.fontFamily
      font.pixelSize: card.fontSmall
    }

    // Browsers: a tab count. A dozen tab titles per card would bury the layout
    // the editor exists to show.
    Text {
      visible: card.showDetail && card.kind === "browser" && !!card.detail.tabs
      Layout.fillWidth: true
      text: card.detail.tabs
        ? card.detail.tabs.length + (card.detail.tabs.length === 1 ? " tab" : " tabs")
        : ""
      color: card.foreground
      opacity: 0.5
      horizontalAlignment: Text.AlignHCenter
      font.family: card.fontFamily
      font.pixelSize: card.fontSmall
    }
  }
}
