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

      pkgs = import nixpkgs {
        inherit system;
        overlays = [ nixgl.overlays.default debianPolkit ];
      };

      mkHome = username: home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          ./home/default.nix
          ./home/session.nix
          ./home/quickshell.nix
          {
            home.username = username;
            home.homeDirectory = "/home/${username}";
            home.stateVersion = "26.05";
          }
        ];
      };
    in
    {
      homeConfigurations = {
        "nixtest@suffer" = mkHome "nixtest";
        "isutton@suffer" = mkHome "isutton";
      };
    };
}
