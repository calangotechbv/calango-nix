import QtQuick
import QtQuick.Shapes

// One icon, drawn from Icons.qml path data.
//
// Drop-in for the old `Text { text: <glyph>; font.family: nerdFont }` pattern: same
// `color`, and `size` where that had `font.pixelSize`. The difference is that
// this always occupies exactly size x size, whereas a glyph occupied whatever
// advance width the font gave it -- which is why swapping bell for bell-off
// used to nudge the rest of the bar sideways.
//
// Sized in a 24x24 space and scaled, because that is the viewBox every MDI
// path is authored in. CurveRenderer rasterises in device space, so scaling
// stays crisp at any size rather than blurring like a pre-rendered image.
Item {
  id: root

  // An MDI name from Icons.paths, e.g. "bell-off". Unknown names draw nothing.
  property string name
  property color color: "#c0caf5"
  property real size: 16

  implicitWidth: size
  implicitHeight: size

  // Matches the colour transitions the glyph Texts already ran, so state
  // changes keep fading rather than snapping.
  Behavior on color { ColorAnimation { duration: 120 } }

  Shape {
    anchors.centerIn: parent
    width: 24
    height: 24
    scale: root.size / 24
    preferredRendererType: Shape.CurveRenderer

    ShapePath {
      fillColor: root.color
      // MDI paths are fills with no stroke; a stroke here would fatten them.
      strokeWidth: -1
      fillRule: ShapePath.WindingFill
      PathSvg { path: Icons.path(root.name) }
    }
  }
}
