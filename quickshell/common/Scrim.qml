pragma ComponentBehavior: Bound
import Quickshell
import Quickshell.Wayland
import QtQuick

// The dim behind an open panel, on every display instead of just the one the
// panel landed on.
//
// A PanelWindow is a wayland layer surface and a layer surface belongs to a
// single output, so the full-window `Rectangle { color: theme.bgOverlay }` that
// each of the fourteen panels used to carry could only ever darken the screen
// the panel opened on. The other monitor stayed at full brightness, which reads
// as the shell being half-broken rather than as a deliberate focus effect.
//
// Variants over Quickshell.screens is the same shape the bar and the OSD
// already use, and it means hotplug needs no code here at all: plug a monitor
// in while a panel is open and it gets its dim.
Variants {
  id: scrim

  // Bound to the panel window's own `visible` at every call site, so the dim
  // cannot outlive the card or the card the dim.
  property bool active: false
  property color color
  signal clicked()

  // PanelGroup's contract. A Scrim closes its panel by being clicked, so
  // dismissing one is exactly clicking it -- but the calendar popup has no dim
  // to click, which is why the contract is named for the effect and not the
  // gesture.
  function dismiss() { clicked(); }

  // Opening a panel dismisses whichever one was up. See PanelGroup.
  onActiveChanged: active ? PanelGroup.claim(scrim) : PanelGroup.release(scrim)

  // Emptied on close rather than left standing with the windows hidden.
  // Fourteen panels times however many monitors would otherwise be a permanent
  // pile of full-screen layer surfaces for something that is on screen a few
  // seconds at a time; creating two on open is cheap by comparison.
  model: active ? Quickshell.screens : []

  PanelWindow {
    required property var modelData
    screen: modelData

    color: scrim.color

    // Overlay, matching the panels: the dim has to cover the bar, which sits on
    // Top. Within one layer hyprland stacks by surface creation order, and this
    // one is created by the same property change that maps the panel -- so the
    // ordering is not something to reason about, it is something to look at.
    // Measured with `hyprctl layers` on both outputs: quickshell-scrim comes out
    // below the panel's own namespace, and the card renders clean over it.
    WlrLayershell.layer: WlrLayer.Overlay

    // Nothing here ever takes a key. The panel's card holds Exclusive keyboard
    // focus and a second focusable surface would pull it away -- typing in the
    // launcher would stop filtering the list and escape would stop closing.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    focusable: false

    // Explicit, and deliberately not the bare "quickshell" a surface inherits
    // when it names nothing: hyprland's blur-quickshell layer rule matches
    // ^quickshell$, and inheriting it would put a full-screen blur behind every
    // panel on every monitor.
    WlrLayershell.namespace: "quickshell-scrim"

    exclusionMode: ExclusionMode.Ignore

    anchors { top: true; bottom: true; left: true; right: true }

    // Clicking the dim dismisses, on the far monitor as much as on the near one.
    MouseArea {
      anchors.fill: parent
      onClicked: scrim.clicked()
    }
  }
}
