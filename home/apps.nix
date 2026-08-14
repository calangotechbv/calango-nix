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
  # discover.py. That comment in quickshell.nix is inaccurate about
  # discover.py: reading the whole file shows its imports are stdlib only
  # (configparser, json, os, re, shlex, subprocess, tempfile) -- pillow belongs
  # to wallpaper/generate-abstract.py alone. A plain interpreter is enough for
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

  # QS_CONFIG_PATH is not optional. quickshell.service is launched with
  # `-p <store path>`, so there is no "default" config for a bare `qs` to
  # find, and `qs ipc call browser open` fails with "Could not find 'default'
  # config directory". That is the defect that left every IPC bind dead from
  # spec 2 until spec 3 found it. A shim the portal launches does not inherit
  # the compositor's environment, so it cannot assume the variable is set.
  calangoOpen = pkgs.writeShellScriptBin "calango-open" ''
    export PATH=${calangoOpenPath}''${PATH:+:$PATH}
    export QS_CONFIG_PATH=${config.calango.quickshellConfig}
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
