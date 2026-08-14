pragma Singleton

import Quickshell
import Quickshell.Io
import QtQuick
import "../common"

Singleton {
    id: root

    // Only consumed by applyHyprlockTheme -- the shell's own widgets take their
    // font from each module. hyprlock has no fontconfig fallback worth relying
    // on, so it gets told explicitly.
    property string font: "AdwaitaMono Nerd Font"

    property int currentIndex: 0
    property int previewIndex: -1
    property bool wallpaperFeatureEnabled: true
    property bool wallpaperMode: false
    property var wallpaperTheme: ({})
    readonly property var current: {
        if (previewIndex >= 0 && previewIndex < themes.length)
            return themes[previewIndex];
        if (wallpaperMode && wallpaperTheme && wallpaperTheme.bgBase)
            return wallpaperTheme;
        return themes[currentIndex];
    }
    readonly property int count: themes.length
    readonly property string currentName: current.name
    readonly property string currentFamily: current.family
    readonly property bool isDark: !isLightColor(current.bgBase)

    function isLightColor(hex) {
        hex = hex.toString().replace("#", "");
        var r = parseInt(hex.substr(0, 2), 16);
        var g = parseInt(hex.substr(2, 2), 16);
        var b = parseInt(hex.substr(4, 2), 16);
        return (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.5;
    }

    function applySystemColorScheme(dark) {
        colorSchemeProc.command = ["gsettings", "set",
            "org.gnome.desktop.interface", "color-scheme",
            dark ? "prefer-dark" : "prefer-light"];
        colorSchemeProc.running = true;
    }

    // Reactive color properties — same API as before
    readonly property color bgBase:       current.bgBase
    readonly property color bgSurface:    current.bgSurface
    readonly property color bgHover:      current.bgHover
    readonly property color bgSelected:   current.bgSelected
    readonly property color bgBorder:     current.bgBorder
    readonly property color bgOverlay:    "#88000000"

    readonly property color textPrimary:   current.textPrimary
    readonly property color textSecondary: current.textSecondary
    readonly property color textMuted:     current.textMuted

    readonly property color accentPrimary: current.accentPrimary
    readonly property color accentCyan:    current.accentCyan
    readonly property color accentGreen:   current.accentGreen
    readonly property color accentOrange:  current.accentOrange
    readonly property color accentRed:     current.accentRed

    // Semantic aliases
    readonly property color urgencyLow:      textMuted
    readonly property color urgencyNormal:   accentPrimary
    readonly property color urgencyCritical: accentRed
    readonly property color batteryGood:     accentGreen
    readonly property color batteryWarning:  accentOrange
    readonly property color batteryCritical: accentRed

    function hexToRgba(hex) {
        return "rgba(" + hex.toString().replace("#", "") + "ff)";
    }

    function applyHyprlandBorders(t) {
        // Fade the accent into the theme's own neutral rather than into a second
        // accent: accentPrimary is yellow in Monokai but blue in Tokyo Night and
        // Catppuccin, so any fixed accent pairing harmonises in some themes and
        // clashes in others. bgBorder works in all of them, and landing on the
        // inactive colour makes the gradient read as a directional glow.
        var from = hexToRgba(t.accentPrimary);
        var to = hexToRgba(t.bgBorder);
        var active = from + " " + to + " 45deg";
        var inactive = to;

        // Two halves, and they are not redundant. theme-borders.conf is what
        // hyprland.lua reads at startup so the theme survives a reload; the eval
        // is what updates the running compositor now. `hyprctl keyword` is NOT
        // usable here -- under the Lua parser it refuses with "keyword can't work
        // with non-legacy parsers" while still exiting 0, so it fails silently.
        var lua = 'hl.config({ general = { col = {' +
            ' active_border = { colors = {"' + from + '", "' + to + '"}, angle = 45 },' +
            ' inactive_border = "' + inactive + '" } } })';

        // Values go in as positional args so no colour is interpolated into shell
        // quoting.
        hyprlandProc.command = ["sh", "-c",
            'printf "general {\\n    col.active_border = %s\\n    col.inactive_border = %s\\n}\\n"' +
            ' "$1" "$2" > "' + Paths.hyprStateDir + '/theme-borders.conf"; ' +
            'hyprctl eval "$3" >/dev/null',
            "sh", active, inactive, lua
        ];
        hyprlandProc.running = true;
    }

    // hyprlock parses colours as rgb(rrggbb), not #rrggbb.
    function hexToHyprlock(hex) {
        return "rgb(" + hex.toString().replace("#", "") + ")";
    }

    // hyprlock reads its config once, at launch, so this only has to be on disk
    // before the screen locks -- there is nothing running to update. hypridle
    // starts it via `loginctl lock-session`, five minutes after you walk away.
    function applyHyprlockTheme(t) {
        // Clock and password field go on one screen; the background still covers
        // every output, so the others are wallpaper and nothing else.
        //
        // Screens.primary is the *resolved* display, not the configured name, and
        // that distinction is the whole safety story here: naming a monitor that
        // is unplugged when the screen locks would leave you with no password
        // field to type into. The resolver falls back to the first connected
        // screen, and the empty string below -- hyprlock's "all monitors" -- is
        // the last resort if it somehow resolves to nothing at all.
        const primary = Screens.primary ? Screens.primary.name : "";

        const conf = [
            '# Generated by the quickshell theme switcher on every theme change',
            '# (theme-switcher/Theme.qml -> applyHyprlockTheme). Edits here are lost.',
            '',
            '$font = ' + root.font,
            '',
            'general {',
            '    hide_cursor = true',
            '}',
            '',
            'animations {',
            '    enabled = true',
            '    bezier = linear, 1, 1, 0, 0',
            '    animation = fadeIn, 1, 5, linear',
            '    animation = fadeOut, 1, 5, linear',
            '    animation = inputFieldDots, 1, 2, linear',
            '}',
            '',
            'background {',
            '    monitor =',
            // WALLPAPER_PATH is substituted by the writer below. Deliberately not
            // `path = screenshot`, which the shipped sample uses: a blurred
            // screenshot still leaks the shape of whatever you left on screen,
            // and a lock screen is exactly where that matters. Falls back to the
            // theme's own background when no wallpaper is set.
            '    path = WALLPAPER_PATH',
            '    color = ' + hexToHyprlock(t.bgBase),
            '    blur_passes = 3',
            '    blur_size = 6',
            '}',
            '',
            'input-field {',
            '    monitor = ' + primary,
            '    size = 320, 52',
            '    outline_thickness = 2',
            '    inner_color = ' + hexToHyprlock(t.bgSurface),
            '    outer_color = ' + hexToHyprlock(t.accentPrimary),
            '    check_color = ' + hexToHyprlock(t.accentCyan),
            '    fail_color = ' + hexToHyprlock(t.accentRed),
            '    font_color = ' + hexToHyprlock(t.textPrimary),
            '    font_family = $font',
            '    placeholder_text = Password',
            '    fail_text = $PAMFAIL',
            '    rounding = 12',
            '    fade_on_empty = false',
            '    dots_spacing = 0.3',
            '    position = 0, -80',
            '    halign = center',
            '    valign = center',
            '}',
            '',
            'label {',
            '    monitor = ' + primary,
            '    text = $TIME',
            '    color = ' + hexToHyprlock(t.textPrimary),
            '    font_size = 88',
            '    font_family = $font',
            '    position = 0, 140',
            '    halign = center',
            '    valign = center',
            '}',
            '',
            'label {',
            '    monitor = ' + primary,
            '    text = cmd[update:60000] date +"%A, %d %B"',
            '    color = ' + hexToHyprlock(t.textSecondary),
            '    font_size = 20',
            '    font_family = $font',
            '    position = 0, 60',
            '    halign = center',
            '    valign = center',
            '}',
            ''
        ].join("\n");

        // The wallpaper path is resolved in the shell rather than in QML so this
        // does not have to reach across into the wallpaper module for one string.
        hyprlockProc.command = ["sh", "-c",
            'wp=$(cat "${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/wallpaper.conf" 2>/dev/null); ' +
            '[ -n "$wp" ] && [ -f "$wp" ] || wp=""; ' +
            'printf "%s" "$1" | sed "s|^    path = WALLPAPER_PATH$|    path = $wp|" ' +
            '> "' + Paths.hyprStateDir + '/hyprlock.conf"',
            "sh", conf
        ];
        hyprlockProc.running = true;
    }

    // The hyprlock config names a specific output, so it goes stale the moment
    // the monitor set changes -- and it is written long before it is read, since
    // hyprlock only starts when the screen locks. Rewriting it here means the
    // file on disk always names a display that exists.
    //
    // Only hyprlock needs this. Kitty and the hyprland borders are not
    // per-monitor, and applyTheme would drag them along for nothing.
    Connections {
        target: Screens
        function onPrimaryChanged() { root.applyHyprlockTheme(root.current); }
    }

    function applyTheme(t) {
        applyFootTheme(t);
        applySystemColorScheme(!isLightColor(t.bgBase));
        applyHyprlandBorders(t);
        applyHyprlockTheme(t);
    }

    function setTheme(index) {
        if (index >= 0 && index < themes.length) {
            wallpaperMode = false;
            currentIndex = index;
            saveProc.command = ["sh", "-c", 'printf "%s" "$1" > "${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/theme.conf"', "sh", String(index)];
            saveProc.running = true;
            applyTheme(themes[index]);
        }
    }

    function setWallpaperMode() {
        if (!wallpaperFeatureEnabled)
            return;
        wallpaperMode = true;
        saveProc.command = ["sh", "-c", 'printf "%s" wallpaper > "${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/theme.conf"'];
        saveProc.running = true;
        if (wallpaperTheme && wallpaperTheme.bgBase)
            applyTheme(wallpaperTheme);
    }

    // Regenerate the wallpaper palette from a given image, then switch to wallpaper
    // mode. set.sh writes wallpaper-theme.json, which the FileView below live-reloads
    // and applies. Without an image this is equivalent to setWallpaperMode().
    function setWallpaperFromImage(img) {
        if (!wallpaperFeatureEnabled)
            return;
        if (img && img.length > 0) {
            generateProc.command = ["sh", Paths.sourceDir + "/theme-switcher/wallpaper-theme/set.sh", img];
            generateProc.running = true;
        }
        setWallpaperMode();
    }

    // The same palette in foot's spelling, written to foot/theme-colors.ini,
    // which foot.ini includes after its themes/*.ini default.
    //
    // No live half: foot has neither remote control nor a config reload, so a
    // running window keeps the colours it started with and only new ones pick
    // this up. That is a foot limitation, not a shortcut -- the alternative is
    // injecting OSC 4/10/11 into every foot's pts, which would interleave with
    // whatever is running in it.
    //
    // [colors-dark], and one section rather than one per light/dark. This
    // writes one palette at a time -- whichever theme is selected -- so a
    // dark/light split would not be carrying information. colors-dark is the
    // section foot uses unless initial-color-theme=light is set, and nothing
    // here sets it or binds foot's light/dark toggle, so the selected palette
    // is always the one in effect.
    //
    // This said [colors] until the Nix port. That was correct while Debian's
    // foot 1.21 was the one reading it: 1.21 rejects "[colors-dark]" as an
    // invalid section name and then refuses the whole config, so every window
    // came up unthemed. foot 1.27 inverted it -- [colors] still works but is
    // deprecated, and warns once per section entry on every start, which was
    // 22 lines of stderr per foot launch here.
    //
    // The version that reads this file now comes from the flake, so it cannot
    // be older than the flake's pin. Keep that in mind before copying this
    // section back to a tree whose foot comes from apt.
    function applyFootTheme(t) {
        function h(c) { return String(c).replace("#", ""); }
        var footConf = [
            "[colors-dark]",
            "foreground=" + h(t.textPrimary),
            "background=" + h(t.bgBase),
            "selection-foreground=" + h(t.textPrimary),
            "selection-background=" + h(t.bgSelected),
            "urls=" + h(t.accentCyan),
            "regular0=" + h(t.bgSurface),
            "regular1=" + h(t.accentRed),
            "regular2=" + h(t.accentGreen),
            "regular3=" + h(t.accentOrange),
            "regular4=" + h(t.accentPrimary),
            "regular5=" + h(t.accentPrimary),
            "regular6=" + h(t.accentCyan),
            "regular7=" + h(t.textSecondary),
            "bright0=" + h(t.textMuted),
            "bright1=" + h(t.accentRed),
            "bright2=" + h(t.accentGreen),
            "bright3=" + h(t.accentOrange),
            "bright4=" + h(t.accentPrimary),
            "bright5=" + h(t.accentPrimary),
            "bright6=" + h(t.accentCyan),
            "bright7=" + h(t.textPrimary)
            // No cursor colour: `[cursor] color` is gone in foot 1.27 and
            // `cursor=` under [colors] does not exist in 1.21, so either
            // spelling makes the other foot reject the whole config. foot
            // falls back to foreground/background reversed, which follows the
            // palette written above on its own.
        ].join("\n");
        footProc.command = ["sh", "-c",
            "printf '%s\\n' '" + footConf + "' > '" + Paths.footStateDir + "/theme-colors.ini'"
        ];
        footProc.running = true;
    }

    Process { id: saveProc; running: false }
    Process { id: generateProc; running: false }
    Process { id: footProc; running: false }
    Process { id: colorSchemeProc; running: false }
    Process { id: hyprlandProc; running: false }
    Process { id: hyprlockProc; running: false }

    Process {
        id: loadProc
        command: ["sh", "-c", "cat ${XDG_STATE_HOME:-$HOME/.local/state}/quickshell/theme.conf 2>/dev/null"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                const raw = text.trim();
                if (raw === "wallpaper" && root.wallpaperFeatureEnabled) {
                    root.wallpaperMode = true;
                    if (root.wallpaperTheme && root.wallpaperTheme.bgBase)
                        root.applyTheme(root.wallpaperTheme);
                    else
                        // wallpaper-theme.json missing/empty yet — show a visible
                        // default until a wallpaper hook regenerates it (the FileView
                        // re-applies once wallpaperTheme populates).
                        root.applyTheme(root.themes[0]);
                    return;
                }
                const idx = parseInt(raw);
                if (!isNaN(idx) && idx >= 0 && idx < root.themes.length) {
                    root.wallpaperMode = false;
                    root.currentIndex = idx;
                    root.applyTheme(root.themes[idx]);
                } else if (raw === "wallpaper") {
                    // Persisted wallpaper choice but the feature is disabled —
                    // fall back to the curated default.
                    root.wallpaperMode = false;
                    root.applyTheme(root.themes[root.currentIndex]);
                }
            }
        }
    }

    // Live-reloads the wallpaper-generated palette. When in wallpaper mode, a new
    // wallpaper (and a fresh wallpaper-theme.json) repaints the shell instantly.
    FileView {
        id: wallpaperThemeFile
        path: Paths.stateDir + "/theme-switcher/wallpaper-theme.json"
        watchChanges: true

        // True only for live, on-disk rewrites (set.sh executed) — not the initial
        // load at startup. A fresh palette means a new wallpaper was set, so we
        // switch the switcher into wallpaper mode rather than just repainting.
        property bool liveChange: false
        onFileChanged: { liveChange = true; reload(); }

        onTextChanged: {
            const raw = wallpaperThemeFile.text();
            if (!raw) return;
            try {
                root.wallpaperTheme = JSON.parse(raw);
                if (wallpaperThemeFile.liveChange && root.wallpaperTheme.bgBase)
                    root.setWallpaperMode();
                else if (root.wallpaperMode && root.wallpaperTheme.bgBase)
                    root.applyTheme(root.wallpaperTheme);
            } catch (e) {
                console.error("Failed to parse wallpaper-theme.json:", e);
            } finally {
                wallpaperThemeFile.liveChange = false;
            }
        }
    }

    FileView {
        id: themesFile
        path: Paths.sourceDir + "/theme-switcher/themes.json"
        onTextChanged: {
            const raw = themesFile.text();
            if (!raw) return;
            try {
                root.themes = JSON.parse(raw);
                loadProc.running = true;
            } catch (e) {
                console.error("Failed to parse themes.json:", e);
            }
        }
    }

    property var themes: [
        {
            name: "Night", family: "Tokyo Night",
            bgBase: "#1a1b26", bgSurface: "#24283b", bgHover: "#1e2235",
            bgSelected: "#283457", bgBorder: "#32364a",
            textPrimary: "#c0caf5", textSecondary: "#a9b1d6", textMuted: "#565f89",
            accentPrimary: "#7aa2f7", accentCyan: "#7dcfff",
            accentGreen: "#9ece6a", accentOrange: "#ff9e64", accentRed: "#f7768e"
        }
    ]
}
