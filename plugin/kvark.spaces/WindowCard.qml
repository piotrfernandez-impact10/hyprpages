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
  property color foreground: "white"
  property color surface: "black"
  property color outline: "gray"

  readonly property string kind: entry.kind || "window"
  readonly property var detail: entry.detail || ({})

  height: content.implicitHeight + pad * 2
  radius: radiusPx
  color: dragArea.drag.active ? Qt.lighter(surface, 1.4) : surface
  border.width: 1
  border.color: outline
  opacity: dragArea.drag.active ? 0.7 : 1

  Drag.active: dragArea.drag.active
  Drag.hotSpot.x: width / 2
  Drag.hotSpot.y: height / 2
  Drag.mimeData: {
    "text/plain": JSON.stringify({
      cls: entry.class,
      floating: entry.floating,
      size: (entry.size && entry.size.length === 2) ? (entry.size[0] + " " + entry.size[1]) : ""
    })
  }

  MouseArea {
    id: dragArea
    anchors.fill: parent
    drag.target: card
    cursorShape: Qt.OpenHandCursor
    onReleased: {
      if (card.Drag.target) card.Drag.drop()
      // Snap home either way: the column re-renders from state after Apply,
      // so a card left mid-air would be lying about where the window is.
      card.x = 0
      card.y = 0
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

      Text {
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
      visible: card.kind === "terminal" && !!card.detail.cwd
      Layout.fillWidth: true
      text: card.detail.cwd || ""
      color: card.foreground
      opacity: 0.5
      elide: Text.ElideLeft
      font.family: card.fontFamily
      font.pixelSize: card.fontSmall
    }

    Text {
      visible: card.kind === "terminal" && !!card.detail.command
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
      visible: card.kind === "browser"
      Layout.fillWidth: true
      text: {
        if (!card.detail.tabs) return "tabs unavailable"
        return card.detail.tabs.length + (card.detail.tabs.length === 1 ? " tab" : " tabs")
      }
      color: card.foreground
      opacity: 0.5
      font.family: card.fontFamily
      font.pixelSize: card.fontSmall
    }
  }
}
