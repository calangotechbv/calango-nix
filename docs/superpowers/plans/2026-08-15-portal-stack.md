# Portal Stack Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move `xdg-desktop-portal`, `xdg-document-portal` and `xdg-permission-store` from Debian to Nix, then remove Debian's package, leaving the portal subsystem entirely Nix's.

**Architecture:** One Nix package (`xdg-desktop-portal` 1.20.4) supplies all three services. Each unit migrates independently by being placed at `~/.config/systemd/user` (UnitPath position 5), which beats `/usr/lib/systemd/user` (position 15) and so decides which binary runs. Three phases ordered by blast radius, each with its own switch and gate, then the Debian package is removed.

**Tech Stack:** Nix flakes, standalone Home Manager (`release-26.05`), nixpkgs `nixos-26.05`, Debian 13 (trixie), systemd user manager, D-Bus activation, xdg-desktop-portal, flatpak.

**Spec:** `docs/superpowers/specs/2026-08-15-portal-stack-design.md`

## Global Constraints

- **Every `nix` and `home-manager` invocation must be wrapped in `sg nix-users -c '...'`.** A bare `nix` fails with `getting status of '/nix/var/nix/daemon-socket/socket': Permission denied`, which looks like a broken installation and is not one.
- **Never read a package version from `nixpkgs#<pkg>`.** That is the flake *registry*, not this flake's pinned input. On this machine the registry reports `xdg-desktop-portal` as `1.22.1` while the pinned input has `1.20.4`. Use `sg nix-users -c 'nix eval --raw .#homeConfigurations."isutton@suffer".pkgs.<pkg>.version'`. This mistake has been made three times across specs 6 and 7.
- **Agents must never run:** `home-manager switch`; any mutating `apt`/`apt-get`/`dpkg`/`apt-mark`/`flatpak` command; `systemctl` with `start`/`stop`/`restart`/`enable`/`disable`; `reboot`; `fusermount`; or the activation script without `DRY_RUN=1`. Read-only queries (`systemctl show`/`is-active`/`list-units`, `busctl`, `apt-get -s`, `apt-cache`, `flatpak list`) are the agent's job by design.
- **Tasks 1 through 4 involve user-run steps.** An agent composes commands, reads results and writes them down.
- **Slack is corp software the user needs to run.** It is a flatpak, and `xdg-document-portal` is what lets it reach files outside its sandbox. Task 3's gate is Slack moving a file.
- **Nothing in this plan is irreversible.** Debian's `xdg-desktop-portal` is downloadable from trixie (`1.20.3+ds-1`) and sits in flatpak's `Recommends`, not `Depends`. Recovery at any point is `sudo apt install xdg-desktop-portal` plus removing flake lines.
- **A Home Manager rollback is not a recovery path.** The current generation carries the uwsm units, the gtk portal backend, `hyprland-portals.conf` and the font baseline.
- **`xdg-desktop-portal-rewrite-launchers.service` IS installed, in Task 2.** An earlier draft skipped it on the grounds that Debian never had it. That was false: `dpkg -L xdg-desktop-portal` lists it, `/etc/systemd/user/graphical-session-pre.target.wants/` enables it, and it ran successfully this boot. Debian ships **four** units, not three. It also carries `WantedBy=graphical-session-pre.target`, so it needs an explicit enablement link — the treatment `home/uwsm.nix` gives `fumon.service`.
- **Gates read a running process's own state.** `/proc/<pid>/exe`, `/usr` code-mapping counts, `busctl --user status` name ownership — plus one thing a person does. Every check in specs 6 and 7 that compared a path, a name or an exit code eventually lied.
- **Verify by counting, never by reading empty output as success.** `sed` and other filters exit 0 and mask an upstream `grep`'s status, so "printed nothing" and "the pipeline broke" look identical.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `home/default.nix` | `home.packages` | Add `xdg-desktop-portal` (Task 1) |
| `home/services.nix` | systemd user services and portal configuration | Add three unit entries and three D-Bus activation entries, one pair per task |
| `docs/2026-08-15-results-suffer-portal-stack.md` | The results document | Created in Task 1, appended by Tasks 2–5 |

