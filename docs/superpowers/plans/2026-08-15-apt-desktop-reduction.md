# Apt Desktop Reduction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the ~230 apt packages nothing on this machine uses, take the last four backports packages to zero, and move the GTK portal backend to Nix.

**Architecture:** Five phases ordered by reversibility, not by theme. Phases 1–3 are restorable with a single `apt install`; only phases 4 and 5 touch packages apt can no longer download, and those get a `dpkg-repack` first. The one addition is Nix's `xdg-desktop-portal-gtk`, installed by the shadow-then-remove pattern this project has used three times.

**Tech Stack:** Nix flakes, standalone Home Manager (`release-26.05`), nixpkgs `nixos-26.05`, Debian 13 (trixie), systemd user manager, xdg-desktop-portal.

**Spec:** `docs/superpowers/specs/2026-08-15-apt-desktop-reduction-design.md`

## Global Constraints

- **Every `nix` and `home-manager` invocation must be wrapped in `sg nix-users -c '...'`.** A bare `nix` fails with `getting status of '/nix/var/nix/daemon-socket/socket': Permission denied`, which looks like a broken installation and is not one.
- **Agents must never run:** `home-manager switch`; any mutating `apt`, `apt-get` or `dpkg` command; `systemctl` with `start`, `stop`, `restart`, `enable` or `disable`; `reboot`; `loginctl terminate-session`; or the activation script without `DRY_RUN=1`. Read-only queries (`show`, `is-active`, `list-units`, `apt-get -s`, `apt-cache`) are the agent's job by design.
- **Tasks 2 through 7 are user-run.** An agent composes the commands, reads the results and writes them down.
- **Corp applications are never touched:** `google-chrome-stable`, `code`, `1password`, `1password-cli`, `endpoint-verification`.
- **`xdg-desktop-portal-gtk` must never be removed before Nix's replacement is verified serving.** It is the only FileChooser provider; `hyprland.portal` does not provide that interface. Removing it early breaks file dialogs in Chrome and Code.
- **`/etc/pam.d/greetd` is not edited.** Its `pam_kwallet5.so` lines carry a leading `-`, so PAM skips them silently once the module is gone. The file is a dpkg conffile owned by `greetd`.
- **`~/.local/share/kwalletd/kdewallet.kwl` is not deleted.**
- **A Home Manager rollback is not a recovery path.** The portal config and the gtk backend unit live in the generation.
- **Read the entire `Remv` list before executing each removal phase.** Categorised, not spot-checked. Anything matching PAM, login, D-Bus, systemd, polkit or portal is justified individually, in writing.
- **Enumerate by syntax, never by a remembered list of names.** Packages by `Section:` and dpkg state; running processes by walking `/proc`, not `pgrep` with names someone thought of. Two design-phase errors in this spec came from hand-written name lists.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `home/default.nix` | `home.packages` — the desktop's package set | Add `xdg-desktop-portal-gtk` |
| `home/services.nix` | systemd user services and portal configuration; already owns the hyprland backend | Add the gtk backend's unit and `Hyprland-portals.conf` |
| `docs/2026-08-15-results-suffer-apt-desktop-reduction.md` | The results document | Created in Task 2, appended by Tasks 3–8 |

The gtk backend goes in `home/services.nix` rather than a new file because that file already owns portal configuration, and the two backends have to be understood together — `Hyprland-portals.conf` names both. `services.nix` reaches roughly 240 lines as a result, which makes it the largest file in `home/`; a later split of portal configuration into its own file is reasonable but is **not** part of this plan.

---

## Task 1: Nix's GTK portal backend

**Files:**
- Modify: `home/default.nix` — `home.packages` list
- Modify: `home/services.nix` — append before the closing `}`

**Interfaces:**
- Produces: a generation containing `.config/systemd/user/xdg-desktop-portal-gtk.service` pointing at a store path, and `.config/xdg-desktop-portal/Hyprland-portals.conf`. Task 4 switches to it and verifies.

**This task is agent-safe.** It builds and inspects only. No switch.

### Why a systemd unit is required, and not optional

Both Debian's and Nix's D-Bus activation files carry the same line:

```
SystemdService=xdg-desktop-portal-gtk.service
```

D-Bus prefers the systemd unit over the `Exec=` line, and that is a unit
*name*, resolved through the user manager's search path. Today it resolves to
Debian's:

```
$ systemctl --user show xdg-desktop-portal-gtk.service -p FragmentPath --value
/usr/lib/systemd/user/xdg-desktop-portal-gtk.service
```

