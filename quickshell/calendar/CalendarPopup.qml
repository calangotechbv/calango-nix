pragma ComponentBehavior: Bound
import Quickshell
import QtQuick
import "../common"

// The month view behind the clock pill. Dates only: there is no agenda and no
// event source, and the spec at
// docs/superpowers/specs/2026-08-05-calendar-on-the-clock-design.md records why
// -- evolution-data-server is installed here with nothing registered in it, so
// an agenda would have been a D-Bus dependency rendering an empty state.
//
// A dropdown rather than the centred card the other fifteen panels use, because
// a calendar hanging off a clock is not a modal. That means no Scrim, which is
// why this claims PanelGroup directly instead of inheriting the one-at-a-time
// rule through one.
//
// Drawn with a plain Grid rather than QtQuick.Controls' MonthGrid, which is
// what this was first built on. A Control positions its contentItem in a polish
// step that runs a frame *after* the item exists, so the first rendered frame
// of a freshly mapped popup showed unpositioned cells -- a stray highlight and
// an outsized day number for a few milliseconds, every single open. Nothing
// outside the Control can fix that, because the deferral is inside it. Plain
// items resolve their geometry on creation, so the first frame is the finished
// frame. The 42 cells cost four lines of date arithmetic, and unlike Qt's
// calendar that arithmetic is ours, so dev-calendar-check.qml can assert it.
PopupWindow {
  id: root

  // Passed in by the bar. Deliberately no default: this is only ever
  // instantiated there, and a fallback theme would be a second source of truth
  // for colours that silently wins when a binding is mistyped.
  property var theme
  property string font: "AdwaitaMono Nerd Font"

  // The bar's own visibility. `qs ipc call bar toggle` hides the bar for a
  // screenshot or a video, and a popup anchored to a surface that has gone is
  // orphaned -- so this closes with it.
  property bool barVisible: true

  // Today as yyyy-MM-dd, handed in as Time.dayStamp. Passed rather than read
  // here so this directory does not import ../bar while ../bar imports this
  // one -- and because a component that takes its "today" is one a check can
  // pin to a fixed day later without touching the clock.
  property string todayStamp

  // The month on screen. Reset on every open.
  property date shown: new Date()

  // When the popup last went away, in ms. See toggle().
  property double _lastHidden: 0

  // Whether the surface has been told what scale it is drawing at yet.
  //
  // A wayland surface does not know its fractional scale until the compositor
  // sends it, which is *after* the surface maps. Measured on this machine, both
  // displays at scale 1.67: a popup maps at devicePixelRatio 2 and is corrected
  // to 1.6667 one frame -- 16 ms -- later. Everything drawn in that frame is
  // 20% oversized and then snaps, which reads as the calendar assembling itself
  // in front of you.
  //
  // Neither setting `screen` nor pre-warming the window helps: measured, a
  // second open maps at 2 again, and Quickshell.screens reports 2 as well, so
  // there is nothing correct to compare against either. Holding the card back
  // until the correction has landed is what is left.
  property bool _scaled: false

  // Geometry, stated rather than negotiated. Seven 32px cells and six 2px gaps
  // is 236, and six 26px rows and five 2px gaps is 166. Both are known before
  // anything is laid out, which is the point.
  readonly property int cellW: 32
  readonly property int cellH: 26
  readonly property int gap: 2
  readonly property int gridW: cellW * 7 + gap * 6

  color: "transparent"
  // Intrinsic to what this is, not a decision the bar gets to make: without it
  // there is no grab, so no outside-click dismissal and no keyboard focus for
  // Keys.onEscapePressed below.
  grabFocus: true
  // Fixed rather than derived from the content: sizing the window to a column
  // that is itself anchored to the window is circular, and QML resolves that by
  // collapsing it to zero with no binding-loop warning. audio/AudioPanel.qml
  // carries the same note for the same reason.
  implicitWidth: 268
  implicitHeight: 268

  // PanelGroup's contract -- see common/PanelGroup.qml.
  function dismiss() { root.visible = false; }

  // Pure, and exported rather than inlined so dev-calendar-check.qml can reach
  // it. Pins the day to 1 *before* shifting the month: adding a month to the
  // 31st gives 31 February, which JS rolls forward into March, so paging from
  // January would skip February outright.
  function shiftMonth(date, delta) {
    const d = new Date(date);
    d.setDate(1);
    d.setMonth(d.getMonth() + delta);
    return d;
  }

  // The grid's first cell: the Monday on or before the 1st of the month.
  //
  // Monday-first is arithmetic here rather than a locale trick. It used to be
  // Qt.locale("en_GB") handed to MonthGrid, which worked, but made the week
  // start a side effect of picking a country -- and the check could only ever
  // assert that the trick still held, never that the grid was right.
  //
  // getDay() is Sunday-based (Sun 0 .. Sat 6); +6 %7 rotates it to Monday-based
  // (Mon 0 .. Sun 6), which is the number of cells the 1st sits in from the
  // left.
  function firstCellOf(date) {
    const d = new Date(date.getFullYear(), date.getMonth(), 1);
    d.setDate(1 - ((d.getDay() + 6) % 7));
    return d;
  }

  readonly property date firstCell: root.firstCellOf(root.shown)

  function cellDate(i) {
    const d = new Date(root.firstCell);
    d.setDate(d.getDate() + i);
    return d;
  }

  function page(delta) { root.shown = root.shiftMonth(root.shown, delta); }

  function toggle() {
    if (root.visible) { root.visible = false; return; }

    // A click on the pill while the popup is open dismisses the grab first, so
    // `visible` is already false by the time this runs. Without this guard the
    // pill would close and instantly reopen, and could never shut anything.
    // Measured: two clicks on a probe pill both logged `visible now: true`.
    if (Date.now() - root._lastHidden < 250) return;

    // Every open starts at today. Paging to December, closing and reopening
    // still in December is a clock that lies about now.
    //
    // Only when it actually differs, though: assigning `shown` rebinds all 42
    // cells, and doing that on the way to mapping the surface is work the first
    // frame has to wait for. Reopening on the month you are already on -- which
    // is most reopens -- now rebinds nothing.
    const now = new Date();
    if (root.shown.getMonth() !== now.getMonth()
        || root.shown.getFullYear() !== now.getFullYear()) {
      root.shown = now;
    }
    root.visible = true;
  }

  onVisibleChanged: {
    if (root.visible) {
      root._scaled = false;
      awaitScale.restart();
      PanelGroup.claim(root);
    } else {
      awaitScale.stop();
      root._lastHidden = Date.now();
      PanelGroup.release(root);
    }
  }

  // ponytail: a fixed two frames rather than a signal, because nothing emits
  // one -- QWindow has no devicePixelRatio notification to bind to, and the
  // only correct value to poll for is the one being waited on. 32 ms is double
  // the 16 ms measured, so a compositor a frame slower than measured still
  // lands inside it; a much slower one would show a single oversized frame
  // again. Swap this for the signal if Qt ever grows one.
  Timer {
    id: awaitScale
    interval: 32
    onTriggered: root._scaled = true
  }

  onBarVisibleChanged: if (!root.barVisible) root.visible = false;

  Rectangle {
    id: card
    anchors.fill: parent
    radius: 16
    color: root.theme.bgBase
    border.color: root.theme.bgBorder
    border.width: 1
    focus: true

    // Nothing is drawn until the surface knows its scale -- see _scaled. Not
    // `visible: false`, which would stop the card taking focus and lose the
    // escape key for those two frames.
    opacity: root._scaled ? 1 : 0

    // Escape works here, which was the design's one open question. Measured
    // against the live compositor: a PopupWindow with grabFocus takes real
    // keyboard focus, so the bar needs no keyboardFocus change of its own.
    Keys.onEscapePressed: root.dismiss()

    // Wheel pages months -- what the hand reaches for on a dropdown. Down is
    // forward, matching every scrollable list in this config.
    WheelHandler {
      onWheel: event => root.page(event.angleDelta.y < 0 ? 1 : -1)
    }

    Column {
      anchors.centerIn: parent
      width: root.gridW
      spacing: 8

      // Header: ‹ August 2026 ›
      Item {
        width: parent.width
        height: 22

        Text {
          anchors { left: parent.left; verticalCenter: parent.verticalCenter }
          text: "‹"
          color: prevHover.containsMouse ? root.theme.textPrimary : root.theme.textMuted
          font { pixelSize: 16; family: root.font }
          MouseArea {
            id: prevHover
            anchors.fill: parent
            anchors.margins: -6
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.page(-1)
          }
        }

        Text {
          anchors.centerIn: parent
          text: Qt.formatDateTime(root.shown, "MMMM yyyy")
          color: root.theme.textPrimary
          font { pixelSize: 12; bold: true; family: root.font }
        }

        Text {
          anchors { right: parent.right; verticalCenter: parent.verticalCenter }
          text: "›"
          color: nextHover.containsMouse ? root.theme.textPrimary : root.theme.textMuted
          font { pixelSize: 16; family: root.font }
          MouseArea {
            id: nextHover
            anchors.fill: parent
            anchors.margins: -6
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.page(1)
          }
        }
      }

      // Day names taken from the grid's own first row rather than from a locale
      // day-number table: the first row is always Monday..Sunday by
      // construction, so these cannot fall out of step with the cells below
      // them the way an independently-indexed list could.
      Row {
        spacing: root.gap
        Repeater {
          model: 7
          Text {
            required property int index
            width: root.cellW
            horizontalAlignment: Text.AlignHCenter
            text: Qt.formatDate(root.cellDate(index), "ddd")
            color: root.theme.textMuted
            font { pixelSize: 10; family: root.font }
          }
        }
      }

      // Read-only: with no events there is nothing behind a day, so days take
      // no clicks and carry no hover state.
      Grid {
        columns: 7
        spacing: root.gap

        Repeater {
          model: 42

          Rectangle {
            required property int index
            readonly property date cell: root.cellDate(index)
            // Compared against the handed-in stamp rather than against a Date
            // built here, so the popup follows midnight: todayStamp changes
            // once a day and every cell re-evaluates off it.
            readonly property bool isToday:
              Qt.formatDateTime(cell, "yyyy-MM-dd") === root.todayStamp
            readonly property bool isThisMonth: cell.getMonth() === root.shown.getMonth()

            width: root.cellW
            height: root.cellH
            radius: 6
            color: isToday ? root.theme.accentPrimary : "transparent"

            Text {
              anchors.centerIn: parent
              text: parent.cell.getDate()
              // Drawn in the background colour when filled, the way every
              // accent-filled state in the bar is: the fill is the contrast.
              color: parent.isToday ? root.theme.bgBase
                   : parent.isThisMonth ? root.theme.textPrimary
                   : root.theme.textMuted
              font { pixelSize: 11; bold: parent.isToday; family: root.font }
            }
          }
        }
      }
    }
  }
}