`home/services.nix` already owns the hyprland backend, the gtk backend and `hyprland-portals.conf`, so the whole portal stack stays described in one file. It reaches roughly 300 lines, which makes it comfortably the largest in `home/`; splitting portal configuration into its own file is reasonable future work and is **not** part of this plan.

### The mapping every task needs

| Unit file | `BusName` | D-Bus activation filename |
|---|---|---|
| `xdg-permission-store.service` | `org.freedesktop.impl.portal.PermissionStore` | `org.freedesktop.impl.portal.PermissionStore.service` |
| `xdg-desktop-portal.service` | `org.freedesktop.portal.Desktop` | `org.freedesktop.portal.Desktop.service` |
| `xdg-document-portal.service` | `org.freedesktop.portal.Documents` | `org.freedesktop.portal.Documents.service` |

The D-Bus activation filename is the bus name plus `.service`.

---

## Task 1: The package, and `xdg-permission-store`

**Files:**
- Modify: `home/default.nix` — `home.packages`
- Modify: `home/services.nix` — append before the final `}`
- Create: `docs/2026-08-15-results-suffer-portal-stack.md`

**Interfaces:**
- Produces: `pkgs.xdg-desktop-portal` in the profile, and the pattern (one `xdg.configFile` unit entry plus one `xdg.dataFile` activation entry per service) that Tasks 2 and 3 repeat.

### Why the package alone changes nothing

Both Debian's and Nix's D-Bus activation files carry `SystemdService=<name>.service`. D-Bus prefers the unit over `Exec=`, and that is a unit *name* resolved through the user manager's search path. Installing the package puts Nix's activation files in `~/.nix-profile/share/dbus-1/services`, which the session bus does not search — its `XDG_DATA_DIRS` has no `~/.nix-profile/share`. **The unit at position 5 is what switches a service.**

- [ ] **Step 1: Add the package**

In `home/default.nix`, in the `home.packages` list, immediately after the `xdg-desktop-portal-gtk` entry:

```nix
    # The portal frontend, plus xdg-document-portal and xdg-permission-store,
    # which the same package ships. Debian has 1.20.3+ds-1; the flake's pinned
    # nixpkgs has 1.20.4 -- a patch bump, re-derived from the pinned input and
    # not from `nixpkgs#`, which reports 1.22.1 and is the registry.
    #
    # As with the gtk backend, this line alone changes nothing at runtime: the
    # D-Bus activation files it brings land in ~/.nix-profile/share, which the
    # session bus does not search. The units in home/services.nix are what
    # switch each service.
    xdg-desktop-portal
```

- [ ] **Step 2: Add the permission-store unit and its activation file**

In `home/services.nix`, immediately before the final closing `}`:

```nix
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
```

- [ ] **Step 3: Build**

```bash
sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage'
```

Record the path as `$NEW`.

- [ ] **Step 4: Verify what landed**

```bash
NEW=<path from Step 3>
grep -E '^(ExecStart|BusName|Type)=' "$NEW/home-files/.config/systemd/user/xdg-permission-store.service"
cat "$NEW/home-files/.local/share/dbus-1/services/org.freedesktop.impl.portal.PermissionStore.service"
```

Expected: `ExecStart=/nix/store/…-xdg-desktop-portal-1.20.4/libexec/xdg-permission-store`,
`BusName=org.freedesktop.impl.portal.PermissionStore`, `Type=dbus`, and an
activation file naming the same store path.

Expected **not** to contain `/usr/libexec`.

- [ ] **Step 5: Record the pre-switch state of the permission store's data**

```bash
ls -l ~/.local/share/flatpak/db/
for t in notifications desktop-used-apps remote-desktop; do
  printf '%-20s ' "$t"
  busctl --user call org.freedesktop.impl.portal.PermissionStore \
    /org/freedesktop/impl/portal/PermissionStore \
    org.freedesktop.impl.portal.PermissionStore List s "$t"