which `ExecStart`s `/usr/libexec/xdg-desktop-portal-gtk` — Debian's binary.
**Adding the package to `home.packages` alone would therefore change
nothing.** This is the same defect class as `ExecStart=fumon` in spec 6: a
name resolved through a search path where the wrong provider answers.

The two units are byte-identical except for `ExecStart`, and Nix's already
carries an absolute store path, so it is copied verbatim rather than
re-described — the same argument `home/uwsm.nix` makes.

- [ ] **Step 1: Add the package to `home.packages`**

In `home/default.nix`, inside the `home.packages` list, immediately after the
`inotify-tools` entry:

```nix
    # The GTK portal backend. hyprland.portal provides only Screenshot,
    # ScreenCast and GlobalShortcuts -- every file dialog, print dialog and
    # Settings read goes through this one instead, including Chrome's and
    # Code's. Debian ships 1.15.3-1 and nixpkgs ships 1.15.3: the same
    # upstream release, with one extra interface (Wallpaper). So this is a
    # lateral move, not an upgrade.
    #
    # This line on its own changes nothing at runtime -- see the unit in
    # home/services.nix for why.
    xdg-desktop-portal-gtk
```

- [ ] **Step 2: Add the unit and the portal config**

In `home/services.nix`, immediately before the final closing `}`:

```nix
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
  # copy that can drift from upstream.
  config.home.file.".config/systemd/user/xdg-desktop-portal-gtk.service".source =
    "${pkgs.xdg-desktop-portal-gtk}/share/systemd/user/xdg-desktop-portal-gtk.service";

  # Backend selection, declared rather than inherited.
  #
  # Without this file the choice is accidental: gtk.portal declares
  # `UseIn=gnome`, which does not match this session, so it wins only as
  # xdg-desktop-portal's last-resort fallback. Removing the kde and lxqt
  # backends would silently change which backend serves which interface. With
  # it, the removals are a no-op.
  #
  # The filename is not arbitrary. The frontend reads
  # $XDG_CURRENT_DESKTOP-portals.conf, and this session reports
  # XDG_CURRENT_DESKTOP=Hyprland. Debian's frontend is 1.20.3 and supports the
  # format -- it ships portals.conf(5).
  config.xdg.configFile."xdg-desktop-portal/Hyprland-portals.conf".text = ''
    [preferred]
    default=gtk
    org.freedesktop.impl.portal.Screenshot=hyprland
    org.freedesktop.impl.portal.ScreenCast=hyprland
    org.freedesktop.impl.portal.GlobalShortcuts=hyprland
    org.freedesktop.impl.portal.Secret=gnome-keyring
  '';
```

- [ ] **Step 3: Build**

```bash
sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage'
```

Expected: a store path. Record it as `$NEW`.

- [ ] **Step 4: Verify the unit landed and points into the store**

```bash
NEW=<the path from Step 3>
cat "$NEW/home-files/.config/systemd/user/xdg-desktop-portal-gtk.service"
```

Expected: `ExecStart=/nix/store/…-xdg-desktop-portal-gtk-1.15.3/libexec/xdg-desktop-portal-gtk`
and `BusName=org.freedesktop.impl.portal.desktop.gtk`.

Expected **not** to contain `/usr/libexec`.

- [ ] **Step 5: Verify the portal config landed**

```bash
cat "$NEW/home-files/.config/xdg-desktop-portal/Hyprland-portals.conf"
```

Expected: exactly the five lines under `[preferred]` from Step 2.

- [ ] **Step 6: Verify the package brought its own D-Bus activation file**

```bash
ls "$NEW/home-path/share/dbus-1/services/" | grep gtk
ls "$NEW/home-path/share/xdg-desktop-portal/portals/" | grep gtk
```

Expected: `org.freedesktop.impl.portal.desktop.gtk.service` and `gtk.portal`.

These are the two filenames that shadow Debian's through `XDG_DATA_DIRS`,
where `/home/isutton/.nix-profile/share` is first and `/usr/share` is last. No
explicit `xdg.dataFile` entry is needed for them — unlike the hyprland backend
above, which has one — because both service files name the same unit, so the
unit is what decides. This was verified, not assumed.

- [ ] **Step 7: Read what sd-switch intends to do**

```bash
OLD=$(readlink -f ~/.local/state/nix/profiles/home-manager)
NEW=<the path from Step 3>
SDSW=$(grep -oE '/nix/store/[a-z0-9]+-sd-switch-[0-9.]+/bin/sd-switch' "$OLD/activate" | head -1)
echo "using $SDSW"

"$SDSW" --dry-run --verbose \
  --old-units "$OLD/home-files/.config/systemd/user" \
  --new-units "$NEW/home-files/.config/systemd/user"
```

