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
              # Kept explicit even though home/gui-apps.nix now puts gammastep
              # in the profile: a unit that resolves its own binaries does not
              # depend on PATH order, and this one was right when the shell was
              # wrong.
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

  # A store path that IS a symlink to /dev/null, for masking a systemd unit.
  #
  # The obvious `.source = "/dev/null"` does not build. xdg.configFile's source
  # is a types.path, so Nix coerces the string and tries to import /dev/null
  # into the store:
  #
  #   error: access to absolute path '/dev' is forbidden in pure evaluation mode
  #
  # This was found the hard way, and the lesson is narrower than "masking does
  # not work declaratively": the mask shape was probed against systemd first,
  # by hand, and it passed -- but that probe only asked whether systemd accepts
  # a store-mediated link to /dev/null. It never asked whether Nix can emit
  # one. Two layers, two questions; the second was assumed.
  #
  # The symlink is created inside the builder, where nothing reads /dev/null --
  # `ln -s` does not resolve its target -- so this is pure. The resulting
  # store path is what both masks point at, and it is the same shape the
  # by-hand probe confirmed systemd reads as a mask.
  #
  # `find -L ... -type l` in flake.nix's no-dangling-home-files does not flag
  # it, because /dev/null exists and so the link resolves.
  maskUnit = pkgs.runCommand "systemd-mask-dev-null" { } "ln -s /dev/null $out";

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

  # Two ssh agents were running, and which one your shell talked to was a race.
  #
  # Debian enables both openssh's ssh-agent.socket and gcr4's
  # gcr-ssh-agent.socket, and *both* set the same variable from ExecStartPost:
  #
  #   ssh-agent.socket      set-environment SSH_AUTH_SOCK=%t/openssh_agent
  #   gcr-ssh-agent.socket  set-environment SSH_AUTH_SOCK=%t/gcr/ssh
  #
  # There is no ordering between them. Both reached active in the same second
  # (measured: ActiveEnterTimestamp 14:14:18 for each), and the winner is
  # whichever ExecStartPost ran last. openssh won that day; nothing guarantees
  # tomorrow. That is why both agents looked idle -- the one holding the socket
  # had no keys, and the one with the keyring behind it was never consulted.
  #
  # gcr-ssh-agent is kept and openssh's units are masked, so exactly one unit
  # can set the variable and the race is gone by construction rather than by
  # luck of activation order.
  #
  # Keeping gcr rather than openssh's is not a functional trade: gcr-ssh-agent
  # is a *wrapper*, and it runs openssh's own agent underneath on a private
  # socket -- `/usr/bin/ssh-agent -D -a /run/user/1000/gcr/.ssh`, observed as
  # its child process. Its unit declares only Requires=gcr-ssh-agent.socket
  # and nothing about ssh-agent.service, so masking openssh's cannot break it.
  # The deciding argument is that gcr4 cannot be removed from this machine at
  # any price: `apt-get -s remove gcr4` takes gnome-keyring, seahorse,
  # pinentry-gnome3 and golang-docker-credential-helpers with it. Since the
  # package is a permanent resident either way, the agent that at least has a
  # keyring path is the better one to keep. See CLAUDE.md for the open question
  # about whether that path can be made to work.
  #
  # Home Manager's services.ssh-agent was considered and rejected. It is not a
  # drop-in: it sets SSH_AUTH_SOCK only through shell initialisation
  # (`sshAuthSock.initialization`, bash/fish/nushell exports), where Debian's
  # socket sets it in the user manager's environment. Switching would leave
  # every GUI application not launched from a shell without the variable.
  #
  # MASKED, not disabled by deleting Debian's /etc links. gcr4's and
  # openssh-client's postinst run `deb-systemd-helper --user unmask` and then
  # re-enable when `was-enabled` returns true -- and it defaults to true, since
  # a bare `rm` never updates that helper's statefile. So the next upgrade of
  # either package would silently restore the links. deb-systemd-helper only
  # ever touches /etc, so a mask here at UnitPath position 5 survives it.
  #
  # A mask is a symlink to /dev/null, and xdg.configFile emits two hops --
  # ~/.config/... -> the home-manager-files store path -> /dev/null. That
  # matters because home/audio.nix's alias needed a raw `ln -s` for exactly
  # this reason: systemd judges an *alias* by the link's immediate target, so a
  # store path defeats it. Masking asks a different question -- does this unit
  # path resolve to /dev/null -- and that is a full chase, so the indirection
  # is invisible to it. Probed by hand on this machine before this was written:
  # both the raw link and the two-hop store link produced LoadState=masked.
  # Do not generalise either result to the other.
  #
  # Note masking does not stop a running unit: ActiveState stayed `active`
  # through both probes. "masked" after a switch says nothing about the
  # process, which is why this is verified after a reboot.
  config.xdg.configFile = {
    "systemd/user/ssh-agent.service".source = maskUnit;
    "systemd/user/ssh-agent.socket".source = maskUnit;
  };
}
