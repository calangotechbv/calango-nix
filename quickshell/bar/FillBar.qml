import QtQuick

// The vertical fill used by every bar pill that reports a proportion: cpu,
// memory, volume, microphone, brightness. Same shape as the OSD's meters, at
// bar scale.
//
// Extracted at the fifth copy, not the first. `color` is the trough, so the
// only thing a caller must supply beyond the value is the fill.
Rectangle {
  id: root

  // 0..1. Clamped here rather than at each call site, since half of them
  // divide by 100 and the other half come from a float that can exceed 1
  // (PipeWire allows volume above unity).
  property real value: 0
  property color fillColor: "white"

  width: 6
  height: 14
  radius: 3
  clip: true

  Rectangle {
    anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
    height: parent.height * Math.max(0, Math.min(1, root.value))
    radius: 3
    color: root.fillColor

    Behavior on height { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
  }
}
