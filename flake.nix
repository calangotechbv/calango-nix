{
  description = "calango-nix: a Hyprland desktop on Debian 13";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # The follows is load-bearing. nixGL's own flake pins
    # inputs.nixpkgs.url = "github:nixos/nixpkgs", and a wrapper built against
    # a different nixpkgs than the programs it wraps fails at runtime with
    # "GLIBC_2.34 not found" rather than at build time.
    nixgl = {
      url = "github:nix-community/nixGL";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager, nixgl, ... }:
    let
      system = "x86_64-linux";

      # nixpkgs builds polkit for NixOS, where the setuid helper lives in
      # /run/wrappers/bin. That directory exists on no Debian machine, so a
      # Nix polkit agent runs, loads its QML, and then dies the moment it is
      # asked to authenticate:
      #
      #   Cannot spawn helper: Failed to execute child process
      #   "/run/wrappers/bin/polkit-agent-helper-1" (No such file or directory)
      #
      # The same shape of bug as /run/opengl-driver/lib, which nixGL exists to
      # solve. Here the fix is a rebuild rather than a wrapper, because the
      # path is compiled into libpolkit-agent-1.
      #
      # pkgs/by-name/po/polkit/package.nix binds `setuid` in a let block, not
      # as a function argument, so it cannot be reached with .override. The
      # substitution below runs after that one and rewrites its result.
      # --replace-fail means a change in upstream's patch breaks the build
      # rather than silently restoring the NixOS path.
      #
      # Debian's helper is /usr/lib/polkit-1/polkit-agent-helper-1, mode 4755
      # root. The alternative was a /run/wrappers symlink kept alive by a
      # tmpfiles.d snippet, and that would have been a second root-owned file.
      # Scoped to hyprpolkitagent on purpose. Replacing `polkit` for the whole
      # package set costs 41 derivations, because pipewire depends on polkit
      # and ffmpeg, qtmultimedia, qtwebengine, gtk4, xwayland and hyprland
      # itself all sit downstream of that. qtwebengine alone is hours. Only
      # the agent actually calls the setuid helper, so only the agent needs
      # the patched build; everything else keeps its cache hit.
      #
      # Both entries are needed. polkit-qt-1 is what carries
      # libpolkit-agent-1.so.0 in its NEEDED list, and hyprpolkitagent also
      # references polkit's store path directly.
      debianPolkit = final: prev:
        let
          patched = prev.polkit.overrideAttrs (old: {
            postPatch = (old.postPatch or "") + ''
              substituteInPlace src/polkitagent/polkitagentsession.c \
                --replace-fail '"/run/wrappers/bin/' '"/usr/lib/polkit-1/'
            '';
          });
        in
        {
          hyprpolkitagent = prev.hyprpolkitagent.override {
            polkit = patched;
            kdePackages = prev.kdePackages.overrideScope (
              kfinal: kprev: {
                polkit-qt-1 = kprev.polkit-qt-1.override { polkit = patched; };
              }
            );
          };
        };

      # nixpkgs patches pam_unix's privileged helper to /run/wrappers/bin,
      # NixOS's setuid-wrapper directory, because the store copy cannot carry
      # the setgid bit -- see the comment at pkgs/by-name/li/linux-pam/package.nix.
      # That directory exists on no Debian machine, so pam_unix could never
      # verify a password here: strace shows
      #   execve("/run/wrappers/bin/unix_chkpwd", ...) = -1 ENOENT
      # against Debian's /usr/sbin/unix_chkpwd, which is -rwxr-sr-x root shadow
      # and is the right target. With this patch the same trace reads
      #   execve("/usr/sbin/unix_chkpwd", ...) = 0
      #
      # Third instance of the same failure as debianPolkit above and nixGL
      # before it. Scoped to hyprlock for the same reason: pam is a dependency
      # of systemd, and replacing it set-wide rebuilds most of the closure.
      # Measured -- scoped, this is 2 derivations, and `systemd` keeps its
      # stock store path.
      #
      # --replace-fail matches nixpkgs' own substituted output, so an upstream
      # change to that line fails the build rather than silently restoring the
      # NixOS path.
      debianPam = final: prev:
        let
          patched = prev.pam.overrideAttrs (old: {
            postPatch = (old.postPatch or "") + ''
              substituteInPlace modules/module-meson.build \
                --replace-fail "'/run/wrappers/bin/unix_chkpwd'" "'/usr/sbin/unix_chkpwd'"
            '';
          });
        in
        {
          hyprlock = prev.hyprlock.override { pam = patched; };

          # A deliberate second consumer, not a convenience. The plan's
          # authentication gate -- the one that decides whether the apt
          # removal is safe -- runs pamtester against `common-auth`. Stock
          # nixpkgs pamtester links stock linux-pam, whose pam_unix execs
          # /run/wrappers/bin/unix_chkpwd: the exact NixOS-only path this
          # overlay exists to fix, and a directory this machine does not have.
          # That test could not pass with any password, and its failure would
          # read as "the PAM fix did not work" immediately before the
          # irreversible step. Overridden here so the gate exercises the SAME
          # patched libpam the lock screen loads, which is the only version of
          # that test that answers the spike's open question.
          #
          # pamtester takes `pam` as a function argument
          # (pkgs/by-name/pa/pamtester/package.nix:6), so a plain .override is
          # enough -- no overrideAttrs, as with hyprlock.
          pamtester = prev.pamtester.override { pam = patched; };
        };

      pkgs = import nixpkgs {
        inherit system;
        overlays = [ nixgl.overlays.default debianPolkit debianPam ];
      };

      mkHome = username: hostname: home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          ./home/default.nix
          ./home/session.nix
          ./home/quickshell.nix
          ./home/hyprland.nix
          ./home/foot.nix
          ./home/lf.nix
          ./home/gtk.nix
          ./home/apps.nix
          ./home/services.nix
          ./home/portals.nix
          ./home/audio.nix
          ./home/gui-apps.nix
          ./home/apt-hygiene.nix
          ./home/uwsm.nix
          ./home/syncthing.nix
          ./home/deb.nix
          ./home/slack.nix
          {
            home.username = username;
            home.homeDirectory = "/home/${username}";
            home.stateVersion = "26.05";
            calango.host = hostname;

            # A dirty build must never outrank a committed one: 0.0+dirty…
            # sorts below 0.<revCount>, verified with dpkg --compare-versions.
            # revCount and rev are absent for a dirty tree; lastModifiedDate is
            # not, which is what makes the fallback expressible at all.
            calango.deb.version =
              if self ? revCount
              then "0.${toString self.revCount}"
              else "0.0+dirty${self.lastModifiedDate}";
          }
        ];
      };
      suffer = mkHome "isutton" "suffer";
    in
    {
      homeConfigurations = {
        "isutton@suffer" = suffer;
      };

      packages.${system}.calangoDeb = suffer.config.calango.debPackage;

      # Every xdg.configFile/xdg.dataFile ".source" in home/portals.nix,
      # home/audio.nix and home/uwsm.nix is a bare string pointing into a
      # package output --
      # nothing checks it resolves. Home Manager's file builder links each one
      # with a plain `ln -s "$source" "$target"` (see the derivation for
      # home-manager-files); there is no existence test anywhere in that path.
      # A nixpkgs bump that relocates a unit or an activation file therefore
      # builds and switches cleanly while quietly producing a dead symlink --
      # proven by hand by pointing a real entry at a nonexistent path and
      # watching the build succeed anyway.
      #
      # This walks the built generation's home-files for exactly that: `find
      # -L ... -type l` prints only symlinks whose target does not exist.
      # `${suffer.activationPackage}/home-files` is the same store path the
      # activation script itself uses (a symlink baked into the activation
      # package's own output), so this checks the real generation, not a
      # reconstruction of it.
      #
      # Same shape as no-pulseaudio-daemon below, and given the same
      # treatment for the same reason: `find -L <dir> -type l || true`
      # swallows "No such file or directory" as readily as it swallows "no
      # matches", so a $dir that stopped existing -- an activationPackage
      # layout change, or a typo here -- would leave $dangling empty and
      # this check would pass vacuously instead of failing loudly.
      checks.${system} = {
        no-dangling-home-files =
          pkgs.runCommand "portal-stack-no-dangling-home-files" { } ''
            dir=${suffer.activationPackage}/home-files
            if [ ! -d "$dir" ] || [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
              echo "$dir does not exist or is empty." >&2
              echo "Either activationPackage's layout changed, or this" >&2
              echo "check's path is wrong -- either way, an empty" >&2
              echo "\$dangling below would be vacuous, not a real pass." >&2
              exit 1
            fi

            dangling="$(find -L "$dir" -type l || true)"
            if [ -n "$dangling" ]; then
              echo "Dangling symlink(s) under home-files -- a .source (or a" >&2
              echo "package it came from) points at a path that does not exist:" >&2
              echo "$dangling" | sed 's/^/  /' >&2
              exit 1
            fi
            touch "$out"
          '';

        # home/audio.nix's pulseaudioClients derivation withholds the
        # pulseaudio daemon binary from its own output, on the strength of a
        # measurement made there: `strings` on libpulse.so.0 shows the bare
        # word "pulseaudio" and no absolute path to the daemon (the one
        # absolute path present is a DT_RUNPATH, a library search path, not
        # a reference to a pulseaudio executable), so PulseAudio's
        # autospawn resolves the daemon through PATH, by name. That guard
        # only inspects pulseaudioClients' own $out/bin, though -- it cannot
        # see the rest of home.packages. A `pkgs.pulseaudio` reference added
        # anywhere else in this profile (the exact mistake pulseaudioClients
        # exists to avoid, arriving a second time -- e.g. straight into
        # home.packages, alongside pulseaudioClients rather than instead of
        # it) would put the real daemon back on PATH with that guard still
        # green, silently reopening the autospawn hazard: a client that
        # failed to reach pipewire-pulse could start a real PulseAudio and
        # seize the ALSA devices, and nothing in the per-derivation guard
        # would notice.
        #
        # This check closes that gap at the level where the hazard actually
        # lives: the built profile's PATH, not any one derivation's output.
        # It walks ${suffer.activationPackage}/home-path/bin at maxdepth 1 --
        # the only directory buildEnv links from home.packages onto the
        # session's PATH, and the same store path uwsm uses for the session
        # and the same generation no-dangling-home-files above checks. A
        # transitive dependency that lands a `pulseaudio` binary there is
        # caught the same way a direct home.packages entry would be; one
        # that ships it only under home-path's sbin/ or libexec/ is not,
        # because nothing puts those on PATH either -- the scope is exactly
        # the hazard's surface, no wider and no narrower.
        no-pulseaudio-daemon =
          pkgs.runCommand "portal-stack-no-pulseaudio-daemon" { } ''
            bindir=${suffer.activationPackage}/home-path/bin

            # Prove the negative check below is actually looking somewhere,
            # not passing vacuously. `find … || true` swallows `No such
            # file or directory` silently: a typo in this path, or an
            # upstream change to the generation's layout, would make
            # $found empty for the wrong reason and this check would touch
            # $out anyway -- the "check that cannot fail" species CLAUDE.md
            # names. Asserting the directory exists, and that a binary this
            # profile always ships is actually in it, makes a path-drift
            # failure loud instead of silently green.
            if [ ! -d "$bindir" ]; then
              echo "$bindir does not exist." >&2
              echo "Either activationPackage's home-path layout changed, or" >&2
              echo "this check's path is wrong. Either way, the negative" >&2
              echo "'no pulseaudio binary found' result below would be" >&2
              echo "vacuous, not a real pass -- fix the path before trusting it." >&2
              exit 1
            fi
            if [ ! -e "$bindir/pactl" ]; then
              echo "$bindir exists but has no pactl." >&2
              echo "pactl is a known binary this profile always ships, via" >&2
              echo "home/audio.nix's pulseaudioClients. Its absence means" >&2
              echo "this check is looking in the wrong directory, not that" >&2
              echo "the profile's PATH is somehow clean." >&2
              exit 1
            fi

            found="$(find "$bindir" -maxdepth 1 -name pulseaudio || true)"
            if [ -n "$found" ]; then
              echo "A 'pulseaudio' binary is on the profile's PATH:" >&2
              echo "$found" | sed 's/^/  /' >&2
              echo "libpulse resolves the daemon by bare name through PATH" >&2
              echo "(autospawn), so its presence here restores the hazard" >&2
              echo "home/audio.nix's pulseaudioClients derivation exists to" >&2
              echo "remove: a client that cannot reach pipewire-pulse can" >&2
              echo "start a real PulseAudio and seize the ALSA devices." >&2
              echo "Likely cause: pkgs.pulseaudio was added to home.packages" >&2
              echo "directly, or pulled in transitively -- remove it and use" >&2
              echo "pulseaudioClients instead." >&2
              exit 1
            fi
            touch "$out"
          '';

        # The .desktop ids that ~/.config/mimeapps.list names AND that this
        # flake is responsible for providing. Declared here, in Nix, because a
        # flake check cannot read mimeapps.list -- it is outside the sandbox.
        #
        # This catches the failure that matters at the moment a package is
        # added: nixpkgs' signal-desktop ships signal.desktop where Debian's
        # ships signal-desktop.desktop, and mimeapps.list names the Debian id
        # for x-scheme-handler/sgnl and x-scheme-handler/signalcaptcha. Migrate
        # Signal without noticing and both handlers stop resolving, silently.
        #
        # As of 2026-08-17 mimeapps.list names six unique ids and this flake
        # provides exactly one of them, eu.calangotech.CalangoOpen.desktop --
        # measured, with `sed -n 's/^[^=]*=//p' | tr ';' '\n' | sort -u`, and a
        # count of that moment rather than a standing property. Two of the
        # other five, bitwarden.desktop and signal-desktop.desktop, are among
        # the seven follow-on applications, so the flake's share of that list
        # is expected to grow. That is the reason this check exists now rather
        # than later. The three package-shipped ids below are named by no
        # handler at all; they are here so the machinery is exercised, and
        # asserted for their own sake -- a launcher entry that vanishes is
        # worth catching whether or not a MIME handler points at it.
        #
        # TWO trees, because this flake ships .desktop entries by two
        # mechanisms and they land in different places:
        #
        #   home-path/share/applications             <- home.packages, via buildEnv
        #   home-files/.local/share/applications     <- xdg.dataFile entries
        #
        # eu.calangotech.CalangoOpen.desktop is the second kind
        # (home/apps.nix's xdg.dataFile."applications/..."), so a check reading
        # only home-path could never assert the one id that matters most --
        # adding it would have failed spuriously. An id found in either tree
        # satisfies the requirement, since both are on the session's search
        # path.
        #
        # Unlike the two checks above this one needs no "does the directory
        # exist" preamble, and the difference is the direction of the
        # assertion, not an inconsistency. Those two are negative checks
        # (nothing dangling, no pulseaudio binary), where a missing directory
        # produces an empty result that reads as a pass. This one is positive:
        # every id in `required` must be present in one tree or the other, so
        # a $apps or $files that does not exist makes some `[ ! -e ... ]` pair
        # true and the check fails. Both branches are load-bearing and neither
        # can rot unnoticed: the three package ids exist only under $apps and
        # CalangoOpen only under $files, so breaking either path breaks the
        # build. Proven by mutating each path in turn.
        gui-desktop-ids =
          pkgs.runCommand "gui-desktop-ids" { } ''
            apps=${suffer.activationPackage}/home-path/share/applications
            files=${suffer.activationPackage}/home-files/.local/share/applications
            fail=0

            # Every id this flake must ship, with the reason it is required.
            # Format: <desktop-id> <why>
            required="org.gnome.seahorse.Application.desktop seahorse-launcher
            gammastep.desktop gammastep-launcher
            gammastep-indicator.desktop gammastep-indicator-launcher
            eu.calangotech.CalangoOpen.desktop mimeapps-http-https-texthtml-about-unknown-handler
            signal.desktop mimeapps-sgnl-and-signalcaptcha-handler
            bitwarden.desktop bitwarden-launcher"

            # Anti-vacuity anchor, the same one no-pulseaudio-daemon and
            # no-dangling-home-files each carry: a positive check is only
            # evidence if it looked at something. Empty `required` and the
            # loop below runs zero times, $fail stays 0 and this derivation
            # passes without touching either tree -- a check that cannot
            # fail. Counted by non-blank lines rather than compared against a
            # fixed number, so adding an id needs no edit here.
            count="$(echo "$required" | grep -c '[^[:space:]]' || true)"
            if [ "$count" -eq 0 ]; then
              echo "the required .desktop id list is empty." >&2
              echo "  Nothing would be looked up in either tree, the loop" >&2
              echo "  below would run zero times, and this check would pass" >&2
              echo "  no matter what the flake ships -- a check that cannot" >&2
              echo "  fail is worse than no check, because it reads as one." >&2
              echo "  Restore the ids, or delete this whole check on purpose" >&2
              echo "  and say why." >&2
              exit 1
            fi

            echo "$required" | while read -r id why; do
              [ -n "$id" ] || continue
              if [ ! -e "$apps/$id" ] && [ ! -e "$files/$id" ]; then
                echo "missing .desktop id: $id (needed for: $why)" >&2
                echo "  Looked in both trees this flake ships entries to:" >&2
                echo "    $apps" >&2
                echo "    $files" >&2
                echo "  The package that should ship it does not, or ships it" >&2
                echo "  under a different name, or an xdg.dataFile entry was" >&2
                echo "  renamed or dropped. nixpkgs and Debian do not always" >&2
                echo "  agree on the id -- signal-desktop is the known case." >&2
                echo "  Check what the package actually ships." >&2
                exit 1
              fi
            done || fail=1

            [ "$fail" -eq 0 ] || exit 1
            touch "$out"
          '';

        # The bar's title slot, run for real: test/title-slot.qml drives
        # quickshell/bar/TitleSlot.qml with four bar geometries and asserts the
        # title's ink never crosses into the right section. The first of them
        # is the measured failure -- bar 1516, left 546, right 742, a bluetooth
        # headset connected -- where the old arithmetic painted the window
        # title across every pill on the right.
        #
        # This is the first check here that RUNS this flake's own QML rather
        # than inspecting a built tree, and the sandbox turned out to allow it:
        # Qt's offscreen platform needs no display, and a fonts.conf carrying
        # one font is enough for text metrics. The metrics are not the session's
        # -- DejaVu here against the session's own family -- so the assertions
        # are inequalities against the section boundaries and never fixed pixel
        # counts. Measured both ways inside the sandbox: it passes as shipped,
        # and removing TitleSlot's gap fallback fails it.
        #
        # Two environment variables are load-bearing and both fail silently.
        # Without QML2_IMPORT_PATH every file dies with "Did not load any
        # objects" and exit 0; without QT_ASSUME_STDERR_HAS_CONSOLE the runtime
        # prints nothing at all and exits 0. Hence the anchor below, which was
        # itself proven by deleting that export and watching this check fail.
        bar-title-slot =
          pkgs.runCommand "bar-title-slot"
            {
              nativeBuildInputs = [ pkgs.qt6.qtdeclarative ];
            }
            ''
              export HOME=$TMPDIR
              export XDG_RUNTIME_DIR=$TMPDIR
              export QT_QPA_PLATFORM=offscreen
              export QT_ASSUME_STDERR_HAS_CONSOLE=1
              export QT_LOGGING_RULES='*=true;qt.*=false'
              export QML2_IMPORT_PATH=${pkgs.qt6.qtdeclarative}/lib/qt-6/qml
              export FONTCONFIG_FILE=${
                pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; }
              }

              mkdir -p src/quickshell src/test
              cp -r ${./quickshell/bar} src/quickshell/bar
              cp ${./test/title-slot.qml} src/test/title-slot.qml
              cd src

              log=$TMPDIR/qml.log
              if qml test/title-slot.qml > "$log" 2>&1; then
                status=ok
              else
                status=failed
              fi
              cat "$log"

              # The anti-vacuity anchor this file's other checks carry, and it
              # is not theoretical here: without QT_ASSUME_STDERR_HAS_CONSOLE
              # the qml runtime prints NOTHING and exits 0. A bare exit-status
              # test would read that silence as a pass.
              for want in "bt connected" "bt disconnected" "empty bar" "no room at all"; do
                if ! grep -qF "$want" "$log"; then
                  echo "the QML test printed no line for case: $want" >&2
                  exit 1
                fi
              done
              if ! grep -qF PASS "$log"; then
                echo "the QML test did not report PASS." >&2
                exit 1
              fi
              [ "$status" = ok ] || exit 1
              touch "$out"
            '';
      };
    };
}