`sd-switch` is extracted from the live activation script, **not** from
`nixpkgs#sd-switch`. The `nixpkgs#` prefix reads the flake *registry*, which
is not this flake's pinned nixpkgs: on this machine the registry gives
`sd-switch-0.6.4` while the pinned input gives `0.6.3`. Dry-running with a
different binary than the switch will use is worthless. Spec 6's plan review
caught the identical mistake with `nixpkgs#uwsm`.

Record the verbatim output. The expectation is that
`xdg-desktop-portal-gtk.service` appears as a newly added unit and that **no
currently-running session unit is stopped** — in particular not
`wayland-wm@hyprland\x2dnixgl.desktop.service`.

If the compositor unit does appear in a stop list, say so in the report and do
not proceed: Task 4 would then need a TTY, exactly as spec 6's Phase 1 did.

- [ ] **Step 8: Commit**

```bash
git add home/default.nix home/services.nix
git commit -m "portals: take the gtk backend from Nix

Adding the package alone would change nothing: both D-Bus activation files
say SystemdService=xdg-desktop-portal-gtk.service, D-Bus prefers the unit
over Exec=, and that name resolves to Debian's unit at position 15. So
install Nix's unit at position 5, where it wins.

Also declares backend selection in Hyprland-portals.conf instead of
inheriting a fallback, so removing the kde and lxqt backends is a no-op
rather than a reshuffle."
```

---

## Task 2: Phase 1 — the tasksel metapackages (user-run)

**Files:**
- Create: `docs/2026-08-15-results-suffer-apt-desktop-reduction.md`

**Interfaces:**
- Consumes: nothing.
- Produces: the results document, with its first section.

**Reversible.** Everything removed here is downloadable from trixie.

- [ ] **Step 1: The agent builds the list by syntax and counts it**

```bash
apt-mark showmanual | grep '^task-' | sort > /tmp/spec7-tasklist.txt
wc -l < /tmp/spec7-tasklist.txt
grep -v -- '-desktop$' /tmp/spec7-tasklist.txt || echo "all end in -desktop"
```

Expected: `136`, and no lines from the second command.

- [ ] **Step 2: The agent reads the whole removal list**

```bash
apt-get -s remove $(tr '\n' ' ' < /tmp/spec7-tasklist.txt) tasksel 2>&1 | grep '^Remv' | awk '{print $2}' | sort > /tmp/spec7-task-remv.txt
wc -l < /tmp/spec7-task-remv.txt
grep -v '^task-' /tmp/spec7-task-remv.txt
```

Expected: `138`, and exactly two non-`task-` lines: `tasksel` and
`tasksel-data`.

**This is the gate for this task.** If any other package appears, stop and
report it. Do not proceed on a package you have not justified in writing.

- [ ] **Step 3: The user removes them**

```bash
sudo apt remove tasksel $(apt-mark showmanual | grep '^task-' | tr '\n' ' ')
```

- [ ] **Step 4: The agent verifies**

```bash
apt-mark showmanual | grep -c '^task-'          # expect 0
dpkg-query -W -f='${db:Status-Abbrev}\n' | grep -c '^ii'
apt-get -s autoremove 2>&1 | grep -c '^Remv'    # expect 0
systemctl --user list-units --state=failed --no-legend
```

Expected: no `task-` packages; the installed count down by 138 from 3256; zero
autoremovable; no failed units.

- [ ] **Step 5: Create the results document with this section**

Create `docs/2026-08-15-results-suffer-apt-desktop-reduction.md`:

```markdown
# Results: reducing the apt desktop footprint — suffer

2026-08-15

## Phase 1: the tasksel metapackages

<the counts from Steps 1, 2 and 4, verbatim, and the full non-task- portion
of the removal list>
```

- [ ] **Step 6: Commit**

```bash
git add docs/2026-08-15-results-suffer-apt-desktop-reduction.md
git commit -m "docs: Phase 1, the tasksel metapackages removed"
```

---

## Task 3: Phase 2 — the KDE installation (user-run)

**Files:**
- Modify: `docs/2026-08-15-results-suffer-apt-desktop-reduction.md` — append `## Phase 2: the KDE installation`

**Interfaces:**
- Consumes: Task 2's completion.
- Produces: the measured aftermath for Task 8.

**Reversible.** All 82 packages are downloadable from trixie.

- [ ] **Step 1: The agent reads the entire removal list and categorises it**

`kwallet6` is in this list, not in Task 5's. `/usr/bin/kwalletd6` is provided
by `kwallet6`, which the autoremove sweep does **not** pick up on its own — so
without naming it here, the KDE task would finish with a KDE daemon still
installed. It also provides `kwallet.portal`; removing it now leaves
`gnome-keyring` as the single Secret provider, which is what already serves
`org.freedesktop.secrets` anyway.