done
```

Expected today: three files, and `List` returning `as 1 "notification"`,
`as 1 "x-scheme-handler/slack"`, `as 1 "031362ce-9406-4407-8cb6-5aee8ac03505"`.
Record them verbatim — Step 8 compares against these exact values.

- [ ] **Step 6: Read what sd-switch intends**

```bash
OLD=$(readlink -f ~/.local/state/nix/profiles/home-manager)
NEW=<path from Step 3>
SDSW=$(grep -oE '/nix/store/[a-z0-9]+-sd-switch-[0-9.]+/bin/sd-switch' "$OLD/activate" | head -1)
"$SDSW" --dry-run --verbose \
  --old-units "$OLD/home-files/.config/systemd/user" \
  --new-units "$NEW/home-files/.config/systemd/user"
```

`sd-switch` is extracted from the live activation script, **not** from
`nixpkgs#sd-switch` — the registry gives 0.6.4 where the pinned input gives
0.6.3, and dry-running with a different binary than the switch will use is
worthless.

Expected: `xdg-permission-store.service` appears; the compositor unit
`wayland-wm@hyprland\x2dnixgl.desktop.service` does **not** appear in any stop
list. If it does, stop and report — the switch would then need a TTY.

- [ ] **Step 7: The user switches**

```bash
cd /home/isutton/Projects/calango-nix
sg nix-users -c 'home-manager switch --flake .#isutton@suffer'
systemctl --user restart xdg-permission-store.service
```

- [ ] **Step 8: Gate**

```bash
systemctl --user show xdg-permission-store.service -p FragmentPath -p ActiveState --no-pager
pid=$(busctl --user status org.freedesktop.impl.portal.PermissionStore 2>/dev/null | awk -F= '/^PID=/{print $2}')
echo "PID=$pid"
readlink -f /proc/$pid/exe
echo "usr code mappings: $(grep -cE '/usr/(lib|bin|libexec)' /proc/$pid/maps)"
for t in notifications desktop-used-apps remote-desktop; do
  printf '%-20s ' "$t"
  busctl --user call org.freedesktop.impl.portal.PermissionStore \
    /org/freedesktop/impl/portal/PermissionStore \
    org.freedesktop.impl.portal.PermissionStore List s "$t"
done
```

Expected: `FragmentPath=/home/isutton/.config/systemd/user/xdg-permission-store.service`;
`ActiveState=active`; the exe under `/nix/store`; and **all three tables
returning exactly the values recorded in Step 5**.

The table contents are the property here. A service being active proves it
started, not that it can still read the database it existed to serve.

- [ ] **Step 9: Create the results document and commit**

Create `docs/2026-08-15-results-suffer-portal-stack.md`:

```markdown
# Results: completing the portal stack — suffer

2026-08-15

## Phase 1: xdg-permission-store

<Steps 4, 5, 6 and 8 output, verbatim>
```

```bash
git add home/default.nix home/services.nix docs/2026-08-15-results-suffer-portal-stack.md
git commit -m "portals: take the permission store from Nix

One package supplies all three portal services; each migrates
independently because each unit is placed at UnitPath position 5. The
permission store goes first: smallest surface, no visible consumer, and
its data lives outside the package in ~/.local/share/flatpak/db."
```

---

## Task 2: `xdg-desktop-portal`, the frontend

**Files:**
- Modify: `home/services.nix`
- Modify: `docs/2026-08-15-results-suffer-portal-stack.md` — append `## Phase 2: the frontend`

**Interfaces:**
- Consumes: Task 1's package entry and its pattern.
- Produces: a Nix frontend, which Task 3's document portal runs alongside.

- [ ] **Step 1: Add the frontend unit and its activation file**

In `home/services.nix`, immediately after the permission-store pair from Task 1:

```nix
  # 2 of 3: the frontend. Every portal call goes through it, and it is what
  # reads hyprland-portals.conf below to choose between the gtk and hyprland
  # backends.
  config.xdg.configFile."systemd/user/xdg-desktop-portal.service".source =
    "${pkgs.xdg-desktop-portal}/share/systemd/user/xdg-desktop-portal.service";

  config.xdg.dataFile."dbus-1/services/org.freedesktop.portal.Desktop.service".source =
    "${pkgs.xdg-desktop-portal}/share/dbus-1/services/org.freedesktop.portal.Desktop.service";
```

- [ ] **Step 1b: Add the rewrite-launchers unit and its enablement link**

