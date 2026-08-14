pragma Singleton
import QtQuick
import Quickshell

Singleton {
  // State: written at runtime, so it must live outside the read-only store.
  readonly property string stateDir:
    (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state"))
    + "/quickshell"

  // Source: ships in the tree, so it must resolve into the store.
  // shellDir is the directory of the running shell.qml.
  readonly property string sourceDir: Quickshell.shellDir

  // hypr's state, not quickshell's. Four files live here and hyprland.lua
  // reads three of them; the two must agree or the compositor silently
  // loads nothing.
  //
  // Deliberately does NOT honour XDG_STATE_HOME, unlike stateDir and
  // sourceDir above. home/hyprland.nix's hyprState is baked into
  // hyprland.lua at build time as ${homeDirectory}/.local/state/hypr, with
  // no way to read an environment variable at that point, so this has to
  // name the same fixed path rather than a possibly-different one -- if
  // XDG_STATE_HOME were ever set, honouring it here would make quickshell
  // write where the compositor never reads.
  readonly property string hyprStateDir:
    Quickshell.env("HOME") + "/.local/state/hypr"
}