```bash
KDEAPPS="dolphin konsole konqueror kfind kruler kdialog keditbookmarks ktaskswitcher kdeconnect kbrowserselector kwallet6"
apt-get -s autoremove $KDEAPPS 2>&1 | grep '^Remv' | awk '{print $2}' | sort > /tmp/spec7-kde-remv.txt
wc -l < /tmp/spec7-kde-remv.txt
echo "--- PAM / login / bus / portal / init entries, each to be justified ---"
grep -E 'pam|login|greet|systemd|dbus|polkit|portal' /tmp/spec7-kde-remv.txt
echo "--- must NOT appear ---"
for keep in google-chrome-stable code 1password 1password-cli endpoint-verification \
            signal-desktop firefox-esr quickshell greetd tuigreet foot kitty deskflow \
            xdg-desktop-portal xdg-desktop-portal-gtk gnome-keyring; do
  grep -qx "$keep" /tmp/spec7-kde-remv.txt && echo "*** $keep WOULD BE REMOVED - STOP ***"
done
```

Expected: `82`; exactly three PAM entries — `libpam-fprintd`,
`libpam-kwallet5`, `libpam-kwallet-common`; no `***` lines.

The three PAM entries are pre-justified:

- `libpam-kwallet5`, `libpam-kwallet-common` — removed deliberately. The
  `pam_kwallet5.so` lines in `/etc/pam.d/greetd` are `-auth optional` and
  `-session optional`; the leading `-` makes PAM skip a missing module
  silently. The file is not edited.
- `libpam-fprintd` — no `fprintd` line exists in any `/etc/pam.d/` file, no
  reader is present, `fprintd.service` is inactive and no prints are enrolled.
  It is in the sweep only because `libkscreenlocker6` depends on it.

Any *fourth* PAM entry, or any entry matching the other patterns, is a stop.

- [ ] **Step 2: The agent records what is running before the removal**

```bash
for p in $(ls /proc | grep -E '^[0-9]+$'); do
  cmd=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null)
  case "$cmd" in *kwallet*|*kdeconnect*|*kde*|*plasma*) echo "$p $cmd";; esac
done
```

Expected: `kwalletd6` and `kdeconnectd`. Recorded so their absence afterwards
is a measurement rather than an assumption. Note this walks `/proc` rather
than using `pgrep` with a guessed name list — the guessed list is what missed
these two during design.

- [ ] **Step 3: The user removes them**

```bash
sudo apt remove dolphin konsole konqueror kfind kruler kdialog \
                keditbookmarks ktaskswitcher kdeconnect kbrowserselector kwallet6
sudo apt autoremove
```

- [ ] **Step 4: The user confirms the corp applications still work**

Launch **Chrome, Code and 1Password** and confirm each one *renders a window*.
Not that the binary exists — that it draws.

- [ ] **Step 5: The agent verifies**

```bash
dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' kwallet6 kdeconnect 2>&1
echo "--- session health ---"
systemctl --user list-units --state=failed --no-legend
for u in fumon.service quickshell.service xdg-desktop-portal-hyprland.service \
         hypridle.service hyprpolkitagent.service; do
  printf '%-40s %s\n' "$u" "$(systemctl --user is-active $u)"
done
echo "--- file dialogs still have a provider ---"
ls /usr/share/xdg-desktop-portal/portals/
dpkg-query -W -f='${db:Status-Abbrev} xdg-desktop-portal-gtk\n' xdg-desktop-portal-gtk
```

Expected: both packages `rc` or absent; no failed units; all five services
active; `gtk.portal` still present and `xdg-desktop-portal-gtk` still `ii`.

The **processes** are deliberately not checked here. Removing a package does
not kill what is already running: `kwalletd6` (pid 3094) and `kdeconnectd`
(pid 3422) both survive their packages' removal until the session ends. Their
absence is measurable only after Step 6's reboot, which is where Step 7 checks
it.

- [ ] **Step 6: The user reboots and logs in**

```bash
sudo systemctl reboot
```

This confirms greetd still starts a session with `libpam-kwallet5` gone —
the one thing the PAM `-` prefix is being trusted for.

> **If the session does not come back:** `Ctrl+Alt+F1` reaches tty1. Restore
> with `sudo apt install libpam-kwallet5 libpam-kwallet-common`.

- [ ] **Step 7: The agent verifies the login path across the reboot**

