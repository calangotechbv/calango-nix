# Spec 8: completing the portal stack — suffer

2026-08-15

Spec 7 moved the GTK portal *backend* to Nix and removed the KDE and LXQt
backends. What it did not move is the portal **frontend** — the process every
portal call goes through — and the two helper services that ship with it.

So the portal stack is currently mixed: two Nix backends running under a
Debian frontend. That is the same half-migrated shape that produced spec 6's
`fumon` defect, where the unit came from Nix and the binary it ran came from
Debian, and no check noticed for two phases.

This spec closes it.

## Scope, in one sentence

Move `xdg-desktop-portal`, `xdg-document-portal` and `xdg-permission-store` to
Nix, then remove Debian's package, leaving the portal subsystem entirely
Nix's.

## The inventory, measured

### One package, three services

```
$ dpkg -S /usr/lib/systemd/user/xdg-{desktop-portal,document-portal,permission-store}.service
xdg-desktop-portal: all three
```

All three units come from the single Debian package `xdg-desktop-portal`
(`1.20.3+ds-1`). nixpkgs, at the flake's **pinned** input, has `1.20.4`:

```
$ nix eval --raw .#homeConfigurations."isutton@suffer".pkgs.xdg-desktop-portal.version
1.20.4
```

That figure is deliberately re-derived from the pinned input rather than from
`nixpkgs#`, which is the flake *registry* and reports `1.22.1`. Spec 7's
results document carried `1.22.1` for a while and used "a real version change"
as a reason to defer this work; the real gap is a patch bump, and this spec
exists partly because that reason was weaker than it looked.

### Nix's package ships one more unit than Debian's

```
share/systemd/user/
  xdg-desktop-portal.service
  xdg-document-portal.service
  xdg-permission-store.service
  xdg-desktop-portal-rewrite-launchers.service     <- Debian has no equivalent
```

The three shared units `diff` **identical to Debian's apart from
`ExecStart`** — same `Type=dbus`, same `BusName`, same
`PartOf=graphical-session.target`, same `Requires=dbus.service`, same
`Slice=session.slice`.

### The activation mechanism is the one spec 7 established

All six D-Bus activation files — Debian's three and Nix's three — carry
`SystemdService=<name>.service`. D-Bus prefers the unit over `Exec=`, and that
is a unit *name* resolved through the user manager's search path. So:

- The **unit** at `~/.config/systemd/user` (UnitPath position 5, against
  `/usr/lib/systemd/user` at 15) is what decides which binary runs.
- The **D-Bus activation file** only becomes load-bearing once Debian's
  package is removed and its copy disappears. At that point Nix's must be
  reachable, and the session bus does not see the Nix profile — its
  `XDG_DATA_DIRS` has no `~/.nix-profile/share`. So each needs an
  `xdg.dataFile` copy into `XDG_DATA_HOME`.

Both facts were established the hard way in spec 7, where the second was
missed in the spec and caught only by review.

### No GL linkage

```
xdg-desktop-portal       GL/gbm libs: 0
xdg-document-portal      GL/gbm libs: 0
xdg-permission-store     GL/gbm libs: 0
```

Checked with `ldd`, not inferred from "they are daemons". So the units are
copied verbatim, with no nixGL wrapper — unlike `xdg-desktop-portal-hyprland`
in the same file, whose wrapper exists because its binary *does* link `libgbm`.

### flatpak, Slack, and a live FUSE mount

flatpak is in real use. `com.slack.Slack` is installed system-wide from
flathub, and the user has confirmed Slack is corp software they need to run.

The document portal is what lets a sandboxed application reach files outside
its sandbox, and it is doing that work right now:

```
$ mount | grep /run/user/1000/doc
portal on /run/user/1000/doc type fuse.portal (rw,nosuid,nodev,relatime,user_id=1000,group_id=1000)
```

That mount is held by Debian's `xdg-document-portal`. Swapping the binary
means tearing it down and letting Nix's recreate it, with a consumer on the
other side that matters.

### The removal is possible, and the whole spec is reversible

`xdg-desktop-portal` appears in flatpak's **Recommends**, not its `Depends`:

```
$ dpkg-query -W -f='${Recommends}' flatpak | tr ',' '\n' | grep xdg-desktop-portal
 xdg-desktop-portal (>= 1.6)
```

So removing it leaves flatpak and Slack installed and working — the same
reason removing `xdg-desktop-portal-gtk` in spec 7 was safe. `apt-get -s
remove` confirms it takes only itself.

And unlike spec 7's backports packages, it is downloadable:

```
Candidate: 1.20.3+ds-1
      500 http://deb.debian.org/debian trixie/main amd64 Packages
```

**There is no irreversible step in this spec.** Recovery at any phase is
`sudo apt install xdg-desktop-portal` plus deleting flake lines.

### The permission store's data is not in the package

```
$ ls ~/.local/share/flatpak/db/
desktop-used-apps   notifications   remote-desktop
```

User-owned GVariant files at the standard path both implementations read.
Package removal does not touch them, and a swap preserves them.

## Decisions

**All three units move, sequenced by blast radius**, each with its own switch
and gate. The package is one, but the units migrate independently, because
each is placed at position 5 individually.

**Debian's package is removed at the end**, rather than left as a permanent
shadow. Leaving inert Debian units at position 15 forever makes "which one is
actually serving" a question every future reader must re-derive — and that
ambiguity is exactly what spec 6's defect was made of.

