import QtQuick
import QtQuick.Window
import "../quickshell/bar"

// Feeds TitleSlot the geometry measured on the live bar with a bluetooth
// headset connected, and asserts the two properties the defect broke:
//   1. the title's ink never reaches the right section
//   2. a title is on screen wherever there is room for one
//
// Each case is CONSTRUCTED with its geometry rather than assigned it
// afterwards. That is not a style choice: a Text laid out at a sane width and
// then given a negative one keeps contentWidth 0, while one created at the
// negative width paints its full string. Only the second reproduces the bug.
Window {
  visible: true
  width: 1516
  height: 34

  readonly property var cases: [
    // name,                bar,  left, right, expect a title
    { n: "bt connected",    b: 1516, l: 546, r: 742,  s: true  },  // the reported failure
    { n: "bt disconnected", b: 1516, l: 546, r: 590,  s: true  },  // the ordinary day
    { n: "empty bar",       b: 1516, l:  20, r:  20,  s: true  },
    { n: "no room at all",  b: 1516, l: 546, r: 1400, s: false }   // sections overlap
  ]

  Repeater {
    id: rep
    model: cases

    TitleSlot {
      required property var modelData
      width: modelData.b
      height: 34
      leftWidth: modelData.l
      rightWidth: modelData.r
      title: "Prime Video: The Walking Dead: World Beyond - Season 1 - Google Chrome"
      fontSize: 13
    }
  }

  Timer {
    running: true
    interval: 50
    onTriggered: {
      let failures = 0;
      for (let i = 0; i < cases.length; i++) {
        const c = cases[i];
        const s = rep.itemAt(i);
        const gapStart = c.l;
        const gapEnd = c.b - c.r;
        console.log(c.n,
                    "| slot", Math.round(s.slotLeft), "..", Math.round(s.slotRight),
                    "| gap", gapStart, "..", gapEnd,
                    "| ink ends", Math.round(s.paintedRight),
                    "| showing", s.showing,
                    "| elided", s.elided,
                    "| centred", s.barCentred);
        if (s.showing) {
          if (s.paintedRight > gapEnd) {
            console.log("  FAIL: ink ends at", Math.round(s.paintedRight),
                        "-- the right section starts at", gapEnd);
            failures++;
          }
          if (s.slotLeft < gapStart) {
            console.log("  FAIL: slot starts at", Math.round(s.slotLeft),
                        "-- inside the left section, which ends at", gapStart);
            failures++;
          }
        }
        if (c.s !== s.showing) {
          console.log("  FAIL: expected a title:", c.s, "-- got", s.showing);
          failures++;
        }
      }
      console.log(failures === 0 ? "PASS" : "FAILURES " + failures);
      Qt.exit(failures === 0 ? 0 : 1);
    }
  }
}