```bash
who -b
systemctl --user list-units --state=failed --no-legend
journalctl -b -u greetd --no-pager | grep -iE 'pam|error|fail' | head
echo "--- neither daemon came back ---"
for p in $(ls /proc | grep -E '^[0-9]+$'); do
  cmd=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null)
  case "$cmd" in *kwallet*|*kdeconnect*) echo "STILL RUNNING: $p $cmd";; esac
done
echo "  (no STILL RUNNING lines = both gone)"
```

Expected: a fresh boot time; no failed units; no PAM errors from greetd; and
neither daemon running.

This is the real check for Step 2's two daemons, and it can only happen here.
It walks `/proc` rather than using `pgrep` with a guessed name list — the
guessed list is what missed both of them during design.

- [ ] **Step 8: Append the section and commit**

Append `## Phase 2: the KDE installation` with the counts from Steps 1 and 5,
the two daemons named in Step 2 and confirmed gone in Step 5, and the reboot
result from Step 7.

```bash
git add docs/2026-08-15-results-suffer-apt-desktop-reduction.md
git commit -m "docs: Phase 2, the unused KDE desktop removed"
```

---

## Task 4: Phase 3a — switch to Nix's GTK backend and gate it (user-run)

**Files:**
- Modify: `docs/2026-08-15-results-suffer-apt-desktop-reduction.md` — append `## Phase 3a: the gtk backend moves to Nix`

**Interfaces:**
- Consumes: Task 1's commit; Task 3's completion.
- Produces: the gate that authorises Task 5.

**Reversible** right up until Task 5: deleting the `xdg-desktop-portal-gtk`
line from `home.packages` hands the backend back to Debian.

- [ ] **Step 1: The user switches**

```bash
cd /home/isutton/Projects/calango-nix
sg nix-users -c 'home-manager switch --flake .#isutton@suffer'
```

Safe from inside the session provided Task 1 Step 7 showed no session unit
being stopped. If it did, run this from tty1 (`Ctrl+Alt+F1`) instead.

- [ ] **Step 2: The user restarts the portal stack**

The old backend is already running and will not exit on its own.

```bash
systemctl --user restart xdg-desktop-portal-gtk.service
systemctl --user restart xdg-desktop-portal.service
```

- [ ] **Step 3: The agent verifies the unit now resolves to Nix's**

```bash
systemctl --user show xdg-desktop-portal-gtk.service -p FragmentPath --value
systemctl --user show xdg-desktop-portal-gtk.service -p ExecStart --value
```

Expected: `FragmentPath=/home/isutton/.config/systemd/user/xdg-desktop-portal-gtk.service`
and an `ExecStart` path under `/nix/store`.

If `FragmentPath` still reads `/usr/lib/systemd/user/...`, the switch did not
take effect — stop and report. That is the exact failure this task exists to
catch.

- [ ] **Step 4: The user opens a real file dialog**

In **Chrome**: `Ctrl+O`, or any "upload file" control. Confirm the dialog
opens.

While it is open, the agent runs:

```bash
pid=$(busctl --user status org.freedesktop.impl.portal.desktop.gtk 2>/dev/null | awk '/^PID=/{print $0}')
echo "$pid"
p=$(echo "$pid" | cut -d= -f2)
tr '\0' ' ' < /proc/$p/cmdline; echo
grep -c '/usr/' /proc/$p/maps
```

Expected: the cmdline is a `/nix/store` path, and the `/usr/` mapping count is
0 or accounted for. **This is the property check** — that a dialog opened
proves only that *some* backend answered.

- [ ] **Step 5: The user judges the dialog's appearance**

Nix's backend draws with Nix's GTK, so theme, fonts and icons come from
`home/gtk.nix` rather than Debian's configuration. Confirm the dialog is
styled, the fonts are correct, and folder and file icons render.

A process check passes whether or not the dialog looks like a broken
stylesheet, which is why this step is a person looking at it.

- [ ] **Step 6: The user confirms the hyprland backend still works**

Take a screenshot through the portal, and start a screen share (any
`getUserMedia` screen-capture page, or a Meet call). Both go through
`hyprland.portal`, and the new `Hyprland-portals.conf` names it explicitly for
those interfaces.

- [ ] **Step 7: The agent records which backend serves what**

```bash
cat ~/.config/xdg-desktop-portal/Hyprland-portals.conf
journalctl --user -u xdg-desktop-portal.service -b --no-pager | grep -iE 'backend|portal|choos' | tail -20
```

Expected: the frontend's log naming `gtk` for FileChooser and `hyprland` for
ScreenCast/Screenshot.

- [ ] **Step 8: Append the section and commit**

**Gate:** Steps 3, 4, 5 and 6 must all pass. Task 5 does not run otherwise.

```bash
git add docs/2026-08-15-results-suffer-apt-desktop-reduction.md
git commit -m "docs: Phase 3a, Nix's gtk portal backend verified serving"
```

