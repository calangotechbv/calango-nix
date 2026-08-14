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
}
