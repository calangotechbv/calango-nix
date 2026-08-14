pragma Singleton

import QtQuick

// One panel on screen at a time.
//
// Every panel dims behind itself with a Scrim, and every Scrim already routes
// clicked() to its own close path -- so opening one panel while another is up
// is just "click the old panel's dim for it". That is why the exclusion lives
// here instead of in fifteen open() functions: it covers the bar buttons, the
// IPC handlers and the hyprland keybinds without any of them knowing the
// others exist.
QtObject {
  // The Scrim or popup of the panel currently on screen, or null.
  property var current: null

  function claim(panel) {
    const prev = current;
    current = panel;
    if (prev && prev !== panel) prev.dismiss();
  }

  function release(panel) {
    // Guarded: the panel we just displaced closes *after* the new one claimed,
    // and an unguarded release would clear the newcomer's own registration.
    if (current === panel) current = null;
  }
}
