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

      pkgs = import nixpkgs {
        inherit system;
        overlays = [ nixgl.overlays.default ];
      };

      mkHome = username: home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          ./home/default.nix
          ./home/session.nix
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
