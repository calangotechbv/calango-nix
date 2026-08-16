{ config, lib, pkgs, ... }:

let
  # Derived by reading quickshell/night-light/run.sh. Deliberately excludes
  # curl and jq: those belong to locate.sh, which quickshell spawns, not this
  # unit -- see home/quickshell.nix's runtimeDeps.
  #
  # run.sh's own #!/bin/sh resolves to Debian's dash, so its `printf` is a
  # dash builtin, not a PATH lookup; `[`, `case`, `read`, `exec`, `set --`
  # are builtins too. What is actually invoked as a command:
  nightLightPath = lib.makeBinPath (with pkgs; [
    gammastep # -m wayland/-l/-t/-O, the whole point of the unit (run.sh:88,93,103)
    gnused    # sed, to read mode/temp out of the conf file (run.sh:38)
    coreutils # tail, to take the last assignment when a key repeats (run.sh:38)
  ]);

  # PyGObject resolves NM and Secret through GI typelibs, which are not on any
  # default search path here. Verified present before this was written:
  # networkmanager ships NM-1.0.typelib and libsecret ships Secret-1.typelib.
  # pkgs.glib's default output is "bin" (no lib/ directory at all); the
  # typelibs -- GLib-2.0, GObject-2.0, Gio-2.0 -- live in pkgs.glib.out,
  # since glib >= 2.80 folded libgirepository into glib itself. gobject-
  # introspection's own girepository-1.0 directory was checked and does not
  # carry GLib/GObject/Gio, so it does not belong in this path.
  nmSecretTypelibs = lib.concatStringsSep ":" [
    "${pkgs.networkmanager}/lib/girepository-1.0"
    "${pkgs.libsecret}/lib/girepository-1.0"
    "${pkgs.glib.out}/lib/girepository-1.0"
  ];

  nmSecretPython = pkgs.python3.withPackages (ps: [ ps.pygobject3 ]);

  nmSecretAgent = pkgs.writeShellScriptBin "nm-secret-agent" ''
    export GI_TYPELIB_PATH=${nmSecretTypelibs}''${GI_TYPELIB_PATH:+:$GI_TYPELIB_PATH}
    exec ${nmSecretPython}/bin/python3 ${./../network/nm-secret-agent} "$@"
  '';

in
{
  config.home.packages = [ nmSecretAgent ];

  config.systemd.user.services.bt-agent = {
    Unit = {
      Description = "Bluetooth pairing agent";
      Documentation = "man:bt-agent(1)";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" "bluetooth.service" ];
    };
    Service = {
      Type = "simple";
      # Was a bare `bt-agent`, resolving to apt's bluez-tools through the
      # default unit PATH.
      ExecStart = "${pkgs.bluez-tools}/bin/bt-agent -c NoInputNoOutput";
      KillSignal = "SIGINT";
      Restart = "on-failure";
      RestartSec = 2;
      Slice = "app.slice";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  config.systemd.user.services.night-light = {
    Unit = {
      Description = "Night light (gammastep)";
      Documentation =
        "file://${./../docs/superpowers/specs/2026-08-14-user-layer-design.md}";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
      ConditionEnvironment = "WAYLAND_DISPLAY";
    };
    Service = {
      Type = "simple";
      ExecStart = "${config.calango.quickshellConfig}/night-light/run.sh";
      Environment = [ "PATH=${nightLightPath}" ];
      Slice = "app.slice";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  config.systemd.user.services.nm-secret-agent = {
    Unit = {
      Description = "NetworkManager secret agent (login keyring)";
      Documentation =
        "file://${./../docs/superpowers/specs/2026-08-14-user-layer-design.md}";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" "NetworkManager.service" ];
      StartLimitIntervalSec = 60;
      StartLimitBurst = 5;
    };
    Service = {
      Type = "simple";
      # Was %h/.local/bin/nm-secret-agent, which install.sh symlinked.
      ExecStart = "${nmSecretAgent}/bin/nm-secret-agent";
      Restart = "on-failure";
      RestartSec = 2;
      Slice = "app.slice";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
