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

## Phase 3: the document portal

The phase the spec was written around. `xdg-document-portal` holds a live
`fuse.portal` mount at `/run/user/1000/doc`, and flatpak Slack — corp software
here — reaches files outside its sandbox through it.

### Recorded before the switch

```
portal on /run/user/1000/doc type fuse.portal (rw,nosuid,nodev,relatime,user_id=1000,group_id=1000)
PID 3485   exe /usr/libexec/xdg-document-portal
com.slack.Slack   (flathub, system)
```

Captured first, deliberately. Without a pre-switch record the post-reboot
check degrades into "a mount exists, looks fine", which is the proxy this
whole spec argues against.

### Handed over by a reboot, not an unmount

The mount was held by the running Debian process. Tearing down a live
`fuse.portal` under a running session to swap the binary underneath it is a
worse operation to reason about than letting the machine restart, so the plan
switched and rebooted. The dry run showed the same takeover pattern as the
frontend: `xdg-document-portal.service` in both stop and start lists, because
the unit is absent from the old generation's managed directory while Debian's
copy at position 15 is live.

### After the reboot

```
$ who -b
system boot  2026-08-16 08:46

$ mount | grep /run/user/1000/doc
portal on /run/user/1000/doc type fuse.portal (rw,nosuid,nodev,relatime,user_id=1000,group_id=1000)

xdg-document-portal.service
  FragmentPath  /home/isutton/.config/systemd/user/xdg-document-portal.service
  ActiveState   active
  PID           3923   (was 3485)
  exe           /nix/store/…-1.20.4/libexec/.xdg-document-portal-wrapped
  usr code mappings  0
```

All three services now answer from the store:

```
org.freedesktop.impl.portal.PermissionStore  …/libexec/.xdg-permission-store-wrapped
org.freedesktop.portal.Desktop               …/libexec/.xdg-desktop-portal-wrapped
org.freedesktop.portal.Documents             …/libexec/.xdg-document-portal-wrapped
```

No failed units.

### The gate

**The user uploaded a file to Slack and downloaded one back.** Both
directions, after the reboot.

That is the property. The mount reappearing is a proxy: a `fuse.portal` mount
can be present at `/run/user/1000/doc` while a sandboxed application cannot
traverse it, so "the mount is back" would have passed in a world where Slack
was broken. A file crossing the sandbox boundary in both directions is the
only check that distinguishes those two states, and it is the one step in this
spec a machine could not perform.

Debian's package is still installed at this point, so the whole phase remained
reversible: removing the document-portal lines from `home/services.nix` and
switching back would have handed the mount to Debian's units at position 15.

## Phase 4: Debian's package removed

### The gate before the removal

```
$ apt-get -s remove xdg-desktop-portal | grep '^Remv'
xdg-desktop-portal
```

One package. Nothing in the keep list — flatpak, the corp applications,
`bluez`, `gnome-keyring`, `greetd`, `xdg-desktop-portal-gtk` all absent from
it.

The in-use check unioned a `/proc` walk with `ps -eo args`, because
`/proc/<pid>/maps` is unreadable for other users' processes and root
outnumbers user processes roughly three to one here — a `/proc`-only check
covers about a quarter of the system, which spec 7 discovered two phases after
relying on it. 911 distinct in-use paths resolved to 293 packages.

The intersection with the removal list was **empty**, which is better than the
plan predicted. The plan expected `xdg-desktop-portal` to appear, since its
binaries would still be running; Tasks 1–3 had already replaced all of them.
Confirmed directly: no `/usr/libexec/xdg-*` process existed.

### The dangling enablement link, for the third time

Removing the package left
`/etc/systemd/user/graphical-session-pre.target.wants/xdg-desktop-portal-rewrite-launchers.service`
pointing at a file that no longer exists. dpkg's systemd helper creates these
links; dpkg does not own them, so it never removes them.

Third occurrence in three specs — apt's `fumon` link survived the uwsm
removal, apt's `ydotool` link survived that one. By this spec it was written
into the plan as a step rather than found again, which is the only difference
between a pattern and a recurring surprise. Nix's own enablement link in
`~/.config/systemd/user/graphical-session-pre.target.wants/` is untouched.

### Before the reboot

Debian's four units and three portal D-Bus activation files gone. Nix's five
present in `XDG_DATA_HOME`, each naming the correct unit:

