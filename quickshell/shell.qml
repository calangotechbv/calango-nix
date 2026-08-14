//@ pragma UseQApplication
//@ pragma Env QT_QPA_PLATFORMTHEME=gtk3
//@ pragma Env QS_NO_RELOAD_POPUP=1
//@ pragma Env QSG_RENDER_LOOP=threaded
//@ pragma Env QT_QUICK_FLICKABLE_WHEEL_DECELERATION=10000

import Quickshell
import QtQuick
import "bar"
import "app-launcher"
import "notifications"
import "theme-switcher"
import "wallpaper"
import "osd"
import "settings"
import "network"
import "audio"
import "bluetooth"
import "idle"
import "window-switcher"
import "session"
import "clipboard"
import "browser"
import "layout-switcher"
import "icon-gallery"

Scope {
  // Named so the queue below can be reached as root.browserReopenQueue from the
  // handlers inside BrowserPicker/BrowserSettings, which are nested scopes: an
  // unqualified name there resolves by walking out through them, which is what
  // qmllint's `unqualified` warns about and what breaks silently the day one of
  // those children gains a property of the same name.
  id: root

  ThemeSwitcher { id: ts }
  NetworkPanel { id: netPanel; theme: ts.theme }
  AudioPanel { id: audioPanel; theme: ts.theme }
  BluetoothPanel { id: btPanel; theme: ts.theme }
  IdlePicker { theme: ts.theme }
  NotificationCenter { id: notifCenter; theme: ts.theme }
  SystemPanel { id: sysPanel; theme: ts.theme }
  Bar {
    theme: ts.theme
    onNetworkClicked: netPanel.toggle()
    onBluetoothClicked: btPanel.toggle()
    onAudioClicked: audioPanel.toggle()
    onNotificationsClicked: notifCenter.toggle()
    onSystemClicked: sysPanel.toggle()
  }
  AppLauncher { theme: ts.theme }
  WindowSwitcher { theme: ts.theme }
  SessionMenu { theme: ts.theme }
  ClipboardPicker { theme: ts.theme }
  // Pending browser urls, stashed across a trip through the settings panel.
  // ctrl+, on the picker (or `qs ipc call browser settings`) opens
  // BrowserSettings so a rule can be added for the very link that is up --
  // but opening it claims PanelGroup, which dismisses the picker, and
  // BrowserPicker.dismiss() abandons its whole queue. That is exactly the
  // loss the queue exists to prevent, so the queue is saved here before
  // settings claims the panel and handed back once settings closes, however
  // it closes.
  property var browserReopenQueue: []

  BrowserPicker {
    id: browserPicker
    theme: ts.theme
    // Toggles, so `qs ipc call browser settings` can put the panel away again.
    // It has no close of its own over ipc, and closing it by opening some other
    // panel on top of it is not a way to close a panel.
    onSettingsRequested: {
      if (browserSettings.isOpen) { browserSettings.close(); return; }
      root.browserReopenQueue = browserPicker.queue;
      browserSettings.open();
    }
  }
  BrowserSettings {
    id: browserSettings
    theme: ts.theme
    onClosed: {
      if (root.browserReopenQueue.length === 0) return;
      // Prepend rather than overwrite: a url that arrived by ipc while
      // settings was open would already be sitting in the picker's queue.
      browserPicker.queue = root.browserReopenQueue.concat(browserPicker.queue);
      root.browserReopenQueue = [];
      browserPicker.panelVisible = true;
    }
  }
  LayoutSwitcher { theme: ts.theme }
  NotificationPopup { theme: ts.theme }
  WallpaperManager { theme: ts.theme }
  OSD { theme: ts.theme }
  SettingsPanel { theme: ts.theme }
  // `qs ipc call icons toggle` -- review surface for the SVG icon swap.
  IconGallery { theme: ts.theme }
}