---

## Task 5: Phase 3b — remove the displaced backends (user-run)

**Files:**
- Modify: `docs/2026-08-15-results-suffer-apt-desktop-reduction.md` — append `## Phase 3b: the displaced backends`

**Interfaces:**
- Consumes: Task 4's gate.
- Produces: a single portal backend pair.

**Reversible.** All are downloadable from trixie.

- [ ] **Step 1: The agent reads the removal list**

```bash
apt-get -s remove xdg-desktop-portal-kde xdg-desktop-portal-lxqt xdg-desktop-portal-gtk 2>&1 \
  | grep '^Remv' | awk '{print $2}' | sort > /tmp/spec7-portal-remv.txt
cat /tmp/spec7-portal-remv.txt
echo "--- must NOT appear ---"
for keep in xdg-desktop-portal gnome-keyring google-chrome-stable code 1password; do
  grep -qx "$keep" /tmp/spec7-portal-remv.txt && echo "*** $keep WOULD BE REMOVED - STOP ***"
done
```

Expected: the three named packages and whatever depends on them; **not**
`xdg-desktop-portal` (the frontend) and **not** `gnome-keyring`.

- [ ] **Step 2: The user removes them**

```bash
sudo apt remove xdg-desktop-portal-kde xdg-desktop-portal-lxqt xdg-desktop-portal-gtk
```

- [ ] **Step 3: The user restarts the portal frontend**

```bash
systemctl --user restart xdg-desktop-portal.service
```

- [ ] **Step 4: The agent verifies the backends that remain**

```bash
ls /usr/share/xdg-desktop-portal/portals/ 2>/dev/null
ls ~/.nix-profile/share/xdg-desktop-portal/portals/
ls ~/.nix-profile/share/dbus-1/services/ | grep -i portal
```

Expected: `gnome-keyring.portal` remaining on the apt side; `gtk.portal` and
`hyprland.portal` on the Nix side; both Nix D-Bus activation files present.

The Nix D-Bus service file matters now that Debian's is gone — this step
confirms it, rather than assuming `home.packages` covered it.

- [ ] **Step 5: The user re-runs the Task 4 gate**

A file dialog in Chrome, a screenshot, and a screen share. All three, again,
after the removal.

- [ ] **Step 6: The agent confirms session health**

```bash
systemctl --user list-units --state=failed --no-legend
systemctl --user show xdg-desktop-portal-gtk.service -p FragmentPath -p ActiveState --no-pager
```

Expected: no failed units; `FragmentPath` under `~/.config/systemd/user`.

- [ ] **Step 7: Append the section and commit**

```bash
git add docs/2026-08-15-results-suffer-apt-desktop-reduction.md
git commit -m "docs: Phase 3b, one portal backend pair, both from Nix"
```

---

## Task 6: Phase 4 — apt's quickshell (user-run, irreversible)

**Files:**
- Modify: `docs/2026-08-15-results-suffer-apt-desktop-reduction.md` — append `## Phase 4: apt's quickshell`

**Interfaces:**
- Consumes: Tasks 2–5.
- Produces: two of the four backports packages gone.

**IRREVERSIBLE without the repack.** `apt-cache policy quickshell` shows a
candidate available only from `/var/lib/dpkg/status` at priority 100 — there
is no download source. The same is true of `libcpptrace1`.

- [ ] **Step 1: The agent confirms Nix's quickshell is the one serving**

```bash
pid=$(systemctl --user show quickshell.service -p MainPID --value)
tr '\0' ' ' < /proc/$pid/cmdline; echo
busctl --user call org.freedesktop.Notifications /org/freedesktop/Notifications \
  org.freedesktop.Notifications GetServerInformation
```

Expected: a `/nix/store` cmdline, and the notification server identifying as
`quickshell`.

- [ ] **Step 2: The user takes the repack first**

```bash
sudo mkdir -p /root/pkg-archive
sudo sh -c 'cd /root/pkg-archive && dpkg-repack quickshell libcpptrace1'
sudo ls -l /root/pkg-archive/
```

`dpkg-repack` writes to the **current directory**, so the `cd` happens inside
the `sudo sh -c` rather than before it — a plain `cd /root` fails for a normal
user, and running `sudo dpkg-repack` from the repository is how spec 6 left a
root-owned `.deb` sitting in the working tree, untracked and not gitignored.

Expected: the two new archives beside `uwsm`'s and `ydotool`'s.

- [ ] **Step 3: The agent reads the removal list**

```bash
apt-get -s remove quickshell 2>&1 | grep -E '^(Remv|The following packages were automatically)' -A3
```

