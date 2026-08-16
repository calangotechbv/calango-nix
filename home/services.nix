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

  # Established by a linkage check on the real binary plus the user manager's
  # environment -- NOT by analogy with quickshell, which is what Task 4 was
  # told not to do.
  #
  # libexec/xdg-desktop-portal-hyprland is a makeWrapper shim that only
  # prepends the package's own bin to PATH (so the portal can find
  # hyprland-share-picker) and then execs
  # libexec/.xdg-desktop-portal-hyprland-wrapped. Plain `ldd` on that real
  # binary shows a direct, non-dlopen dependency:
  #
  #   libgbm.so.1 => /nix/store/...-mesa-libgbm-26.0.3/lib/libgbm.so.1
  #
  # so the ldd-is-a-false-negative caveat that applies to Qt's dlopen'd
  # plugins does not apply here -- the linker resolves this one at load.
  # And `systemctl --user show-environment` contains none of
  # GBM_BACKENDS_PATH, LIBGL_DRIVERS_PATH, __EGL_VENDOR_LIBRARY_FILENAMES or
  # LD_LIBRARY_PATH, so Nix's libgbm falls back to its compiled-in
  # /run/opengl-driver/lib/gbm, which does not exist on Debian.
  #
  # The switch replaces the live Debian portal with this one, so there is no
  # later moment of controlled choice. Wrapped on the outside, exactly as
  # quickshell.service and hyprpolkitagent are: nixGLIntel -> the makeWrapper
  # shim -> the real binary, which keeps the shim's PATH work intact and hands
  # the share-picker the GL environment too, since it is a child of this unit.
  portal-nixgl = pkgs.writeShellScript "xdg-desktop-portal-hyprland-nixgl" ''
    exec ${pkgs.nixgl.nixGLIntel}/bin/nixGLIntel \
      ${pkgs.xdg-desktop-portal-hyprland}/libexec/xdg-desktop-portal-hyprland "$@"
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

  # Debian's /usr/lib/systemd/user/xdg-desktop-portal-hyprland.service names
  # /usr/libexec/xdg-desktop-portal-hyprland absolutely, so removing apt's
  # package takes the running implementation with it. A user unit of the same
  # name shadows the system one.
  #
  # Nix's .portal file already wins on its own: ~/.nix-profile/share is first in
  # the session's XDG_DATA_DIRS, so no XDG work is needed here. The D-Bus
  # *activation* file (org.freedesktop.impl.portal.desktop.hyprland.service)
  # is a different story -- see the xdg.dataFile block below this unit.
  #
  # Type=dbus and BusName are copied from Debian's unit deliberately. The portal
  # frontend activates this over D-Bus, and Type=simple would let systemd report
  # it started before it owns the name.
  #
  # ExecStart is the nixGL wrapper, not the portal binary -- see portal-nixgl
  # above for the linkage evidence that established it.
  config.systemd.user.services.xdg-desktop-portal-hyprland = {
    Unit = {
      Description = "Portal service (Hyprland implementation)";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
      ConditionEnvironment = "WAYLAND_DISPLAY";
    };
    Service = {
      Type = "dbus";
      BusName = "org.freedesktop.impl.portal.desktop.hyprland";
      ExecStart = "${portal-nixgl}";
      Restart = "on-failure";
      Slice = "session.slice";
    };
  };

  # Post-reboot verification found the portal not D-Bus activatable:
  # `ServiceUnknown: The name is not activatable`. Apt's package used to ship
  # /usr/share/dbus-1/services/org.freedesktop.impl.portal.desktop.hyprland.service,
  # and removing that package took the .service file with it, even though
  # xdg-desktop-portal-hyprland is already in home.packages (home/default.nix)
  # and its own SystemdService= line already names the unit above.
  #
  # This is NOT redundant with the .portal file. The two are read by
  # different consumers with different startup timing:
  #
  #   - hyprland.portal (share/xdg-desktop-portal/portals/) is read by
  #     xdg-desktop-portal itself, which starts under the graphical session
  #     after uwsm has set XDG_DATA_DIRS -- so ~/.nix-profile/share, first in
  #     that list, is searched and the file is found there. No copy needed.
  #
  #   - This .service file is read by dbus-broker's activation scanner,
  #     which starts long before uwsm runs and so scans XDG_DATA_DIRS from
  #     its own earlier environment -- one that never gets ~/.nix-profile/share
  #     added to it. dbus-broker does search ~/.local/share/dbus-1/services,
  #     though, which is why that -- not the profile -- is where this needs
  #     to land. Same shape as home/apps.nix's .desktop entries, which go to
  #     ~/.local/share/applications for the analogous reason.
  #
  # Proven by hand: copying this file to ~/.local/share/dbus-1/services/ and
  # calling dbus's ReloadConfig made the Ping return and the unit go active.
  # xdg.dataFile reproduces that placement declaratively.
  config.xdg.dataFile."dbus-1/services/org.freedesktop.impl.portal.desktop.hyprland.service".source =
    "${pkgs.xdg-desktop-portal-hyprland}/share/dbus-1/services/org.freedesktop.impl.portal.desktop.hyprland.service";

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

  # Nix's own gtk portal unit, at ~/.config/systemd/user (UnitPath position 5)
  # so it beats Debian's at /usr/lib/systemd/user (position 15).
  #
  # This is the part that actually switches the backend. Both D-Bus activation
  # files -- Debian's and Nix's -- say
  # `SystemdService=xdg-desktop-portal-gtk.service`, and D-Bus prefers the unit
  # over the Exec= line. That is a unit *name*, so whichever unit wins the
  # search path decides which binary runs. Installing the package without this
  # would leave Debian's unit answering, and Debian's binary serving, while
  # every file looked correct.
  #
  # Copied verbatim rather than re-described with systemd.user.services: Nix's
  # unit already carries an absolute store path in ExecStart and needs no
  # nixGL wrapper (the binary has no libGL, libEGL or libgbm linkage, unlike
  # xdg-desktop-portal-hyprland above). Re-describing it would mean owning a
  # copy that can drift from upstream. The verbatim copy also means this unit
  # does not get the hyprland unit's Restart=on-failure or Slice=session.slice
  # -- Nix's file simply doesn't set them. That asymmetry is deliberate, not
  # an oversight: Type=dbus plus the xdg.dataFile activation entry below means
  # a crashed gtk backend is re-activated on the next portal call, so
  # Restart=on-failure buys little, and the slice assignment is cosmetic.
  #
  # xdg.configFile rather than home.file.".config/...": home-manager's own
  # systemd module writes user units through xdg.configFile, and sd-switch
  # follows xdg.configHome, not a literal ".config". Identical today, since
  # xdg.configHome defaults to ~/.config, but a literal path would silently
  # stop being seen by sd-switch if xdg.configHome were ever set elsewhere.
  config.xdg.configFile."systemd/user/xdg-desktop-portal-gtk.service".source =
    "${pkgs.xdg-desktop-portal-gtk}/share/systemd/user/xdg-desktop-portal-gtk.service";

  # Same bug as xdg-desktop-portal-hyprland's D-Bus activation file above,
  # for the same reason: the session bus's own XDG_DATA_DIRS omits the Nix
  # profile (`systemctl --user show dbus.service -p MainPID --value`, then
  # `tr '\0' '\n' < /proc/<pid>/environ | grep XDG_DATA_DIRS` shows only
  # flatpak, /usr/local/share and /usr/share -- no ~/.nix-profile/share). The
  # package's own presence in home.packages is not enough once Debian's copy
  # of this file is gone; ~/.local/share/dbus-1/services is XDG_DATA_HOME,
  # which the bus searches ahead of XDG_DATA_DIRS, so this is where the copy
  # needs to land.
  config.xdg.dataFile."dbus-1/services/org.freedesktop.impl.portal.desktop.gtk.service".source =
    "${pkgs.xdg-desktop-portal-gtk}/share/dbus-1/services/org.freedesktop.impl.portal.desktop.gtk.service";

  # Backend selection, declared rather than inherited.
  #
  # Without this file the choice is accidental: gtk.portal declares
  # `UseIn=gnome`, which does not match this session, so it wins only as
  # xdg-desktop-portal's last-resort fallback. Removing the kde and lxqt
  # backends would silently change which backend serves which interface. With
  # it, the removals are a no-op.
  #
  # The filename is not arbitrary, but it is not $XDG_CURRENT_DESKTOP
  # verbatim either. `man 5 portals.conf`: "DESKTOP is the desktop
  # environment name in lower-case" -- case-folding ASCII upper case to lower
  # case, with KDE's own example being kde-portals.conf for desktop name
  # "KDE". This session reports XDG_CURRENT_DESKTOP=Hyprland, lower-cased to
  # hyprland. Debian's frontend is 1.20.3 and supports the format -- it ships
  # portals.conf(5).
  config.xdg.configFile."xdg-desktop-portal/hyprland-portals.conf".text = ''
    [preferred]
    default=gtk
    org.freedesktop.impl.portal.Screenshot=hyprland
    org.freedesktop.impl.portal.ScreenCast=hyprland
    org.freedesktop.impl.portal.GlobalShortcuts=hyprland
    org.freedesktop.impl.portal.Secret=gnome-keyring
  '';

  # The portal frontend's three services, migrated one at a time. All three
  # come from a single package; each moves independently because each unit is
  # placed here at UnitPath position 5, ahead of /usr/lib/systemd/user at 15.
  #
  # Copied verbatim rather than re-described: Nix's three units diff identical
  # to Debian's apart from ExecStart -- same Type=dbus, BusName, Slice and
  # PartOf. None of the three binaries links libGL, libEGL or libgbm (checked
  # with ldd), so unlike xdg-desktop-portal-hyprland above they need no nixGL
  # wrapper.
  #
  # The xdg.dataFile entries are not redundant with the package. They matter
  # from the moment Debian's package is removed and its own activation files
  # disappear: the session bus searches XDG_DATA_HOME but not the Nix profile,
  # so ~/.local/share is where Nix's copies have to be. Same reason the gtk
  # backend above has one.

  # 1 of 3: the permission store. Smallest surface, no visible consumer, and
  # its data lives outside the package in ~/.local/share/flatpak/db.
  config.xdg.configFile."systemd/user/xdg-permission-store.service".source =
    "${pkgs.xdg-desktop-portal}/share/systemd/user/xdg-permission-store.service";

  config.xdg.dataFile."dbus-1/services/org.freedesktop.impl.portal.PermissionStore.service".source =
    "${pkgs.xdg-desktop-portal}/share/dbus-1/services/org.freedesktop.impl.portal.PermissionStore.service";
}
