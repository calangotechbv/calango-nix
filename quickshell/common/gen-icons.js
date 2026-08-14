// Generates quickshell/common/Icons.qml from @mdi/svg.
// Rerun after editing WANT: node gen-icons.js > .../common/Icons.qml
const fs = require("fs");

// Every icon the shell draws, by MDI name. Grouped the way the interface uses
// them so a missing state is visible here rather than at render time.
const WANT = {
  "volume": ["volume-off", "volume-low", "volume-medium", "volume-high", "volume-mute"],
  "microphone": ["microphone", "microphone-off"],
  "notifications": ["bell", "bell-outline", "bell-off"],
  "battery": ["battery", "battery-90", "battery-80", "battery-70", "battery-60",
              "battery-50", "battery-40", "battery-30", "battery-20", "battery-10",
              "battery-outline", "battery-charging"],
  "network": ["ethernet", "wifi-off", "wifi-strength-1", "wifi-strength-2",
              "wifi-strength-3", "wifi-strength-4"],
  "bluetooth": ["bluetooth", "bluetooth-off", "bluetooth-connect"],
  "devices": ["headset", "headphones", "speaker", "mouse", "keyboard",
              "gamepad-variant", "tablet", "cellphone", "laptop", "printer",
              "camera", "television"],
  "power-profile": ["leaf", "speedometer", "gauge"],
  "media": ["play", "pause", "music"],
  "system": ["cpu-64-bit", "memory", "thermometer", "brightness-7"],
  "idle": ["coffee", "coffee-off"],
  "night-light": ["weather-night", "theme-light-dark", "white-balance-sunny"],
  // monitor and monitor-multiple are in "panels" already, and the map is flat
  // by name, so listing them twice would emit duplicate keys.
  "screencast": ["record", "application-outline"],
  "actions": ["delete", "close", "refresh", "check",
              "checkbox-blank-circle-outline", "power", "cog", "stop"],
  "panels": ["monitor", "monitor-multiple", "format-paint", "rotate-left",
             "rotate-right", "screen-rotation", "image", "clipboard-text",
             "wallpaper", "auto-fix"],
  "session": ["lock", "sleep", "logout", "restart"],
  "apps": ["firefox", "google-chrome", "spotify", "console", "alert"],
  "hints": ["keyboard-return", "arrow-up", "arrow-down", "arrow-left",
            "arrow-right", "arrow-left-right", "menu-up", "menu-down", "infinity"],
};

const dir = "./package/svg";
const out = [];
const groups = [];

for (const [group, names] of Object.entries(WANT)) {
  groups.push(`    "${group}": [${names.map(n => `"${n}"`).join(", ")}]`);
  for (const name of names) {
    const svg = fs.readFileSync(`${dir}/${name}.svg`, "utf8");
    const paths = [...svg.matchAll(/\sd="([^"]+)"/g)].map(m => m[1]);
    if (paths.length !== 1) throw new Error(`${name}: expected 1 path, got ${paths.length}`);
    out.push(`    "${name}": "${paths[0]}"`);
  }
}

process.stdout.write(`pragma Singleton

import QtQuick

// Material Design Icons as SVG path data, drawn by Icon.qml.
//
// The bar used Nerd Font glyphs, which are these same icons -- but a font
// glyph carries its own advance width, so swapping bell for bell-off or
// volume-high for volume-off moved everything to its right. These render into
// a fixed box instead, so a state change never reflows the bar.
//
// Generated, do not hand-edit: see gen-icons.js in the commit that added this.
// Source: @mdi/svg 7.4.47, Apache-2.0. All paths are in a 24x24 viewBox.
QtObject {
  // name -> SVG path data
  readonly property var paths: ({
${out.join(",\n")}
  })

  // Grouping for the gallery, in the order the interface uses them.
  readonly property var groups: ({
${groups.join(",\n")}
  })

  // Unknown names draw nothing rather than throwing, so a typo in a state
  // expression degrades to a blank box instead of tearing down the panel.
  function path(name) {
    return paths[name] !== undefined ? paths[name] : "";
  }

  function has(name) {
    return paths[name] !== undefined;
  }
}
`);
