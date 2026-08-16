{ pkgs, ... }:

let
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
  #
  # This is the one unit in this file re-described with systemd.user.services
  # rather than copied verbatim (contrast the gtk unit below, which argues
  # against exactly that for the drift risk it creates). The risk is the same
  # here and is accepted deliberately, not overlooked: ExecStart must route
  # through nixGL, which a verbatim copy of upstream's unit cannot express, so
  # owning a copy that can drift from upstream is the cost of the wrapper, not
  # a side effect nobody noticed.
  portal-nixgl = pkgs.writeShellScript "xdg-desktop-portal-hyprland-nixgl" ''
    exec ${pkgs.nixgl.nixGLIntel}/bin/nixGLIntel \
      ${pkgs.xdg-desktop-portal-hyprland}/libexec/xdg-desktop-portal-hyprland "$@"
  '';
in
{
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

  # Nix's own gtk portal unit, at ~/.config/systemd/user (UnitPath position 5)
  # so it beats Debian's at /usr/lib/systemd/user (position 15).
  #
  # This is the part that actually switches the backend. Both D-Bus activation
  # files -- Debian's and Nix's -- said
  # `SystemdService=xdg-desktop-portal-gtk.service`, and D-Bus prefers the unit
  # over the Exec= line. That is a unit *name*, so whichever unit wins the
  # search path decides which binary runs. Installing the package without this
  # would leave Debian's unit answering, and Debian's binary serving, while
  # every file looked correct. Debian's activation file is gone now -- spec 7
  # removed it -- so today only Nix's exists, but the D-Bus preference-over-
  # Exec= behaviour it relies on is unchanged.
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
  # hyprland. Nix's frontend, 1.20.4, parses the format -- confirmed directly
  # by running it verbosely against a throwaway bus (`dbus-run-session -- env
  # XDG_CURRENT_DESKTOP=Hyprland .../xdg-desktop-portal -v`), where every
  # interface resolves the backend named here with "(config)". Debian's
  # 1.20.3+ds-1 shipped portals.conf(5) too, before this spec removed the
  # package.
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
  # Those numbers are `systemctl --user show -p UnitPath --value`, the
  # manager's own list. `systemd-analyze --user unit-paths` looks like the
  # obvious way to check this and answers a different question: it computes
  # the path from the *calling* process's environment, and a shell in the
  # graphical session has XDG_DATA_DIRS entries (~/.nix-profile/share among
  # them) that the manager itself never saw at startup. That shifts
  # /usr/lib/systemd/user to 18 and invents a
  # ~/.nix-profile/share/systemd/user entry that isn't on the manager's list
  # at all -- which is exactly why the xdg.configFile entries below, not the
  # package in home.packages, are what switches each service.
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

  # 2 of 3: the frontend. Every portal call goes through it, and it is what
  # reads hyprland-portals.conf above to choose between the gtk and hyprland
  # backends.
  config.xdg.configFile."systemd/user/xdg-desktop-portal.service".source =
    "${pkgs.xdg-desktop-portal}/share/systemd/user/xdg-desktop-portal.service";

  config.xdg.dataFile."dbus-1/services/org.freedesktop.portal.Desktop.service".source =
    "${pkgs.xdg-desktop-portal}/share/dbus-1/services/org.freedesktop.portal.Desktop.service";

  # 3 of 3: the document portal. This one holds a live fuse.portal mount at
  # /run/user/1000/doc, and it is how flatpak applications reach files outside
  # their sandbox -- Slack among them, which is corp software here. Swapping
  # the binary means the mount is torn down and recreated, so the switch is
  # followed by a reboot rather than a restart, and the gate is Slack moving a
  # file rather than the mount merely existing.
  config.xdg.configFile."systemd/user/xdg-document-portal.service".source =
    "${pkgs.xdg-desktop-portal}/share/systemd/user/xdg-document-portal.service";

  config.xdg.dataFile."dbus-1/services/org.freedesktop.portal.Documents.service".source =
    "${pkgs.xdg-desktop-portal}/share/dbus-1/services/org.freedesktop.portal.Documents.service";

  # Debian ships four units from this package and enables this one via
  # /etc/systemd/user/graphical-session-pre.target.wants. It runs at every
  # graphical session start and finishes in under a second.
  #
  # A oneshot that rewrites .desktop entries created through the
  # DynamicLauncher portal. There are none on this machine, so it does nothing
  # here -- it is installed for parity with what Debian already does, not
  # because anything needs it. Dropping it would be a behaviour change smuggled
  # into a migration.
  #
  # Unlike the other three units this one carries
  # WantedBy=graphical-session-pre.target, so the unit file alone does not
  # enable it. The .wants link below does, owned here rather than left to the
  # root-owned /etc symlink that Debian's package installed and that Task 4
  # deletes. Same shape as fumon.service in home/uwsm.nix.
  config.xdg.configFile."systemd/user/xdg-desktop-portal-rewrite-launchers.service".source =
    "${pkgs.xdg-desktop-portal}/share/systemd/user/xdg-desktop-portal-rewrite-launchers.service";

  config.xdg.configFile."systemd/user/graphical-session-pre.target.wants/xdg-desktop-portal-rewrite-launchers.service".source =
    "${pkgs.xdg-desktop-portal}/share/systemd/user/xdg-desktop-portal-rewrite-launchers.service";
}