Debian ships four units and enables this one; parity is the default, and the
reason an earlier draft gave for skipping it was factually wrong.

It is a `oneshot` in `graphical-session-pre.target` that rewrites `.desktop`
entries created through the DynamicLauncher portal. There are none here —
`~/.local/share/applications` holds three entries, none of them portal-created
— so it is a no-op today. It is installed for parity, not for need, and the
comment says so.

Immediately after the frontend pair:

```nix
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
```

- [ ] **Step 2: Build and verify**

```bash
NEW=$(sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage')
echo "$NEW"
grep -E '^(ExecStart|BusName)=' "$NEW/home-files/.config/systemd/user/xdg-desktop-portal.service"
```

Expected: `ExecStart=/nix/store/…-xdg-desktop-portal-1.20.4/libexec/xdg-desktop-portal`,
`BusName=org.freedesktop.portal.Desktop`, and no `/usr/libexec`.

Also confirm the rewrite-launchers unit and its enablement link:

```bash
grep -E '^(ExecStart|WantedBy)=' "$NEW/home-files/.config/systemd/user/xdg-desktop-portal-rewrite-launchers.service"
ls -l "$NEW/home-files/.config/systemd/user/graphical-session-pre.target.wants/"
```

Expected: `ExecStart` under `/nix/store`, `WantedBy=graphical-session-pre.target`,
and the `.wants` directory containing the link.

- [ ] **Step 3: Read the dry run**

```bash
OLD=$(readlink -f ~/.local/state/nix/profiles/home-manager)
SDSW=$(grep -oE '/nix/store/[a-z0-9]+-sd-switch-[0-9.]+/bin/sd-switch' "$OLD/activate" | head -1)
"$SDSW" --dry-run --verbose \
  --old-units "$OLD/home-files/.config/systemd/user" \
  --new-units "$NEW/home-files/.config/systemd/user"
```

Expected: `xdg-desktop-portal.service` appears; the compositor unit does not.

- [ ] **Step 4: The user switches and restarts the frontend**

```bash
cd /home/isutton/Projects/calango-nix
sg nix-users -c 'home-manager switch --flake .#isutton@suffer'
systemctl --user restart xdg-desktop-portal.service
```

- [ ] **Step 5: The agent checks provenance**

```bash
systemctl --user show xdg-desktop-portal.service -p FragmentPath -p ActiveState --no-pager
pid=$(busctl --user status org.freedesktop.portal.Desktop 2>/dev/null | awk -F= '/^PID=/{print $2}')
echo "PID=$pid"; readlink -f /proc/$pid/exe
echo "usr code mappings: $(grep -cE '/usr/(lib|bin|libexec)' /proc/$pid/maps)"
```

Expected: `FragmentPath` under `~/.config/systemd/user`, `ActiveState=active`,
exe under `/nix/store`.

- [ ] **Step 6: The agent checks backend selection is still honoured**

```bash
journalctl --user -u xdg-desktop-portal.service -b --no-pager | tail -30
```

Expected: the frontend logging its chosen implementations — `gtk` for
FileChooser, `hyprland` for ScreenCast and Screenshot — from
`hyprland-portals.conf`. A new frontend reading the same config must reach the
same choices; if it does not, the config's syntax may differ between 1.20.3
and 1.20.4 and that is a stop.

- [ ] **Step 7: The user runs the three checks**

A real file dialog in Chrome (`Ctrl+O`), a screenshot, and a screen share.
All three, by hand. These are the same checks spec 7 used and they exist
because a process check passes whether or not the dialog draws.

- [ ] **Step 8: Append the section and commit**

**Gate:** Steps 5, 6 and 7 must all pass before Task 3.

```bash
git add home/services.nix docs/2026-08-15-results-suffer-portal-stack.md
git commit -m "portals: take the frontend from Nix"
```

---

## Task 3: `xdg-document-portal`, and the Slack gate

**Files:**
- Modify: `home/services.nix`
- Modify: `docs/2026-08-15-results-suffer-portal-stack.md` — append `## Phase 3: the document portal`

**Interfaces:**
- Consumes: Tasks 1 and 2.
- Produces: the state Task 4's removal requires.

