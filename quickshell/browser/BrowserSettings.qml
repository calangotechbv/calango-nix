pragma ComponentBehavior: Bound
import Quickshell
import Quickshell.Wayland
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../common"

// Where a url goes without being asked, which browsers the picker offers, and
// which letter opens which.
//
// Its own panel rather than a third section in settings/SettingsPanel.qml: that
// file is already 770 lines of bar opacity and display arrangement, and a url
// routing table has nothing to do with either.
Scope {
  id: root
  property var theme: DefaultTheme {}
  property string font: "AdwaitaMono Nerd Font"

  // The entry whose speed key is being captured, or "" for none. While it is
  // set, the next letter typed is bound to it rather than doing anything else.
  property string capturingFor: ""

  // Emitted every time this panel closes, however it closes -- escape, the
  // close button, the scrim, or another panel claiming PanelGroup out from
  // under it. shell.qml listens for this to hand back a url queue stashed
  // before opening (see shell.qml for why one exists to hand back at all).
  signal closed()

  // Whether the panel is up, so a caller can decide between opening and closing
  // it without reaching into the window.
  readonly property alias isOpen: settingsPanel.visible

  function open() {
    root.capturingFor = "";
    BrowserService.reload();
    settingsPanel.visible = true;
  }
  function close() {
    root.capturingFor = "";
    settingsPanel.visible = false;
    root.closed();
  }

  // A browser as one short line, for the places that only have one line to give
  // it: the rule's target pill and the options under it.
  //
  // discover.py's `detail` is "dropsolid.com · igor.sutton@dropsolid.com" -- the
  // profile label and the account it belongs to. Both fit in the picker, which
  // gives detail its own row under the name. Here they do not, and the string
  // elides mid-address, so all three chrome profiles read as
  // "Google Chrome · dropsolid.com · igor.sutto…" -- a chooser whose options
  // cannot be told apart. The label alone is what distinguishes them; the
  // address is the part that repeats.
  function shortLabel(entry) {
    if (!entry) return "";
    const label = (entry.detail || "").split(" · ")[0];
    return label ? entry.name + " · " + label : entry.name;
  }

  function addRule() {
    const first = BrowserService.visibleEntries()[0];
    if (!first) return;
    BrowserService.setRules((BrowserService.config.rules || [])
      .concat([{ pattern: "*example.com*", target: first.id }]));
  }

  function removeRule(index) {
    const next = (BrowserService.config.rules || []).slice();
    next.splice(index, 1);
    BrowserService.setRules(next);
  }

  // Rules are replaced wholesale rather than edited in place, for the reason
  // BrowserService._patch gives: writing into the object a qml property holds
  // emits no change signal, and the list would keep rendering the old text.
  function updateRule(index, key, value) {
    const next = (BrowserService.config.rules || []).map(r =>
      ({ pattern: r.pattern, target: r.target }));
    if (!next[index]) return;
    next[index][key] = value;
    BrowserService.setRules(next);
  }

  Scrim { active: settingsPanel.visible; color: root.theme.bgOverlay; onClicked: root.close() }

  PanelWindow {
    id: settingsPanel
    visible: false
    focusable: true
    color: "transparent"

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    WlrLayershell.namespace: "quickshell-browser-settings"

    exclusionMode: ExclusionMode.Ignore

    anchors { top: true; bottom: true; left: true; right: true }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    Rectangle {
      anchors.centerIn: parent
      width: 640
      height: 560
      radius: 16
      color: root.theme.bgBase
      border.color: root.theme.bgBorder
      border.width: 1

      MouseArea {
        anchors.fill: parent
        onClicked: event => event.accepted = true
      }

      focus: true
      Keys.onEscapePressed: {
        if (root.capturingFor !== "") root.capturingFor = "";
        else root.close();
      }
      Keys.onPressed: event => {
        if (root.capturingFor === "") return;
        // Capturing: backspace clears the binding, any single letter takes it.
        if (event.key === Qt.Key_Backspace) {
          event.accepted = true;
          BrowserService.setKey("", root.capturingFor);
          root.capturingFor = "";
        } else if (event.text.length === 1 && /[a-z0-9]/i.test(event.text)) {
          event.accepted = true;
          BrowserService.setKey(event.text.toLowerCase(), root.capturingFor);
          root.capturingFor = "";
        }
      }

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 12

        RowLayout {
          Layout.fillWidth: true
          Text {
            text: "  Browser rules"
            color: root.theme.accentPrimary
            font { pixelSize: 14; bold: true; family: root.font }
          }
          Item { Layout.fillWidth: true }
          CloseButton { onClicked: root.close() }
        }

        Text {
          text: "RULES — a match opens without asking"
          color: root.theme.textMuted
          font { pixelSize: 10; family: root.font }
        }

        ListView {
          Layout.fillWidth: true
          Layout.preferredHeight: Math.min(160, contentHeight)
          model: BrowserService.config.rules || []
          clip: true
          spacing: 4
          boundsBehavior: Flickable.StopAtBounds

          delegate: RowLayout {
            id: ruleRow
            required property var modelData
            required property int index

            width: ListView.view.width
            spacing: 8

            Rectangle {
              Layout.preferredWidth: 220
              Layout.preferredHeight: 30
              radius: 6
              color: root.theme.bgSurface
              border.color: patternInput.activeFocus ? root.theme.accentPrimary
                                                     : root.theme.bgBorder
              border.width: 1

              TextInput {
                id: patternInput
                anchors.fill: parent
                anchors.margins: 8
                verticalAlignment: TextInput.AlignVCenter
                color: root.theme.textPrimary
                font { pixelSize: 12; family: root.font }
                text: ruleRow.modelData.pattern
                clip: true
                Accessible.role: Accessible.EditableText
                Accessible.name: "URL pattern"
                onEditingFinished: root.updateRule(ruleRow.index, "pattern", text)
              }
            }

            Text {
              text: "→"
              color: root.theme.textMuted
              font { pixelSize: 12; family: root.font }
            }

            // The target picker: the current browser, and a chevron that drops
            // the rest down over the panel.
            //
            // Built the way the display-mode picker in settings/MonitorPanel.qml
            // is -- a pill plus a Controls Popup parented to it -- rather than
            // as a plain Rectangle in this delegate. That is not only for
            // consistency: this row lives in a ListView with clip: true, so
            // anything drawn inside the delegate would be cut off at the list's
            // edge. A Popup renders in the window's overlay instead and escapes
            // the clip, which is the whole reason to reach for one here.
            Rectangle {
              id: targetPill
              Layout.fillWidth: true
              Layout.preferredHeight: 30
              radius: 6
              color: targetHover.containsMouse ? root.theme.bgHover : root.theme.bgSurface
              border.color: targetDropdown.opened ? root.theme.accentPrimary : "transparent"
              border.width: 1

              readonly property var entry:
                BrowserService.entryById(ruleRow.modelData.target)

              Row {
                anchors { fill: parent; leftMargin: 8; rightMargin: 8 }
                spacing: 0

                Text {
                  width: parent.width - 16
                  height: parent.height
                  verticalAlignment: Text.AlignVCenter
                  elide: Text.ElideRight
                  color: targetPill.entry ? root.theme.textSecondary : root.theme.accentRed
                  font { pixelSize: 12; family: root.font }
                  text: targetPill.entry ? root.shortLabel(targetPill.entry)
                                         : "(missing — this rule is skipped)"
                }

                Text {
                  width: 16
                  height: parent.height
                  horizontalAlignment: Text.AlignRight
                  verticalAlignment: Text.AlignVCenter
                  text: targetDropdown.opened ? "▴" : "▾"
                  color: root.theme.textMuted
                  font { pixelSize: 10; family: root.font }
                }
              }

              MouseArea {
                id: targetHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: targetDropdown.opened ? targetDropdown.close()
                                                 : targetDropdown.open()
              }

              Popup {
                id: targetDropdown
                parent: targetPill
                x: 0
                y: targetPill.height + 4
                width: targetPill.width
                // The background border is drawn inward, so without this the
                // contentItem sits on top of it.
                padding: 1
                closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent

                background: Rectangle {
                  radius: 6
                  color: root.theme.bgSurface
                  border.color: root.theme.accentPrimary
                  border.width: 1
                }

                contentItem: ListView {
                  implicitHeight: Math.min(contentHeight, 200)
                  // Only entries the picker would actually offer. A rule
                  // pointing at a hidden one is skipped at match time, so
                  // offering them here would be offering a rule that cannot fire.
                  model: BrowserService.visibleEntries()
                  clip: true
                  boundsBehavior: Flickable.StopAtBounds

                  delegate: Rectangle {
                    id: optionRow
                    required property var modelData

                    width: ListView.view.width
                    height: 28
                    color: optionHover.containsMouse ? root.theme.bgHover
                         : optionRow.modelData.id === ruleRow.modelData.target
                           ? root.theme.bgSelected : "transparent"

                    Text {
                      anchors { fill: parent; leftMargin: 8; rightMargin: 8 }
                      verticalAlignment: Text.AlignVCenter
                      elide: Text.ElideRight
                      color: root.theme.textSecondary
                      font { pixelSize: 12; family: root.font }
                      text: root.shortLabel(optionRow.modelData)
                    }

                    MouseArea {
                      id: optionHover
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        root.updateRule(ruleRow.index, "target", optionRow.modelData.id);
                        targetDropdown.close();
                      }
                    }
                  }
                }
              }
            }

            Text {
              text: "✕"
              color: removeHover.containsMouse ? root.theme.accentRed : root.theme.textMuted
              font { pixelSize: 12; family: root.font }
              MouseArea {
                id: removeHover
                anchors.fill: parent
                anchors.margins: -6
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.removeRule(ruleRow.index)
              }
            }
          }
        }

        Text {
          text: "+ add rule"
          color: addHover.containsMouse ? root.theme.accentPrimary : root.theme.textMuted
          font { pixelSize: 11; family: root.font }
          MouseArea {
            id: addHover
            anchors.fill: parent
            anchors.margins: -4
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.addRule()
          }
        }

        Text {
          text: "BROWSERS"
          color: root.theme.textMuted
          font { pixelSize: 10; family: root.font }
        }

        ListView {
          Layout.fillWidth: true
          Layout.fillHeight: true
          model: BrowserService.entries
          clip: true
          spacing: 2
          boundsBehavior: Flickable.StopAtBounds

          delegate: RowLayout {
            id: entryRow
            required property var modelData

            readonly property bool isHidden:
              (BrowserService.config.hidden || []).indexOf(entryRow.modelData.id) >= 0
            readonly property bool isCapturing:
              root.capturingFor === entryRow.modelData.id

            width: ListView.view.width
            height: 34
            spacing: 10

            Image {
              source: entryRow.modelData.icon.startsWith("/")
                      ? "file://" + entryRow.modelData.icon
                      : Quickshell.iconPath(entryRow.modelData.icon, true)
              sourceSize { width: 20; height: 20 }
              Layout.preferredWidth: 20
              Layout.preferredHeight: 20
              opacity: entryRow.isHidden ? 0.4 : 1.0
            }

            Text {
              Layout.fillWidth: true
              text: entryRow.modelData.detail
                    ? entryRow.modelData.name + " · " + entryRow.modelData.detail
                    : entryRow.modelData.name
              color: entryRow.isHidden ? root.theme.textMuted : root.theme.textSecondary
              font { pixelSize: 12; family: root.font }
              elide: Text.ElideRight
            }

            // Click to capture, then the next letter typed binds. Backspace
            // clears it, escape gives up.
            Rectangle {
              Layout.preferredWidth: 44
              Layout.preferredHeight: 22
              radius: 4
              color: entryRow.isCapturing ? root.theme.bgSelected : root.theme.bgSurface
              border.color: entryRow.isCapturing ? root.theme.accentPrimary : "transparent"
              border.width: 1

              Text {
                anchors.centerIn: parent
                text: entryRow.isCapturing
                      ? "…"
                      : (BrowserService.keyFor(entryRow.modelData.id) || "—")
                color: root.theme.textMuted
                font { pixelSize: 11; family: root.font }
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.capturingFor =
                  entryRow.isCapturing ? "" : entryRow.modelData.id
              }
            }

            Text {
              Layout.preferredWidth: 60
              text: entryRow.isHidden ? "hidden" : "shown"
              color: entryRow.isHidden ? root.theme.textMuted : root.theme.accentGreen
              font { pixelSize: 11; family: root.font }
              horizontalAlignment: Text.AlignRight

              MouseArea {
                anchors.fill: parent
                anchors.margins: -4
                cursorShape: Qt.PointingHandCursor
                onClicked: BrowserService.setHidden(entryRow.modelData.id,
                                                    !entryRow.isHidden)
              }
            }
          }
        }
      }
    }
  }
}
