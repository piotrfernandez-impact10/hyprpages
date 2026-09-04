// One window in a page column: what it is, and what is running inside it.
//
// The card is the drag source. It carries only the window class and its
// floating geometry, because that is all a placement rule needs -- titles and
// URLs stay on screen and never enter the configuration.

import QtQuick
import QtQuick.Layouts

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

  signal contextRequested(real globalX, real globalY)
  signal dragFinished()

  // True while the left button is dragging this tile. The canvas watches it to
  // draw the snap preview.
  readonly property bool dragging: dragArea.drag.active
  property color foreground: "white"
  property color surface: "black"
  property color outline: "gray"

  readonly property string kind: entry.kind || "window"
  readonly property var detail: entry.detail || ({})

  // Size and position are set by the canvas from the window's real geometry,
  // so the card must not size itself. Content is clipped instead: a small
  // window gets a small box, exactly as on screen.
  clip: true
  radius: radiusPx
  color: dragArea.drag.active ? Qt.lighter(surface, 1.35)
       : hoverArea.hovered ? Qt.lighter(surface, 1.15)
       : surface
  border.width: 1
  border.color: dragArea.drag.active ? foreground : outline
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

  ColumnLayout {
    id: content
    anchors.fill: parent
    anchors.margins: card.pad
    spacing: 2

    RowLayout {
      Layout.fillWidth: true
      spacing: card.pad

      // The application's own icon when one could be resolved, and a shape
      // standing for the window's kind when it could not.
      Image {
        visible: card.iconSource !== ""
        source: card.iconSource
        sourceSize.width: card.fontBody + 2
        sourceSize.height: card.fontBody + 2
        // Layout.* rather than width/height: the RowLayout owns geometry here.
        Layout.preferredWidth: card.fontBody + 2
        Layout.preferredHeight: card.fontBody + 2
        fillMode: Image.PreserveAspectFit
        smooth: true
        asynchronous: true
      }

      Text {
        visible: card.iconSource === ""
        text: card.kind === "terminal" ? "▸" : card.kind === "browser" ? "●" : "■"
        color: card.foreground
        opacity: 0.6
        font.pixelSize: card.fontSmall
      }

      Text {
        Layout.fillWidth: true
        text: card.entry.class || "?"
        color: card.foreground
        elide: Text.ElideRight
        font.family: card.fontFamily
        font.pixelSize: card.fontBody
        font.bold: true
      }

      Text {
        visible: card.grouped
        text: "grouped"
        color: card.foreground
        opacity: 0.5
        font.family: card.fontFamily
        font.pixelSize: card.fontSmall
      }

      Text {
        visible: card.entry.floating === true
        text: "float"
        color: card.foreground
        opacity: 0.5
        font.family: card.fontFamily
        font.pixelSize: card.fontSmall
      }
    }

    // Terminals: the directory, and the command actually running there.
    Text {
      visible: card.height > 64 && card.kind === "terminal" && !!card.detail.cwd
      Layout.fillWidth: true
      text: card.detail.cwd || ""
      color: card.foreground
      opacity: 0.5
      elide: Text.ElideLeft
      font.family: card.fontFamily
      font.pixelSize: card.fontSmall
    }

    Text {
      visible: card.height > 46 && card.kind === "terminal" && !!card.detail.command
      Layout.fillWidth: true
      text: card.detail.command || ""
      color: card.foreground
      opacity: 0.75
      elide: Text.ElideRight
      font.family: card.fontFamily
      font.pixelSize: card.fontSmall
    }

    // Browsers: a tab count, expanded on hover rather than always listed --
    // a dozen tab titles per card would bury the layout the editor is for.
    Text {
      visible: card.height > 46 && card.kind === "browser" && !!card.detail.tabs
      Layout.fillWidth: true
      text: card.detail.tabs
        ? card.detail.tabs.length + (card.detail.tabs.length === 1 ? " tab" : " tabs")
        : ""
      color: card.foreground
      opacity: 0.5
      font.family: card.fontFamily
      font.pixelSize: card.fontSmall
    }
  }
}
