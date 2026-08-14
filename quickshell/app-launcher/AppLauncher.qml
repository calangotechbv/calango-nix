pragma ComponentBehavior: Bound
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../common"

Scope {
  id: root
  property var theme: DefaultTheme {}
  property string font: "AdwaitaMono Nerd Font"

  IpcHandler {
    target: "launcher"

    function toggle(): void {
      launcherPanel.visible = !launcherPanel.visible
      if (launcherPanel.visible) {
        searchInput.text = ""
        root.selectedIndex = -1
        root.hoverArmed = false
        searchInput.forceActiveFocus()
      }
    }
  }

  property int selectedIndex: 0

  // Scene position the pointer was last seen at, so hover can tell itself moving
  // from the list moving underneath it. See the delegate's onPositionChanged.
  property point lastHoverPoint: Qt.point(-1, -1)

  // Whether the pointer has moved since the launcher opened. Until it has, the
  // list appearing under a resting cursor is not a hover, so the first event
  // only records where the pointer was.
  property bool hoverArmed: false

  ScriptModel {
    id: filteredApps
    objectProp: "id"
    values: {
      const all = [...DesktopEntries.applications.values];
      const q = searchInput.text.trim().toLowerCase();
      if (q === "") return all.sort((a, b) => a.name.localeCompare(b.name));
      return all.filter(d =>
        (d.name && d.name.toLowerCase().includes(q)) ||
        (d.genericName && d.genericName.toLowerCase().includes(q)) ||
        (d.keywords && d.keywords.some(k => k.toLowerCase().includes(q))) ||
        (d.categories && d.categories.some(c => c.toLowerCase().includes(q)))
      ).sort((a, b) => {
        const an = a.name.toLowerCase();
        const bn = b.name.toLowerCase();
        const aStarts = an.startsWith(q);
        const bStarts = bn.startsWith(q);
        if (aStarts && !bStarts) return -1;
        if (!aStarts && bStarts) return 1;
        return an.localeCompare(bn);
      });
    }
  }

  // Terminal for desktop entries declaring Terminal=true. Kept in step with
  // `terminal` in hypr/hyprland.lua, which is what SUPER+Q opens -- an entry
  // launched from here should land in the same terminal as one opened by hand.
  //
  // The "-e" below is safe for foot: it has no meaning there and foot documents
  // it as ignored, for compatibility with xterm -e. So the argv shape does not
  // have to know which terminal it is naming.
  property string terminal: "foot"

  // The scope launch itself lives in common/AppLaunch.qml, shared with the
  // browser picker. What stays here is the DesktopEntry-shaped part: turning an
  // entry into an argv, and falling back to entry.execute() when there is
  // nothing runnable or no systemd to run it under.
  function launchApp(entry) {
    launcherPanel.visible = false;
    if (!entry) return;

    let argv = AppLaunch.stripFieldCodes([...(entry.command || [])]);
    if (argv.length === 0) { entry.execute(); return; }
    if (entry.runInTerminal) argv = [root.terminal, "-e"].concat(argv);

    if (!AppLaunch.run(argv, entry.id, entry.workingDirectory || ""))
      entry.execute();
  }

  Scrim { active: launcherPanel.visible; color: root.theme.bgOverlay; onClicked: launcherPanel.visible = false }

  PanelWindow {
    id: launcherPanel
    visible: false
    focusable: true
    color: "transparent"

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    WlrLayershell.namespace: "quickshell-launcher"

    exclusionMode: ExclusionMode.Ignore

    anchors {
      top: true
      bottom: true
      left: true
      right: true
    }

    // Click outside the card dismisses. This one only ever sees presses on the
    // screen the card is on: the scrim below covers every screen, but this
    // surface is over it and takes the press first.
    MouseArea {
      anchors.fill: parent
      onClicked: launcherPanel.visible = false
    }

    // Centered launcher box
    Rectangle {
      id: launcherBox
      anchors.centerIn: parent
      width: 580
      height: 480
      radius: 16
      color: root.theme.bgBase
      border.color: root.theme.bgBorder
      border.width: 1

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 12

        // Header
        Text {
          text: "  Applications"
          color: root.theme.accentPrimary
          font.pixelSize: 14
          font.family: root.font
          font.bold: true
        }

        // Search bar
        Rectangle {
          Layout.fillWidth: true
          Layout.preferredHeight: 44
          radius: 10
          color: root.theme.bgSurface
          border.color: searchInput.activeFocus ? root.theme.accentPrimary : root.theme.bgBorder
          border.width: 1

          Behavior on border.color {
            ColorAnimation { duration: 150 }
          }

          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 14
            anchors.rightMargin: 14
            spacing: 10

            Text {
              text: ""
              color: root.theme.textMuted
              font.pixelSize: 16
              font.family: root.font
              Layout.alignment: Qt.AlignVCenter
            }

            TextInput {
              id: searchInput
              Layout.fillWidth: true
              Layout.alignment: Qt.AlignVCenter
              color: root.theme.textPrimary
              font.pixelSize: 15
              font.family: root.font
              clip: true
              focus: true
              Accessible.role: Accessible.EditableText
              Accessible.name: "Search applications"

              Text {
                anchors.fill: parent
                text: "Type to search..."
                color: root.theme.textMuted
                font: parent.font
                visible: !parent.text && !parent.activeFocus
                verticalAlignment: Text.AlignVCenter
              }

              onTextChanged: root.selectedIndex = text === "" ? -1 : 0

              Keys.onEscapePressed: launcherPanel.visible = false

              Keys.onPressed: event => {
                if (event.key === Qt.Key_Down) {
                  event.accepted = true;
                  root.selectedIndex = Math.min(root.selectedIndex + 1, resultsList.count - 1);
                  resultsList.positionViewAtIndex(root.selectedIndex, ListView.Contain);
                } else if (event.key === Qt.Key_Up) {
                  event.accepted = true;
                  root.selectedIndex = Math.max(root.selectedIndex - 1, 0);
                  resultsList.positionViewAtIndex(root.selectedIndex, ListView.Contain);
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  event.accepted = true;
                  if (root.selectedIndex >= 0) {
                    const entry = filteredApps.values[root.selectedIndex];
                    if (entry) root.launchApp(entry);
                  }
                } else if (event.key === Qt.Key_Tab) {
                  event.accepted = true;
                  root.selectedIndex = Math.min(root.selectedIndex + 1, resultsList.count - 1);
                  resultsList.positionViewAtIndex(root.selectedIndex, ListView.Contain);
                }
              }
            }
          }
        }

        // Results count
        Text {
          text: resultsList.count + " application" + (resultsList.count !== 1 ? "s" : "")
          color: root.theme.textMuted
          font.pixelSize: 11
          font.family: root.font
        }

        // App list
        ListView {
          id: resultsList
          Layout.fillWidth: true
          Layout.fillHeight: true
          model: filteredApps
          clip: true
          spacing: 2
          boundsBehavior: Flickable.StopAtBounds

          // The selection is drawn by the delegate rather than by ListView's
          // `highlight`, because `highlight` follows ListView.currentIndex and
          // currentIndex does not stay put across a search.
          //
          // filteredApps is a ScriptModel keyed on `id`, so re-running the filter
          // emits inserts/removes/moves rather than a reset, and ListView answers
          // those by keeping the *same item* current -- dragging currentIndex to
          // wherever that item landed. `currentIndex: root.selectedIndex` does not
          // undo it: the binding only re-evaluates when selectedIndex changes, and
          // typing a second character leaves it at 0 throughout. So the bar sat on
          // whatever row the previously-selected app had moved to (measured:
          // currentIndex 8, then 2, while selectedIndex was 0) until an arrow key
          // changed selectedIndex and re-asserted the binding.
          //
          // Enter was always right -- it reads filteredApps.values[selectedIndex]
          // -- which is what made this look like a highlight that lied rather than
          // a launcher that opened the wrong app. Binding the delegate straight to
          // selectedIndex leaves one source of truth and nothing to drift.

          delegate: Rectangle {
            id: delegateRoot
            required property var modelData
            required property int index

            readonly property bool isSelected: root.selectedIndex === delegateRoot.index

            Accessible.role: Accessible.Button
            Accessible.name: (modelData.name ?? "Application") + (modelData.genericName ? " - " + modelData.genericName : "")

            width: resultsList.width
            height: 44
            radius: 8
            color: delegateRoot.isSelected ? root.theme.bgSelected : "transparent"

            Behavior on color { ColorAnimation { duration: 120 } }

            Rectangle {
              width: 3
              height: 24
              radius: 2
              color: root.theme.accentPrimary
              anchors.left: parent.left
              anchors.leftMargin: 2
              anchors.verticalCenter: parent.verticalCenter
              visible: delegateRoot.isSelected
            }

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: 12
              anchors.rightMargin: 12
              spacing: 12

              // App icon
              Item {
                Layout.preferredWidth: 28
                Layout.preferredHeight: 28
                Layout.alignment: Qt.AlignVCenter

                IconImage {
                  anchors.fill: parent
                  source: Quickshell.iconPath(delegateRoot.modelData.icon ?? "", true)
                  visible: (delegateRoot.modelData.icon ?? "") !== ""
                }

                // Fallback icon
                Text {
                  anchors.centerIn: parent
                  text: ""
                  color: root.theme.accentPrimary
                  font.pixelSize: 20
                  font.family: root.font
                  visible: (delegateRoot.modelData.icon ?? "") === ""
                }
              }

              // App info
              ColumnLayout {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                spacing: 1

                Text {
                  text: delegateRoot.modelData.name ?? ""
                  color: delegateRoot.isSelected ? root.theme.textPrimary : root.theme.textSecondary
                  font.pixelSize: 13
                  font.family: root.font
                  font.bold: delegateRoot.isSelected
                  elide: Text.ElideRight
                  Layout.fillWidth: true
                }

                Text {
                  text: delegateRoot.modelData.genericName ?? delegateRoot.modelData.comment ?? ""
                  color: root.theme.textMuted
                  font.pixelSize: 11
                  font.family: root.font
                  elide: Text.ElideRight
                  Layout.fillWidth: true
                  visible: text !== ""
                }
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.launchApp(delegateRoot.modelData)

              // Follow the pointer only when the pointer is what moved. Qt
              // delivers a hover move to whatever MouseArea ends up under the
              // cursor, including when the delegate slid there on its own -- and
              // this list re-sorts on every keystroke. Taking that as a hover
              // handed the selection to whichever row happened to land under a
              // pointer nobody had touched: opening the launcher with the cursor
              // over the list put selectedIndex on row 3 before a key was
              // pressed, and a keystroke could put it back there afterwards.
              //
              // Hiding the cursor does not help -- measured with the pointer
              // hidden before the list appeared, and the selection still moved.
              // A hidden cursor is only unpainted, and hover keeps flowing.
              //
              // The comparison has to be in scene coordinates: mouse.x/y are
              // relative to the delegate, so they change when the delegate moves
              // under a stationary pointer, which is the case being excluded.
              onPositionChanged: mouse => {
                const p = delegateRoot.mapToItem(null, mouse.x, mouse.y);
                if (Math.abs(p.x - root.lastHoverPoint.x) < 1
                 && Math.abs(p.y - root.lastHoverPoint.y) < 1) return;

                root.lastHoverPoint = p;

                // First event after opening: the pointer has not moved, the list
                // moved to meet it. Record and wait for a real one.
                if (!root.hoverArmed) {
                  root.hoverArmed = true;
                  return;
                }

                root.selectedIndex = delegateRoot.index;
              }
            }
          }

          // Empty state
          Text {
            anchors.centerIn: parent
            text: "  No applications found"
            color: root.theme.textMuted
            font.pixelSize: 14
            font.family: root.font
            visible: resultsList.count === 0 && searchInput.text !== ""
          }
        }

        // Footer hint
        RowLayout {
          Layout.fillWidth: true
          spacing: 16

          Row {
            spacing: 4
            Rectangle {
              width: hintUp.width + 8; height: 18; radius: 4; color: root.theme.bgSurface
              Text { id: hintUp; anchors.centerIn: parent; text: "↑↓"; color: root.theme.textMuted; font.pixelSize: 10; font.family: root.font }
            }
            Text { text: "navigate"; color: root.theme.textMuted; font.pixelSize: 10; font.family: root.font; anchors.verticalCenter: parent.verticalCenter }
          }

          Row {
            spacing: 4
            Rectangle {
              width: hintEnter.width + 8; height: 18; radius: 4; color: root.theme.bgSurface
              Text { id: hintEnter; anchors.centerIn: parent; text: "⏎"; color: root.theme.textMuted; font.pixelSize: 10; font.family: root.font }
            }
            Text { text: "launch"; color: root.theme.textMuted; font.pixelSize: 10; font.family: root.font; anchors.verticalCenter: parent.verticalCenter }
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
