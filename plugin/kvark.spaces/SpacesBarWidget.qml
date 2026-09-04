// Bar button that shows and hides the Spaces editor.
//
// NOT named BarWidget.qml: a plugin directory is an implicit QML module, so a
// file with that name shadows the BarWidget base type it inherits from and the
// component fails to load with "File name case mismatch".
//
// The icon is drawn rather than set as a glyph. Omarchy's own icon font carries
// only brand logos, and picking a Nerd Font codepoint would depend on which
// font the user's theme happens to use -- two rectangles always render, and
// they say what the tool is about.

import QtQuick
import qs.Commons  // Style lives here, not in qs.Ui
import qs.Ui

BarWidget {
  id: root
  moduleName: "kvark.spaces"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar

    // The button sizes itself from its text, which there is none of here.
    text: ""
    hasVisualContent: true
    labelVisible: false
    fixedWidth: root.vertical ? -1 : Style.space(22)
    fixedHeight: root.vertical ? Style.space(22) : -1
    tooltipText: "Spaces"

    onPressed: function (mouseButton) {
      if (!root.bar || mouseButton !== Qt.LeftButton) return
      // toggle, so the same button opens and closes it
      root.bar.run("omarchy-shell shell toggle kvark.spaces")
    }

    Item {
      anchors.centerIn: parent
      width: Style.space(14)
      height: Style.space(10)

      // Two screens side by side, in the proportions the editor itself draws:
      // a wider one and a narrower one.
      Rectangle {
        x: 0
        y: 0
        width: parent.width * 0.55
        height: parent.height
        radius: 1
        color: "transparent"
        border.width: 1
        border.color: button.foreground
      }

      Rectangle {
        x: parent.width * 0.62
        y: parent.height * 0.15
        width: parent.width * 0.38
        height: parent.height * 0.7
        radius: 1
        color: "transparent"
        border.width: 1
        border.color: button.foreground
      }
    }
  }
}