This is the phase that earns the spec. The FUSE mount at `/run/user/1000/doc`
is currently held by Debian's binary, and flatpak Slack reaches files through
it.

- [ ] **Step 1: Record the pre-switch mount and Slack's state**

```bash
mount | grep '/run/user/1000/doc'
ls -ld /run/user/1000/doc
pid=$(busctl --user status org.freedesktop.portal.Documents 2>/dev/null | awk -F= '/^PID=/{print $2}')
echo "documents portal PID=$pid"; readlink -f /proc/$pid/exe
flatpak list --app --columns=application,origin
```

Expected: `portal on /run/user/1000/doc type fuse.portal`, the exe under
`/usr/libexec`, and `com.slack.Slack` listed.

- [ ] **Step 2: Add the document-portal unit and its activation file**

In `home/services.nix`, immediately after the frontend pair from Task 2:

```nix
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
```

- [ ] **Step 3: Build and verify**

```bash
NEW=$(sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage')
echo "$NEW"
grep -E '^(ExecStart|BusName)=' "$NEW/home-files/.config/systemd/user/xdg-document-portal.service"
ls "$NEW/home-files/.local/share/dbus-1/services/" | grep -i portal
```

Expected: `ExecStart` under `/nix/store`, `BusName=org.freedesktop.portal.Documents`,
and all three Nix activation files now present.

- [ ] **Step 4: The user switches and reboots**

```bash
cd /home/isutton/Projects/calango-nix
sg nix-users -c 'home-manager switch --flake .#isutton@suffer'
sudo systemctl reboot
```

The reboot rather than a restart: the FUSE mount is held by the running
process, and a clean handover is easier to reason about than unmounting a
live `fuse.portal` under a running session.

> **If the session does not come back:** `Ctrl+Alt+F1` reaches tty1.
> `sudo apt install xdg-desktop-portal` restores Debian's, whose units at
> position 15 take over once the flake's are removed. Do **not** roll back the
> Home Manager generation.

- [ ] **Step 5: The agent verifies the mount and the process**

```bash
mount | grep '/run/user/1000/doc'
pid=$(busctl --user status org.freedesktop.portal.Documents 2>/dev/null | awk -F= '/^PID=/{print $2}')
echo "PID=$pid"; readlink -f /proc/$pid/exe
echo "usr code mappings: $(grep -cE '/usr/(lib|bin|libexec)' /proc/$pid/maps)"
systemctl --user show xdg-document-portal.service -p FragmentPath --value
systemctl --user list-units --state=failed --no-legend
```

Expected: the mount is back as `fuse.portal`; the exe under `/nix/store`;
`FragmentPath` under `~/.config/systemd/user`; no failed units.

- [ ] **Step 6: The user proves it with Slack**

Open Slack. **Upload a file to any channel, then download a file back.**

This is the gate. The mount existing is a proxy: it can be present while a
sandboxed application cannot traverse it. A file crossing the sandbox boundary
in both directions is the property.

- [ ] **Step 7: Append the section and commit**

**Gate:** Steps 5 and 6 must both pass before Task 4.

```bash
git add home/services.nix docs/2026-08-15-results-suffer-portal-stack.md
git commit -m "portals: take the document portal from Nix"
```

---

## Task 4: Remove Debian's package

**Files:**
- Modify: `docs/2026-08-15-results-suffer-portal-stack.md` — append `## Phase 4: Debian's package removed`

**Interfaces:**
- Consumes: Tasks 1–3, all gated.

Reversible: `1.20.3+ds-1` is downloadable from trixie.

- [ ] **Step 1: The agent reads the whole removal list**