**`xdg-desktop-portal-rewrite-launchers.service` is not installed.** Debian
never had it, nothing here uses dynamic launchers, and adding a unit to
`graphical-session-pre.target` is a session-startup risk for no benefit. The
decision is recorded so a later reader does not mistake its absence for an
oversight.

**No nixGL wrapper**, on the `ldd` evidence above.

## Non-goals

- **The audio cluster** — `pipewire`, `pipewire-pulse`, `wireplumber`,
  `filter-chain`, all Debian user units. Its own spec: the failure mode is "no
  audio", and PipeWire's A2DP path couples to `bluez`, which stays on apt
  permanently for architectural reasons.
- **The secrets and agent cluster** — `gnome-keyring-daemon`, `gcr-ssh-agent`,
  `gpg-agent`, `ssh-agent`.
- **`dbus-broker`** — the session bus itself. Not a candidate.
- **The ~21 remaining GUI applications**, minus the corp set, which now
  includes Slack.
- **`foot`'s shadow** — the flake provides `foot`, `/usr/bin/foot` runs, and
  `foot-server.service` is Debian's. Same shape, but not this subsystem.
- **`/run/opengl-driver`** — still parked, still unestablished.

## Design

### Phase 0 — the package and the flake

`xdg-desktop-portal` into `home.packages` in `home/default.nix`. As with the
gtk backend, this line alone changes nothing at runtime, and the comment says
so.

`home/services.nix` gains, per service, two entries:

```nix
xdg.configFile."systemd/user/<name>.service".source =
  "${pkgs.xdg-desktop-portal}/share/systemd/user/<name>.service";

xdg.dataFile."dbus-1/services/<bus name>.service".source =
  "${pkgs.xdg-desktop-portal}/share/dbus-1/services/<bus name>.service";
```

`xdg.configFile` rather than `home.file.".config/..."`: home-manager's own
systemd module writes user units that way, and sd-switch follows
`xdg.configHome` rather than a literal `.config`.

### Phase 1 — `xdg-permission-store`

Smallest surface, no visible consumer, and its data lives outside the package.

**Gate:** the service is active with `/proc/<pid>/exe` under `/nix/store`; the
three tables in `~/.local/share/flatpak/db/` are still readable and unchanged.

### Phase 2 — `xdg-desktop-portal`, the frontend

Every portal call goes through it.

**Gate:** the three checks spec 7 established — a real file dialog opens in
Chrome, a screenshot works, a screen share works — plus `busctl --user status
org.freedesktop.portal.Desktop` naming a store path, and the frontend's log
showing `gtk` chosen for FileChooser and `hyprland` for ScreenCast, both from
`hyprland-portals.conf`.

### Phase 3 — `xdg-document-portal`

Slack's file bridge, and the phase that earns this spec.

The FUSE mount at `/run/user/1000/doc` is held by the running Debian binary.
A reboot is the clean way to hand it over.

**Gate:** the mount reappears as `fuse.portal`, its serving process is a store
path, **and Slack uploads and downloads a file**. The mount existing is a
proxy; a file crossing the sandbox boundary is the property. A mount can be
present while a sandboxed application cannot traverse it.

### Phase 4 — remove Debian's package

```
sudo apt remove xdg-desktop-portal
```

Takes only itself. This is the moment the `xdg.dataFile` entries become
load-bearing: Debian's three D-Bus activation files disappear, and Nix's — in
`XDG_DATA_HOME`, which the session bus does search — become the only ones.

**Gate:** all three services still activate from cold after a reboot, and the
phase 2 and phase 3 checks pass again.

### Passing cleanup

`org.gtk.Gtk3theme.Breeze` is installed as a flatpak — a KDE theme, orphaned
by spec 7's removal of the KDE desktop. One `flatpak uninstall`, recorded in
the results document rather than given a phase.

## Verification

Spec 7's finding, restated because it is the design principle here: every
check that compared a path, a name or an exit code eventually lied; every
check that read a running process's own state told the truth.

So each gate uses:

1. `/proc/<pid>/exe` and the process's `/usr` **code** mapping count.
2. `busctl --user status <bus name>` for which process owns the name.
3. One thing a person does — the dialog, the screenshot, the file transfer.

And two habits carried forward:

- **Count, do not read empty output as success.** Spec 7's closing check
  reported zero by printing nothing, with `sed` masking `grep`'s exit status,
  so success and a broken pipeline were indistinguishable.
- **Enumerate by syntax, never by a remembered list of names.** Every
  name-list check in specs 6 and 7 missed something. While writing this spec I
  called `ListTables` on the permission store and it does not exist — a guessed
  method name, caught immediately, and the reason the phase 1 gate reads the
  database files instead.

## Recovery

- Any phase: `sudo apt install xdg-desktop-portal`, plus removing the relevant
  flake lines. Everything is downloadable from trixie.
- **A Home Manager rollback is not a recovery path.** The current generation
  carries the uwsm units, the gtk portal backend, the portal configuration and
  the font baseline. This rule has held since spec 6 and this spec extends it
  again.
- If the session does not start, `Ctrl+Alt+F1` reaches tty1.

## Endpoint

- The portal subsystem entirely Nix's: frontend, both backends, document
  portal and permission store.
- One fewer apt package.
- The last mixed-provenance subsystem in the session closed — after this, what
  remains on Debian is audio, the secrets and agent cluster, the session bus,
  and applications.
