import QtQuick
import QtQuick.Layouts
import "../common"

// One OSD meter: caption, vertical fill, icon. Volume, microphone and
// brightness are the same object with a different icon and colour, so they are
// one file rather than three copies of sixty lines.
//
// `visible` follows the fade rather than `shown` directly: a Column skips
// invisible children, so a hidden meter gives its space back and whichever one
// is on screen stays centred. Keyed off opacity so the fade still runs to the
// end before the slot collapses.
Rectangle {
  id: root

  property var theme
  property string font
  property bool shown: false
  property real value: 0
  property string caption: ""
  property string icon: ""   // icon name for common/Icon.qml
  property color accent: "white"
  property string accessibleName: ""

  width: 36
  height: 200
  radius: 25
  color: theme.bgBase
  border.color: theme.bgBorder
  border.width: 1

  opacity: shown ? 1 : 0
  visible: opacity > 0.01

  Behavior on opacity { NumberAnimation { duration: 150 } }

  Accessible.role: Accessible.ProgressBar
  Accessible.name: root.accessibleName

  ColumnLayout {
    anchors.fill: parent
    anchors.topMargin: 12
    anchors.bottomMargin: 12
    anchors.leftMargin: 0
    anchors.rightMargin: 0
    spacing: 8

    Text {
      text: root.caption
      color: root.theme.textSecondary
      font.pixelSize: 10
      font.family: root.font
      Layout.alignment: Qt.AlignHCenter
    }

    Rectangle {
      Layout.fillHeight: true
      Layout.alignment: Qt.AlignHCenter
      Layout.preferredWidth: 8
      radius: 4
      color: root.theme.bgSurface
      border.color: root.theme.bgBorder
      border.width: 1
      clip: true

      Rectangle {
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: 2
        height: Math.max(0, (parent.height - 4) * Math.max(0, Math.min(1, root.value)))
        radius: 3
        color: root.accent

        Behavior on height { NumberAnimation { duration: 100; easing.type: Easing.OutCubic } }
      }
    }

    Icon {
      name: root.icon
      color: root.accent
      size: 15
      Layout.alignment: Qt.AlignHCenter
    }
  }
}
