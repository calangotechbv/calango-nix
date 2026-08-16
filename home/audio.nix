{ config, lib, pkgs, ... }:

let
  # Both unit sets, written out by name rather than read from the store with
  # builtins.readDir -- that would be import-from-derivation, and it would
  # trade a loud build failure for a silent change in what gets installed.
  # The audioUnits derivation below cross-checks these lists against the real
  # directories, so a list that goes stale is a build error rather than a unit
  # that quietly stops existing.
  #
  # Spec 8 learned this the expensive way from the other direction: its first
  # draft asserted Debian shipped three units from xdg-desktop-portal when
  # dpkg -L showed four, because `systemctl --user list-units` does not show a
  # oneshot that has already finished. Enumerate by listing, never by memory.
  #
  # C collation is not incidental. '-' is 0x2D, '.' is 0x2E and '@' is 0x40,
  # so under LC_ALL=C `pipewire-pulse.service` sorts before `pipewire.service`
  # and `wireplumber.service` before `wireplumber@.service`. A list transcribed
  # from unsorted `ls` output would fail the check on a correct tree.
  pipewireUnits = [
    "filter-chain.service"
    "pipewire-pulse.service"
    "pipewire-pulse.socket"
    "pipewire.service"
    "pipewire.socket"
  ];

  wireplumberUnits = [
    "wireplumber.service"
    "wireplumber@.service"
  ];

  allUnits = pipewireUnits ++ wireplumberUnits;

  # A copy of both unit directories that refuses to build if anything this
  # module depends on has changed upstream. The files are copied rather than
  # symlinked so the checks sit in the path of the files themselves -- nothing
  # can consume a unit without having passed them. Copying preserves the
  # absolute /nix/store paths written inside each unit, which is the entire
  # point of using Nix's copies instead of Debian's.
  audioUnits = pkgs.runCommand "audio-session-units" { } ''
    mkdir -p "$out"

    check_set() {
      pkgdir="$1"; expected="$2"; label="$3"
      actual="$(cd "$pkgdir" && LC_ALL=C ls -1 | LC_ALL=C sort | tr '\n' ' ')"
      actual="''${actual% }"
      if [ "$expected" != "$actual" ]; then
        echo "$label's unit set has changed." >&2
        echo "$expected" | tr ' ' '\n' | LC_ALL=C sort > expected.txt
        echo "$actual"   | tr ' ' '\n' | LC_ALL=C sort > actual.txt
        LC_ALL=C comm -13 expected.txt actual.txt | sed 's/^/  added:   /' >&2
        LC_ALL=C comm -23 expected.txt actual.txt | sed 's/^/  removed: /' >&2
        echo "Update the unit list in home/audio.nix, then check that every" >&2
        echo "added or removed unit is accounted for -- including its" >&2
        echo "enablement link, which this module owns and upstream does not." >&2
        exit 1
      fi
      cp "$pkgdir"/* "$out/"
    }

    check_set ${pkgs.pipewire}/share/systemd/user \
      "${lib.concatStringsSep " " pipewireUnits}" pipewire
    check_set ${pkgs.wireplumber}/share/systemd/user \
      "${lib.concatStringsSep " " wireplumberUnits}" wireplumber

    chmod -R u+w "$out"

    # Guard 1: no relative Exec directive.
    #
    # systemd does NOT resolve a bare program name against the manager's PATH.
    # It uses a search path fixed when systemd was compiled --
    # `systemd-path search-binaries-default` prints
    # /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin -- which contains no
    # /nix/store entry and never will. home/uwsm.nix shipped exactly this bug
    # for two phases: ExecStart=fumon ran Debian's binary under Nix's unit.
    #
    # ^Exec[A-Za-z]*= rather than a list of directive names. Enumerating the
    # directives by hand is what produced that bug. The prefix characters
    # @ - : + ! are systemd's exec modifiers, stripped before the path is read.
    #
    # All seven units are absolute today, filter-chain.service included --
    # its `-c filter-chain.conf` argument is a config name resolved by
    # pipewire's own search path, not by systemd, and only the program word is
    # examined here.
    relative="$(
      grep -hE '^Exec[A-Za-z]*=' "$out"/* \
        | sed -E 's/^Exec[A-Za-z]*=//; s/^[@:+!-]+//' \
        | awk 'NF && $1 !~ /^\// { print }'
    )" || true
    if [ -n "$relative" ]; then
      echo "An audio unit ships an Exec directive that is not absolute:" >&2
      echo "$relative" | sed 's/^/  /' >&2
      echo "systemd resolves these against a compile-time search path, not" >&2
      echo "the manager's PATH, and no /nix/store entry is on it." >&2
      exit 1
    fi

    # Guard 2: the alias still exists upstream.
    #
    # This is the load-bearing one. Nix's pipewire-pulse.service says
    #   Wants=pipewire.service pipewire-session-manager.service
    # and Nix's filter-chain.service says
    #   After=pipewire.service pipewire-session-manager.service
    # Neither name is wireplumber's own; both work only because
    # wireplumber.service declares Alias=pipewire-session-manager.service and
    # something writes the alias symlink. That link is written by the
    # home.activation hook below, not by this module's xdg.configFile block --
    # xdg.configFile cannot produce it (see the hook's comment) -- but the
    # hook hardcodes this exact name, so if upstream ever drops or renames the
    # Alias=, this build must fail rather than let the hook keep writing a
    # link nothing declares.
    #
    # The failure it prevents is silent. systemd treats Wants= and After= on a
    # unit that does not exist as satisfied-by-absence: the dependency is
    # dropped, the ordering with it, audio starts anyway with the session
    # manager no longer sequenced ahead of the pulse shim, and nothing appears
    # in `systemctl --user --state=failed`.
    if [ "$(grep -cxF 'Alias=pipewire-session-manager.service' \
              "$out/wireplumber.service")" != 1 ]; then
      echo "wireplumber.service no longer declares" >&2
      echo "  Alias=pipewire-session-manager.service" >&2
      echo "The alias link this module writes is now unfounded. Re-read" >&2
      echo "Nix's pipewire-pulse.service and filter-chain.service to see" >&2
      echo "what name they depend on now, and fix both together." >&2
      exit 1
    fi
  '';

  # The seven unit files, at ~/.config/systemd/user -- UnitPath position 5,
  # against /usr/lib/systemd/user at position 15.
  #
  # Those numbers are `systemctl --user show -p UnitPath --value`, the
  # manager's own property. `systemd-analyze --user unit-paths` looks like the
  # obvious way to check and answers a different question: it computes the
  # list from the *calling* process's environment, reports 18 entries, and
  # invents a ~/.nix-profile/share/systemd/user entry the manager has never
  # seen. In one review cycle a reviewer and the controller drew opposite
  # wrong conclusions from it.
  unitFiles = lib.listToAttrs (map
    (n: lib.nameValuePair "systemd/user/${n}" { source = "${audioUnits}/${n}"; })
    allUnits);

  # Enablement, owned here rather than inherited.
  #
  # Six of the seven units carry [Install] WantedBy=, so the unit file alone
  # enables nothing -- exactly the treatment home/uwsm.nix gives fumon.service
  # and home/portals.nix gives xdg-desktop-portal-rewrite-launchers.service.
  # Debian's package installed root-owned symlinks under /etc/systemd/user for
  # all six; removing the package either deletes them or leaves them dangling,
  # and neither outcome should decide whether audio starts.
  #
  # .wants links from every UnitPath entry are unioned rather than shadowed,
  # so while Debian's package is still installed both sets exist and both name
  # the same unit -- which resolves to the fragment at position 5. No conflict.
  #
  # wireplumber@.service gets no link: it is the split-mode template, disabled
  # on Debian too. Installed for parity, enabled by nothing.
  wants = {
    "sockets.target.wants" = [ "pipewire.socket" "pipewire-pulse.socket" ];
    "default.target.wants" = [
      "pipewire.service"
      "pipewire-pulse.service"
      "filter-chain.service"
    ];
    "pipewire.service.wants" = [ "wireplumber.service" ];
  };

  wantLinks = lib.listToAttrs (lib.concatLists (lib.mapAttrsToList
    (dir: units: map
      (n: lib.nameValuePair "systemd/user/${dir}/${n}" {
        source = "${audioUnits}/${n}";
      })
      units)
    wants));
in
{
  # pipewire brings pw-play, pw-dump, pw-top, pw-cli and the 14 bluez5 SPA
  # plugins; wireplumber brings wpctl. Debian's pulseaudio-utils stays for
  # pactl, which Nix does not ship and which most of this migration's gate
  # speaks -- see the plan's Global Constraints for why it gets marked manual.
  #
  # Unlike every other package line in this flake, this one is NOT inert at
  # runtime -- Task 1's rehearsal found out the hard way. wireplumber resolves
  # its Lua scripts through XDG_DATA_DIRS rather than a compiled-in datadir,
  # and the user manager's own XDG_DATA_DIRS (`systemctl --user
  # show-environment`) leads with ~/.nix-profile/share. Before this package
  # was in home.packages, ~/.nix-profile/share/wireplumber did not exist,
  # /usr/share/wireplumber was the only scripts tree on the path, and Nix's
  # wireplumber 0.5.14 binary ran Debian's 0.5.8 Lua scripts -- state-routes
  # .lua:119 throwing "bad argument #1 to 'next' (table expected, got
  # GBoxed)", which reads like a 0.5.14 bug but is a binary/script version
  # mismatch. So this line is load-bearing: it is what puts Nix's scripts
  # ahead of Debian's on XDG_DATA_DIRS. It is a mechanism, confirmed by hand
  # on this machine, not luck -- and it does not generalise to pipewire below,
  # which resolves its configuration through its own compiled-in datadir, not
  # XDG_DATA_DIRS.
  home.packages = [ pkgs.pipewire pkgs.wireplumber ];

  # xdg.configFile rather than home.file.".config/...": home-manager's own
  # systemd module writes user units through xdg.configFile, and sd-switch
  # follows xdg.configHome rather than a literal ".config". Identical today,
  # since xdg.configHome defaults to ~/.config, but a literal path would
  # silently stop being seen by sd-switch if xdg.configHome were ever set
  # elsewhere.
  #
  # No alias entry here -- see the home.activation hook below for why
  # xdg.configFile cannot express one.
  xdg.configFile = unitFiles // wantLinks;

  # The alias, written by a raw `ln -s` because xdg.configFile cannot express
  # one and nothing else in Home Manager will.
  #
  # Nix's pipewire-pulse.service carries
  #   Wants=pipewire.service pipewire-session-manager.service
  #   After=pipewire.service pipewire-session-manager.service
  # and Nix's filter-chain.service carries the After= half. Neither name is
  # wireplumber's own. Both work only because wireplumber.service declares
  # Alias=pipewire-session-manager.service AND something writes the alias
  # symlink. `systemctl enable` writes it; this flake installs units
  # declaratively and never enables anything.
  #
  # And systemd only treats a symlink in a unit directory as an alias when the
  # link's IMMEDIATE target is a path inside a unit directory. Measured here,
  # four variants, stack stopped: a link whose immediate target is
  # /nix/store/...-wireplumber-0.5.14/share/systemd/user/wireplumber.service
  # loads as a SECOND, independent unit with its own FragmentPath (`systemctl
  # --user show ... -p Id` returns Id=pipewire-session-manager.service, not an
  # alias) -- present even with wireplumber.service also in the directory, so
  # "the basename names no loadable unit" is excluded as the cause. A relative
  # link to the sibling (`wireplumber.service`, no directory part) gives
  # Id=wireplumber.service with Names=wireplumber.service
  # pipewire-session-manager.service -- a true alias -- and so does an
  # absolute link to the sibling's own ~/.config path, even though its chase
  # also terminates in the store. The rule is the symlink's immediate target,
  # not the fully chased one. xdg.configFile can only ever produce the first,
  # forbidden shape, because hop 1 of every xdg.configFile link is always
  # ~/.config/... -> /nix/store/<home-manager-files>/...; there is no
  # arrangement of .source that avoids it, and
  # config.lib.file.mkOutOfStoreSymlink does not help either -- it is merged
  # into home.file and goes through the same linker. Full evidence in
  # .superpowers/sdd/2026-08-16-audio-stack/alias-research.md.
  #
  # The failure this prevents is otherwise silent. Wants= and After= naming a
  # unit that does not exist are not errors: the dependency is dropped, the
  # ordering with it, audio starts anyway with the session manager no longer
  # sequenced ahead of the pulse shim, and --state=failed stays empty.
  #
  # Fatal on a missing target, unlike home/gtk.nix's cosmetic hook: if
  # wireplumber.service is not there, this link would dangle and the ordering
  # would be lost silently, which is the whole thing being guarded against.
  # The `run` wrapper makes the entire body a no-op under DRY_RUN, so a dry
  # run before the first switch does not abort on a target that has not been
  # linked yet.
  home.activation.pipewireSessionManagerAlias =
    lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      run ${pkgs.bash}/bin/sh -c '
        dir=${lib.escapeShellArg "${config.xdg.configHome}/systemd/user"}
        if [ ! -e "$dir/wireplumber.service" ]; then
          echo "pipewire-session-manager alias: $dir/wireplumber.service is missing." >&2
          echo "home/audio.nix must install wireplumber.service before this hook runs." >&2
          exit 1
        fi
        rm -f "$dir/pipewire-session-manager.service"
        ln -s wireplumber.service "$dir/pipewire-session-manager.service"
      '
    '';
}