```bash
apt-get -s remove xdg-desktop-portal 2>&1 | grep '^Remv' | awk '{print $2}' | sort > /tmp/spec8-remv.txt
wc -l < /tmp/spec8-remv.txt
cat /tmp/spec8-remv.txt
echo "--- must NOT appear ---"
for keep in flatpak google-chrome-stable code 1password bluez gnome-keyring greetd; do
  grep -qx "$keep" /tmp/spec8-remv.txt && echo "*** $keep WOULD BE REMOVED - STOP ***"
done
echo "--- in-use check, covering root processes too ---"
{ for p in $(ls /proc | grep -E '^[0-9]+$'); do
    readlink /proc/$p/exe 2>/dev/null
    grep -oE '/(usr|lib|opt)/[^ ]*' /proc/$p/maps 2>/dev/null
  done
  ps -eo args= --no-headers | awk '{print $1}' | grep '^/'
} | sort -u | xargs -d'\n' dpkg -S 2>/dev/null | cut -d: -f1 | tr ',' '\n' | sort -u > /tmp/spec8-inuse.txt
comm -12 /tmp/spec8-inuse.txt /tmp/spec8-remv.txt
```

Expected: one package removed, `xdg-desktop-portal`; no `***` lines.

The in-use check unions `/proc` walking with `ps -eo args`. `/proc/<pid>/maps`
is unreadable for another user's processes, and there are roughly three times
as many root processes as user ones on this machine — a `/proc`-only check
covers about a quarter of the system. Spec 7 found that out two phases after
relying on it.

The `xdg-desktop-portal` package **will** appear in that intersection, because
its three binaries are running. That is expected: they are being replaced, and
Tasks 1–3 have already proven the replacements serve.

- [ ] **Step 2: The user removes it**

```bash
sudo apt remove xdg-desktop-portal
```

- [ ] **Step 3: The agent verifies the activation files that remain**

```bash
ls /usr/share/dbus-1/services/ 2>/dev/null | grep -i portal
ls ~/.local/share/dbus-1/services/ | grep -i portal
ls /usr/lib/systemd/user/ | grep -E 'xdg-(desktop-portal|document-portal|permission-store)'
```