Expected: `quickshell` removed; `libcpptrace1`, `libdwarf1`, `libjemalloc2`
reported newly autoremovable.

- [ ] **Step 4: The user removes**

```bash
sudo apt remove quickshell
sudo apt autoremove
```

- [ ] **Step 5: The agent verifies**

```bash
dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' quickshell libcpptrace1 2>&1
ls /usr/bin/qs /usr/bin/quickshell 2>&1 | tail -2
pid=$(systemctl --user show quickshell.service -p MainPID --value)
tr '\0' ' ' < /proc/$pid/cmdline; echo
systemctl --user list-units --state=failed --no-legend
```

Expected: both `rc` or absent; no `/usr/bin/qs`; the running quickshell
unchanged and still a store path; no failed units.

- [ ] **Step 6: The user confirms the shell still works**

The bar renders, panels toggle, a notification appears. Not "the unit is
active" — the actual interface.

- [ ] **Step 7: Append the section and commit**

```bash
git add docs/2026-08-15-results-suffer-apt-desktop-reduction.md
git commit -m "docs: Phase 4, apt's redundant quickshell removed"
```

---

## Task 7: Phase 5 — the xkbcommon downgrade (user-run, irreversible)

**Files:**
- Modify: `docs/2026-08-15-results-suffer-apt-desktop-reduction.md` — append `## Phase 5: xkbcommon back to a maintained version`

**Interfaces:**
- Consumes: Task 6.
- Produces: zero backports packages.

**IRREVERSIBLE without the repack.** Trixie's `1.7.0-2` is downloadable; the
installed `1.13.1-1~bpo13+1` is not.

- [ ] **Step 1: The agent re-confirms nothing needs the newer version**

```bash
dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\t${Depends}\n' 2>/dev/null \
 | awk -F'\t' '$1 ~ /^ii/' \
 | while IFS=$'\t' read -r s p d; do
     echo "$d" | tr ',' '\n' | grep -oE 'libxkbcommon(0|-x11-0) \(>= [^)]*\)' | while read -r c; do
       printf '%s\t%s\n' "$(echo "$c" | grep -oE '>= [0-9.~]+' | tr -d '>= ')" "$p"
     done
   done | sort -Vr | head -5
```

Expected: the highest constraint is `1.0.0`. Trixie ships `1.7.0-2`, which
satisfies it. If anything now demands more than `1.7.0`, **stop** — the
package set has changed since the spec was measured.

- [ ] **Step 2: The agent confirms the compositor is immune**

```bash
hpid=$(systemctl --user show 'wayland-wm@hyprland\x2dnixgl.desktop.service' -p MainPID --value)
for p in $(pgrep -f Hyprland); do
  grep -oE '/[^ ]*libxkbcommon[^ ]*' /proc/$p/maps 2>/dev/null
done | sort -u
```

Expected: only `/nix/store/…-libxkbcommon-1.13.1/...`. The session's keyboard
handling does not go through Debian's copy, so a failure here is confined to
apt applications.

- [ ] **Step 3: The agent lists which apt processes will be affected**

```bash
for p in $(ls /proc | grep -E '^[0-9]+$'); do
  grep -qE '/usr/lib/x86_64-linux-gnu/libxkbcommon' /proc/$p/maps 2>/dev/null \
    && echo "$p $(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | cut -c1-60)"
done
```

Record this list. These are the processes the downgrade can reach.

- [ ] **Step 4: The user takes the repack first**

```bash
sudo sh -c 'cd /root/pkg-archive && dpkg-repack libxkbcommon0 libxkbcommon-x11-0'
sudo ls -l /root/pkg-archive/
```

The `cd` is inside the `sudo sh -c` for the same reason as Task 6 Step 2:
`dpkg-repack` writes to the current directory.

- [ ] **Step 5: The agent simulates the downgrade**

```bash
apt-get -s install libxkbcommon0=1.7.0-2 libxkbcommon-x11-0=1.7.0-2 2>&1 \
  | grep -E '^(Inst|Remv|The following|E:)'
```

Expected: two `Inst` lines showing the downgrade, and **no** `Remv` lines.
Any removal is a stop.

- [ ] **Step 6: The user downgrades**

```bash
sudo apt-get install libxkbcommon0=1.7.0-2 libxkbcommon-x11-0=1.7.0-2
```

- [ ] **Step 7: The user restarts an affected app and tests typing**

Close and reopen **Chrome** and **Code**. In each: type ordinary text, then a
character requiring a modifier (`@`, `#`), and a non-ASCII character from your
layout.

The compositor proves nothing here — it links Nix's copy. The test has to
happen inside an apt application.

