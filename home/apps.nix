{ config, lib, pkgs, ... }:

let
  # Derived by reading bin/calango-open (eight non-comment lines) and the
  # discover.py it falls back to. Every external command either script can
  # reach, exhaustively:
  #
  #   bin/calango-open   printf   bash builtin here (used only inside the
  #                                script's own `[ -n "$url" ] || { printf ...`
  #                                guard) -- never resolved through PATH, so it
  #                                needs no package of its own.
  #   bin/calango-open   qs       pkgs.quickshell, to reach the running
  #                                instance via `qs ipc call browser open`.
  #   bin/calango-open   python3  the interpreter for the fallback,
  #                                `exec python3 "$discover" --fallback -- ...`.
  #   discover.py:140    gio      pkgs.glib's `gio mime x-scheme-handler/https`
  #                                in registered_handlers() -- the only
  #                                subprocess call in the module. Omitting this
  #                                fails silently: the `except (OSError, ...)`
  #                                around it turns a missing gio into "no
  #                                browsers registered" rather than an error.
  #   discover.py:323    os.execvp(chosen["argv"][0], ...)  the *chosen
  #                                browser itself*, resolved against whatever
  #                                PATH the wrapper below hands it -- not a
  #                                package here on purpose. It is apt's chrome,
  #                                firefox, etc., found by prepending (not
  #                                replacing) PATH, so the ambient session's
  #                                browsers stay reachable.
  #
  # python3 is plain here, not python3.withPackages (ps: [ ps.pillow ]) the way
  # home/quickshell.nix wraps it for the compositor's copy of this same
  # discover.py. Reading discover.py end to end shows its imports are stdlib
  # only (configparser, json, os, re, shlex, subprocess, tempfile) -- pillow
  # belongs to wallpaper/generate-abstract.py alone, and home/quickshell.nix's
  # comment on runtimeDeps says so too. A plain interpreter is enough for
  # every path calango-open can take.
  calangoOpenPath = lib.makeBinPath (with pkgs; [
    quickshell # qs, bin/calango-open's primary path to the running shell
    python3    # the fallback interpreter; plain, see comment above
    glib       # gio, discover.py's registered_handlers()
  ]);

  binConfig = pkgs.runCommand "calango-bin" { } ''
    mkdir -p "$out"
    cp ${./../bin/calango-open} "$out/calango-open"
    chmod u+w "$out/calango-open"

    substituteInPlace "$out/calango-open" \
      --replace-fail '@quickshellSource@' '${config.calango.quickshellConfig}'

    if grep -q '@[a-zA-Z]*@' "$out/calango-open"; then
      echo "unsubstituted token left in calango-open:" >&2
      grep -n '@[a-zA-Z]*@' "$out/calango-open" >&2
      exit 1
    fi
  '';

  # No QS_CONFIG_PATH. This shim is launched by xdg-desktop-portal and inherits
  # nothing from the compositor, so it once had to name quickshell's config
  # itself or `qs ipc call browser open` would fail with "Could not find
  # 'default' config directory" -- the defect that left every IPC bind dead
  # from spec 2 until spec 3 found it.
  #
  # It no longer has to. quickshell.service reads ~/.config/quickshell/shell.qml
  # (see home/quickshell.nix), which IS the default a bare `qs` looks for, so
  # this shim needs no more environment than any other caller. Naming the store
  # path here would reintroduce the staleness that killed the compositor's
  # binds: this wrapper is rebuilt on every switch, but a long-lived portal
  # process that spawned before one would still hold the old path.
  calangoOpen = pkgs.writeShellScriptBin "calango-open" ''
    export PATH=${calangoOpenPath}''${PATH:+:$PATH}
    exec ${binConfig}/calango-open "$@"
  '';

  # Not writeShellScriptBin: bin/code carries its own `#!/usr/bin/env bash`
  # shebang, and wrapping would give it two. patchShebangs points it at Nix's
  # bash so it does not depend on Debian's /usr/bin/env resolution.
  codeShim = pkgs.runCommand "calango-code" { nativeBuildInputs = [ pkgs.bash ]; } ''
    mkdir -p "$out/bin"
    install -m555 ${./../bin/code} "$out/bin/code"
    patchShebangs "$out/bin/code"
  '';

  desktopEntries = pkgs.runCommand "calango-desktop-entries" { } ''
    mkdir -p "$out"
    cp ${./../data/eu.calangotech.CalangoOpen.desktop} "$out/eu.calangotech.CalangoOpen.desktop"
    cp ${./../data/code.desktop} "$out/code.desktop"
    chmod u+w "$out"/*.desktop

    substituteInPlace "$out/eu.calangotech.CalangoOpen.desktop" \
      --replace-fail '@calangoOpen@' '${calangoOpen}/bin/calango-open'

    substituteInPlace "$out/code.desktop" \
      --replace-fail 'Exec=@codeShim@ %F' 'Exec=${codeShim}/bin/code %F' \
      --replace-fail 'Exec=@codeShim@ --new-window %F' 'Exec=${codeShim}/bin/code --new-window %F'

    for f in "$out"/*.desktop; do
      if grep -q '@[a-zA-Z]*@' "$f"; then
        echo "unsubstituted token left in $f:" >&2
        grep -n '@[a-zA-Z]*@' "$f" >&2
        exit 1
      fi
    done
  '';
in
{
  config.home.packages = [ calangoOpen codeShim ];

  # uwsm sources this from `uwsm aux prepare-env` before the compositor
  # starts. There is no flag for its location; it must be at this path.
  config.xdg.configFile."uwsm/env".source = ./../uwsm/env;

  # Individual files, NOT the trees. ~/.config/autostart holds five entries
  # this repository does not own (1password, bitwarden, deskflow,
  # syncthingtray, displaycal) and pipewire-pulse.conf.d is a drop-in
  # directory distribution packages also write into. Linking either directory
  # would replace it with a symlink and hide everything already there.
  config.xdg.configFile."autostart/im-launch.desktop".source =
    ./../autostart/im-launch.desktop;
  config.xdg.configFile."autostart/org.kde.xwaylandvideobridge.desktop".source =
    ./../autostart/org.kde.xwaylandvideobridge.desktop;
  config.xdg.configFile."pipewire/pipewire-pulse.conf.d/20-block-source-volume.conf".source =
    ./../pipewire/20-block-source-volume.conf;

  # ~/.local/share/applications, not the profile's share tree. Spec 1 proved
  # XDG_DATA_DIRS works for wayland-sessions, but MIME handling needs a
  # mimeinfo.cache in the same directory as the entry, and Home Manager builds
  # none for ~/.nix-profile/share/applications.
  config.xdg.dataFile."applications/eu.calangotech.CalangoOpen.desktop".source =
    "${desktopEntries}/eu.calangotech.CalangoOpen.desktop";
  config.xdg.dataFile."applications/code.desktop".source =
    "${desktopEntries}/code.desktop";

  # Without this the entry above is present but not discoverable, so the
  # default-browser hook below would set a handler nothing can resolve.
  #
  # entryAfter "linkGeneration", not "writeBoundary": linkGeneration is what
  # actually creates ~/.local/share/applications/eu.calangotech.CalangoOpen.desktop
  # (the xdg.dataFile above), and Home Manager's generated activate sorts it
  # dead last -- after writeBoundary, gtkAppearance, installPackages, and this
  # hook's old position. On a first switch, running this before linkGeneration
  # would rebuild mimeinfo.cache from a directory that does not yet contain the
  # entry, silently omitting CalangoOpen with nothing on stderr, and the
  # defaultBrowser hook below would then fail to resolve it too.
  config.home.activation.desktopDatabase =
    lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      run ${pkgs.desktop-file-utils}/bin/update-desktop-database \
        ${lib.escapeShellArg "${config.xdg.dataHome}/applications"} \
        || echo "update-desktop-database failed; the browser handler may not resolve" >&2
    '';

  # Warn when ~/.config/mimeapps.list names a .desktop id that neither
  # XDG_DATA_DIRS nor $HOME/.local/share provides any more. The loop below
  # searches both, and the second is the load-bearing half: measured on this
  # machine XDG_DATA_DIRS is
  # ~/.nix-profile/share:...flatpak...:/usr/local/share:/usr/share, with no
  # ~/.local/share on it at all -- and ~/.local/share/applications is exactly
  # where this module's own xdg.dataFile entries land, CalangoOpen included.
  # A search of XDG_DATA_DIRS alone would report this flake's own default
  # browser as missing.
  #
  # Non-fatal, deliberately. Measured on the live file: 12 assignment lines
  # (10 under [Default Applications], 2 under [Added Associations]) naming 6
  # unique ids, and only one of those six is this flake's -- the rest are
  # flatpak Slack, bitwarden, claude-code-url-handler and Signal, whose
  # absence is none of this flake's business and must never abort a switch.
  # Both counts are of 2026-08-17, not standing properties: bitwarden and
  # signal-desktop are among the follow-on applications this project intends
  # to migrate. The fatal half of this property is flake.nix's
  # gui-desktop-ids, which asserts only what the flake itself ships.
  #
  # This is the layer that can see the live file at all: a flake check runs in
  # the Nix sandbox, where ~/.config and /usr/share are both invisible.
  #
  # Ordering: three `after` edges, all real, none of them inherited from an
  # attribute name.
  #
  #   linkGeneration   creates ~/.local/share/applications/*.desktop from the
  #                    xdg.dataFile entries above -- half the search path.
  #   installPackages  builds ~/.nix-profile, and so populates
  #                    ~/.nix-profile/share/applications, the first entry on
  #                    XDG_DATA_DIRS -- the other half.
  #   defaultBrowser   rewrites the very file this hook reads, via
  #                    `xdg-settings set default-web-browser`. Reading it
  #                    first would report on the pre-switch contents.
  #
  # Naming all three matters because Home Manager's hm.dag.topoSort feeds
  # builtins.attrValues -- attribute-name sorted -- into a stable
  # lib.toposort, so any pair of entries with no stated relation is ordered
  # alphabetically. Measured in the built activate before this was declared,
  # every hook after linkGeneration sat in exactly alphabetical order:
  # defaultBrowser, desktopDatabase, footThemeColors, gtkAppearance,
  # hyprlockConf, installPackages, mimeappsIds, onFilesChange. So "mimeappsIds"
  # ran last of the three only because the letter m sorts after d and i;
  # renaming this attribute to anything sorting earlier -- checkMimeappsIds,
  # auditMimeapps -- would have moved it silently ahead of both, and it would
  # then have reported against a search path not yet built and a file not yet
  # rewritten, with nothing to distinguish that from a genuine finding. This
  # is the same defect home/audio.nix's pipewireSessionManagerAlias paid for.
  #
  # entryAfter and not entryBetween, unlike that precedent, and the difference
  # is that there the second edge was real: reloadSystemd had to come after
  # the alias link or systemd would never see it. Here nothing downstream
  # reads anything this hook produces -- it only writes warnings to stderr --
  # so the `before` list would be empty, and entryBetween [] xs is by
  # definition entryAfter xs. Declaring an empty edge would state a constraint
  # that does not exist. The fragility this fixes was entirely on the `after`
  # side, and all three of those are now stated.
  config.home.activation.mimeappsIds =
    lib.hm.dag.entryAfter [ "linkGeneration" "installPackages" "defaultBrowser" ] ''
      run ${pkgs.bash}/bin/sh -c '
        list="$HOME/.config/mimeapps.list"
        [ -r "$list" ] || exit 0
        missing=0
        ids=$(sed -n "s/^[^=]*=//p" "$list" | tr ";" "\n" | sed "/^$/d" | sort -u)
        for id in $ids; do
          found=0
          IFS=":"
          for d in $XDG_DATA_DIRS $HOME/.local/share; do
            [ -e "$d/applications/$id" ] && { found=1; break; }
          done
          unset IFS
          [ "$found" -eq 1 ] || { echo "mimeapps.list names a missing .desktop id: $id" >&2; missing=$((missing+1)); }
        done
        [ "$missing" -eq 0 ] || echo "$missing unresolved id(s) in mimeapps.list -- handlers for them will do nothing" >&2
      ' || true
    '';

  # Displaces the stale root-owned eu.calangotech.KBrowserSelector.desktop
  # that currently holds http/https on this machine. Deliberately not
  # xdg.mimeApps: that would freeze ~/.config/mimeapps.list, which holds six
  # associations (slack, bitwarden, claude-cli, signal x2) this repository
  # does not own, and no application could ever set a default again.
  config.home.activation.defaultBrowser =
    lib.hm.dag.entryAfter [ "desktopDatabase" ] ''
      previous=$(${pkgs.xdg-utils}/bin/xdg-settings get default-web-browser 2>/dev/null || true)
      if [ "$previous" != "eu.calangotech.CalangoOpen.desktop" ]; then
        run ${pkgs.xdg-utils}/bin/xdg-settings set default-web-browser \
          eu.calangotech.CalangoOpen.desktop \
          || echo "could not set the default browser (was: $previous)" >&2
      fi
    '';
}