```
org.freedesktop.portal.Desktop.service              → xdg-desktop-portal.service
org.freedesktop.portal.Documents.service            → xdg-document-portal.service
org.freedesktop.impl.portal.PermissionStore.service → xdg-permission-store.service
org.freedesktop.impl.portal.desktop.gtk.service     (spec 7)
org.freedesktop.impl.portal.desktop.hyprland.service (spec 5)
```

This was checked *before* the reboot deliberately. Until this moment every
service had two activation files available and Debian's could silently cover a
gap in Nix's. Afterwards it could not.

### The cold boot

```
$ who -b
system boot  2026-08-16 09:46

org.freedesktop.impl.portal.PermissionStore  pid 3187  …/libexec/.xdg-permission-store-wrapped
org.freedesktop.portal.Desktop               pid 3378  …/libexec/.xdg-desktop-portal-wrapped
org.freedesktop.portal.Documents             pid 3398  …/libexec/.xdg-document-portal-wrapped

portal on /run/user/1000/doc type fuse.portal (rw,nosuid,nodev,relatime,…)

notifications      as 1 "notification"
desktop-used-apps  as 1 "x-scheme-handler/slack"
remote-desktop     as 1 "031362ce-9406-4407-8cb6-5aee8ac03505"

xdg-desktop-portal-rewrite-launchers.service
  UnitFileState  enabled
  Result         success
  FragmentPath   /home/isutton/.config/systemd/user/…

xdg-desktop-portal  rc
Debian portal binaries running: none
```

Every service activated from Nix's D-Bus files alone. No failed units. The
permission tables still hold the values recorded before Phase 1 touched
anything.

Then the four human checks again — file dialog, screenshot, screen share, and
a Slack upload and download — all passing against a system with no Debian
portal package at all.

### Passing cleanup

`org.gtk.Gtk3theme.Breeze` uninstalled: a KDE GTK theme orphaned when spec 7
removed the KDE desktop. `flatpak list --app` now shows only
`com.slack.Slack`, with the freedesktop Platform runtimes behind it.

## Did it work?

| Question | Before | After |
|---|---|---|
| `org.freedesktop.portal.Desktop` | Debian `1.20.3+ds-1` | Nix `1.20.4`, store path |
| `org.freedesktop.portal.Documents` | Debian | Nix |
| `org.freedesktop.impl.portal.PermissionStore` | Debian | Nix |
| Portal backends (from spec 7) | Nix | Nix, unchanged |
| Portal subsystem provenance | **mixed** — Nix backends under a Debian frontend | **entirely Nix's** |
| `xdg-desktop-portal` package | `ii` | `rc` |
| Debian units from it | 4 | 0 |
| Portal D-Bus activation files serving | Debian's and Nix's both present | Nix's only |
| FUSE mount at `/run/user/1000/doc` | Debian's binary | Nix's binary |
| Slack file transfer | works | works |
| Installed packages | 2221 | 2220 |
| Debian user services running | 17 | 15 |

The mixed-provenance subsystem is closed. That was the point: two Nix backends
running under a Debian frontend is the same half-migrated shape that produced
spec 6's `fumon` defect, where a Nix unit ran a Debian binary and no check
noticed for two phases.

## Every defect, and who owns it

### The spec miscounted Debian's units

**Owner: the spec's first draft. Caught by the pre-flight scan, before Task 1.**

The spec said Debian ships three units from `xdg-desktop-portal` and that
`xdg-desktop-portal-rewrite-launchers.service` was Nix-only, and used that to
justify not installing it. `dpkg -L` lists four; the fourth is enabled by a
root-owned `/etc` symlink and ran successfully at that boot.

The miscount came from reading `systemctl --user list-units`, where a
`oneshot` that has already finished does not appear — a view that structurally
could not show the thing being counted.

The correction mattered beyond the number. "It does nothing here" would have
been a fine reason to skip it; "Debian never had it" was the reason actually
given, and it was false. A behaviour reduction should not ride along inside a
migration on the strength of an unchecked premise. It is installed, and it is
a no-op, and both of those are now written down.

### A check that could not answer its own question

**Owner: the plan. Caught by running it.**