- [ ] **Step 8: The user reboots and repeats**

```bash
sudo systemctl reboot
```

Then log in and type in Chrome again.

> **If input misbehaves:** `Ctrl+Alt+F1` reaches tty1, whose console keyboard
> does not use libxkbcommon at all. Restore with
> `sudo dpkg -i /root/pkg-archive/libxkbcommon0_*.deb /root/pkg-archive/libxkbcommon-x11-0_*.deb`.

- [ ] **Step 9: The agent verifies zero backports packages remain**

```bash
dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' 2>/dev/null \
  | awk '$1=="ii"' | grep 'bpo13' || echo "ZERO backports packages installed"
```

Expected: `ZERO backports packages installed`.

- [ ] **Step 10: Append the section and commit**

```bash
git add docs/2026-08-15-results-suffer-apt-desktop-reduction.md
git commit -m "docs: Phase 5, zero backports packages"
```

---

## Task 8: Finish the results document

**Files:**
- Modify: `docs/2026-08-15-results-suffer-apt-desktop-reduction.md`

**Interfaces:**
- Consumes: every prior task's measurements.

- [ ] **Step 1: Write `## Did it work?`**

A before/after table covering: manually-installed package count; total
installed count; backports packages; which binary serves FileChooser; which
serves ScreenCast; whether backend selection is declared or accidental; and
whether any KDE daemon runs.

- [ ] **Step 2: Write `## Every defect, and who owns it`**

At minimum, the two this plan already knows about, both found while writing
the spec and both hand-written name lists:

- Counting KDE packages with `^(kde|kwin|plasma|kf6|libkf|kio)`, which missed
  `dolphin`, `konsole` and `konqueror`.
- `pgrep 'kwin|plasma|kded|ksmserver'`, which reported "none of it is running"
  while `kwalletd6` and `kdeconnectd` were running — and which was told to the
  user as fact before being corrected.

And the design-phase trap that a naive reading would have hit: adding
`xdg-desktop-portal-gtk` to `home.packages` alone changes nothing, because
`SystemdService=` resolves a unit *name* through the search path. Record it
as the same defect class as spec 6's `ExecStart=fumon`.

Add any defect found during Tasks 1–7, with the same honesty.

- [ ] **Step 3: Write `## What is still true`**

The remaining apt desktop packages, and why each stays: the corp five by
decision; `gnome-keyring` as the live Secret provider; the ~25 GUI
applications awaiting their own spec. Note that
`/usr/local/share/wayland-sessions/hyprland-nix.desktop` remains the only file
this project installs outside `$HOME` — Task 3 deliberately did not edit
`/etc/pam.d/greetd`, and this is where that decision gets recorded as having
held.

- [ ] **Step 4: Write `## What the next spec inherits`**

- The **portal frontend** is still Debian's `1.20.3` driving two Nix backends.
  Now the only mixed piece, and therefore the obvious next spec.
- **~25 GUI applications** on apt with no Nix counterpart, minus the corp five.
- **`/run/opengl-driver`** remains parked and unestablished.
- **82 dictionary packages** nobody has justified.
- The rollback rule, unchanged and now extended: the portal config and gtk
  backend unit live in the generation.

- [ ] **Step 5: Verify every claim traces to a measurement**

Re-read the finished document and check each factual assertion against a
command output recorded in Tasks 1–7. Anything that cannot be traced gets
removed or marked unverified.

Spec 6's results document asserted results it had merely obtained, and a
reviewer caught it. Show the output, do not summarise it.

- [ ] **Step 6: Commit**

```bash
git add docs/2026-08-15-results-suffer-apt-desktop-reduction.md
git commit -m "docs: results for spec 7, the apt desktop reduction"
```

---

## Notes for the executor

**The `sg nix-users -c '...'` wrapper is not optional.** Every `nix` and
`home-manager` invocation needs it.

**Tasks 2 through 7 belong to the user.** An agent may compose the commands,
read the results and write them down. An agent may not run `home-manager
switch`, any `apt`/`dpkg` command, or `reboot`.

**Task 4 is a gate.** If Nix's gtk backend is not verifiably the process
serving a real file dialog, Task 5 does not run — removing Debian's package
would then leave the session with no FileChooser provider at all, and the
first symptom would be Chrome unable to upload a file.

**The order of Task 6 and Task 7 is fixed** and both are one-way. Neither runs
without its `dpkg-repack` completing first, into `/root/pkg-archive/`, run
from `/root` and not from the repository.

**Two units are expected never to move.** `graphical-session.target` and
`graphical-session-pre.target` belong to systemd. A check demanding they move
under `~/.config` is wrong and produces a false failure.
