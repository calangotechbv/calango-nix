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

  outputs = { nixpkgs, home-manager, nixgl, ... }:
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
          ./home/uwsm.nix
          {
            home.username = username;
            home.homeDirectory = "/home/${username}";
            home.stateVersion = "26.05";
            calango.host = hostname;
          }
        ];
      };
      suffer = mkHome "isutton" "suffer";
    in
    {
      homeConfigurations = {
        "isutton@suffer" = suffer;
      };

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
      checks.${system} = {
        no-dangling-home-files =
          pkgs.runCommand "portal-stack-no-dangling-home-files" { } ''
            dangling="$(find -L ${suffer.activationPackage}/home-files -type l || true)"
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
        # word "pulseaudio" and no absolute store path, so PulseAudio's
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
        # It walks ${suffer.activationPackage}/home-path/bin -- the same
        # store path uwsm puts on PATH for the session, and the same
        # generation no-dangling-home-files above checks -- rather than
        # reasoning about which packages are listed in home.packages, so a
        # transitive dependency that happens to ship a `pulseaudio` binary is
        # caught the same way a direct one would be.
        no-pulseaudio-daemon =
          pkgs.runCommand "portal-stack-no-pulseaudio-daemon" { } ''
            found="$(find ${suffer.activationPackage}/home-path/bin -maxdepth 1 -name pulseaudio || true)"
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
      };
    };
}
