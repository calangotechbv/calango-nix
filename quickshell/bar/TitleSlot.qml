import QtQuick

// The bar's centre: the focused window's title, in a pill.
//
// Extracted from Bar.qml because the geometry needs a test of its own. It ran
// inline for as long as it was one expression, and that expression was wrong
// in a way no reading of it caught: a bluetooth device connects, the right
// section grows past half the bar, and the title paints across every pill on
// the right.
//
// Two budgets, because "centred on the bar" and "fits" are different
// questions:
//
//   centredWidth  reserves max(left, right) on BOTH sides, so the pill's
//                 centre is the bar's centre whatever the two sections do.
//                 It is the nicer of the two and it is the one that collapses.
//   gapWidth      is what is really free between the sections. It is never
//                 the smaller of the two -- left + right <= 2 * max(left,
//                 right) -- so falling back to it never costs width.
//
// The fallback is not decoration. Measured on this machine with a bluetooth
// headset connected: bar 1516, left 546, right 742, so centredWidth is 0 and
// gapWidth is 228. The old code took the 0, and a zero-width slot gives the
// Text a NEGATIVE width, which switches Qt's eliding off entirely -- a Text
// with `width < 0` paints its full natural width rather than nothing. That is
// the whole defect: not a pill drawn too wide, but an unelided string painted
// out of a box that had shrunk to nothing.
//
// Three guards, and they are NOT equal -- each was mutated on its own against
// the geometry above, and only one of the three can be made to fail:
//
//   the gap fallback   load-bearing. Remove it and the title vanishes with a
//                      headset connected. This is the fix.
//   Math.max(0, ...)   a net. With the fallback in place the width is never
//                      negative, so removing this changes nothing measurable.
//   clip on the slot   a net, for the same reason.
//
// The two nets stay because they cost nothing and they answer the arithmetic
// rather than trusting it. Do not read them as tested: they are not.
Item {
  id: root

  property string title: ""
  // The two sections this one has to fit between. Widths rather than the items
  // themselves: it makes the component testable with two numbers.
  property real leftWidth: 0
  property real rightWidth: 0
  property color pillColor: "transparent"
  property color textColor: "white"
  property string fontFamily: ""
  property int fontSize: 13

  // Breathing room between the title pill and either section.
  readonly property real pad: 16

  // Below this, a bar-centred title is not worth the centring: it holds about
  // two words. Take the gap instead, which by construction offers at least as
  // much.
  readonly property real centredMinimum: 160

  readonly property real centredWidth:
    Math.max(0, root.width - 2 * Math.max(root.leftWidth, root.rightWidth) - 2 * root.pad)
  readonly property real gapWidth:
    Math.max(0, root.width - root.leftWidth - root.rightWidth - 2 * root.pad)
  readonly property bool barCentred: root.centredWidth >= root.centredMinimum

  // What the test asserts on. `paintedRight` is deliberately the ink and not
  // the box: contentWidth is what Qt really draws, and the defect this file
  // exists for was ink outside its box.
  readonly property real slotLeft: slot.x
  readonly property real slotRight: slot.x + slot.width
  readonly property real paintedRight: slot.x + pill.x + titleText.x + titleText.contentWidth
  readonly property bool elided: titleText.truncated
  // Whether a title is on screen at all. `paintedRight` is measured before
  // the clip, on purpose -- so a test can hold the layout to the gap and keep
  // the clip as the net it is meant to be, rather than as the mechanism.
  readonly property bool showing: pill.visible

  Item {
    id: slot
    height: parent.height
    anchors.verticalCenter: parent.verticalCenter
    clip: true

    width: root.barCentred ? root.centredWidth : root.gapWidth
    x: root.barCentred ? (root.width - width) / 2 : root.leftWidth + root.pad

    Rectangle {
      id: pill
      anchors.centerIn: parent
      height: 24
      // Grows with the title but stops where the slot does: a pill wider than
      // the gap between the two sections would sit under them.
      width: Math.min(titleText.implicitWidth + 16, parent.width)
      radius: 12
      color: root.pillColor
      // No focused window, no pill -- an empty one is just a smudge in the
      // middle of the bar. Nor one too narrow to hold a character.
      visible: titleText.text !== "" && width > 24

      Text {
        id: titleText
        Accessible.role: Accessible.StaticText
        Accessible.name: "Active window: " + text
        text: root.title
        color: root.textColor
        font.pixelSize: root.fontSize
        font.family: root.fontFamily
        elide: Text.ElideRight
        // Math.max(0, ...) answers the one input that breaks a Text: a
        // negative width turns eliding off and the string paints in full. The
        // slot above no longer hands one down, so this is the net described in
        // the header and not the fix.
        width: Math.max(0, Math.min(implicitWidth, parent.width - 16))
        anchors.centerIn: parent
      }
    }
  }
}
