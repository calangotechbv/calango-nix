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
    # Only five of the seven units carry any Exec directive at all -- the two
    # sockets (pipewire.socket, pipewire-pulse.socket) carry none, since a
    # socket unit is activated by the kernel, not exec'd. Of the five that do,
    # every one is absolute today, filter-chain.service included -- its
    # `-c filter-chain.conf` argument is a config name resolved by pipewire's
    # own search path, not by systemd, and only the program word is examined
    # here.
    #
    # An empty $relative is ambiguous by itself: "no relative Exec directive
    # found" and "grep matched nothing because $out was empty or unreadable"
    # look identical to `[ -n "$relative" ]`. check_set above makes $out
    # non-empty today, but this guard should not depend on a different
    # guard's correctness to be non-vacuous. So count what was actually
    # examined and compare it to the number this file's own comment just
    # asserted, rather than reading empty output as success.
    examined="$(grep -hE '^Exec[A-Za-z]*=' "$out"/* | wc -l)"
    if [ "$examined" != 5 ]; then
      echo "Expected exactly 5 Exec* directives across the seven audio" >&2
      echo "units (five services carry one each; the two sockets carry" >&2
      echo "none) -- found $examined." >&2
      echo "Either a unit gained or lost an Exec directive, or this guard" >&2
      echo "examined the wrong files; either way the absolute-path check" >&2
      echo "below cannot be trusted until this is understood." >&2
      exit 1
    fi

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

    # Guard 3: the data tree the WIREPLUMBER_DATA_DIR drop-in points at is
    # really there.
    #
    # The drop-in below (xdg.configFile's
    # "systemd/user/wireplumber.service.d/10-data-dir.conf" and its
    # wireplumber@.service.d twin) hardcodes ${pkgs.wireplumber}/share/wireplumber
    # as an Environment= value. Nix cannot check that a string embedded in a
    # unit file names a real path -- an interpolated store path always
    # exists, but the directory tree under it is upstream's to rearrange.
    # Checking specific files rather than just the top-level directory
    # matters: an upstream reshuffle that left share/wireplumber present but
    # emptied would pass a directory-only check while still leaving
    # wireplumber unable to find its scripts or its config.
    #
    # Three things are checked, because the drop-in's WIREPLUMBER_DATA_DIR is
    # also where wireplumber looks for wireplumber.conf and
    # wireplumber.conf.d, not only for scripts/ -- an upstream move of the
    # config alone, leaving scripts/ untouched, would pass a scripts-only
    # check while leaving wireplumber configless.
    if [ ! -f ${pkgs.wireplumber}/share/wireplumber/scripts/device/state-routes.lua ] \
      || [ ! -f ${pkgs.wireplumber}/share/wireplumber/wireplumber.conf ] \
      || [ ! -d ${pkgs.wireplumber}/share/wireplumber/wireplumber.conf.d ]; then
      echo "pkgs.wireplumber no longer ships the layout the" >&2
      echo "WIREPLUMBER_DATA_DIR drop-in assumes under" >&2
      echo "  share/wireplumber/" >&2
      echo "one of scripts/device/state-routes.lua, wireplumber.conf or" >&2
      echo "wireplumber.conf.d is missing. Re-check where upstream now keeps" >&2
      echo "its Lua scripts and its config, and update the drop-in's path to" >&2
      echo "match." >&2
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
  # All seven units carry [Install] WantedBy= -- wireplumber@.service's own
  # is WantedBy=pipewire.service, same as wireplumber.service's -- so the
  # unit file alone enables nothing for any of them, exactly the treatment
  # home/uwsm.nix gives fumon.service and home/portals.nix gives
  # xdg-desktop-portal-rewrite-launchers.service. This module links six of
  # the seven; wireplumber@.service is excluded below by policy (it is the
  # disabled-by-design split-mode template), not because it lacks a
  # WantedBy= to act on. Debian's package installed root-owned symlinks
  # under /etc/systemd/user for its six enabled units; removing the package
  # either deletes them or leaves them dangling, and neither outcome should
  # decide whether audio starts.
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

  # Task 4b: pactl and its siblings from Nix, without the daemon.
  #
  # Spec 9 decided pulseaudio-utils stays on apt, on the grounds that "Nix
  # ships a rich pw-* toolset and no pactl". That premise is false: at this
  # flake's pinned input, pkgs.pulseaudio is 17.0 -- the same upstream
  # release as Debian's pulseaudio-utils 17.0+dfsg1-2+b1 -- and
  # ${pkgs.pulseaudio}/bin holds 11 binaries, counted by listing the
  # directory rather than transcribed: pacat pacmd pactl padsp pa-info
  # pamon paplay parec parecord pasuspender pulseaudio -- ten clients plus
  # the daemon itself, which Debian's pulseaudio-utils has never carried.
  # 11 - 1 = 10 exposed below, which is what this derivation's own guards
  # count and what the results document files.
  #
  # Not full parity with Debian's package, though: Debian's pulseaudio-utils
  # also ships pax11publish, which nixpkgs' pulseaudio omits because its
  # x11Support defaults to false (confirmed absent from the same listing).
  # Practical impact is nil on Wayland -- pax11publish only publishes
  # PULSE_SERVER to the X11 root window -- but that is worth saying rather
  # than claiming a parity that does not hold.
  #
  # The pulseaudio daemon package has never been installed on this machine
  # (dpkg-query shows `un`) -- so putting pkgs.pulseaudio straight into
  # home.packages would not be the lateral move it looks like. It would put
  # a real PulseAudio daemon on PATH here for the first time.
  #
  # That distinction has teeth because of how PulseAudio clients find a
  # daemon: `strings` on libpulse.so.0 shows the bare word "pulseaudio", and
  # no absolute path to the daemon anywhere in the binary -- the one
  # absolute path it does contain is the DT_RUNPATH, a library search path,
  # not a reference to a pulseaudio executable. Autospawn resolves the
  # daemon through PATH, by name, whenever a client fails to reach one. A
  # client that couldn't reach pipewire-pulse could therefore autospawn a
  # real PulseAudio, which would seize the ALSA devices out from under
  # pipewire -- the same two-sound-servers hazard that put
  # libcanberra-pulse into Task 4's removal set, reintroduced here through
  # pactl's own upstream package. Which is also why withholding the daemon
  # from $out/bin is not theatre: because the lookup is by bare name and
  # nothing else, its absence from PATH genuinely prevents autospawn rather
  # than merely hiding the binary somewhere it could still be found.
  #
  # An `autospawn = no` in ~/.config/pulse/client.conf was considered and
  # rejected. Guard 2 below only reaches this derivation's own $out/bin --
  # it says nothing about the rest of home.packages, so it cannot by itself
  # be the reason to skip a client.conf belt-and-suspenders. The property
  # that actually matters -- no `pulseaudio` binary anywhere on the built
  # profile's PATH, however it got there -- is enforced separately, at
  # flake.nix's checks.${system}.no-pulseaudio-daemon, which walks the real
  # generation's home-path/bin rather than reasoning about which
  # derivation a stray reference came from. With that check in place, the
  # rejection still holds, just anchored to the right guard: `autospawn =
  # no` would defend only against some future edit that put a `pulseaudio`
  # binary back on PATH -- pkgs.pulseaudio added to home.packages directly,
  # or pulled in transitively -- and no-pulseaudio-daemon already turns
  # that edit into a build failure. The config file would be defending
  # against a change that cannot happen silently. Not worth the extra
  # moving part.
  #
  # pactl has one consumer in this repo, and it is load-bearing:
  # hypr/idle-sleep.sh:135-136, the second half of audio_active(). The
  # script's own comment above it explains why: /proc/asound is kernel-level
  # and dependency-free but "cannot see a bluetooth sink, which has no ALSA
  # card, so pactl covers that". idle-sleep.sh is hypridle's on-timeout
  # command (home/hyprland.nix), so if a future reader drops
  # pulseaudioClients, `command -v pactl` in that script fails,
  # audio_active() returns 1, and the machine suspends during Bluetooth-only
  # playback -- silently, because idle-sleep.sh treats pactl as an optional
  # dependency by design and nothing errors. That is what makes the failure
  # quiet rather than loud.
  #
  # An earlier version of this comment claimed pactl had no consumer here.
  # That came from a grep over quickshell/, home/ and ~/.local/bin -- which
  # does not include hypr/. Enumeration by a remembered list of directories,
  # in a file whose own header forbids exactly that.
  #
  # Every binary in ${pkgs.pulseaudio}/bin is linked except pulseaudio
  # itself, found by iterating the directory rather than by writing out the
  # ten wanted names. CLAUDE.md's rule -- enumerate by syntax, never by a
  # remembered list -- exists because a written list is exactly what missed
  # ExecStart=fumon; a list of "the ten client binaries" would go stale the
  # first time upstream adds or renames one, silently dropping it from PATH
  # while this derivation kept reporting success.
  pulseaudioClients = pkgs.runCommand "pulseaudio-clients" { } ''
    # Guard 1: the binary this derivation exists to exclude is still there
    # to exclude. The whole derivation is an exclusion; if pkgs.pulseaudio
    # no longer ships bin/pulseaudio, the exclusion below excludes nothing,
    # and someone must re-read what the package now ships rather than let
    # a now-meaningless exclusion pass silently.
    if [ ! -e ${pkgs.pulseaudio}/bin/pulseaudio ]; then
      echo "pkgs.pulseaudio no longer ships bin/pulseaudio." >&2
      echo "home/audio.nix's pulseaudioClients derivation exists to keep" >&2
      echo "exactly this binary off PATH. Re-check what pkgs.pulseaudio" >&2
      echo "ships now and update the exclusion to match." >&2
      exit 1
    fi

    mkdir -p "$out/bin"
    for f in ${pkgs.pulseaudio}/bin/*; do
      name="$(basename "$f")"
      [ "$name" = "pulseaudio" ] && continue
      ln -s "$f" "$out/bin/$name"
    done

    # Guard 2: the property this derivation exists for, asserted directly
    # rather than inferred from the loop above having been written
    # correctly.
    if [ -e "$out/bin/pulseaudio" ]; then
      echo "pulseaudioClients linked the pulseaudio daemon into \$out/bin." >&2
      echo "That is the one binary this derivation must withhold -- see" >&2
      echo "the comment above it for why an autospawned daemon on PATH" >&2
      echo "would seize the ALSA devices from pipewire." >&2
      exit 1
    fi

    # Guard 3: the binary this derivation exists to provide.
    if [ ! -e "$out/bin/pactl" ]; then
      echo "pulseaudioClients did not produce \$out/bin/pactl." >&2
      echo "pactl is the reason this derivation exists -- see home/audio.nix." >&2
      exit 1
    fi
  '';

  # The noise-canceling source, and the directories its LADSPA plugins live
  # in. Both are bound here rather than written out at each use, because the
  # drop-in below has to name the same store path that xdg.configFile installs:
  # X-Restart-Triggers works by naming a path that MOVES when the content
  # changes, so two independent references to the same file would be a defect
  # waiting for someone to edit one of them.
  noiseCancelingSource = ./../pipewire/50-noise-canceling-source.conf;

  # LADSPA_PATH, not an absolute plugin path. PipeWire appends ".so" to the
  # `plugin` field and searches a directory list -- measured, with an absolute
  # path, as: failed to load plugin '<abs path>' in
  # '/usr/lib64/ladspa:/usr/lib/ladspa:<pipewire libdir>'. None of those three
  # is a directory this flake controls, so the search path itself must be set.
  #
  # Two directories, because the graph needs two plugins from two packages:
  # rnnoise for the denoiser and swh-plugins for the gate. PipeWire tries each
  # directory in turn and the miss is harmless -- measured, it logs
  # "failed to open '<rnnoise dir>/gate_1410.so'" at debug level and then finds
  # it in the second directory.
  #
  # Same species as home/uwsm.nix's ExecStart=fumon defect -- a name resolved
  # against a search path no /nix/store entry will ever join -- with the
  # opposite fix, because here an absolute path is the thing that is refused.
  ladspaDirs = [
    "${pkgs.rnnoise-plugin}/lib/ladspa"
    "${pkgs.ladspaPlugins}/lib/ladspa"
  ];
  ladspaPath = lib.concatStringsSep ":" ladspaDirs;

  # Every name pipewire/50-noise-canceling-source.conf hands to a library,
  # checked against that library, at build time.
  #
  # The names are read OUT OF THE FILE rather than written here. A list of
  # "the six controls" typed into this derivation would go stale the first
  # time someone edits the config, and would go on passing -- which is the
  # exact failure CLAUDE.md's "enumerate by syntax, never by a remembered
  # list" rule exists to prevent, and which produced ExecStart=fumon.
  #
  # This rides in home.packages rather than in flake.nix's checks so it runs on
  # every generation build, which is strictly more often than anyone types
  # `nix flake check`. Same choice as wrappedGuiApps and pulseaudioClients.
  noiseCancelingGuard =
    pkgs.runCommand "noise-canceling-source-guard"
      {
        conf = noiseCancelingSource;
        dirs = lib.concatStringsSep " " ladspaDirs;
        builtinSo = "${pkgs.pipewire}/lib/spa-0.2/filter-graph/libspa-filter-graph-plugin-builtin.so";
        # binutils, for strings -- the whole-line existence test below caches
        # each library's string table with it rather than grepping the .so
        # directly, so it needs a real toolchain. This is the first guard in
        # home/audio.nix to declare one.
        nativeBuildInputs = [ pkgs.binutils ];
      }
      ''
        # A state machine over the config, not a list of names. The selector is
        # the PLUGIN name rather than the node type, because the graph now uses
        # two LADSPA plugins from two different packages and `type = ladspa` no
        # longer identifies which library a name must be found in.
        #
        # A control KEY is quoted and sits left of the `=`. A quoted VALUE sits
        # right of it, so the trailing `=` in the pattern is what tells the two
        # apart -- node.description = "Noise Canceling source" must not be read
        # as a control name.
        awk '
          # Comments first, and this rule is not optional. It keeps a future
          # comment from being read as config -- a mention of a plugin or
          # control name in prose would otherwise parse the same as the real
          # thing. Same species as the spec 11 appPath guard, which matched
          # the very comment written to describe it.
          #
          # NOTE for anyone editing this awk program: it is inside a
          # single-quoted shell string, so no apostrophe may appear anywhere
          # in it, comments included. One apostrophe ends the string and the
          # rest of the program becomes shell words.
          /^[[:space:]]*#/ { next }
          # type = is optional in PipeWire filter-graph syntax, so lib must
          # not simply persist from the previous node -- a node that names no
          # plugin and no type would otherwise be checked against whatever
          # library the PRIOR node happened to use. Reset at the name = line
          # that starts every node, before the plugin rule below can set it.
          # Deliberately no next. Verified against the shipped config rather
          # than assumed: this pattern does NOT also catch the modules own
          # header line, { name = libpipewire-module-filter-chain -- the
          # leading brace on that line means it does not start with
          # whitespace then name, so ^ anchors past it. Harmless either way,
          # since that line is followed immediately by a real node whose own
          # type or plugin line sets lib correctly. A node that declares no
          # plugin and no type reaches the orphan branch below.
          /^[[:space:]]*name[[:space:]]*=/ { lib = "" }
          /type[[:space:]]*=[[:space:]]*ladspa/  { lib = ""; next }
          /type[[:space:]]*=[[:space:]]*builtin/ { lib = "builtin"; next }
          match($0, /plugin[[:space:]]*=[[:space:]]*"[^"]+"/) {
            s = substr($0, RSTART, RLENGTH)
            sub(/plugin[[:space:]]*=[[:space:]]*"/, "", s); sub(/"$/, "", s)
            lib = s
            print "PLUGIN " (lib == "" ? "-" : lib) " " s; next
          }
          match($0, /label[[:space:]]*=[[:space:]]*[A-Za-z0-9_]+/) {
            s = substr($0, RSTART, RLENGTH)
            sub(/label[[:space:]]*=[[:space:]]*/, "", s)
            print "LABEL " (lib == "" ? "-" : lib) " " s; next
          }
          # A loop over every match on the line, not a single match(). match()
          # finds only the FIRST occurrence, and the shipped config already
          # has an inline control block on one line --
          # control = { "VAD Threshold (%)" = 50.0 } -- so a second control
          # added to that same line would otherwise go entirely unchecked,
          # silently, with the vacuity anchor below none the wiser since its
          # counters would still be non-zero.
          {
            rest = $0
            while (match(rest, /"[^"]+"[[:space:]]*=/)) {
              s = substr(rest, RSTART, RLENGTH)
              rest = substr(rest, RSTART + RLENGTH)
              sub(/^"/, "", s); sub(/"[[:space:]]*=$/, "", s)
              print "CONTROL " (lib == "" ? "-" : lib) " " s
            }
          }
        ' "$conf" > names.txt

        labels=0
        controls=0
        plugins=0
        bad=0

        # Redirected from a file, never piped: a `while read` on the right of a
        # pipe runs in a subshell and every counter below would be discarded.
        #
        # The awk program above prints "-" rather than leaving lib blank when
        # a name belongs to no plugin. An empty field is invisible to `read`
        # under the default IFS: "LABEL␣␣name" (two spaces, empty middle
        # field) collapses on whitespace, so lib would receive the NEXT
        # non-blank word instead of empty, and name would receive nothing.
        # `[ -z "$lib" ]` against that misparse is never true, so the orphan
        # branch below could never fire -- the build would still fail, but
        # through the wrong branch, blaming a missing .so instead of the real
        # fault: a node with no plugin line at all. The sentinel makes the
        # empty case a real, non-empty token that `read` cannot swallow.
        while read -r kind lib name; do
          # Resolve which library this name must be found in.
          so=""
          if [ "$lib" = "builtin" ]; then
            so="$builtinSo"
            if [ ! -e "$so" ]; then
              echo "The config uses a builtin filter, but pipewire no longer" >&2
              echo "ships its builtin filter-graph plugin at" >&2
              echo "  $so" >&2
              echo "Find where upstream moved it and update builtinSo." >&2
              exit 1
            fi
          elif [ -n "$lib" ]; then
            for d in $dirs; do
              if [ -e "$d/$lib.so" ]; then so="$d/$lib.so"; break; fi
            done
          fi

          if [ "$lib" = "-" ]; then
            echo "home/audio.nix's guard read a $kind named '$name' that" >&2
            echo "belongs to no filter node -- no plugin line and no" >&2
            echo "'type = builtin' preceded it in the config. Either a node" >&2
            echo "lost its plugin, or a new node type was added and this" >&2
            echo "guard has not been taught about it." >&2
            exit 1
          fi

          if [ -z "$so" ]; then
            echo "The config names the LADSPA plugin '$lib', but no" >&2
            echo "'$lib.so' exists in any directory of LADSPA_PATH:" >&2
            for d in $dirs; do echo "  $d" >&2; done
            echo "The package that provides it has moved or renamed it. Note" >&2
            echo "the config must NOT be changed to an absolute path --" >&2
            echo "pipewire refuses one; fix ladspaDirs instead." >&2
            bad=1
            continue
          fi

          # A whole-line test, not a substring one. PipeWire matches a control
          # name exactly and IGNORES one it does not know, so a name that is
          # merely a substring of a real port -- "Threshold" against
          # "Threshold (dB)" -- would pass a substring grep and then be
          # silently dropped at runtime, which is the exact failure this
          # guard exists to stop. Measured against the shipped library:
          # `grep -caF -e Threshold gate_1410.so` reads 1, so a truncated
          # name would have gone undetected.
          #
          # Cached to a file rather than piped. `strings ... | grep -q` looks
          # obvious and is wrong here: grep -q exits at the first match and
          # SIGPIPEs strings, and under pipefail the pipeline then reports
          # 141, so the guard would announce a name as missing precisely when
          # it is present.
          cache="strings-$(printf '%s' "$so" | tr -c 'A-Za-z0-9' '_')"
          if [ ! -f "$cache" ]; then
            strings "$so" > "$cache"
          fi

          case "$kind" in
            PLUGIN)
              # Resolution above WAS the existence check, and it is what makes
              # the LADSPA_PATH drop-in honest: some directory it names must
              # really hold this object.
              plugins=$((plugins + 1))
              ;;
            LABEL)
              labels=$((labels + 1))
              # A condition, not a bare grep: this builder runs with errexit,
              # and a grep that matches nothing exits 1.
              if ! grep -qxF -e "$name" "$cache"; then
                echo "The config uses the filter label '$name', which does" >&2
                echo "not appear in $so." >&2
                echo "  (from $conf)" >&2
                echo "Upstream renamed or dropped it. The config's flags do" >&2
                echo "NOT include nofail, so this would fail the unit at" >&2
                echo "runtime rather than pass silently." >&2
                bad=1
              fi
              ;;
            CONTROL)
              controls=$((controls + 1))
              if ! grep -qxF -e "$name" "$cache"; then
                echo "The config sets the control '$name', which does not" >&2
                echo "appear in $so." >&2
                echo "  (from $conf)" >&2
                echo "A control pipewire does not know is IGNORED, so the" >&2
                echo "filter would run at its default instead of the value" >&2
                echo "the config asks for -- silently. Note this guard checks" >&2
                echo "that a NAME exists; it cannot tell you that a filter" >&2
                echo "loads and then emits silence, which is how the builtin" >&2
                echo "noisegate defect reached a live machine." >&2
                bad=1
              fi
              ;;
          esac
        done < names.txt

        # The vacuity anchor. Without it a config the parser cannot read at all
        # -- a reformat, a renamed key, a file replaced by an empty one --
        # produces zero names to check, zero failures, and a guard that reports
        # success having asserted nothing.
        if [ "$plugins" -eq 0 ] || [ "$labels" -eq 0 ] || [ "$controls" -eq 0 ]; then
          echo "The guard parsed $plugins plugin(s), $labels label(s) and" >&2
          echo "$controls control(s) out of" >&2
          echo "  $conf" >&2
          echo "and at least one of those is zero, so it checked nothing." >&2
          echo "The config's syntax has changed under the parser above. Read" >&2
          echo "the file and update the awk program, and do not delete this" >&2
          echo "check -- it is the only thing standing between a reformat and" >&2
          echo "a guard that passes vacuously for ever." >&2
          exit 1
        fi

        [ "$bad" -eq 0 ] || exit 1

        echo "ok: $plugins plugin(s), $labels label(s), $controls control(s) checked"
        mkdir -p "$out"
      '';
