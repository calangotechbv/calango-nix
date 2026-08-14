pragma Singleton

import Quickshell
import Quickshell.Io
import QtQuick
import "../common"

// Which browsers exist, which profiles they have, and where a url is supposed
// to go. Both the picker and its settings panel read this; neither owns it.
//
// The discovery itself is quickshell/browser/discover.py rather than qml. What
// it replaces is chrome's Local State, firefox's profiles.ini and desktop-entry
// exec lines -- file-format archaeology, and python has a json and an ini
// parser where qml has neither. Run it by hand to see exactly what the picker
// will show.
Singleton {
  id: root

  // discover.py's array. Each entry is
  // { id, name, detail, icon, argv, private }.
  property var entries: []

  // browser.json, always with all four keys present so no reader has to guard.
  property var config: ({ fallback: "", rules: [], hidden: [], keys: ({}) })

  // Flips once the config read has completed either way. Saving stays disabled
  // until it does, or a write racing the first read would persist the defaults
  // over a real file.
  property bool loaded: false

  readonly property string configPath:
    Quickshell.env("HOME") + "/.config/quickshell/browser.json"

  function reload() { discoverProc.running = true; }

  Process {
    id: discoverProc
    command: ["python3", Quickshell.env("HOME")
                         + "/.config/quickshell/browser/discover.py"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          const parsed = JSON.parse(text);
          if (Array.isArray(parsed)) root.entries = parsed;
        } catch (e) {
          console.error("BrowserService: discover.py returned no usable json:", e);
        }
      }
    }
  }

  // Read with a Process rather than a FileView for the reason
  // NotificationService gives: a missing file still has to produce a completion
  // signal, or `loaded` never flips and saving stays disabled forever on a
  // fresh install.
  Process {
    id: configLoadProc
    command: ["sh", "-c", "cat \"$1\" 2>/dev/null", "sh", root.configPath]
    running: true
    stdout: StdioCollector {
      onStreamFinished: {
        const raw = text.trim();
        if (raw !== "") {
          try {
            const parsed = JSON.parse(raw);
            root.config = {
              fallback: parsed.fallback || "",
              rules: Array.isArray(parsed.rules) ? parsed.rules : [],
              hidden: Array.isArray(parsed.hidden) ? parsed.hidden : [],
              keys: (parsed.keys && typeof parsed.keys === "object") ? parsed.keys : ({})
            };
          } catch (e) {
            console.error("BrowserService: bad browser.json:", e);
          }
        }
        root.loaded = true;
      }
    }
  }

  Process { id: saveProc; running: false }

  Timer {
    id: saveDebounce
    interval: 200
    onTriggered: {
      if (saveProc.running) { saveDebounce.restart(); return; }
      saveProc.command = ["sh", "-c", 'printf "%s" "$2" > "$1"', "sh",
                          root.configPath,
                          JSON.stringify({ version: 1,
                                           fallback: root.config.fallback,
                                           rules: root.config.rules,
                                           hidden: root.config.hidden,
                                           keys: root.config.keys }, null, 2) + "\n"];
      saveProc.running = true;
    }
  }

  function _save() { if (root.loaded) saveDebounce.restart(); }

  // Reassigned wholesale rather than mutated: a qml property holding a
  // javascript object emits no change signal when a key inside it is written,
  // so the panels would keep rendering the old value.
  function _patch(key, value) {
    const next = {
      fallback: root.config.fallback, rules: root.config.rules,
      hidden: root.config.hidden, keys: root.config.keys
    };
    next[key] = value;
    root.config = next;
    root._save();
  }

  function entryById(id) {
    for (const entry of root.entries) if (entry.id === id) return entry;
    return null;
  }

  function visibleEntries() {
    const hidden = root.config.hidden || [];
    return root.entries.filter(e => hidden.indexOf(e.id) < 0);
  }

  function keyFor(id) {
    const keys = root.config.keys || {};
    for (const letter in keys) if (keys[letter] === id) return letter;
    return "";
  }

  // Glob, as vala's GLib.PatternSpec is: * spans anything, ? is one character,
  // everything else is literal. Escaping the rest is the whole reason this
  // exists -- an unescaped "example.com" is a regexp that also matches
  // "exampleXcom", which is a rule quietly routing more than it says.
  function globToRegExp(pattern) {
    const escaped = pattern.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
                           .replace(/\\\*/g, ".*")
                           .replace(/\\\?/g, ".");
    return new RegExp("^" + escaped + "$", "i");
  }

  // The entry a rule sends this url to, or null for "ask". A rule whose target
  // is hidden or no longer exists falls through rather than being obeyed, so
  // hiding a profile cannot strand the links pointing at it.
  function matchRule(url) {
    for (const rule of (root.config.rules || [])) {
      if (!rule || !rule.pattern) continue;
      if (!root.globToRegExp(rule.pattern).test(url)) continue;
      const target = root.entryById(rule.target);
      if (!target) continue;
      if ((root.config.hidden || []).indexOf(rule.target) >= 0) continue;
      return target;
    }
    return null;
  }

  // Launches by scope when it can, and falls back to a plain detached exec
  // when it can't -- rather than reporting failure and leaving the caller to
  // decide, because both the picker's pick() and its routed-rule open() have
  // nowhere useful to put that decision except "lose the url". AppLaunch.run()
  // fails whenever AppLaunch.canScope is false: true for the first moments of
  // every session (it is resolved by an async Process at startup) and true
  // forever on a machine with no systemd-run, which install.sh still treats as
  // merely `expected`. Quickshell.execDetached() covers both without the
  // per-app systemd scope AppLaunch.run() would have given it -- the same
  // trade AppLauncher.qml already makes when it falls back to
  // entry.execute().
  //
  // Only returns false when there is nothing runnable at all, which the
  // fallback cannot save either; callers must not treat this launch as having
  // happened.
  // What this entry would actually be run as. Split out from launch() because
  // it is the part worth asserting and the only part that can be: launch()
  // itself ends in a process, and AppLaunch.run is a singleton method, so a
  // check cannot stand in front of it.
  //
  // An empty url must produce no argument at all rather than an empty one --
  // chrome treats "" as a page to open and lands on a blank tab instead of the
  // profile's normal startup.
  function launchArgv(entry, url) {
    if (!entry || !entry.argv) return [];
    return url ? entry.argv.concat([url]) : entry.argv.slice();
  }

  function launch(entry, url) {
    if (!entry) return false;
    const argv = root.launchArgv(entry, url);
    if (argv.length === 0) return false;
    if (!AppLaunch.run(argv, entry.id, "")) Quickshell.execDetached(argv);
    return true;
  }

  function setHidden(id, hidden) {
    const next = (root.config.hidden || []).filter(h => h !== id);
    if (hidden) next.push(id);
    root._patch("hidden", next);
  }

  // Keyed letter -> id, so one letter can only ever mean one entry. Assigning a
  // letter that is already taken moves it; assigning "" to an entry clears
  // whatever letter it held.
  function setKey(letter, id) {
    const next = {};
    for (const existing in (root.config.keys || {}))
      if (root.config.keys[existing] !== id) next[existing] = root.config.keys[existing];
    if (letter) next[letter] = id;
    root._patch("keys", next);
  }

  function setRules(rules) { root._patch("rules", rules); }
  function setFallback(id) { root._patch("fallback", id); }
}
