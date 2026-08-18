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
  # Non-fatal, deliberately. Measured on the live file, all six ids listed
  # rather than summarised, because an earlier version of this comment named
  # four of the five that are not this flake's:
  #
  #   $ grep -c '^[^=]*=' ~/.config/mimeapps.list
  #   12
  #   $ sed -n 's/^[^=]*=//p' ~/.config/mimeapps.list | tr ';' '\n' \
  #       | sed '/^$/d' | sort -u
  #   bitwarden.desktop
  #   claude-code-url-handler.desktop
  #   eu.calangotech.CalangoOpen.desktop
  #   eu.calangotech.KBrowserSelector.desktop
  #   signal-desktop.desktop
  #   slack.desktop
  #   $ grep -c 'CalangoOpen' ~/.config/mimeapps.list
  #   5
  #
  # 12 assignment lines (10 under [Default Applications], 2 under [Added
  # Associations]) naming 6 unique ids. Five of the twelve name this flake's
  # CalangoOpen; the other seven name the five other ids above, whose absence
  # is none of this flake's business and must never abort a switch.
  #
  # Two of those five do not resolve today, and they are what this hook warns
  # about -- eu.calangotech.KBrowserSelector.desktop, this module's own
  # displaced entry, which the [Added Associations] pair still names although
  # it exists nowhere on the search path, and slack.desktop. Note slack.desktop
  # is NOT flatpak Slack's id: flatpak exports com.slack.Slack.desktop, a
  # different string, which is exactly why that association is dead. See
  # CLAUDE.md's corp-set entry, which records the same distinction.
  #
  # All of this is of 2026-08-17, not a standing property: bitwarden and
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
  # alphabetically. The 12 hooks from linkGeneration on, in the built
  # activate. Regenerate rather than trust the numbers: they shift whenever a
  # hook is added, and this listing was already stale once, captured before
  # signalMimeappsId existed and still saying eleven.
  #
  #   $ A=$(sg nix-users -c 'nix build --no-link --print-out-paths \
  #         .#homeConfigurations."isutton@suffer".activationPackage')
  #   $ grep -n 'Activating %s' "$A"/activate | sed -n '/linkGeneration/,$p'
  #   284:_iNote "Activating %s" "linkGeneration"
  #   316:_iNote "Activating %s" "desktopDatabase"
  #   322:_iNote "Activating %s" "defaultBrowser"
  #   331:_iNote "Activating %s" "footThemeColors"
  #   338:_iNote "Activating %s" "gtkAppearance"
  #   348:_iNote "Activating %s" "hyprlockConf"
  #   356:_iNote "Activating %s" "installPackages"
  #   386:_iNote "Activating %s" "signalMimeappsId"
  #   398:_iNote "Activating %s" "mimeappsIds"
  #   417:_iNote "Activating %s" "onFilesChange"
  #   420:_iNote "Activating %s" "pipewireSessionManagerAlias"
  #   433:_iNote "Activating %s" "reloadSystemd"
  #
  # Alphabetical with exactly two exceptions, and both are real edges rather
  # than luck. desktopDatabase runs BEFORE defaultBrowser, because
  # defaultBrowser declares entryAfter [ "desktopDatabase" ] -- present already
  # at this branch's base 3afbf7a. And signalMimeappsId runs BEFORE mimeappsIds
  # despite s sorting after m, because it declares
  # entryBetween [ "mimeappsIds" ] [ "writeBoundary" ] -- without which the hook
  # that REPORTS dead .desktop ids would run before the hook that FIXES one, and
  # warn about signal-desktop.desktop at every switch.
  #
  # Every other adjacent pair is ordered by nothing but its attribute name,
  # which is the hazard: mimeappsIds sits behind its dependencies only because
  # the letter m sorts after d and i, and renaming it to anything sorting
  # earlier -- checkMimeappsIds, auditMimeapps -- would move it silently ahead
  # of them, reporting against a search path not yet built and a file not yet
  # rewritten, with nothing to distinguish that from a genuine finding. The
  # edges above are what stop that, proven by performing exactly that rename and
  # watching the position hold. This is the same defect home/audio.nix's
  # pipewireSessionManagerAlias paid for.
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

  # Signal's .desktop id changes across the Debian/Nix boundary --
  # signal-desktop.desktop becomes signal.desktop -- and two handlers in
  # ~/.config/mimeapps.list name the old one. Migrating without this leaves
  # x-scheme-handler/sgnl and x-scheme-handler/signalcaptcha pointing at an id
  # that does not exist, silently.
  #
  # This writes a file the flake does not own, which is why it is narrow:
  # it rewrites only the exact token signal-desktop.desktop, only where that
  # token is a whole value, and it touches nothing else. mimeapps.list also
  # carries ids this flake will never own -- a dead
  # eu.calangotech.KBrowserSelector.desktop, and slack.desktop, which apt's
  # slack-desktop ships and which this flake does not own either -- so it
  # must survive untouched for the same reason, not because it is dead.
  #
  # Non-fatal for the same reason mimeappsIds is -- this is the user's file, and
  # a switch must not abort over it. The body runs under `sh -c`, which inherits
  # neither errexit nor pipefail from the activation script ($- is `hBc` there,
  # measured), so every step carries its own `|| exit 0` rather than relying on
  # set -e. `grep -q`, not `grep -c`: the latter prints 0 and exits 1 on no
  # match, which would make the guard indistinguishable from a broken pipeline.
  #
  # Idempotent, but the property belongs to the sed and not to the grep, and the
  # difference is measurable. The guard is a plain substring test while the sed
  # matches only whole values, so the guard is the broader of the two: on a file
  # where signal-desktop.desktop occurs only inside a longer id
  # (xsignal-desktop.desktop, signal-desktop.desktop.bak) the guard passes, sed
  # runs, and correctly changes nothing -- the file stays byte-identical and the
  # message prints anyway. Proven on a synthetic file; the real mimeapps.list has
  # no such id, so after the rewrite the guard finds nothing and this hook is
  # silent on every later switch. Do not restate this as "a second run exits
  # before sed": that is true here and not true in general.
  #
  # One known gap, recorded because it converges rather than because it bites:
  # `g` consumes the separator it matched, so two ADJACENT occurrences in one
  # `;`-list rewrite one per invocation. The next switch fixes the rest, and a
  # value listing the same id twice does not occur here.
  #
  # entryBetween, and the `before` edge is the load-bearing one. It is the same
  # hazard the mimeappsIds comment above documents at length: hm.dag.topoSort
  # orders any unrelated pair by attribute name, and `signalMimeappsId` sorts
  # after every other hook here. Measured with the plan's original
  # `entryAfter [ "writeBoundary" ]`, this hook landed dead last in the built
  # activate -- line 463, against mimeappsIds at 386 -- so the hook that reports
  # dead ids in mimeapps.list read the file before the hook that fixes one of
  # them had run. That is precisely the defect mimeappsIds fixed for itself by
  # naming defaultBrowser: "reading it first would report on the pre-switch
  # contents". Stating the edge moves this hook to 380, ahead of mimeappsIds,
  # and the two are then ordered by a real relation rather than by the letter s.
  #
  # Only the one `before` edge is real. Nothing here reads the .desktop search
  # path, so linkGeneration and installPackages are irrelevant; and defaultBrowser
  # rewrites this same file through `xdg-settings set default-web-browser`, which
  # is a read-modify-write that preserves unrelated assignments, so neither order
  # against it is required. `after [ "writeBoundary" ]` is the floor for any hook
  # that writes to $HOME at all.
  config.home.activation.signalMimeappsId =
    lib.hm.dag.entryBetween [ "mimeappsIds" ] [ "writeBoundary" ] ''
      run ${pkgs.bash}/bin/sh -c '
        list="$HOME/.config/mimeapps.list"
        [ -w "$list" ] || exit 0
        ${pkgs.gnugrep}/bin/grep -q "signal-desktop\.desktop" "$list" || exit 0
        ${pkgs.gnused}/bin/sed -i \
          "s/\(^\|[=;]\)signal-desktop\.desktop\($\|;\)/\1signal.desktop\2/g" \
          "$list"
        echo "mimeapps.list: signal-desktop.desktop -> signal.desktop" >&2
      ' || true
    '';

  # Displaces the stale eu.calangotech.KBrowserSelector.desktop. It no longer
  # holds the http/https *defaults* -- [Default Applications] names
  # CalangoOpen there -- but the two [Added Associations] lines still name it,
  # and it exists nowhere on the search path (`find` across all of
  # $XDG_DATA_DIRS and ~/.local/share returns 0; see the results doc). Not
  # called root-owned here any more: nothing measurable now supports that,
  # ~/.config/mimeapps.list is isutton:nix-users, and the entry it names is
  # simply absent.
  #
  # Deliberately not xdg.mimeApps: that would freeze
  # ~/.config/mimeapps.list, and 7 of its 12 assignment lines -- all but the
  # 5 naming CalangoOpen, both counts in the mimeappsIds comment above --
  # belong to applications this repository does not own, so no application
  # could ever set a default again.
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
