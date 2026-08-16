# Results: completing the portal stack — suffer

2026-08-15

## Phase 1: xdg-permission-store

### What the package alone does: nothing

Both Debian's and Nix's D-Bus activation files carry
`SystemdService=<name>.service`. D-Bus prefers the unit over `Exec=`, and that
is a unit *name* resolved through the user manager's search path. Adding
`xdg-desktop-portal` to `home.packages` puts Nix's activation files in
`~/.nix-profile/share/dbus-1/services`, which the session bus does not search.
The unit at `~/.config/systemd/user` — UnitPath position 5, against
`/usr/lib/systemd/user` at 15 — is what switches a service.

### A miscount, caught before implementation

The spec's first draft said Debian ships three units from this package and
that `xdg-desktop-portal-rewrite-launchers.service` was Nix-only. It is not:

```
$ dpkg -L xdg-desktop-portal | grep systemd/user
/usr/lib/systemd/user/xdg-desktop-portal-rewrite-launchers.service
/usr/lib/systemd/user/xdg-desktop-portal.service
/usr/lib/systemd/user/xdg-document-portal.service
/usr/lib/systemd/user/xdg-permission-store.service

$ ls -l /etc/systemd/user/graphical-session-pre.target.wants/
xdg-desktop-portal-rewrite-launchers.service -> /usr/lib/systemd/user/…

$ journalctl --user -u xdg-desktop-portal-rewrite-launchers -b
Starting … Finished xdg-desktop-portal-rewrite-launchers.service
```

**Four units, enabled, and it ran at this boot.** The miscount came from
reading `systemctl --user list-units`, where a `oneshot` that has already
finished does not appear — a view that structurally could not show the thing
being counted.

The correction is recorded here rather than quietly fixed, because the
*reason* the spec gave for skipping it ("Debian never had it") was the false
part. It is genuinely a no-op on this machine — `~/.local/share/applications`
holds three entries and none was created through the DynamicLauncher portal —
but that is a different argument, and it was not the one made. Parity with
current behaviour is the default; a behaviour reduction should not ride along
inside a migration. It is installed in Phase 2.

### The dry run

`sd-switch`, extracted from the live activation script rather than
`nixpkgs#sd-switch` (the registry gives a different version than the pinned
input), reported only `xdg-permission-store.service` in its stop and start
lists. `wayland-wm@hyprland\x2dnixgl.desktop.service` and every other session
unit were under "Keeping unchanged units", so the switch was safe from inside
the running session.

### The gate

Recorded before the switch, and compared after:

```
notifications      as 1 "notification"
desktop-used-apps  as 1 "x-scheme-handler/slack"
remote-desktop     as 1 "031362ce-9406-4407-8cb6-5aee8ac03505"
```

After:

```
FragmentPath  /home/isutton/.config/systemd/user/xdg-permission-store.service
ActiveState   active
exe           /nix/store/…-xdg-desktop-portal-1.20.4/libexec/.xdg-permission-store-wrapped
usr code mappings  0

notifications      as 1 "notification"
desktop-used-apps  as 1 "x-scheme-handler/slack"
remote-desktop     as 1 "031362ce-9406-4407-8cb6-5aee8ac03505"
```

All three identical. No failed units.

The table contents are the property being checked. A service being active
proves it started; it does not prove it can still read the database it exists
to serve, and the database lives outside the package in
`~/.local/share/flatpak/db`. `desktop-used-apps` holding
`x-scheme-handler/slack` is Slack's own registration, which makes it a
usefully concrete thing to have survive.