The plan's Task 2 Step 6 said to read the frontend's journal for its chosen
backend implementations. At default verbosity the journal contains only
`Starting` and `Stopped`. The check would have produced no evidence either
way, and "no contradicting log line" reads as success.

The question was real: a `1.20.4` frontend parsing `1.20.3`'s config file
differently would have reverted backend selection to the accidental fallback
that existed before spec 7, while every ordinary symptom still looked like a
working portal. The evidence was obtained instead by running the new binary
verbosely against a throwaway bus, where every interface resolves `(config)`.

Same fault as spec 6's `pgrep -x fumon` and spec 7's empty-output zero-check,
in a plan written after both were documented.

### A reviewer's finding that was wrong, and a controller's reasoning that was wrong the other way

**Owner: shared. Both from the same tool, within one review cycle.**

Task 1's review flagged the comment stating `/usr/lib/systemd/user` is at
UnitPath position 15, reporting 18 from `systemd-analyze --user unit-paths`.

The controller ruled the finding incorrect: `systemctl --user show -p UnitPath`
is the manager's own property and gives 15. `systemd-analyze` computes the list
from the **caller's** environment, and a shell inside the graphical session
carries `XDG_DATA_DIRS` entries the manager never saw.

But the controller then read `~/.nix-profile/share/systemd/user` at "position
12" in that same misleading output and briefly concluded the package alone
would have placed Nix's units ahead of Debian's, making the `xdg.configFile`
entries redundant. It would not have — that path is not on the manager's
UnitPath at all.

Two readers, opposite wrong conclusions, one tool. The re-reviewer settled it
with a controlled experiment neither had run: `env -u XDG_DATA_DIRS
systemd-analyze --user unit-paths` collapses to the manager's exact list, and
the manager's own `/proc/<pid>/environ` is empty. The number stayed 15 and a
comment now records which tool is authoritative.

### `rewrite-launchers` needed an enablement link the other three did not

**Owner: nobody — caught by checking rather than assuming.**

Three of the four units are `static`, purely D-Bus activated. The fourth
carries `WantedBy=graphical-session-pre.target`, so placing the unit file at
position 5 does not enable it. Without the `.wants` entry the unit would exist
and never run, and nothing would look wrong.

It was caught because `home/uwsm.nix` already does exactly this for
`fumon.service`, and that precedent prompted the check.

## What is still true

15 Debian user services still run, in clusters:

- **Audio** — `pipewire`, `pipewire-pulse`, `wireplumber`, `filter-chain`
- **Secrets and agents** — `gnome-keyring-daemon`, `gcr-ssh-agent`,
  `ssh-agent`
- **The session bus** — `dbus-broker`
- **flatpak's own** — `flatpak-portal`, `flatpak-session-helper`. These come
  from the `flatpak` package, not `xdg-desktop-portal`; `flatpak-portal`
  serves `org.freedesktop.portal.Flatpak`, a different interface from anything
  this spec moved.
- **The rest** — `dconf`, `gvfs-daemon`, `mpris-proxy`, `foot-server`,
  `syncthing`

`gnome-keyring` still supplies the Secret portal backend and stays. `bluez`
remains permanently apt for architectural reasons — `bluetoothd` is a system
service and standalone Home Manager cannot supply one.

## What the next spec inherits

**Audio is the obvious next piece.** Four user services, all Debian units at
position 15 — the exact shape this spec and spec 6 have now each solved once.
Nix's `wireplumber-0.5.14` is already on the session PATH. Deferred here
because the failure mode is "no audio" and PipeWire's A2DP path couples to
`bluez`, which is staying.

**`foot`** — the flake provides it, `/usr/bin/foot` runs, `foot-server.service`
is Debian's. One package, the same shadow shape, already half-solved.

**The secrets and agent cluster** — four services, and `gnome-keyring` among
them is load-bearing for the Secret portal.

**Unchanged from spec 7's list:** the two unmanaged font piles under
`~/.local/share/fonts` (218 MB, and the `calango-desktop` one still shadows
the flake's own `adwaita-fonts`), 82 dictionary packages, ~119 packages in
`rc` state, and `/run/opengl-driver`.

**The rollback rule, extended again.** A previous Home Manager generation now
also carries the portal frontend, the document portal, the permission store
and `rewrite-launchers`. It has not been a recovery path since spec 6 and it
is further from being one with each spec.
