{ config, lib, pkgs, ... }:

let
  # gsettings comes from Nix's glib rather than Debian's /usr/bin/gsettings,
  # so the script is self-contained. Left unadorned, though, that gsettings
  # cannot reach dconf at all: Nix's glib builds gio with no GSettings backend
  # modules on its own closure, so `gio/modules/` in that glib's lib output is
  # empty, and gsettings silently falls back to GKeyfileSettingsBackend --
  # confirmed with `G_MESSAGES_DEBUG=all gsettings ...`, which prints "Found
  # default implementation keyfile (GKeyfileSettingsBackend) for
  # 'gsettings-backend'". That backend writes
  # ~/.config/glib-2.0/settings/keyfile, a file nothing else reads: the
  # portal, libadwaita and every Debian GTK app read dconf. The two stores
  # had already diverged before this was caught --
  # org.gnome.desktop.interface cursor-theme was 'Adwaita' via this
  # gsettings and 'default' via /usr/bin/gsettings.
  #
  # GIO_EXTRA_MODULES points gio at dconf's own GIO module
  # (pkgs.dconf.lib/lib/gio/modules, which does contain libdconfsettings.so),
  # which is what makes this gsettings pick the dconf backend and land in the
  # same database Debian's GTK applications read.
  gsettingsSchemas =
    "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/"
    + "${pkgs.gsettings-desktop-schemas.name}/glib-2.0/schemas";

  # Derived by reading gtk/apply-gtk-theme, not transcribed.
  applyPath = lib.makeBinPath (with pkgs; [
    # gsettings :90,95,104-109,119,204,210,412-420 -- hard required, the
    # script `die`s at :90 without it.
    glib

    # cat :43,228,463,519 (usage/managed_keys/gtk2rc/xresources heredocs);
    # mkdir :425,518; head :164; tr :164; rm :296 (inside the EXIT trap, not
    # at command position -- easy to miss with a regex over command words);
    # mktemp :295 (runs unconditionally, including under --check, and the
    # script dies if it fails); cp :430.
    coreutils

    # grep :455 (gtk2 detection via ldconfig -p), :500 (XCURSOR_THEME check
    # in hyprland.lua).
    gnugrep

    # awk :259,264 -- the ini-merge in render_ini().
    gawk

    # sed :163 -- extracting the Inherits= target in resolve_cursor_alias().
    gnused

    # cmp :427 -- skip-if-unchanged compare before overwriting a settings.ini.
    # cmp is diffutils, not coreutils.
    diffutils

    # hyprctl :486-493, guarded by `command -v hyprctl` and
    # HYPRLAND_INSTANCE_SIGNATURE. Included deliberately: this session is
    # inside Hyprland, so the guard would otherwise pass by luck against
    # whatever hyprctl happens to be on the inherited PATH, and its absence
    # would silently drop cursor-size pushes to the compositor with nothing
    # to say why.
    hyprland

    # xrdb :529, guarded by `command -v xrdb` and DISPLAY (XWayland sets
    # DISPLAY in this session). Included for the same reason as hyprctl:
    # optional, but reachable now, so make it reachable on purpose rather
    # than by accident of the inherited PATH.
    xrdb

    # dbus-update-activation-environment :547 -- but only as a `command -v`
    # presence guard. The command actually executed inside that guarded
    # block (:548) is `systemctl --user set-environment`, covered by the
    # systemd entry below. dbus is included so the guard itself doesn't
    # depend on inherited-PATH luck.
    dbus

    # systemctl :548 (`systemctl --user set-environment XCURSOR_THEME=...
    # XCURSOR_SIZE=...`, propagating the cursor to the compositor). Nix's
    # systemd is fine here, unlike the reasoning that used to exclude it:
    # `systemctl --user` is a thin client over
    # $XDG_RUNTIME_DIR/systemd/private, and a Nix build answers identically
    # to Debian's own -- home/quickshell.nix already relies on that same fact
    # for its own `systemctl --user` call. What actually breaks this call is
    # PATH, not which systemd built it: Home Manager's activate script
    # exports a PATH of its own (bash, coreutils, diffutils, findutils,
    # gettext, gnugrep, gnused, jq, ncurses, nix-env's directory) with no
    # /usr/bin on it, so during activation this line has nothing to resolve
    # against unless it is on applyPath -- and the call is wrapped in
    # `2>/dev/null || true`, so a missing systemctl fails silently rather
    # than being noticed. ldconfig (:453, gtk2 detection) and python3 (:372,
    # the `import gi` typelib check) stay deliberately excluded: both are
    # genuine probes of *this host's* own state -- ldconfig of Debian's
    # multiarch filesystem layout, python3 of the host's own GI typelibs --
    # and are reached through the inherited PATH this script's PATH= line
    # appends onto, not a Nix stand-in for either.
    systemd
  ]);

  gtkConfig = pkgs.runCommand "gtk-config" { } ''
    cp -r ${./../gtk} "$out"
    chmod -R u+w "$out"

    substituteInPlace "$out/apply-gtk-theme" \
      --replace-fail '@hyprSource@' '${config.calango.hyprConfig}'

    if [ -f "$out/hosts/${config.calango.host}.conf" ]; then
      substituteInPlace "$out/appearance.conf" \
        --replace-fail '@gtkHostConf@' "$out/hosts/${config.calango.host}.conf"
    else
      substituteInPlace "$out/appearance.conf" \
        --replace-fail '@gtkHostConf@' '/dev/null'
    fi

    # apply-gtk-theme's only literal @ is "''${dd[@]}" -- a bash array
    # expansion, one character, which cannot match a pair. Do not widen.
    for f in "$out/apply-gtk-theme" "$out/appearance.conf"; do
      if grep -q '@[a-zA-Z]*@' "$f"; then
        echo "unsubstituted token left in $f:" >&2
        grep -n '@[a-zA-Z]*@' "$f" >&2
        exit 1
      fi
    done
  '';

  applyGtkTheme = pkgs.writeShellScriptBin "apply-gtk-theme" ''
    export PATH=${applyPath}''${PATH:+:$PATH}
    export GSETTINGS_SCHEMA_DIR=${gsettingsSchemas}
    export GIO_EXTRA_MODULES=${pkgs.dconf.lib}/lib/gio/modules
    exec ${gtkConfig}/apply-gtk-theme "$@"
  '';
in
{
  config.home.packages = [ applyGtkTheme ];

  # Replaces calango-desktop's `make gtk`: pushes the values this repository
  # pins into gsettings, and from there into the ini files GTK actually reads.
  # Hyprland runs no settings daemon, so nothing else bridges the two.
  #
  # Non-fatal. A failing home.activation block aborts the whole switch, and a
  # cosmetic step must not be able to do that. (home/foot.nix's hook is the
  # deliberate exception -- see its comment.)
  config.home.activation.gtkAppearance =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${pkgs.bash}/bin/sh -c '
        . ${gtkConfig}/appearance.conf
        exec ${applyGtkTheme}/bin/apply-gtk-theme \
          --theme "$theme" --icons "$icons" \
          --cursor "$cursor" --cursor-size "$cursor_size" \
          --font "$font" --mono-font "$mono_font"
      ' || echo "apply-gtk-theme failed; GTK appearance not pushed" >&2
    '';
}