Expected: Debian's three activation files and **four** units gone; Nix's five
activation files present in `XDG_DATA_HOME` (three from this spec, two from
spec 7's backends). Debian ships four units but only three D-Bus activation
files — rewrite-launchers is a oneshot, not a bus-activated service.

This is the moment the `xdg.dataFile` entries become load-bearing. Until now
Debian's copies were also present.

- [ ] **Step 3b: The user removes the dangling enablement link**

```bash
ls -l /etc/systemd/user/graphical-session-pre.target.wants/
sudo rm /etc/systemd/user/graphical-session-pre.target.wants/xdg-desktop-portal-rewrite-launchers.service
sudo rmdir --ignore-fail-on-non-empty /etc/systemd/user/graphical-session-pre.target.wants
```

Removing Debian's package leaves this symlink pointing at a file that no
longer exists. dpkg does not own these links — its systemd helper creates them
— so it never cleans them up.

This is the **third** occurrence of the same pattern in three specs: apt's
`fumon` link survived the uwsm removal, apt's `ydotool` link survived that
removal, and now this one. It is a predictable consequence, not a discovery.
Nix's own enablement link at `~/.config/systemd/user/graphical-session-pre.target.wants/`
is unaffected and keeps the unit enabled.

- [ ] **Step 4: The user reboots**

```bash
sudo systemctl reboot
```

Cold activation is the real test: every service must now start from Nix's
activation files alone.

- [ ] **Step 5: The agent re-runs every gate**

```bash
systemctl --user list-units --state=failed --no-legend
for n in org.freedesktop.impl.portal.PermissionStore org.freedesktop.portal.Desktop org.freedesktop.portal.Documents; do
  pid=$(busctl --user status "$n" 2>/dev/null | awk -F= '/^PID=/{print $2}')
  printf '%-52s pid=%-8s %s\n' "$n" "$pid" "$(readlink -f /proc/$pid/exe 2>/dev/null)"
done
mount | grep '/run/user/1000/doc'
for t in notifications desktop-used-apps remote-desktop; do
  printf '%-20s ' "$t"
  busctl --user call org.freedesktop.impl.portal.PermissionStore \
    /org/freedesktop/impl/portal/PermissionStore \
    org.freedesktop.impl.portal.PermissionStore List s "$t"
done
dpkg-query -W -f='xdg-desktop-portal ${db:Status-Abbrev}\n' xdg-desktop-portal 2>&1
```

Expected: no failed units; all three exes under `/nix/store`; the FUSE mount
present; all three permission tables returning their Task 1 Step 5 values; the
package `rc` or absent.

- [ ] **Step 6: The user re-runs the human checks**

File dialog in Chrome, screenshot, screen share, and a Slack file upload and
download. All five, after the removal and the reboot.

- [ ] **Step 7: The passing cleanup**

```bash
flatpak list --columns=application | grep Gtk3theme
flatpak uninstall org.gtk.Gtk3theme.Breeze
```

A KDE theme, orphaned when spec 7 removed the KDE desktop. Confirm nothing
else references it first — `flatpak list --app` should show only
`com.slack.Slack`.

- [ ] **Step 8: Append the section and commit**

```bash
git add docs/2026-08-15-results-suffer-portal-stack.md
git commit -m "docs: Phase 4, Debian's portal package removed"
```

---

## Task 5: Finish the results document

**Files:**
- Modify: `docs/2026-08-15-results-suffer-portal-stack.md`

- [ ] **Step 1: Write `## Did it work?`**

A before/after table covering: what serves each of the three bus names; the
portal subsystem's provenance as a whole; the apt package count; whether the
FUSE mount survived; whether Slack can still move files; and how many Debian
user units remain in the session.

- [ ] **Step 2: Write `## Every defect, and who owns it`**

Any defect found during Tasks 1–4, with owners and the same honesty as specs 6
and 7. If none were found, say so plainly and note that this spec was smaller
and fully reversible, which is a likelier explanation than the process
improving.

Record whether the `hyprland-portals.conf` syntax carried unchanged from
frontend 1.20.3 to 1.20.4 — Task 2 Step 6 checks it, and a silent change there
would have reverted backend selection to accidental.

- [ ] **Step 3: Write `## What is still true`**

The remaining Debian user services, by cluster: audio (`pipewire`,
`pipewire-pulse`, `wireplumber`, `filter-chain`); secrets and agents
(`gnome-keyring-daemon`, `gcr-ssh-agent`, `gpg-agent`, `ssh-agent`);
`dbus-broker`; and the rest (`dconf`, `gvfs-daemon`, `mpris-proxy`,
`foot-server`, `syncthing`). Note that `gnome-keyring` still supplies the
Secret portal backend and stays.

- [ ] **Step 4: Write `## What the next spec inherits`**

- **Audio** is now the obvious next piece: four user services, the exact uwsm
  shape, Nix's `wireplumber-0.5.14` already on the session PATH. Deferred
  because the failure mode is "no audio" and PipeWire's A2DP path couples to
  `bluez`, which stays on apt permanently.
- **`foot`** — the flake provides it, `/usr/bin/foot` runs, `foot-server.service`
  is Debian's.
- The unmanaged font piles, the 82 dictionaries, the `rc`-state packages, and
  `/run/opengl-driver`, all unchanged from spec 7's list.
- The rollback rule, extended again by this spec's three units and three
  activation files.

- [ ] **Step 5: Verify every claim traces to a measurement**

Re-read the finished document and check each factual assertion against command
output recorded in Tasks 1–4. Anything untraceable is removed or marked
unverified.

Re-derive every version claim from the **pinned** input. Spec 7's results
document shipped `1.22.1` from the registry and built an argument on it.

- [ ] **Step 6: Commit**

```bash
git add docs/2026-08-15-results-suffer-portal-stack.md
git commit -m "docs: results for spec 8, the portal stack"
```

---

## Notes for the executor

**The `sg nix-users -c '...'` wrapper is not optional.**

**Never read a version from `nixpkgs#`.** It is the registry, not the pinned
input. Three specs have now made this mistake.

**Tasks 1–4 have user-run steps.** An agent may compose commands, read results
and write them down. An agent may not switch, reboot, or run apt, dpkg or
flatpak.

**Task 3 is the gate that matters.** If Slack cannot move a file, Task 4 does
not run. Debian's package is still installed at that point, so recovery is
removing the document-portal lines from `home/services.nix` and switching
back.

**Two units are expected never to move.** `graphical-session.target` and
`graphical-session-pre.target` belong to systemd. A check demanding they move
under `~/.config` is wrong.

**`gnome-keyring` stays.** It supplies the Secret portal backend and is
unrelated to this package.
