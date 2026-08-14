pragma ComponentBehavior: Bound
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Layouts
import "../common"

Scope {
  id: root
  property var theme: DefaultTheme {}
  property string font: "AdwaitaMono Nerd Font"

  property string searchText: ""
  property string previewPath: ""

  IpcHandler {
    target: "wallpaper"

    function toggle(): void {
      wallpaperPanel.visible = !wallpaperPanel.visible;
      if (wallpaperPanel.visible) {
        root.searchText = "";
        root.previewPath = "";
        searchInput.forceActiveFocus();
        if (WallpaperService.wallpapers.length === 0) WallpaperService.rescan();
      }
    }
  }

  property var filteredWallpapers: {
    const q = searchText.toLowerCase();
    if (q === "") return WallpaperService.wallpapers;
    return WallpaperService.wallpapers.filter(p => {
      const name = p.split("/").pop().toLowerCase();
      return name.includes(q);
    });
  }

  Scrim { active: wallpaperPanel.visible; color: root.theme.bgOverlay; onClicked: wallpaperPanel.visible = false }

  PanelWindow {
    id: wallpaperPanel
    visible: false
    focusable: true
    color: "transparent"

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    WlrLayershell.namespace: "quickshell-wallpaper"

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
      onClicked: wallpaperPanel.visible = false
    }

    // Main wallpaper picker box
    Rectangle {
      anchors.centerIn: parent
      width: 720
      height: 560
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

        // Header
        RowLayout {
          Layout.fillWidth: true
          spacing: 12

          // Grouped: the header row's spacing is 12, which belongs between the
          // title and the buttons beside it, not between an icon and its word.
          RowLayout {
            spacing: 6

            Icon {
              name: "wallpaper"
              color: root.theme.accentPrimary
              size: 14
            }

            Text {
              text: "Wallpaper"
              color: root.theme.accentPrimary
              font.pixelSize: 14
              font.family: root.font
              font.bold: true
            }
          }

          Item { Layout.fillWidth: true }

          Text {
            text: root.filteredWallpapers.length + " images"
            color: root.theme.textMuted
            font.pixelSize: 11
            font.family: root.font
          }

          // Refresh button
          Rectangle {
            Layout.preferredWidth: 28
            Layout.preferredHeight: 28
            radius: 14
            color: refreshHover.containsMouse ? root.theme.bgHover : "transparent"
            Accessible.role: Accessible.Button
            Accessible.name: "Refresh wallpaper list"

            Icon {
              anchors.centerIn: parent
              name: "refresh"
              color: root.theme.textMuted
              size: 14
            }

            MouseArea {
              id: refreshHover
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: WallpaperService.rescan()
            }
          }
        }

        // Search
        Rectangle {
          Layout.fillWidth: true
          Layout.preferredHeight: 36
          radius: 8
          color: root.theme.bgSurface
          border.color: searchInput.activeFocus ? root.theme.accentPrimary : root.theme.bgBorder
          border.width: 1

          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            spacing: 8

            Text {
              text: ""
              color: root.theme.textMuted
              font.pixelSize: 13
              font.family: root.font
              Layout.alignment: Qt.AlignVCenter
            }

            TextInput {
              id: searchInput
              Layout.fillWidth: true
              Layout.alignment: Qt.AlignVCenter
              color: root.theme.textPrimary
              font.pixelSize: 13
              font.family: root.font
              clip: true
              selectByMouse: true
              Accessible.role: Accessible.EditableText
              Accessible.name: "Search wallpapers"
              onTextChanged: root.searchText = text

              Keys.onEscapePressed: {
                if (root.previewPath !== "") {
                  root.previewPath = "";
                } else {
                  wallpaperPanel.visible = false;
                }
              }
            }

            Text {
              text: "Search wallpapers..."
              color: root.theme.textMuted
              font.pixelSize: 13
              font.family: root.font
              visible: searchInput.text === "" && !searchInput.activeFocus
            }
          }
        }

        // Wallpaper grid
        GridView {
          id: wallpaperGrid
          Layout.fillWidth: true
          Layout.fillHeight: true
          cellWidth: Math.floor(width / 4)
          cellHeight: cellWidth * 0.6 + 8
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          model: root.filteredWallpapers

          delegate: Item {
            id: wallpaperDelegate
            required property string modelData
            required property int index

            Accessible.role: Accessible.Button
            Accessible.name: modelData.split("/").pop() + (WallpaperService.currentWallpaper === modelData ? ", current wallpaper" : "")

            width: wallpaperGrid.cellWidth
            height: wallpaperGrid.cellHeight

            Rectangle {
              anchors.fill: parent
              anchors.margins: 4
              radius: 8
              color: root.theme.bgSurface
              border.color: WallpaperService.currentWallpaper === modelData ? root.theme.accentPrimary : (imgHover.containsMouse ? root.theme.bgBorder : "transparent")
              border.width: WallpaperService.currentWallpaper === modelData ? 2 : 1
              clip: true

              Image {
                anchors.fill: parent
                anchors.margins: 2
                source: "file://" + wallpaperDelegate.modelData
                fillMode: Image.PreserveAspectCrop
                sourceSize.width: 200
                sourceSize.height: 120
                asynchronous: true

                Rectangle {
                  anchors.fill: parent
                  color: root.theme.bgSurface
                  visible: parent.status !== Image.Ready

                  Icon {
                    anchors.centerIn: parent
                    name: "image"
                    color: root.theme.textMuted
                    size: 24
                  }
                }
              }

              // Filename label
              Rectangle {
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                height: 22
                color: Qt.rgba(0, 0, 0, 0.6)

                Text {
                  anchors.centerIn: parent
                  text: wallpaperDelegate.modelData.split("/").pop()
                  color: "#ffffff"
                  font.pixelSize: 9
                  font.family: root.font
                  elide: Text.ElideMiddle
                  width: parent.width - 8
                  horizontalAlignment: Text.AlignHCenter
                }
              }

              // Active indicator
              Rectangle {
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: 6
                width: 20
                height: 20
                radius: 10
                color: root.theme.accentGreen
                visible: WallpaperService.currentWallpaper === modelData

                Text {
                  anchors.centerIn: parent
                  text: ""
                  color: root.theme.bgBase
                  font.pixelSize: 12
                  font.family: root.font
                }
              }

              MouseArea {
                id: imgHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: mouse => {
                  if (mouse.button === Qt.RightButton) {
                    root.previewPath = wallpaperDelegate.modelData;
                  } else {
                    WallpaperService.setWallpaper(wallpaperDelegate.modelData);
                  }
                }
              }
            }
          }

          // Empty state. The icon led the first line as a glyph; stacked above
          // the message now, since it can no longer sit inside the string.
          Column {
            anchors.centerIn: parent
            spacing: 8
            visible: wallpaperGrid.count === 0

            Icon {
              anchors.horizontalCenter: parent.horizontalCenter
              name: "image"
              color: root.theme.textMuted
              size: 24
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "No wallpapers found\nAdd images to ~/Pictures/Wallpapers/"
              color: root.theme.textMuted
              font.pixelSize: 13
              font.family: root.font
              horizontalAlignment: Text.AlignHCenter
            }
          }
        }

        // Footer
        RowLayout {
          Layout.fillWidth: true
          spacing: 16

          Row {
            spacing: 4
            Rectangle {
              width: hintClick.width + 8; height: 18; radius: 4; color: root.theme.bgSurface
              Text { id: hintClick; anchors.centerIn: parent; text: "click"; color: root.theme.textMuted; font.pixelSize: 10; font.family: root.font }
            }
            Text { text: "apply"; color: root.theme.textMuted; font.pixelSize: 10; font.family: root.font; anchors.verticalCenter: parent.verticalCenter }
          }

          Row {
            spacing: 4
            Rectangle {
              width: hintRight.width + 8; height: 18; radius: 4; color: root.theme.bgSurface
              Text { id: hintRight; anchors.centerIn: parent; text: "right-click"; color: root.theme.textMuted; font.pixelSize: 10; font.family: root.font }
            }
            Text { text: "preview"; color: root.theme.textMuted; font.pixelSize: 10; font.family: root.font; anchors.verticalCenter: parent.verticalCenter }
          }

          Row {
            spacing: 4
            Text { text: "Backend: " + WallpaperService.backend; color: root.theme.textMuted; font.pixelSize: 10; font.family: root.font; anchors.verticalCenter: parent.verticalCenter }
          }

          Item { Layout.fillWidth: true }
        }
      }
    }

    // Preview overlay
    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.85)
      visible: root.previewPath !== ""

      MouseArea {
        anchors.fill: parent
        onClicked: root.previewPath = ""
      }

      Image {
        anchors.centerIn: parent
        width: parent.width * 0.8
        height: parent.height * 0.8
        source: root.previewPath !== "" ? "file://" + root.previewPath : ""
        fillMode: Image.PreserveAspectFit
        asynchronous: true
      }

      // Apply button
      Rectangle {
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottomMargin: 40
        width: applyRow.width + 32
        height: 40
        radius: 20
        color: root.theme.accentPrimary
        Accessible.role: Accessible.Button
        Accessible.name: "Apply wallpaper"

        Row {
          id: applyRow
          anchors.centerIn: parent
          spacing: 8

          Text {
            text: ""
            color: root.theme.bgBase
            font.pixelSize: 14
            font.family: root.font
            anchors.verticalCenter: parent.verticalCenter
          }
          Text {
            text: "Apply Wallpaper"
            color: root.theme.bgBase
            font.pixelSize: 13
            font.family: root.font
            font.bold: true
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            WallpaperService.setWallpaper(root.previewPath);
            root.previewPath = "";
          }
        }
      }
    }
  }
}
