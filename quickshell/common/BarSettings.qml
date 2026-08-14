pragma Singleton

import Quickshell
import Quickshell.Io
import QtQuick

// How the bar looks, kept outside Bar.qml so the settings panel can drive it
// without reaching across the shell for the Bar instance.
//
// All of it lands in one `bar.conf` of `key=value` lines rather than a file per
// setting: hyprland.lua reads the blur line out of the same file at startup,
// and three one-value files to keep in step across two ignore lists is worse
// than one parser of three keys.
Singleton {
  id: root

  // Alpha of the strip behind the pills, 0..1. At 0 the bar is only its pills,
  // floating over the wallpaper.
  property real barOpacity: 0.5

  // Alpha of the pills themselves -- their background, not their contents, so
  // the icons and readouts stay at full strength however low this goes.
  property real pillOpacity: 1.0

  // Whether hyprland blurs what shows through. This is not a shell setting at
  // all: the compositor owns it, the shell only asks. Kept here because it is
  // the same knob to the person using it, and useless without the two above.
  //
  // One flag covers the strip and the pills together, and cannot be split:
  // blur applies to a whole wayland surface, and the bar is one surface with
  // the pills drawn onto it. What it does do is skip fully transparent pixels
  // (`ignore_alpha` below), so a 0% strip with translucent pills gets blur
  // behind the pills alone.
  property bool blur: true

  // Deliberately not persisted, unlike everything above. This is the same flag
  // `qs ipc call bar toggle` flips, and it is usually off for a reason that
  // lasts minutes -- a screenshot, a full-screen video. Saving it would let a
  // restart come back with no bar and nothing on screen to say why.
  property bool barVisible: true

  function setBarOpacity(value)  { root.barOpacity  = root._clamp(value); saveDebounce.restart(); }
  function setPillOpacity(value) { root.pillOpacity = root._clamp(value); saveDebounce.restart(); }

  function setBlur(on) {
    root.blur = !!on;
    // Live, then saved: hyprland.lua reads the file back at startup, so the
    // eval is what makes the change visible now and the file is what makes it
    // survive. Re-declaring the rule under the same name replaces it.
    if (!blurProc.running) {
      blurProc.command = ["hyprctl", "eval", root._blurRule];
      blurProc.running = true;
    }
    saveDebounce.restart();
  }

  function _clamp(value) { return Math.max(0, Math.min(1, value)); }

  readonly property string _blurRule:
    'hl.layer_rule({ name = "blur-quickshell", match = { namespace = "^quickshell$" }, blur = '
    + (root.blur ? "true" : "false") + ', ignore_alpha = 0.05 })'

  Process { id: blurProc; running: false }

  // Debounced and coalesced the same way BrightnessService writes: a second
  // click while the first write is still in flight would otherwise reassign a
  // running Process.
  Timer {
    id: saveDebounce
    interval: 50
    onTriggered: {
      if (saveProc.running) { saveDebounce.restart(); return; }
      saveProc.command = ["sh", "-c",
                          'printf "%s" "$1" > "$HOME/.config/quickshell/bar.conf"',
                          "sh",
                          "opacity=" + root.barOpacity
                          + "\npill-opacity=" + root.pillOpacity
                          + "\nblur=" + (root.blur ? 1 : 0) + "\n"];
      saveProc.running = true;
    }
  }

  Process { id: saveProc; running: false }

  // Read once at startup, same shape as Screens.qml's. Anything unparseable or
  // out of range leaves the default for that key -- a bar at alpha "abc" would
  // be invisible and look like the shell had crashed.
  //
  // No blur eval from here: hyprland.lua has already read this same file by the
  // time the shell starts, and applying it again would only be a chance to
  // apply the default before the file is parsed.
  FileView {
    id: pref
    path: Quickshell.env("HOME") + "/.config/quickshell/bar.conf"
    printErrors: false
    onTextChanged: {
      for (const line of pref.text().split("\n")) {
        const kv = line.match(/^([a-z-]+)=(.+)$/);
        if (!kv) continue;
        const value = parseFloat(kv[2]);
        if (isNaN(value)) continue;
        if      (kv[1] === "opacity"      && value >= 0 && value <= 1) root.barOpacity  = value;
        else if (kv[1] === "pill-opacity" && value >= 0 && value <= 1) root.pillOpacity = value;
        else if (kv[1] === "blur")                                     root.blur        = value !== 0;
      }
    }
  }
}
