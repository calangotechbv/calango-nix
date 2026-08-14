pragma ComponentBehavior: Bound
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Layouts
import "../common"

// Which browser, and which profile, opens this url.
//
// Reached from xdg-open by way of ~/.local/bin/calango-open, which hands the
// url over with `qs ipc call browser open URL` and falls back to launching a
// browser itself when this shell is not running.
//
// The list carries no search box, unlike the launcher and the clipboard picker.
// Speed keys bind bare letters to entries, and a focused TextInput eats every
// one of them -- so a filter would cost the speed keys a modifier, which is the
// whole of what they are for. Six entries do not need a filter.
Scope {
  id: root
  property var theme: DefaultTheme {}
  property string font: "AdwaitaMono Nerd Font"

  signal settingsRequested()

  // Pending urls, head first. A second link clicked while the panel is up
  // appends rather than replacing: replacing would silently drop a url that was
  // already asked for, which is the one failure here that loses something the
  // user cannot get back.
  property var queue: []

  readonly property string currentUrl: root.queue.length > 0 ? root.queue[0] : ""

  // Whether the card should be on screen. Held here rather than read off the
  // window so dev-browser-check.qml can drive open() and advance() -- the two
  // things worth checking -- without a layer surface ever being mapped over
  // whatever the user is looking at. See `headless`.
  property bool panelVisible: false

  // Set only by the check. A PanelWindow maps as soon as it is visible, and a
  // check that flashes a panel on screen is one you stop running.
  property bool headless: false

  property int selectedIndex: 0

  readonly property var shown: BrowserService.visibleEntries()

  IpcHandler {
    target: "browser"
    function open(url: string): void { root.open(url); }
    function toggle(): void          { root.toggle(); }
    function close(): void           { root.dismiss(); }
    function settings(): void        { root.settingsRequested(); }
  }

  // The picker with nothing to open: pick a browser and it starts with no url.
  //
  // This is the one thing the app launcher cannot do. It launches Google Chrome;
  // it has no idea Chrome has three profiles, because a profile is not a desktop
  // entry. Everything needed to offer them is already here.
  function toggle() {
    if (root.panelVisible) { root.dismiss(); return; }
    root.selectedIndex = 0;
    BrowserService.reload();
    root.panelVisible = true;
  }

  function open(url) {
    if (!url) return;

    // Rules first, so a routed url never draws a panel at all -- unless the
    // launch itself fails, in which case falling through to the panel beats
    // dropping the url on the floor.
    const routed = BrowserService.matchRule(url);
    if (routed && BrowserService.launch(routed, url)) return;

    root.queue = root.queue.concat([url]);
    root.selectedIndex = 0;
    // Re-run discovery on open rather than trusting a list read at startup: a
    // profile added in chrome an hour ago should be in this list.
    BrowserService.reload();
    root.panelVisible = true;
  }

  // Drop the head and show the next, or close when there is none.
  function advance() {
    root.queue = root.queue.slice(1);
    root.selectedIndex = 0;
    if (root.queue.length === 0) root.panelVisible = false;
  }

  function pick(entry) {
    if (!entry) return;

    // Nothing queued means the panel was opened by the keybind rather than by a
    // link, so the browser starts with no url and there is no queue to advance.
    if (root.queue.length === 0) {
      if (BrowserService.launch(entry, "")) root.panelVisible = false;
      return;
    }

    // A launch that did not happen must not advance: the url stays at the
    // head of the queue and the panel stays up, same as if nothing had been
    // clicked, rather than closing on a browser that never opened.
    if (!BrowserService.launch(entry, root.queue[0])) return;
    root.advance();
  }

  // Escape abandons every pending url, not just the one on screen: they arrived
  // together and dismissing them one at a time is not what the key means.
  function dismiss() {
    root.queue = [];
    root.panelVisible = false;
  }

  Scrim { active: pickerPanel.visible; color: root.theme.bgOverlay; onClicked: root.dismiss() }

  PanelWindow {
    id: pickerPanel
    visible: root.panelVisible && !root.headless
    focusable: true
    color: "transparent"

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    WlrLayershell.namespace: "quickshell-browser"

    exclusionMode: ExclusionMode.Ignore

    anchors { top: true; bottom: true; left: true; right: true }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    Rectangle {
      anchors.centerIn: parent
      // Fixed, as ClipboardPicker and AppLauncher both are: a height derived
      // from list.contentHeight is 0 when discovery finds nothing, and the
      // "no browser is registered" empty state would render in a sliver.
      width: 560
      height: 480
      radius: 16
      color: root.theme.bgBase
      border.color: root.theme.bgBorder
      border.width: 1

      MouseArea {
        anchors.fill: parent
        onClicked: event => event.accepted = true
      }

      // The card holds the keys rather than any child of it: with no text input
      // there is nothing else that wants them, and one handler is easier to
      // reason about than focus moving around a list.
      focus: true
      Keys.onEscapePressed: root.dismiss()
      Keys.onPressed: event => {
        const last = root.shown.length - 1;
        if (event.key === Qt.Key_Down || event.key === Qt.Key_Tab) {
          event.accepted = true;
          root.selectedIndex = root.selectedIndex >= last ? 0 : root.selectedIndex + 1;
        } else if (event.key === Qt.Key_Up || event.key === Qt.Key_Backtab) {
          event.accepted = true;
          root.selectedIndex = root.selectedIndex <= 0 ? last : root.selectedIndex - 1;
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          event.accepted = true;
          root.pick(root.shown[root.selectedIndex]);
        } else if (event.key === Qt.Key_Comma && (event.modifiers & Qt.ControlModifier)) {
          event.accepted = true;
          root.settingsRequested();
        } else if (event.text.length === 1 && !(event.modifiers & ~Qt.ShiftModifier)) {
          // A bare letter opens whatever it is bound to. Nothing else on this
          // surface wants single characters, which is why there is no filter.
          const id = (BrowserService.config.keys || {})[event.text.toLowerCase()];
          const entry = id ? BrowserService.entryById(id) : null;
          if (entry && root.shown.indexOf(entry) >= 0) {
            event.accepted = true;
            root.pick(entry);
          }
        }
      }

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 12

        ColumnLayout {
          id: header
          Layout.fillWidth: true
          spacing: 2

          RowLayout {
            Layout.fillWidth: true
            Text {
              // Opened by the keybind rather than by a link, so there is no url
              // to show and the title is the whole of the question.
              text: root.currentUrl === "" ? "  Open browser" : "  Open link"
              color: root.theme.accentPrimary
              font { pixelSize: 14; bold: true; family: root.font }
            }
            Item { Layout.fillWidth: true }
            Text {
              visible: root.queue.length > 1
              text: "+" + (root.queue.length - 1) + " waiting"
              color: root.theme.textMuted
              font { pixelSize: 11; family: root.font }
            }
          }

          Text {
            Layout.fillWidth: true
            visible: root.currentUrl !== ""
            text: root.currentUrl
            color: root.theme.textSecondary
            font { pixelSize: 12; family: root.font }
            elide: Text.ElideMiddle
            maximumLineCount: 1
          }
        }

        ListView {
          id: list
          Layout.fillWidth: true
          Layout.fillHeight: true
          model: root.shown
          clip: true
          spacing: 2
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          delegate: Rectangle {
            id: browserRow
            required property var modelData
            required property int index

            readonly property bool isSelected: root.selectedIndex === index
            readonly property string speedKey: BrowserService.keyFor(browserRow.modelData.id)

            width: list.width
            height: 48
            radius: 8
            color: isSelected ? root.theme.bgSelected : "transparent"

            Behavior on color { ColorAnimation { duration: 100 } }

            Accessible.role: Accessible.Button
            Accessible.name: browserRow.modelData.name
                             + (browserRow.modelData.detail
                                ? ", " + browserRow.modelData.detail : "")

            Rectangle {
              visible: browserRow.isSelected
              width: 3; height: 24; radius: 2
              color: root.theme.accentPrimary
              anchors.left: parent.left
              anchors.leftMargin: 2
              anchors.verticalCenter: parent.verticalCenter
            }

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: 14
              anchors.rightMargin: 12
              spacing: 12

              // discover.py hands back either an absolute path -- a chrome
              // profile picture -- or an icon-theme name from the desktop file,
              // so the source has to answer both.
              Image {
                source: browserRow.modelData.icon.startsWith("/")
                        ? "file://" + browserRow.modelData.icon
                        : Quickshell.iconPath(browserRow.modelData.icon, true)
                sourceSize { width: 28; height: 28 }
                Layout.preferredWidth: 28
                Layout.preferredHeight: 28
                Layout.alignment: Qt.AlignVCenter
                opacity: browserRow.modelData.private ? 0.75 : 1.0
              }

              ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                Text {
                  Layout.fillWidth: true
                  text: browserRow.modelData.name
                  color: browserRow.isSelected ? root.theme.textPrimary
                                               : root.theme.textSecondary
                  font { pixelSize: 13; family: root.font }
                  elide: Text.ElideRight
                }

                Text {
                  Layout.fillWidth: true
                  visible: browserRow.modelData.detail !== ""
                  text: browserRow.modelData.detail
                  color: root.theme.textMuted
                  font {
                    pixelSize: 11
                    family: root.font
                    italic: browserRow.modelData.private
                  }
                  elide: Text.ElideRight
                }
              }

              Rectangle {
                visible: browserRow.speedKey !== ""
                Layout.preferredWidth: 18; Layout.preferredHeight: 18; radius: 4
                color: root.theme.bgSurface
                Layout.alignment: Qt.AlignVCenter
                Text {
                  anchors.centerIn: parent
                  text: browserRow.speedKey
                  color: root.theme.textMuted
                  font { pixelSize: 10; family: root.font }
                }
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              z: -1
              onClicked: root.pick(browserRow.modelData)
              onPositionChanged: root.selectedIndex = browserRow.index
            }
          }

          Text {
            anchors.centerIn: parent
            text: "  No browser is registered for https"
            color: root.theme.textMuted
            font { pixelSize: 13; family: root.font }
            visible: list.count === 0
          }
        }

        RowLayout {
          id: hints
          Layout.fillWidth: true
          spacing: 16

          Row {
            spacing: 4
            Rectangle {
              width: hintEnter.width + 8; height: 18; radius: 4; color: root.theme.bgSurface
              Text { id: hintEnter; anchors.centerIn: parent; text: "⏎"; color: root.theme.textMuted; font.pixelSize: 10; font.family: root.font }
            }
            Text { text: "open"; color: root.theme.textMuted; font.pixelSize: 10; font.family: root.font; anchors.verticalCenter: parent.verticalCenter }
          }

          Row {
            spacing: 4
            Rectangle {
              width: hintCtrl.width + 8; height: 18; radius: 4; color: root.theme.bgSurface
              Text { id: hintCtrl; anchors.centerIn: parent; text: "ctrl+,"; color: root.theme.textMuted; font.pixelSize: 10; font.family: root.font }
            }
            Text { text: "rules"; color: root.theme.textMuted; font.pixelSize: 10; font.family: root.font; anchors.verticalCenter: parent.verticalCenter }
          }

          Row {
            spacing: 4
            Rectangle {
              width: hintEsc.width + 8; height: 18; radius: 4; color: root.theme.bgSurface
              Text { id: hintEsc; anchors.centerIn: parent; text: "esc"; color: root.theme.textMuted; font.pixelSize: 10; font.family: root.font }
            }
            Text { text: "cancel"; color: root.theme.textMuted; font.pixelSize: 10; font.family: root.font; anchors.verticalCenter: parent.verticalCenter }
          }

          Item { Layout.fillWidth: true }
        }
      }
    }
  }
}
