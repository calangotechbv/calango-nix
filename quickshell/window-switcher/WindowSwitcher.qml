pragma ComponentBehavior: Bound
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import Quickshell.Widgets
import QtQuick
import QtQuick.Layouts
import "../common"

// Replaces `rofi -show window`. Same shape as the app launcher, over open
// windows instead of desktop entries.
Scope {
  id: root
  property var theme: DefaultTheme {}
  property string font: "AdwaitaMono Nerd Font"

  property int selectedIndex: 0

  // The window list as it looked when the switcher opened. Everything below
  // reads this rather than Hyprland.toplevels directly, so the rows cannot
  // reshuffle while you are looking at them -- focusing, closing or opening a
  // window elsewhere would otherwise reorder the list under your fingers and
  // move whatever you were about to press Enter on.
  property var snapshot: []

  // Focus order, most recent first, as a list of window addresses. Maintained
  // live from Hyprland's focus events rather than queried when the switcher
  // opens, because the query is asynchronous: refreshToplevels() took a measured
  // ~34ms to land, and the rows it reorders are the top few -- exactly the ones
  // resetSelection() lands on. Ordering off an event stream that is already
  // up to date means the first painted frame is the final one.
  property var mru: []

  Connections {
    target: Hyprland
    function onActiveToplevelChanged() {
      const t = Hyprland.activeToplevel;
      if (!t || !t.address) return;
      root.mru = [t.address, ...root.mru.filter(a => a !== t.address)];
    }
  }

  // Where a window sits in the focus order. Anything focused since quickshell
  // started ranks by the live list; anything else -- windows last touched before
  // the shell came up -- falls in behind it, keeping Hyprland's own ordering
  // among themselves. That fallback is what carries a fresh shell until the
  // first focus change fills the live list in.
  function mruRank(t) {
    const i = t.address ? root.mru.indexOf(t.address) : -1;
    return i >= 0 ? i : 1000 + root.historyId(t);
  }

  // Scene position the pointer was last seen at, and whether it has moved since
  // the switcher opened. Both exist to keep a resting cursor from taking the
  // selection -- see the delegate's onPositionChanged.
  property point lastHoverPoint: Qt.point(-1, -1)
  property bool hoverArmed: false

  function takeSnapshot() {
    root.snapshot = [...Hyprland.toplevels.values]
      .filter(t => t && t.title !== null)
      .sort((a, b) => root.mruRank(a) - root.mruRank(b));
  }

  function open() {
    // One snapshot, and no settle timer behind it. The order comes from
    // root.mru, which is already current when this runs, so the first painted
    // frame is the final one. refreshToplevels() stays for the other fields:
    // the snapshot holds the toplevel objects themselves, so titles and
    // workspaces keep updating through their bindings while the frozen array
    // holds the order still.
    Hyprland.refreshToplevels();
    root.takeSnapshot();
    searchInput.text = "";
    root.hoverArmed = false;
    switcherPanel.visible = true;
    root.resetSelection();
    searchInput.forceActiveFocus();
  }

  function close() { switcherPanel.visible = false; }
  function toggle() { switcherPanel.visible ? root.close() : root.open(); }

  // Land on the previously focused window, not the current one, so open-then-
  // Enter is an alt-tab. Typing a filter moves it back to the top hit, where
  // the whole list has been reordered by relevance anyway.
  function resetSelection() {
    root.selectedIndex = (searchInput.text === "" && root.snapshot.length > 1) ? 1 : 0;
  }

  IpcHandler {
    target: "switcher"
    function toggle(): void { root.toggle(); }
    function open(): void   { root.open(); }
    function close(): void  { root.close(); }
  }

  // Hyprland reports the focus stack as focusHistoryID: 0 is the focused
  // window, 1 the one before it, and so on. Sorting on it gives most-recently-
  // used order for free, which is the only ordering a window switcher should
  // have -- alphabetical would put the window you just left in an arbitrary
  // place.
  function historyId(t) {
    const o = t.lastIpcObject;
    return (o && typeof o.focusHistoryID === "number") ? o.focusHistoryID : 9999;
  }

  function windowClass(t) {
    const o = t.lastIpcObject;
    return (o && o.class) ? o.class : "";
  }

  ScriptModel {
    id: windows
    objectProp: "address"
    // Reads root.snapshot, deliberately not Hyprland.toplevels: binding to the
    // live list is what would let it reorder mid-use.
    values: {
      const q = searchInput.text.trim().toLowerCase();
      if (q === "") return root.snapshot;

      // Already in recency order from the snapshot, so filtering preserves it
      // and only the class-match promotion needs a sort.
      return root.snapshot.filter(t => {
        const title = (t.title || "").toLowerCase();
        const cls   = root.windowClass(t).toLowerCase();
        return title.includes(q) || cls.includes(q);
      }).sort((a, b) => {
        // A class match is a deliberate "show me my terminals"; a title match is
        // often incidental, since titles carry file names and page titles. Rank
        // the class hits first, then fall back to recency within each group.
        const ac = root.windowClass(a).toLowerCase().startsWith(q);
        const bc = root.windowClass(b).toLowerCase().startsWith(q);
        if (ac !== bc) return ac ? -1 : 1;
        return root.mruRank(a) - root.mruRank(b);
      });
    }
  }

  function focusWindow(t) {
    if (!t) return;
    root.close();
    // Goes through the wayland handle rather than a focuswindow dispatch: the
    // foreign-toplevel activate request is what Hyprland already honours for
    // taskbars, and it pulls the workspace across with it.
    if (t.wayland) t.wayland.activate();
  }

  // Window classes are not icon names, but they are close enough often enough
  // that the heuristic lookup resolves most of them. Falls through to an icon
  // when it does not.
  function iconFor(t) {
    const cls = root.windowClass(t);
    if (cls === "") return "";
    try {
      const entry = DesktopEntries.heuristicLookup(cls);
      if (entry && entry.icon) return Quickshell.iconPath(entry.icon, true);
    } catch (e) {}
    return Quickshell.iconPath(cls, true);
  }

  Scrim { active: switcherPanel.visible; color: root.theme.bgOverlay; onClicked: root.close() }

  PanelWindow {
    id: switcherPanel
    visible: false
    focusable: true
    color: "transparent"

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    WlrLayershell.namespace: "quickshell-switcher"

    exclusionMode: ExclusionMode.Ignore

    anchors { top: true; bottom: true; left: true; right: true }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    Rectangle {
      id: switcherBox
      anchors.centerIn: parent
      width: 620
      height: 480
      radius: 16
      color: root.theme.bgBase
      border.color: root.theme.bgBorder
      border.width: 1

      MouseArea {
        anchors.fill: parent
        onClicked: event => event.accepted = true
      }

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 12

        Text {
          text: "  Windows"
          color: root.theme.accentPrimary
          font { pixelSize: 14; bold: true; family: root.font }
        }

        // Search bar
        Rectangle {
          Layout.fillWidth: true
          Layout.preferredHeight: 44
          radius: 10
          color: root.theme.bgSurface
          border.color: searchInput.activeFocus ? root.theme.accentPrimary : root.theme.bgBorder
          border.width: 1

          Behavior on border.color { ColorAnimation { duration: 150 } }

          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 14
            anchors.rightMargin: 14
            spacing: 10

            Text {
              text: ""
              color: root.theme.textMuted
              font { pixelSize: 16; family: root.font }
              Layout.alignment: Qt.AlignVCenter
            }

            TextInput {
              id: searchInput
              Layout.fillWidth: true
              Layout.alignment: Qt.AlignVCenter
              color: root.theme.textPrimary
              font { pixelSize: 15; family: root.font }
              clip: true
              focus: true
              Accessible.role: Accessible.EditableText
              Accessible.name: "Search open windows"

              Text {
                anchors.fill: parent
                text: "Filter by title or app..."
                color: root.theme.textMuted
                font: parent.font
                visible: !parent.text && !parent.activeFocus
                verticalAlignment: Text.AlignVCenter
              }

              onTextChanged: root.resetSelection()

              Keys.onEscapePressed: root.close()

              Keys.onPressed: event => {
                const last = resultsList.count - 1;
                if (event.key === Qt.Key_Down || (event.key === Qt.Key_Tab && !(event.modifiers & Qt.ShiftModifier))) {
                  event.accepted = true;
                  // Wraps, unlike the app launcher. With a handful of windows and
                  // Tab held down, stopping dead at the end is just a dead key.
                  root.selectedIndex = root.selectedIndex >= last ? 0 : root.selectedIndex + 1;
                  resultsList.positionViewAtIndex(root.selectedIndex, ListView.Contain);
                } else if (event.key === Qt.Key_Up || (event.key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier))) {
                  event.accepted = true;
                  root.selectedIndex = root.selectedIndex <= 0 ? last : root.selectedIndex - 1;
                  resultsList.positionViewAtIndex(root.selectedIndex, ListView.Contain);
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  event.accepted = true;
                  if (root.selectedIndex >= 0) root.focusWindow(windows.values[root.selectedIndex]);
                }
              }
            }
          }
        }

        Text {
          text: resultsList.count + " window" + (resultsList.count !== 1 ? "s" : "")
          color: root.theme.textMuted
          font { pixelSize: 11; family: root.font }
        }

        ListView {
          id: resultsList
          Layout.fillWidth: true
          Layout.fillHeight: true
          model: windows
          clip: true
          spacing: 2
          boundsBehavior: Flickable.StopAtBounds

          // No currentIndex/highlight pair here, unlike the app launcher. A
          // ListView writes currentIndex itself to keep it pointing at the same
          // item when rows move, which fights a `currentIndex: selectedIndex`
          // binding and silently breaks it -- the highlight ends up on a row
          // nobody selected. Colouring the delegate keeps selection in exactly
          // one place.
          delegate: Rectangle {
            id: winRow
            required property var modelData
            required property int index

            readonly property bool isSelected: root.selectedIndex === index
            readonly property bool isActive: modelData.activated
            readonly property string cls: root.windowClass(modelData)

            Accessible.role: Accessible.Button
            Accessible.name: (winRow.cls || "Window") + ": " + (winRow.modelData.title || "")
                             + (winRow.modelData.workspace ? ", workspace " + winRow.modelData.workspace.name : "")

            width: resultsList.width
            height: 48
            radius: 8
            color: winRow.isSelected ? root.theme.bgSelected : "transparent"

            Behavior on color { ColorAnimation { duration: 100 } }

            Rectangle {
              visible: winRow.isSelected
              width: 3
              height: 24
              radius: 2
              color: root.theme.accentPrimary
              anchors.left: parent.left
              anchors.leftMargin: 2
              anchors.verticalCenter: parent.verticalCenter
            }

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: 12
              anchors.rightMargin: 12
              spacing: 12

              Item {
                Layout.preferredWidth: 28
                Layout.preferredHeight: 28
                Layout.alignment: Qt.AlignVCenter

                IconImage {
                  id: winIcon
                  anchors.fill: parent
                  source: root.iconFor(winRow.modelData)
                  visible: status === Image.Ready
                }

                Text {
                  anchors.centerIn: parent
                  text: ""
                  color: root.theme.accentPrimary
                  font { pixelSize: 18; family: root.font }
                  visible: !winIcon.visible
                }
              }

              ColumnLayout {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                spacing: 1

                Text {
                  text: winRow.modelData.title || "(untitled)"
                  color: winRow.isSelected ? root.theme.textPrimary : root.theme.textSecondary
                  font { pixelSize: 13; bold: winRow.isSelected; family: root.font }
                  elide: Text.ElideRight
                  Layout.fillWidth: true
                }

                Text {
                  text: winRow.cls
                  color: root.theme.textMuted
                  font { pixelSize: 11; family: root.font }
                  elide: Text.ElideRight
                  Layout.fillWidth: true
                  visible: text !== ""
                }
              }

              // Marks the window you are on right now, which is otherwise
              // indistinguishable from the one above it in a recency-ordered list.
              Rectangle {
                visible: winRow.isActive
                Layout.preferredHeight: 18
                Layout.preferredWidth: 46
                radius: 9
                color: "transparent"
                border.color: root.theme.accentGreen
                border.width: 1

                Text {
                  anchors.centerIn: parent
                  text: "here"
                  color: root.theme.accentGreen
                  font { pixelSize: 9; family: root.font }
                }
              }

              Rectangle {
                visible: winRow.modelData.workspace !== null
                Layout.preferredHeight: 20
                Layout.preferredWidth: Math.max(20, wsLabel.width + 12)
                radius: 10
                color: root.theme.bgSurface

                Text {
                  id: wsLabel
                  anchors.centerIn: parent
                  text: winRow.modelData.workspace ? winRow.modelData.workspace.name : ""
                  color: root.theme.textSecondary
                  font { pixelSize: 10; family: root.font }
                }
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.focusWindow(winRow.modelData)

              // Follow the pointer only when the pointer is what moved. Qt hands
              // a hover move to whatever MouseArea ends up under the cursor, and
              // that includes rows arriving there on their own, which they do on
              // every keystroke that re-filters. Measured with the pointer resting
              // over the fourth row, typing one character moved selectedIndex from
              // the top hit to 3.
              //
              // The comparison is in scene coordinates because mouse.x/y are
              // relative to the row, so they change when the row moves under a
              // pointer that did not. The arming flag covers the open itself.
              onPositionChanged: mouse => {
                const p = winRow.mapToItem(null, mouse.x, mouse.y);
                if (Math.abs(p.x - root.lastHoverPoint.x) < 1
                 && Math.abs(p.y - root.lastHoverPoint.y) < 1) return;

                root.lastHoverPoint = p;

                if (!root.hoverArmed) {
                  root.hoverArmed = true;
                  return;
                }

                root.selectedIndex = winRow.index;
              }
            }
          }

          Text {
            anchors.centerIn: parent
            text: "  No windows match"
            color: root.theme.textMuted
            font { pixelSize: 14; family: root.font }
            visible: resultsList.count === 0
          }
        }

        // Footer hint
        RowLayout {
          Layout.fillWidth: true
          spacing: 16

          Row {
            spacing: 4
            Rectangle {
              width: hintTab.width + 8; height: 18; radius: 4; color: root.theme.bgSurface
              Text { id: hintTab; anchors.centerIn: parent; text: "tab"; color: root.theme.textMuted; font.pixelSize: 10; font.family: root.font }
            }
            Text { text: "cycle"; color: root.theme.textMuted; font.pixelSize: 10; font.family: root.font; anchors.verticalCenter: parent.verticalCenter }
          }

          Row {
            spacing: 4
            Rectangle {
              width: hintEnter.width + 8; height: 18; radius: 4; color: root.theme.bgSurface
              Text { id: hintEnter; anchors.centerIn: parent; text: "⏎"; color: root.theme.textMuted; font.pixelSize: 10; font.family: root.font }
            }
            Text { text: "focus"; color: root.theme.textMuted; font.pixelSize: 10; font.family: root.font; anchors.verticalCenter: parent.verticalCenter }
          }

          Row {
            spacing: 4
            Rectangle {
              width: hintEsc.width + 8; height: 18; radius: 4; color: root.theme.bgSurface
              Text { id: hintEsc; anchors.centerIn: parent; text: "esc"; color: root.theme.textMuted; font.pixelSize: 10; font.family: root.font }
            }
            Text { text: "close"; color: root.theme.textMuted; font.pixelSize: 10; font.family: root.font; anchors.verticalCenter: parent.verticalCenter }
          }

          Item { Layout.fillWidth: true }
        }
      }
    }
  }
}
