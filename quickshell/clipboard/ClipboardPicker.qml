pragma ComponentBehavior: Bound
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Layouts
import "../common"

// Clipboard history, over cliphist. The app launcher's list with a different
// model, as promised -- the only real differences are that entries are text
// rather than desktop files, and that deleting one is a first-class action.
//
// cliphist itself only records what the wl-paste watchers hand it. Those live in
// hyprland.lua's autostart; with them not running this panel is simply empty.
Scope {
  id: root
  property var theme: DefaultTheme {}
  property string font: "AdwaitaMono Nerd Font"

  property int selectedIndex: 0

  // Each entry is { id, preview, binary }. cliphist list emits "<id>\t<preview>"
  // and renders non-text as "[[ binary data ... ]]".
  property var entries: []

  function open() {
    searchInput.text = "";
    root.selectedIndex = 0;
    clipPanel.visible = true;
    searchInput.forceActiveFocus();
    root.reload();
  }

  function close() { clipPanel.visible = false; }
  function toggle() { clipPanel.visible ? root.close() : root.open(); }

  function reload() { listProc.running = true; }

  IpcHandler {
    target: "clipboard"
    function toggle(): void { root.toggle(); }
    function open(): void   { root.open(); }
    function close(): void  { root.close(); }
  }

  // `cliphist list` on an empty db writes "opening db: please store something
  // first" to stdout rather than failing, so the parse has to recognise it --
  // otherwise it shows up as a clipboard entry you can select.
  Process {
    id: listProc
    command: ["cliphist", "list"]
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        const out = [];
        for (const line of text.split("\n")) {
          if (line === "" || line.startsWith("opening db:")) continue;
          const tab = line.indexOf("\t");
          if (tab < 0) continue;
          const preview = line.slice(tab + 1);
          out.push({
            id: line.slice(0, tab),
            preview: preview,
            binary: preview.startsWith("[[ binary data")
          });
        }
        root.entries = out;
        root.selectedIndex = 0;
      }
    }
  }

  Process { id: actionProc; running: false }

  Process {
    id: deleteProc
    running: false
    // Reload once the delete has actually finished, rather than trusting it.
    // Deletes can legitimately fail: ids shift whenever anything is copied --
    // including by this panel, since copying re-triggers the wl-paste watcher --
    // so a line captured when the list loaded may no longer exist. Matching on
    // the whole line means a stale delete no-ops instead of removing the wrong
    // entry, and this reload is what stops the UI from claiming otherwise.
    onExited: root.reload()
  }

  // Round-trips through cliphist decode rather than pasting the preview: the
  // preview is truncated at 100 characters and strips newlines, so copying it
  // would quietly hand back a mangled version of whatever was stored.
  function copyEntry(entry) {
    if (!entry) return;
    root.close();
    actionProc.command = ["sh", "-c",
      'cliphist decode "$1" | wl-copy', "sh", entry.id];
    actionProc.running = true;
  }

  // cliphist delete reads the *list line* on stdin -- id, tab, preview -- not the
  // id as an argument. Sending the whole line rather than just the id is the
  // safe choice: if the entry has shifted since the list was read, this fails to
  // match and deletes nothing, where an id-only delete would remove whatever
  // now holds that id.
  function deleteEntry(entry) {
    if (!entry) return;
    deleteProc.command = ["sh", "-c",
      'printf "%s\\t%s\\n" "$1" "$2" | cliphist delete', "sh", entry.id, entry.preview];
    deleteProc.running = true;
  }

  ScriptModel {
    id: filtered
    objectProp: "id"
    values: {
      const q = searchInput.text.trim().toLowerCase();
      if (q === "") return root.entries;
      return root.entries.filter(e => e.preview.toLowerCase().includes(q));
    }
  }

  Scrim { active: clipPanel.visible; color: root.theme.bgOverlay; onClicked: root.close() }

  PanelWindow {
    id: clipPanel
    visible: false
    focusable: true
    color: "transparent"

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    WlrLayershell.namespace: "quickshell-clipboard"

    exclusionMode: ExclusionMode.Ignore

    anchors { top: true; bottom: true; left: true; right: true }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    Rectangle {
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
          text: "  Clipboard"
          color: root.theme.accentPrimary
          font { pixelSize: 14; bold: true; family: root.font }
        }

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
              Accessible.name: "Search clipboard history"

              Text {
                anchors.fill: parent
                text: "Type to search history..."
                color: root.theme.textMuted
                font: parent.font
                visible: !parent.text && !parent.activeFocus
                verticalAlignment: Text.AlignVCenter
              }

              onTextChanged: root.selectedIndex = 0

              Keys.onEscapePressed: root.close()

              Keys.onPressed: event => {
                const last = resultsList.count - 1;
                if (event.key === Qt.Key_Down || (event.key === Qt.Key_Tab && !(event.modifiers & Qt.ShiftModifier))) {
                  event.accepted = true;
                  root.selectedIndex = root.selectedIndex >= last ? 0 : root.selectedIndex + 1;
                  resultsList.positionViewAtIndex(root.selectedIndex, ListView.Contain);
                } else if (event.key === Qt.Key_Up || (event.key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier))) {
                  event.accepted = true;
                  root.selectedIndex = root.selectedIndex <= 0 ? last : root.selectedIndex - 1;
                  resultsList.positionViewAtIndex(root.selectedIndex, ListView.Contain);
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  event.accepted = true;
                  root.copyEntry(filtered.values[root.selectedIndex]);
                } else if (event.key === Qt.Key_Delete
                           || (event.key === Qt.Key_D && (event.modifiers & Qt.ControlModifier))) {
                  event.accepted = true;
                  root.deleteEntry(filtered.values[root.selectedIndex]);
                }
              }
            }
          }
        }

        Text {
          text: resultsList.count + (resultsList.count === 1 ? " entry" : " entries")
          color: root.theme.textMuted
          font { pixelSize: 11; family: root.font }
        }

        ListView {
          id: resultsList
          Layout.fillWidth: true
          Layout.fillHeight: true
          model: filtered
          clip: true
          spacing: 2
          boundsBehavior: Flickable.StopAtBounds

          delegate: Rectangle {
            id: clipRow
            required property var modelData
            required property int index

            readonly property bool isSelected: root.selectedIndex === index

            width: resultsList.width
            height: 40
            radius: 8
            color: isSelected ? root.theme.bgSelected : "transparent"

            Behavior on color { ColorAnimation { duration: 100 } }

            Accessible.role: Accessible.Button
            Accessible.name: clipRow.modelData.binary
                             ? "Binary clipboard entry"
                             : clipRow.modelData.preview

            Rectangle {
              visible: clipRow.isSelected
              width: 3
              height: 20
              radius: 2
              color: root.theme.accentPrimary
              anchors.left: parent.left
              anchors.leftMargin: 2
              anchors.verticalCenter: parent.verticalCenter
            }

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: 14
              anchors.rightMargin: 10
              spacing: 10

              Icon {
                name: clipRow.modelData.binary ? "image" : "clipboard-text"
                color: clipRow.isSelected ? root.theme.accentPrimary : root.theme.textMuted
                size: 14
                Layout.alignment: Qt.AlignVCenter
              }

              Text {
                Layout.fillWidth: true
                text: clipRow.modelData.binary ? "image or binary data" : clipRow.modelData.preview
                color: clipRow.modelData.binary ? root.theme.textMuted
                     : clipRow.isSelected       ? root.theme.textPrimary
                     : root.theme.textSecondary
                font {
                  pixelSize: 12
                  family: root.font
                  italic: clipRow.modelData.binary
                }
                elide: Text.ElideRight
                maximumLineCount: 1
              }

              Icon {
                visible: rowHover.containsMouse
                name: "delete"
                color: delHover.containsMouse ? root.theme.accentRed : root.theme.textMuted
                size: 13

                MouseArea {
                  id: delHover
                  anchors.fill: parent
                  anchors.margins: -4
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.deleteEntry(clipRow.modelData)
                }
              }
            }

            MouseArea {
              id: rowHover
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              z: -1
              onClicked: root.copyEntry(clipRow.modelData)
              onPositionChanged: root.selectedIndex = clipRow.index
            }
          }

          Text {
            anchors.centerIn: parent
            text: searchInput.text !== "" ? "  Nothing matches"
                                          : "  Clipboard history is empty"
            color: root.theme.textMuted
            font { pixelSize: 14; family: root.font }
            visible: resultsList.count === 0
          }
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: 16

          Row {
            spacing: 4
            Rectangle {
              width: hintEnter.width + 8; height: 18; radius: 4; color: root.theme.bgSurface
              Text { id: hintEnter; anchors.centerIn: parent; text: "⏎"; color: root.theme.textMuted; font.pixelSize: 10; font.family: root.font }
            }
            Text { text: "copy"; color: root.theme.textMuted; font.pixelSize: 10; font.family: root.font; anchors.verticalCenter: parent.verticalCenter }
          }

          Row {
            spacing: 4
            Rectangle {
              width: hintDel.width + 8; height: 18; radius: 4; color: root.theme.bgSurface
              Text { id: hintDel; anchors.centerIn: parent; text: "del"; color: root.theme.textMuted; font.pixelSize: 10; font.family: root.font }
            }
            Text { text: "remove"; color: root.theme.textMuted; font.pixelSize: 10; font.family: root.font; anchors.verticalCenter: parent.verticalCenter }
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
