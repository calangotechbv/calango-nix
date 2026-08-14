import QtQuick
import QtQuick.Layouts
import "../common"

// Generic clickable button (icon, text label, or both) with hover highlight.
// Root is Rectangle so callers can set border.color / border.width directly.
Rectangle {
    id: root

    required property var   theme
    required property string font

    property string icon:       ""   // icon name for common/Icon.qml
    property string label:      ""
    property color  iconColor:  root.theme.textSecondary
    property int    iconSize:   14
    property bool   bold:       false
    property bool   circular:   false           // true → radius = height / 2
    property color  baseColor:  "transparent"
    property color  hoverColor: root.theme.bgHover
    property bool   _enabled:   true
    property int    hPadding:   8

    signal clicked()

    implicitWidth:  content.implicitWidth + hPadding * 2
    implicitHeight: 28
    radius:         circular ? height / 2 : 8
    color:          (area.containsMouse && _enabled) ? hoverColor : baseColor

    // Was a single Text concatenating glyph + "  " + label. An Icon cannot live
    // inside a string, so the two are siblings now; RowLayout drops whichever
    // one is empty, which is what that concatenation was doing by hand.
    RowLayout {
        id: content
        anchors.centerIn: parent
        spacing: 6

        Icon {
            visible: root.icon !== ""
            name: root.icon
            color: root.iconColor
            size: root.iconSize
        }

        Text {
            visible: root.label !== ""
            text: root.label
            color: root.iconColor
            font  { pixelSize: root.iconSize; bold: root.bold; family: root.font }
        }
    }

    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: root._enabled
        cursorShape:  root._enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        enabled:      root._enabled
        onClicked:    root.clicked()
    }
}
