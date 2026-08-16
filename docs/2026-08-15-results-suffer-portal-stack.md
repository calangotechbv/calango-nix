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

## Phase 2: the frontend, and rewrite-launchers

### The dry run

`sd-switch` listed `xdg-desktop-portal.service` in **both** its stopping and
starting lists. That is the takeover, not an anomaly: the unit is absent from
the old generation's managed directory entirely, while Debian's copy at
position 15 is live — so sd-switch stops the running Debian instance and
starts Nix's from position 5.

`graphical-session-pre.target` itself was never touched. The only new thing on
it, `xdg-desktop-portal-rewrite-launchers.service`, appeared under "Starting
units" as a one-time start — the same mechanism `fumon.service` uses. That
target matters because it runs earlier in session startup than anything Phase
1 touched: a unit that fails there fails before the compositor exists.

The compositor stayed in "Keeping unchanged units".

### Provenance after the switch

```
xdg-desktop-portal.service
  FragmentPath  /home/isutton/.config/systemd/user/xdg-desktop-portal.service
  ActiveState   active
  exe           /nix/store/…-xdg-desktop-portal-1.20.4/libexec/.xdg-desktop-portal-wrapped
  usr code mappings  0

xdg-desktop-portal-rewrite-launchers.service
  FragmentPath   /home/isutton/.config/systemd/user/…
  UnitFileState  enabled
  Result         success
```

`UnitFileState=enabled` is the part worth checking. Unlike the other three
units this one carries `WantedBy=graphical-session-pre.target`, so the unit
file alone does not enable it — the `.wants` entry in the flake does, the same
shape `home/uwsm.nix` uses for `fumon.service`. Without it the unit would
exist and never run, and nothing would look wrong.

Phase 1's permission store was re-checked and still resolves to Nix's binary;
no failed units.

### The check the plan specified could not answer the question

The plan's Step 6 said to read the frontend's journal for its chosen backend
implementations. At default verbosity it logs nothing of the sort — only
`Starting` and `Stopped` lines. The check would have produced no evidence
either way, and "no contradicting log line" reads as success.

The question mattered: a *different* frontend build reading the same config
could parse it differently, and if `1.20.4` disagreed with `1.20.3`, backend
selection would silently revert to the accidental fallback it was before spec
7 — while every symptom still looked like a working portal.

So the evidence was obtained directly, by running the new binary verbosely
against a throwaway bus:

```
$ dbus-run-session -- env XDG_CURRENT_DESKTOP=Hyprland \
    /nix/store/…-xdg-desktop-portal-1.20.4/libexec/xdg-desktop-portal -v

XDP: Looking for portals configuration in '…/xdg-desktop-portal/hyprland-portals.conf'
XDP: Using portal configuration file '…/hyprland-portals.conf' for desktop 'hyprland'
XDP: Found 'gtk' in configuration for default
XDP: Using gtk.portal for org.freedesktop.impl.portal.FileChooser (config)
XDP: Using gtk.portal for org.freedesktop.impl.portal.Settings (config)
XDP: Using gtk.portal for org.freedesktop.impl.portal.Print (config)
XDP: Found 'hyprland' in configuration for org.freedesktop.impl.portal.Screenshot
XDP: Using hyprland.portal for org.freedesktop.impl.portal.Screenshot (config)
```

Every interface resolves `(config)`. Note `for desktop 'hyprland'` —
lower-cased, which is the same case-folding rule that made spec 7's first
attempt at this filename unreadable.

### The human checks

A file dialog in Chrome, a screenshot, and a screen share, all confirmed by
the user after the switch. The process serving the open dialog was Nix's gtk
backend:

```
org.freedesktop.impl.portal.desktop.gtk  PID 3514
  /nix/store/…-xdg-desktop-portal-gtk-1.15.3/libexec/.xdg-desktop-portal-gtk-wrapped
```

These exist because a process check passes whether or not anything draws.
