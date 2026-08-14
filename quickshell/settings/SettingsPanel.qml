pragma ComponentBehavior: Bound
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Layouts
import "../common"

Scope {
  id: root

  property var  theme: DefaultTheme {}
  property string font: "AdwaitaMono Nerd Font"

  // Which tab is showing: "monitors" or "appearance". Deliberately not reset by
  // openEditor -- reopening where you left it is what every other tabbed thing
  // does, and the monitor tab reloads its state on open either way.
  property string tab: "monitors"

  property var  editState:       []
  property int  selectedIndex:   -1
  property bool isOpen:          false
  property bool isApplying:      false
  property string applyError:    ""
  property bool hotplugDetected: false
  property bool persistWarning:  false
  property var  _openSnapshot:   []
  property bool _isInitialLoad:  false

  function openEditor() {
    isOpen          = true;
    selectedIndex   = -1;
    applyError      = "";
    hotplugDetected = false;
    persistWarning  = !MonitorService.persistenceAvailable;
    editState       = [];
    _openSnapshot   = [];
    _isInitialLoad  = true;
    MonitorService.refresh();
  }

  function initEditState() {
    const raw = MonitorService.monitors.map(m => Object.assign({}, m));

    // Auto-place newly appeared monitors that land at (0,0) overlapping others
    const enabled    = raw.filter(m => !m.disabled);
    const rightEdge  = enabled.reduce((max, m) => {
      const atOrigin = m.x === 0 && m.y === 0;
      return atOrigin ? max : Math.max(max, m.x + MonitorUtils.logicalW(m));
    }, 0);

    for (const m of raw) {
      if (m.disabled || !(m.x === 0 && m.y === 0)) continue;
      const others   = enabled.filter(o => o.name !== m.name);
      const overlaps = others.some(o =>
        MonitorUtils.overlapsAABB(m.x, m.y, MonitorUtils.logicalW(m), MonitorUtils.logicalH(m),
                                  o.x, o.y, MonitorUtils.logicalW(o), MonitorUtils.logicalH(o))
      );
      if (overlaps) m.x = rightEdge;
    }

    editState      = raw;
    _openSnapshot  = MonitorService.monitors.map(m => Object.assign({}, m));
    _isInitialLoad = false;
  }

  // True when any two enabled, non-mirroring monitors overlap
  readonly property bool hasOverlap: {
    const enabled = editState.filter(m => !m.disabled && m.mirrorOf === "");
    for (let i = 0; i < enabled.length; i++) {
      for (let j = i + 1; j < enabled.length; j++) {
        const a = enabled[i], b = enabled[j];
        if (MonitorUtils.overlapsAABB(
              a.x, a.y, MonitorUtils.logicalW(a), MonitorUtils.logicalH(a),
              b.x, b.y, MonitorUtils.logicalW(b), MonitorUtils.logicalH(b)))
          return true;
      }
    }
    return false;
  }

  function applyChanges() {
    const enabledCount = editState.filter(m => !m.disabled).length;
    if (enabledCount === 0) {
      applyError = "At least one monitor must remain enabled.";
      return;
    }
    if (root.hasOverlap) {
      applyError = "Monitors are overlapping — drag them apart before applying.";
      return;
    }
    applyError = "";
    isApplying = true;
    // persistToFile is called in onApplyDone success path — not here,
    // so we never write an invalid config to disk
    MonitorService.apply(editState);
  }

  function cancelChanges() {
    if (!isApplying) isOpen = false;
  }

  function _hasExternalChange() {
    const live = MonitorService.monitors;
    if (live.length !== _openSnapshot.length) return true;
    for (const snap of _openSnapshot) {
      const l = live.find(m => m.name === snap.name);
      if (!l) return true;
      if (l.selectedMode !== snap.selectedMode) return true;
      if (l.disabled      !== snap.disabled)    return true;
      if (l.x             !== snap.x)           return true;
      if (l.y             !== snap.y)           return true;
      if (l.scale         !== snap.scale)       return true;
      if (l.transform     !== snap.transform)   return true;
    }
    return false;
  }

  // editState mutation helpers — all guarded against out-of-bounds selectedIndex
  function onModeSelected(mode) {
    if (selectedIndex < 0 || selectedIndex >= editState.length) return;
    const parsed = MonitorUtils.parseMode(mode);
    if (!parsed) return;
    const copy = editState.slice();
    copy[selectedIndex] = Object.assign({}, editState[selectedIndex], {
      selectedMode: mode,
      width:        parsed.w,
      height:       parsed.h,
    });
    editState = copy;
  }

  function onScaleChanged(scale) {
    if (selectedIndex < 0 || selectedIndex >= editState.length) return;
    const copy = editState.slice();
    copy[selectedIndex] = Object.assign({}, editState[selectedIndex], { scale: scale });
    editState = copy;
  }

  function onTransformChanged(t) {
    if (selectedIndex < 0 || selectedIndex >= editState.length) return;
    const copy = editState.slice();
    copy[selectedIndex] = Object.assign({}, editState[selectedIndex], { transform: t });
    editState = copy;
  }

  function onEnabledChanged(enabled) {
    if (selectedIndex < 0 || selectedIndex >= editState.length) return;
    const willBeDisabled = !enabled;
    if (willBeDisabled) {
      const currentlyEnabled = editState.filter(m => !m.disabled).length;
      if (currentlyEnabled <= 1) {
        applyError = "Cannot disable the only active monitor.";
        return;
      }
    }
    const copy = editState.slice();
    copy[selectedIndex] = Object.assign({}, editState[selectedIndex], { disabled: willBeDisabled });
    editState = copy;
  }

  function onMirrorChanged(mirrorName) {
    if (selectedIndex < 0 || selectedIndex >= editState.length) return;
    let patch = { mirrorOf: mirrorName };
    if (mirrorName !== "") {
      const src = editState.find(m => m.name === mirrorName);
      if (src) { patch.x = src.x; patch.y = src.y; }
    }
    const copy = editState.slice();
    copy[selectedIndex] = Object.assign({}, editState[selectedIndex], patch);
    editState = copy;
  }

  IpcHandler {
    target: "settings"
    function toggle(): void {
      if (root.isOpen) root.isOpen = false;
      else root.openEditor();
    }
    function refresh(): void { MonitorService.refresh(); }
  }

  Connections {
    target: MonitorService

    function onApplyDone(hasErrors, errorText) {
      root.isApplying = false;
      if (hasErrors) {
        root.applyError = errorText;
      } else {
        // Only persist on confirmed success — never write an invalid config
        MonitorService.persistToFile(root.editState);
        root.initEditState();
        root.isOpen = false;
      }
    }

    function onMonitorsLoaded() {
      if (MonitorService._pendingVerify) return;
      if (!root.isOpen) return;

      if (root._isInitialLoad) {
        root.initEditState();
      } else {
        if (root._hasExternalChange()) {
          root.hotplugDetected = true;
          root._openSnapshot = MonitorService.monitors.map(m => Object.assign({}, m));
        }
      }
    }
  }

  Scrim {
    active: overlay.visible
    color: root.theme.bgOverlay
    onClicked: {
      panel.modePickerOpen   = false;
      panel.mirrorPickerOpen = false;
      root.cancelChanges();
    }
  }

  PanelWindow {
    id: overlay
    visible: root.isOpen
    focusable: true
    color: "transparent"

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    WlrLayershell.namespace: "quickshell-monitors"

    exclusionMode: ExclusionMode.Ignore

    anchors { top: true; bottom: true; left: true; right: true }

    // Poll for external hyprctl keyword changes — declared here so canvas id is in scope
    Timer {
      id: externalChangePollTimer
      interval: 3000
      repeat: true
      running: root.isOpen
               && root.tab === "monitors"
               && !MonitorService.loading
               && !MonitorService._pendingVerify
               && !canvas.isDragging
      onTriggered: MonitorService.refresh()
    }

    // Click outside the card closes the pickers and cancels. Only for presses on
    // the screen the card is on -- the scrim below covers the rest and repeats
    // the same three statements.
    MouseArea {
      anchors.fill: parent
      onClicked: {
        panel.modePickerOpen   = false;
        panel.mirrorPickerOpen = false;
        root.cancelChanges();
      }
    }

    // Main card
    Rectangle {
      anchors.centerIn: parent
      width: 960
      height: 640
      radius: 16
      color: root.theme.bgBase
      border.color: root.theme.bgBorder
      border.width: 1
      focus: true
      Keys.onEscapePressed: { if (!root.isApplying) root.cancelChanges(); }

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

          // Grouped rather than two children of the header row, whose spacing
          // is 12 -- the icon belongs to the word, not to the tab strip.
          RowLayout {
            spacing: 6

            Icon {
              name: "cog"
              color: root.theme.accentPrimary
              size: 14
            }

            Text {
              text: "Settings"
              color: root.theme.accentPrimary
              font { pixelSize: 14; bold: true; family: root.font }
            }
          }

          // Tabs. Two of them is barely a tab strip, but the monitor canvas
          // wants the whole card and anything else in the panel would be
          // squeezed in beside it.
          Repeater {
            model: [{ id: "monitors",   icon: "monitor-multiple", label: "Monitors" },
                    { id: "appearance", icon: "format-paint",     label: "Appearance" }]

            IconButton {
              required property var modelData
              readonly property bool current: root.tab === modelData.id

              height: 26
              theme:      root.theme
              font:       root.font
              icon:       modelData.icon
              label:      modelData.label
              iconSize:   11
              iconColor:  current ? root.theme.bgBase : root.theme.textSecondary
              baseColor:  current ? root.theme.accentPrimary : root.theme.bgSurface
              hoverColor: current ? root.theme.accentPrimary : root.theme.bgHover
              onClicked:  root.tab = modelData.id
            }
          }

          Item { Layout.fillWidth: true }

          // Refresh button
          IconButton {
            Layout.preferredWidth: 28; Layout.preferredHeight: 28
            visible:   root.tab === "monitors"
            circular:  true
            theme:     root.theme
            font:      root.font
            icon:      "refresh"
            iconColor: MonitorService.loading ? root.theme.textMuted : root.theme.textSecondary
            onClicked: MonitorService.refresh()
          }

          // The other four panels have carried one of these for a while; this
          // was the only one where escape was the only way out, which is not
          // discoverable and is no use at all to a pointer.
          //
          // Goes through cancelChanges() rather than setting isOpen directly,
          // so it obeys the same guard escape does: an apply in flight is not
          // interruptible, and closing over one would leave the panel's edit
          // state and the compositor disagreeing about what was applied.
          CloseButton {
            theme: root.theme
            font: root.font
            onClicked: root.cancelChanges()
          }
        }

        // Content: canvas + panel
        RowLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          visible: root.tab === "monitors"
          spacing: 12

          MonitorCanvas {
            id: canvas
            Layout.fillWidth: true
            Layout.fillHeight: true
            monitors:      root.editState
            selectedIndex: root.selectedIndex
            theme:         root.theme
            font:          root.font

            onMonitorSelected: idx => root.selectedIndex = idx
            onMonitorMoved: (idx, nx, ny) => {
              const copy = root.editState.slice();
              copy[idx] = Object.assign({}, root.editState[idx], { x: nx, y: ny });
              root.editState = copy;
            }
          }

          MonitorPanel {
            id: panel
            Layout.preferredWidth: 260
            Layout.fillHeight: true
            visible: root.selectedIndex >= 0 && root.editState.length > 0

            monitor:     visible ? root.editState[root.selectedIndex] : null
            allMonitors: root.editState
            theme:       root.theme
            font:        root.font

            onModeSelected:     mode    => root.onModeSelected(mode)
            onScaleSelected:    scale   => root.onScaleChanged(scale)
            onTransformChanged: t       => root.onTransformChanged(t)
            onEnableToggled:    enabled => root.onEnabledChanged(enabled)
            onMirrorChanged:    name    => root.onMirrorChanged(name)
          }
        }

        // Appearance tab: shell settings, none of which the compositor has an
        // opinion about. They apply the moment they are clicked -- there is no
        // Apply here, because unlike a monitor layout none of this can leave
        // you looking at a black screen.
        ColumnLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          visible: root.tab === "appearance"
          spacing: 12

          Text {
            text: "Bar"
            color: root.theme.textSecondary
            font { pixelSize: 11; family: root.font }
          }

          // Alphas, not a level: 0 means no strip at all, and the bar becomes
          // its pills over the wallpaper.
          OptionRow {
            theme: root.theme
            font:  root.font
            label: "opacity"
            options: [{ value: 0,    label: "0%"   }, { value: 0.25, label: "25%"  },
                      { value: 0.5,  label: "50%"  }, { value: 0.75, label: "75%"  },
                      { value: 1,    label: "100%" }]
            current: BarSettings.barOpacity
            onPicked: value => BarSettings.setBarOpacity(value)
          }

          // The pill backgrounds only. Their contents keep full contrast at any
          // setting, so this thins the chrome and not the readouts.
          OptionRow {
            theme: root.theme
            font:  root.font
            label: "pills"
            options: [{ value: 0,    label: "0%"   }, { value: 0.25, label: "25%"  },
                      { value: 0.5,  label: "50%"  }, { value: 0.75, label: "75%"  },
                      { value: 1,    label: "100%" }]
            current: BarSettings.pillOpacity
            onPicked: value => BarSettings.setPillOpacity(value)
          }

          // Hyprland's, not the shell's: one flag for the whole bar surface,
          // because that is the unit the compositor blurs. It skips fully
          // transparent pixels, so at 0% opacity only the pills are frosted.
          OptionRow {
            theme: root.theme
            font:  root.font
            label: "blur"
            options: [{ value: true, label: "on" }, { value: false, label: "off" }]
            current: BarSettings.blur
            onPicked: value => BarSettings.setBlur(value)
          }

          // The same flag `qs ipc call bar toggle` flips, so the panel agrees
          // with the keybind rather than shadowing it. Not saved: see BarSettings.
          OptionRow {
            theme: root.theme
            font:  root.font
            label: "visible"
            options: [{ value: true, label: "shown" }, { value: false, label: "hidden" }]
            current: BarSettings.barVisible
            onPicked: value => BarSettings.barVisible = value
          }

          Divider { color: root.theme.bgBorder }

          // Which display carries the machine-wide surfaces: the bar's status
          // pills and tray, and the notification popups. Not a hyprland setting
          // and deliberately not written to monitors.lua -- the compositor has no
          // opinion about it, it is purely where the shell puts things. Only shown
          // on a machine with somewhere else to put them.
          Text {
            text: "Main display"
            visible: Screens.hasChoice
            color: root.theme.textSecondary
            font { pixelSize: 11; family: root.font }
          }

          Flow {
            visible: Screens.hasChoice
            Layout.fillWidth: true
            spacing: 6

            Repeater {
              model: Quickshell.screens

              Rectangle {
                id: screenChip
                required property var modelData

                readonly property bool active: Screens.primaryName === screenChip.modelData.name
                // The configured display being absent is why `primary` falls
                // back, and the fallback is worth saying out loud rather than
                // leaving a chip that looks unselected for no visible reason.
                readonly property bool standingIn:
                  !Screens.primaryPresent && Screens.primary === screenChip.modelData

                implicitWidth: screenChipText.implicitWidth + 20
                implicitHeight: 26
                radius: 8
                color: screenChip.active ? root.theme.bgSelected
                     : screenChipHover.containsMouse ? root.theme.bgHover
                     : root.theme.bgSurface
                border.width: (screenChip.active || screenChip.standingIn) ? 1 : 0
                border.color: screenChip.active ? root.theme.accentPrimary
                                                : root.theme.accentOrange

                Accessible.role: Accessible.RadioButton
                Accessible.name: screenChip.modelData.name
                                 + (screenChip.active ? ", main display"
                                    : screenChip.standingIn ? ", standing in for "
                                                              + Screens.primaryName : "")

                Row {
                  id: screenChipText
                  anchors.centerIn: parent
                  spacing: 6

                  Icon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "monitor"
                    color: screenChip.active ? root.theme.accentPrimary
                         : screenChip.standingIn ? root.theme.accentOrange
                         : root.theme.textMuted
                    size: 12
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: screenChip.modelData.name
                    color: screenChip.active ? root.theme.textPrimary : root.theme.textSecondary
                    font { pixelSize: 11; family: root.font }
                  }
                }

                MouseArea {
                  id: screenChipHover
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: Screens.select(screenChip.modelData.name)
                }
              }
            }
          }

          // Settings sit at the top of the card; the canvas is what earns the
          // rest of the height, and this tab does not have one.
          Item { Layout.fillHeight: true }
        }

        // Persist warning banner
        Rectangle {
          Layout.fillWidth: true
          visible: root.persistWarning && root.tab === "monitors"
          Layout.preferredHeight: 40
          radius: 8
          color: Qt.rgba(root.theme.accentOrange.r, root.theme.accentOrange.g, root.theme.accentOrange.b, 0.12)
          border.color: root.theme.accentOrange
          border.width: 1

          RowLayout {
            anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
            spacing: 8

            Text {
              Layout.fillWidth: true
              // hyprland.lua lives read-only in the Nix store now and
              // unconditionally dofiles monitors.lua back in, so there is no
              // line left for a user to add. The only thing that makes this
              // check fail is the state directory itself being missing, so
              // name that directory -- it's the one thing a user can act on.
              text: "Persistence disabled — state directory " + Paths.hyprStateDir + " is missing."
              color: root.theme.accentOrange
              font { pixelSize: 11; family: root.font }
              elide: Text.ElideRight
            }

            Text {
              text: "✕"
              color: root.theme.accentOrange
              font { pixelSize: 11; family: root.font }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.persistWarning = false
              }
            }
          }
        }

        // Hotplug / external change banner
        Rectangle {
          Layout.fillWidth: true
          visible: root.hotplugDetected && root.tab === "monitors"
          Layout.preferredHeight: 40
          radius: 8
          color: Qt.rgba(root.theme.accentCyan.r, root.theme.accentCyan.g, root.theme.accentCyan.b, 0.12)
          border.color: root.theme.accentCyan
          border.width: 1

          RowLayout {
            anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
            spacing: 8

            Text {
              Layout.fillWidth: true
              text: "A display was connected or disconnected."
              color: root.theme.accentCyan
              font { pixelSize: 11; family: root.font }
            }

            IconButton {
              Layout.preferredHeight: 24; radius: 6
              theme:     root.theme
              font:      root.font
              label:     "Ignore"
              iconSize:  11
              iconColor: root.theme.textPrimary
              baseColor: root.theme.bgSurface
              onClicked: root.hotplugDetected = false
            }

            IconButton {
              Layout.preferredHeight: 24; radius: 6
              theme:      root.theme
              font:       root.font
              label:      "Reload layout"
              iconSize:   11
              iconColor:  root.theme.bgBase
              baseColor:  root.theme.accentCyan
              hoverColor: root.theme.accentCyan
              onClicked: {
                root.hotplugDetected = false;
                root.initEditState();
              }
            }
          }
        }

        // Error banner
        Rectangle {
          id: errorBanner
          Layout.fillWidth: true
          visible: root.applyError !== "" && root.tab === "monitors"
          Layout.preferredHeight: 40
          radius: 8
          color: Qt.rgba(root.theme.accentRed.r, root.theme.accentRed.g, root.theme.accentRed.b, 0.15)
          border.color: root.theme.accentRed
          border.width: 1

          onVisibleChanged: if (visible) errorDismissTimer.restart()

          Timer {
            id: errorDismissTimer
            interval: 5000
            onTriggered: root.applyError = ""
          }

          RowLayout {
            anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
            spacing: 8

            Text {
              Layout.fillWidth: true
              text: root.applyError
              color: root.theme.accentRed
              font { pixelSize: 11; family: root.font }
              elide: Text.ElideRight
            }

            Text {
              text: "✕"
              color: root.theme.accentRed
              font { pixelSize: 11; family: root.font }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: { errorDismissTimer.stop(); root.applyError = "" }
              }
            }
          }
        }

        // Footer
        RowLayout {
          Layout.fillWidth: true
          spacing: 16

          // The two canvas hints only describe the monitor tab. Escape closes
          // either, so it stays.
          Row {
            spacing: 4
            visible: root.tab === "monitors"
            Rectangle {
              width: hintDrag.width + 8; height: 18; radius: 4; color: root.theme.bgSurface
              Text { id: hintDrag; anchors.centerIn: parent; text: "drag"; color: root.theme.textMuted; font.pixelSize: 10; font.family: root.font }
            }
            Text { text: "arrange"; color: root.theme.textMuted; font.pixelSize: 10; font.family: root.font; anchors.verticalCenter: parent.verticalCenter }
          }

          Row {
            spacing: 4
            visible: root.tab === "monitors"
            Rectangle {
              width: hintClick.width + 8; height: 18; radius: 4; color: root.theme.bgSurface
              Text { id: hintClick; anchors.centerIn: parent; text: "click"; color: root.theme.textMuted; font.pixelSize: 10; font.family: root.font }
            }
            Text { text: "select"; color: root.theme.textMuted; font.pixelSize: 10; font.family: root.font; anchors.verticalCenter: parent.verticalCenter }
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

          RowLayout {
            visible: MonitorService.loading && root.tab === "monitors"
            spacing: 6

            Icon {
              name: "refresh"
              color: root.theme.textMuted
              size: 11
            }

            Text {
              text: "Loading…"
              color: root.theme.textMuted
              font { pixelSize: 11; family: root.font }
            }
          }

          // Appearance has no Apply: every setting there is already live.
          Rectangle {
            visible: root.tab === "monitors"
            Layout.preferredWidth: applyText.width + 24; Layout.preferredHeight: 32; radius: 8
            color: (root.isApplying || MonitorService.loading || root.hasOverlap)
                   ? root.theme.bgSurface : root.theme.accentPrimary
            border.color: root.theme.bgBorder
            border.width: 1
            opacity: (root.isApplying || MonitorService.loading || root.hasOverlap) ? 0.5 : 1.0

            Text {
              id: applyText
              anchors.centerIn: parent
              text: root.isApplying ? "Applying…" : "Apply"
              color: (root.isApplying || MonitorService.loading || root.hasOverlap)
                     ? root.theme.textMuted : root.theme.bgBase
              font { pixelSize: 12; bold: true; family: root.font }
            }
            MouseArea {
              anchors.fill: parent
              cursorShape: (root.isApplying || MonitorService.loading || root.hasOverlap)
                           ? Qt.ArrowCursor : Qt.PointingHandCursor
              enabled: !root.isApplying && !MonitorService.loading && !root.hasOverlap
              onClicked: root.applyChanges()
            }
          }
        }
      }
    }
  }
}