in
{
  # pipewire brings pw-play, pw-dump, pw-top, pw-cli and the 14 bluez5 SPA
  # plugins; wireplumber brings wpctl; pulseaudioClients (above) brings
  # pactl and the rest of pulseaudio-utils' vocabulary, minus the daemon --
  # see that derivation's comment for why Debian's pulseaudio-utils staying
  # on apt was a false premise, corrected in Task 4b.
  #
  # This line puts these binaries on PATH and nothing more. An earlier version
  # of this comment claimed it was also what put Nix's wireplumber scripts
  # ahead of Debian's on XDG_DATA_DIRS -- that claim was false. Membership in
  # home.packages only affects $XDG_DATA_DIRS for processes that start inside
  # a shell carrying ~/.nix-profile on it (uwsm's session, or any interactive
  # shell after login). wireplumber.service is not one of those: it is
  # WantedBy=pipewire.service, which starts at user-manager start from
  # default.target, three seconds before uwsm ever runs and sets the session
  # environment. `/proc/<wireplumber MainPID>/environ` at that unit's own
  # ActiveEnterTimestamp of 13:27:33 showed
  #   XDG_DATA_DIRS=…flatpak…:/usr/local/share/:/usr/share/
  # -- no ~/.nix-profile/share at all -- while graphical-session.target, and
  # with it uwsm's environment update, landed at 13:27:36. So the boot-path
  # unit finds only /usr/share/wireplumber, and no amount of adding the
  # package to home.packages changes what that already-running process
  # inherited. What actually fixes this is the WIREPLUMBER_DATA_DIR drop-in
  # below, in xdg.configFile. This package line still matters for wpctl and
  # for anything spawned after login, and it does not generalise to pipewire,
  # which resolves its own configuration through a compiled-in datadir and
  # PIPEWIRE_CONFIG_DIR, not XDG_DATA_DIRS (checked with strings on both
  # libraries) -- so pipewire needed no equivalent fix.
  home.packages = [ pkgs.pipewire pkgs.wireplumber pulseaudioClients noiseCancelingGuard ];

  # apt packages this audio stack needs Debian to keep. Nine of the ten fill
  # the compiled-in module directory of DEBIAN's libpipewire-0.3.so, which is a
  # dependency no in-use check can ever see: a plugin directory is not
  # something apt models, and nothing holds a mapping on it until a plugin is
  # loaded. Every automated check clears all nine, because nothing that needs
  # them was running. That is exactly why they are declared rather than
  # measured.
  calango.deb.keep = {
    rtkit = "rtkit-daemon runs from /usr/lib/systemd/system/rtkit-daemon.service, a system unit, and standalone Home Manager writes only ~/.config/systemd/user. It grants pipewire's data-loop.0 thread SCHED_RR priority 20, measured under Nix's pipewire.";
    "libpipewire-0.3-modules" = "Fills the compiled-in module directory of DEBIAN's libpipewire-0.3.so, /usr/lib/x86_64-linux-gnu/pipewire-0.3, with 44 .so files. That client library is kept installed by libfluidsynth3 and qemu-system-gui, and a Debian-linked PipeWire client -- a qemu VM's audio device, in practice -- loads its protocol and client-node modules from there. Nix's pipewire has its own closure and is unaffected. It has zero reverse dependencies, so nothing but this declaration holds it.";
    libffado2 = "A hard Depends of libpipewire-0.3-modules.";
    "libroc0.4" = "A hard Depends of libpipewire-0.3-modules.";
    "libconfig++11" = "In libffado2's dependency chain.";
    "libglibmm-2.4-1t64" = "In libffado2's dependency chain.";
    "libxml++2.6-2v5" = "In libffado2's dependency chain.";
    "libsigc++-2.0-0v5" = "In libglibmm-2.4-1t64's and libxml++2.6-2v5's dependency chain.";
    libopenfec1 = "In libroc0.4's dependency chain.";
    libspeexdsp1 = "In libroc0.4's dependency chain.";
  };

  # xdg.configFile rather than home.file.".config/...": home-manager's own
  # systemd module writes user units through xdg.configFile, and sd-switch
  # follows xdg.configHome rather than a literal ".config". Identical today,
  # since xdg.configHome defaults to ~/.config, but a literal path would
  # silently stop being seen by sd-switch if xdg.configHome were ever set
  # elsewhere.
  #
  # No alias entry here -- see the home.activation hook below for why
  # xdg.configFile cannot express one.
  #
  # The drop-in below is added here rather than by editing wireplumber.service
  # itself: this module's units are deliberately verbatim copies (see
  # audioUnits above), and a drop-in is systemd's own mechanism for layering a
  # change on top of a unit without touching the original.
  #
  # wireplumber resolves its Lua scripts and wireplumber.conf through
  # XDG_DATA_DIRS, not a compiled-in datadir (confirmed with strings on
  # libwireplumber-0.5.so, which also names WIREPLUMBER_CONFIG_DIR and
  # WIREPLUMBER_MODULE_DIR alongside WIREPLUMBER_DATA_DIR). That is what makes
  # this drop-in necessary at all -- pipewire, below in home.packages, does
  # NOT share this behaviour: its own strings show a compiled-in
  # /nix/store/…/share/pipewire plus PIPEWIRE_CONFIG_DIR, so nothing here
  # generalises to it and no equivalent drop-in exists for pipewire.service.
  #
  # wireplumber.service is WantedBy=pipewire.service and starts at
  # user-manager start, from default.target -- three seconds before uwsm sets
  # the session environment. Measured on this boot:
  #
  #   wireplumber.service ActiveEnterTimestamp   13:27:33
  #     /proc/<MainPID>/environ:
  #     XDG_DATA_DIRS=…flatpak…:/usr/local/share/:/usr/share/
  #   graphical-session.target reached                       13:27:36
  #     systemctl --user show-environment:
  #     XDG_DATA_DIRS=/home/isutton/.nix-profile/share:…
  #
  # `systemctl --user show-environment` is the wrong instrument for this
  # question: it reports the manager's environment as it is NOW, after uwsm
  # has already mutated it -- not what a unit that started at boot actually
  # inherited. It says nothing about wireplumber.service's own, earlier
  # environment. This is the same trap as `systemd-analyze --user
  # unit-paths` documented in CLAUDE.md, walked into during this very
  # migration; the authoritative source for what a running unit sees is
  # always that unit's own /proc/<MainPID>/environ. So the unit's actual
  # search path at startup has only /usr/share/wireplumber to find scripts
  # in, home.packages or not -- adding pkgs.wireplumber to home.packages
  # changes what a login shell's XDG_DATA_DIRS contains, not what a unit
  # already running before that shell existed inherited.
  #
  # Without this, Nix's 0.5.14 binary runs Debian's 0.5.8 Lua scripts: a
  # mixed-provenance stack, confirmed this boot by
  #   wplua: [string "state-routes.lua"]:119: bad argument #1 to 'next'
  #   (table expected, got GBoxed)
  # eight times, because 0.5.14 passes a Properties GBoxed where 0.5.8's
  # state-routes.lua:119 (`if next (selected_routes) == nil then`) expects a
  # table -- 0.5.14 moved that guard to :117 as
  # `selected_routes:get_count () == 0`. Running the binary by hand with the
  # unit's own broken XDG_DATA_DIRS plus only WIREPLUMBER_DATA_DIR added gave
  # zero tracebacks, with the one remaining log line moving to alsa.lua:397 --
  # Nix's line number, where Debian's is 392, confirming Nix's tree is now
  # what's read. This must stay explicit rather than be left to fix itself:
  # Task 4 removes Debian's wireplumber package, at which point
  # /usr/share/wireplumber disappears and the mismatch would silently vanish
  # too -- but only by accident, and only until the next thing that ships a
  # tree under /usr/share/wireplumber.
  #
  # wireplumber@.service.d gets the identical drop-in. It is disabled and
  # nothing in this module links it, but it is still installed (see
  # wireplumberUnits above, "for parity") and shares wireplumber.service's
  # binary and its dependence on XDG_DATA_DIRS for the same Lua scripts. Without
  # this, wireplumber@.service would carry no data dir at all the moment
  # /usr/share/wireplumber is gone -- not merely a stale one -- if anyone
  # ever starts it by hand for split-mode debugging. Cheap to keep correct;
  # no reason to let the disabled unit rot just because nothing here starts it.
  xdg.configFile = unitFiles // wantLinks // {
    "systemd/user/wireplumber.service.d/10-data-dir.conf".text = ''
      [Service]
      Environment=WIREPLUMBER_DATA_DIR=${pkgs.wireplumber}/share/wireplumber
    '';
    "systemd/user/wireplumber@.service.d/10-data-dir.conf".text = ''
      [Service]
      Environment=WIREPLUMBER_DATA_DIR=${pkgs.wireplumber}/share/wireplumber
    '';

    # The filter graph. A .d fragment merges into the filter-chain.conf that
    # pipewire finds in its own compiled-in share directory, so no base config
    # is needed here -- verified by running `pipewire -c filter-chain.conf`
    # against a scratch XDG_CONFIG_HOME holding only this fragment, which
    # produced the source `fragtest_output.rnnoise` with an empty log.
    "pipewire/filter-chain.conf.d/50-noise-canceling-source.conf".source =
      noiseCancelingSource;

    # Two directives that look unrelated and are both mandatory.
    #
    # LADSPA_PATH: see the ladspaPath binding above. Without it the graph does
    # not load and the unit fails.
    #
    # X-Restart-Triggers: sd-switch restarts a unit when the unit FILE changes,
    # never when a file the unit reads changes. A change confined to the
    # fragment above leaves filter-chain.service byte-identical, sd-switch
    # correctly does nothing, and the service goes on serving the previous
    # graph from a store path nothing points at any more. The switch succeeds
    # and the edit has no effect -- the defect every quickshell change in this
    # flake carried until spec 11. Naming the config's store path here makes
    # this drop-in's own text move whenever the config's content moves.
    #
    # X- keys are ignored by systemd itself, which is why this is the
    # conventional spelling; see home/quickshell.nix's Unit.X-Restart-Triggers.
    "systemd/user/filter-chain.service.d/10-noise-canceling-source.conf".text = ''
      [Unit]
      X-Restart-Triggers=${noiseCancelingSource}

      [Service]
      Environment=LADSPA_PATH=${ladspaPath}
    '';
  };

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
  # into home.file and goes through the same linker. Full evidence in this
  # branch's alias research notes (not part of the committed tree).
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
  #
  # Ordering: after the files are linked, and before systemd is reloaded --
  # the second half is a real constraint, not a nicety. Home Manager's own
  # reloadSystemd (modules/systemd.nix) is ALSO entryAfter
  # [ "linkGeneration" ], so two DAG entries with no stated relation between
  # them are ordered only by hm.dag.topoSort's tie-break: it feeds
  # builtins.attrValues -- attribute-name sorted -- into a stable
  # lib.toposort. An entryAfter here lands ahead of reloadSystemd only
  # because "pipewireSessionManagerAlias" sorts before "reloadSystemd";
  # renaming this attribute to anything that sorts after (e.g.
  # "wireplumberAlias") would silently move it past the daemon-reload.
  # sd-switch would then restart pipewire-pulse.service while
  # pipewire-session-manager.service is still unknown to systemd --
  # Wants=/After= dropped for that session, with nothing in
  # --state=failed. entryBetween pins both edges explicitly, so the
  # ordering cannot depend on how a future rename happens to sort.
  home.activation.pipewireSessionManagerAlias =
    lib.hm.dag.entryBetween [ "reloadSystemd" ] [ "linkGeneration" ] ''
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
