# GUI Application Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish a reusable, checked way to run a Nix GUI application on this Debian desktop, and prove it by migrating `seahorse` and `gammastep`.

**Architecture:** Three mechanisms, each with a check that can fail. GL wrapping decided by running the binary rather than by `ldd`, which is a false negative for Qt. GSettings schemas — which nixpkgs relocates out of `XDG_DATA_DIRS` — verified to be handled by the package's own `wrapGAppsHook` wrapper, with a build-time guard for a package that lacks one. And `.desktop` identity, split across a build-time check on declared ID→package pairs and a non-fatal activation-time check against the live `mimeapps.list`.

**Tech Stack:** Nix flakes, standalone Home Manager (`release-26.05`), nixpkgs `nixos-26.05`, Debian 13 (trixie), Hyprland/Wayland, nixGL, GLib/GSettings, XDG desktop entries.

**Spec:** `docs/superpowers/specs/2026-08-17-gui-application-migration-design.md`

## Corrections to the spec, established while writing this plan

The spec is right about the problems and wrong about one solution. Both
corrections are load-bearing; do not implement the spec's version.

1. **Mechanism 2 is already solved by nixpkgs, per package.** The spec says a
   schema mechanism must be built because schemas live at
   `share/gsettings-schemas/<name>/` where GLib never looks. The relocation is
   real, but `bin/seahorse` is a `makeBinaryWrapper` around
   `bin/.seahorse-wrapped` that prefixes `XDG_DATA_DIRS` with four schema
   directories including its own:

   ```
   gsettings-schemas/gsettings-desktop-schemas-50.1
   gsettings-schemas/gtk+3-3.24.52
   gsettings-schemas/gcr-3.41.2
   gsettings-schemas/seahorse-47.0.1
   ```

   `gammastep-indicator` is a bash wrapper doing the same. So the work is
   **verification plus a guard**, not construction: assert that a GUI package
   this flake installs is wrapped, so that a package missing `wrapGAppsHook`
   fails the build instead of aborting at startup.

2. **A risk the spec does not name: the winning `.desktop` and the winning
   binary are decided by two independent search orders.** Nix's and Debian's
   seahorse ship the *same* ID, `org.gnome.seahorse.Application.desktop`, and
   its `Exec=seahorse %u` is a **bare name**. So `XDG_DATA_DIRS` order picks
   the `.desktop`, and `PATH` order picks the binary — independently. That is
   spec 6's `fumon` shape: the right unit running the wrong binary. Removing
   Debian's package is therefore part of correctness, not tidying, and the gate
   must read the running process rather than the launcher entry.

## Global Constraints

- **Every `nix` and `home-manager` invocation must be wrapped in `sg nix-users -c '...'`.** `/nix/var/nix/daemon-socket/` is `0770 root:nix-users`; a bare `nix` fails with `getting status of '/nix/var/nix/daemon-socket/socket': Permission denied`, which reads as a broken Nix install and is not one.
- **Never read a package version from `nixpkgs#<pkg>`.** That is the flake *registry*, not this flake's pinned input. Use `sg nix-users -c 'nix eval --raw .#homeConfigurations."isutton@suffer".pkgs.<pkg>.version'`. This mistake has been made in specs 6, 7, 8 and 9.
- **Never conclude a package is absent from nixpkgs from one attribute lookup.** `bitwarden` resolves only as `bitwarden-desktop`, `isoimagewriter` only as `kdePackages.isoimagewriter`. Both first read as ABSENT.
- **Agents must never run:** `home-manager switch`; any mutating `apt`/`apt-get`/`dpkg`/`apt-mark`/`flatpak`; `systemctl` with start/stop/restart/enable/disable/daemon-reload; `reboot`; or the activation script without `DRY_RUN=1`. Read-only queries are the agent's job by design.
- **Tasks 1, 2 and 3 contain user-run steps.** An agent composes the command, the user runs it, the agent reads the output and records it.
- **`ldd` is not a decision procedure for a `dlopen` question.** Qt loads its platform and GL plugins with `dlopen`, so `ldd` is clean for a binary that aborts on first draw. The GL question is decided by running the binary against the real compositor. Same rule that governs PipeWire's SPA plugins.
- **Gates read a running process's own state, plus one thing a person does.** `/proc/<pid>/exe`, the `/usr` code-mapping count, `busctl --user status` — and then a window that actually appears. For applications the failure mode is a window that never opens, which reads as a broken package.
- **Verify by counting, never by reading empty output as success.** `sed` and other filters exit 0 and mask an upstream `grep`'s status.
- **Enumerate by listing the filesystem, never from a remembered list.** Every name-list check in specs 6 through 9 missed something.
- **`~/.nix-profile/bin` precedes `/usr/bin` on the user manager's PATH** — positions 30 and 34, measured with `systemctl --user show-environment`. This is what makes a bare-name `Exec=` resolve to Nix's binary while both packages are installed. Do not assume it; the Task 2 gate re-measures it.
- **`gnome-keyring` and `gcr4` stay on apt, permanently.** Recorded in `CLAUDE.md` with the PAM reason. `seahorse` moves *while they stay* — that is the point of the task, not an oversight.
- **A Home Manager rollback is not a recovery path.** Recovery is fix-forward, or `sudo apt install <pkg>`; every Debian package here is downloadable from trixie.
- **Nothing in this plan is in the login path.** The worst case is an application that will not start. Nothing here can cost audio, the session or the compositor.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `home/gui-apps.nix` | GUI applications migrated from apt, and the wrapper guard that makes them safe | **Create** (Task 2) |
| `flake.nix` | Module list; the `gui-desktop-ids` build-time check | Modify (Tasks 2, 4) |
| `home/apps.nix` | The activation-time `mimeapps.list` check | Modify (Task 4) |
| `home/services.nix` | One comment line on why `nightLightPath` keeps naming `gammastep` explicitly even though the profile now provides it | Modify (Task 3) |
| `docs/2026-08-17-results-suffer-gui-applications.md` | Results | Create (Task 1), appended by 2–5 |
| `CLAUDE.md` | Standing facts and the new gotchas | Modify (Task 5) |
| `docs/superpowers/specs/2026-08-17-gui-application-migration-design.md` | `## Corrections`, append-only | Modify (Task 5) |

`home/gui-apps.nix` is a new file rather than an addition to `home/apps.nix`,
following the one-file-per-subsystem shape `home/portals.nix` and
`home/audio.nix` established. `home/apps.nix` owns launcher and MIME wiring and
keeps that job.

### `kitty` is removed too, and the reasoning behind it

`home/quickshell.nix:75` records that this project installs foot rather than
kitty, and that the theme switcher's kitty code path was deleted. The user has
confirmed the removal, so it is in scope — earlier drafts of this plan left it
out because the spec asserted it without anyone having agreed.

Measured: `apt-get -s remove kitty` takes **only itself**, installs nothing, and
the binary was last touched 2026-08-13 with no process running. Nothing in
`~/.config/mimeapps.list` names `kitty.desktop`.

One reference survives in the repo and is **not** a dependency:
`quickshell/notifications/NotificationPopup.qml:155` tests whether a
notification's application name contains `kitty` in order to pick a console
icon. It becomes a dead branch, harms nothing, and is deliberately left alone —
removing it would be an unrelated change riding along inside a migration.

### The precondition

`thunar`, `pcmanfm-qt`, `emacs-lucid`, `deskflow` and `kitty` are to be removed
rather than migrated — all five agreed by the user. This is a user-run step in Task 1, not a
migration. `apt-get -s remove` on the four also takes `thunar-volman`, installs
nothing, and leaves 131 packages autoremovable, of which only `libffado2` and
`system-config-printer-udev` ship anything system-level. `cups` is **not**
orphaned, so printing survives; USB printer auto-setup would go on a later
`apt autoremove`, which is out of scope here.

---

## Task 1: Baseline, the four removals, and the GL question

Spec Phase 0. Nothing is written to the flake. The deliverables are a recorded
baseline, five fewer apt packages, and a measured answer to "does this binary
need nixGL" for both subjects.

**Files:**
- Create: `docs/2026-08-17-results-suffer-gui-applications.md`

**Interfaces:**
- Produces: the two store paths, the GL verdict for `seahorse`, `gammastep` and `gammastep-indicator`, and the pre-migration `.desktop` and PATH baseline that Tasks 2 and 3 compare against.

- [ ] **Step 1: Realise both packages from the pinned input**

```bash
cd /home/isutton/Projects/calango-nix
sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".pkgs.seahorse'
sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".pkgs.gammastep'
sg nix-users -c 'nix eval --raw .#homeConfigurations."isutton@suffer".pkgs.seahorse.version'; echo
sg nix-users -c 'nix eval --raw .#homeConfigurations."isutton@suffer".pkgs.gammastep.version'; echo
```

Expected: two store paths, then `47.0.1` and `2.0.11`. Record the paths as
`$SH` and `$GS`.

If the versions read anything else, the command consulted the registry rather
than the pinned input — re-read the Global Constraints.

- [ ] **Step 2: Record the baseline**

```bash
SH=<path from Step 1>
GS=<path from Step 1>

echo "=== Debian versions"
dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' \
  seahorse gammastep thunar thunar-volman pcmanfm-qt emacs-lucid deskflow kitty \
  gnome-keyring gcr4

echo "=== which binary a launcher would run today"
command -v seahorse; command -v gammastep; command -v gammastep-indicator
echo "manager PATH positions:"
systemctl --user show-environment | tr ':' '\n' | grep -nE 'nix-profile/bin|^/usr/bin'

echo "=== .desktop ids, both sides"
dpkg -L seahorse  | grep 'applications/.*desktop' | xargs -n1 basename
dpkg -L gammastep | grep 'applications/.*desktop' | xargs -n1 basename
ls -1 "$SH/share/applications/" "$GS/share/applications/"

echo "=== the keyring daemon that seahorse must keep talking to"
busctl --user status org.freedesktop.secrets | head -4
ls -l ~/.local/share/keyrings/

echo "=== the night-light split, before"
systemctl --user show night-light.service -p ActiveState -p MainPID
NL=$(systemctl --user show night-light.service -p MainPID --value)
for c in $(cat /proc/$NL/task/$NL/children 2>/dev/null); do
  echo "child: $(readlink -f /proc/$c/exe)"
done
```

Expected, and record verbatim — Tasks 2 and 3 compare against these:

- `seahorse 47.0.1-2` and `gammastep 2.0.9-1+b1` both `ii`; the five packages
  Step 3 removes all still `ii`; `gnome-keyring 48.0-1` and `gcr4 4.4.0.1-3`
  `ii` and staying.
- `command -v` returning `/usr/bin/...` for all three today.
- `~/.nix-profile/bin` at a **lower** position number than `/usr/bin`.
- `org.gnome.seahorse.Application.desktop` on both sides;
  `gammastep.desktop` and `gammastep-indicator.desktop` on both sides.
- `org.freedesktop.secrets` owned by `gnome-keyring-daemon`; note its PID.
- `night-light.service` active, with a child under `/nix/store`.

- [ ] **Step 3: The user removes the five agreed packages**

⚠️ `deskflow` is running and will keep running until logout — removing a
package does not kill its process. Input sharing stops at the next boot.

```bash
apt-get -s remove thunar pcmanfm-qt emacs-lucid deskflow kitty 2>&1 | tail -10
sudo apt remove thunar pcmanfm-qt emacs-lucid deskflow kitty
dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' \
  thunar thunar-volman pcmanfm-qt emacs-lucid deskflow kitty
```

Expected: the simulation shows **six** to remove — the five named plus
`thunar-volman`, which Thunar drags along — and zero installed. Afterwards all
six read `rc` or `un`.

Read the "no longer required" list before running it, per `CLAUDE.md`. `cups` is
not in it, so printing survives, but `system-config-printer-udev` is — flag
before any later `apt autoremove` if you print.

- [ ] **Step 4: The user decides the GL question by running the binaries**

`ldd` is excluded. Run each directly, unwrapped, from a terminal inside the
Hyprland session:

```bash
SH=<path from Step 1>
GS=<path from Step 1>
"$SH/bin/seahorse"            # close the window when it appears
"$GS/bin/gammastep-indicator" # a tray icon; Ctrl-C to stop
"$GS/bin/gammastep" -m wayland -O 4000   # then Ctrl-C; screen should warm
```

For each, record: did a window or tray icon appear, and what did it print.
The failure this looks for is an abort on first draw — the shape
`hyprpolkitagent` had in spec 1, where the process starts, registers, and then
dies the instant it is asked to render.

- [ ] **Step 5: If any of them fails, retry through nixGL**

Only for the ones that failed Step 4:

```bash
NIXGL=$(sg nix-users -c 'nix eval --raw .#homeConfigurations."isutton@suffer".pkgs.nixgl.nixGLIntel.outPath')
"$NIXGL/bin/nixGLIntel" "$SH/bin/seahorse"
```

Expected: if a binary failed bare and succeeds wrapped, it needs the wrapper
and Task 2 must wrap it. If it succeeded bare, it does not — and wrapping it
anyway would be an unexamined cost, not a safety margin.

Record the verdict per binary. This is the answer Task 2 and Task 3 consume.

- [ ] **Step 6: Create the results document and commit**

Create `docs/2026-08-17-results-suffer-gui-applications.md`:

```markdown
# Results: GUI applications — suffer

2026-08-17

Spec: `docs/superpowers/specs/2026-08-17-gui-application-migration-design.md`
Plan: `docs/superpowers/plans/2026-08-17-gui-application-migration.md`

## Phase 0: baseline, the four removals, and the GL question

### Pinned versions

<Step 1 output>

### Baseline

<Step 2 output, verbatim>

### The four removals

<Step 3 output>

### The GL verdict

<Steps 4 and 5, per binary: bare result, wrapped result if run, verdict>
```

```bash
git add docs/2026-08-17-results-suffer-gui-applications.md
git commit -m "gui: baseline, remove four unused apps, decide the GL question

ldd cannot answer whether a Nix GUI binary needs the nixGL wrapper --
Qt dlopens its platform and GL plugins, so linkage is clean for a
binary that aborts on first draw. Decided by running seahorse and both
gammastep binaries against the real compositor instead, bare and then
wrapped, and recording which shape each one needs.

Also removes thunar, pcmanfm-qt, emacs-lucid, deskflow and kitty, none
of which are being migrated -- kitty because home/quickshell.nix already
records that this project installs foot and deleted the theme switcher's
kitty path. thunar-volman comes with Thunar."
```

---

## Task 2: `seahorse` from Nix, while the keyring stays on Debian

Spec Phase 1. The first demonstration in this project that a client can cross
to Nix while its daemon does not.

**Files:**
- Create: `home/gui-apps.nix`
- Modify: `flake.nix` — the `modules` list
- Modify: `docs/2026-08-17-results-suffer-gui-applications.md`

**Interfaces:**
- Consumes: Task 1's GL verdict for `seahorse`, and its recorded `org.freedesktop.secrets` owner PID.
- Produces: `home/gui-apps.nix` with the `guiPackages` list and the `wrappedGuiApps` guard derivation, which Task 3 extends and Task 4's build-time check reads.

- [ ] **Step 1: Create `home/gui-apps.nix`**

Write the module. `seahorse` needs no nixGL if Task 1 Step 4 said so; if it
needed the wrapper, wrap it with the `nixglWrap` shape `home/default.nix`
already uses and say why in a comment.

```nix
{ lib, pkgs, ... }:

let
  # GUI applications migrated off apt. One list, because the guard below
  # asserts a property over all of them at once and a second list would be a
  # second thing to keep in step.
  guiPackages = [ pkgs.seahorse ];

  # Assert that every GUI package here is wrapped for GSettings schemas.
  #
  # nixpkgs relocates schemas to share/gsettings-schemas/<name>/glib-2.0/schemas,
  # a path GLib never searches -- on NixOS the module system adds those
  # directories to XDG_DATA_DIRS, and standalone Home Manager on Debian does
  # nothing of the kind. A GTK application whose schema is missing does not
  # degrade; it aborts with `Settings schema '...' is not installed`, which
  # reads as a broken package.
  #
  # In practice nixpkgs solves this per package: wrapGAppsHook produces a
  # wrapper that prefixes XDG_DATA_DIRS with every schema directory the
  # application needs. seahorse's bin/seahorse is a makeBinaryWrapper around
  # bin/.seahorse-wrapped carrying four of them, its own included. So this
  # guard does not build a mechanism -- it checks that the mechanism upstream
  # already applied is present, so a package that forgot the hook is a build
  # error rather than a window that never opens.
  #
  # Detected by the .<name>-wrapped sibling, which both makeWrapper and
  # makeBinaryWrapper produce, rather than by grepping the binary -- one is a
  # shell script and the other an ELF, and a check that only understands one
  # would pass vacuously on the other.
  #
  # Packages with no GSettings schema at all are exempt, and the exemption is
  # derived rather than listed: if the package ships no gsettings-schemas
  # directory, there is nothing to find and nothing to wrap.
  wrappedGuiApps = pkgs.runCommand "gui-apps-schema-wrapped" { } ''
    fail=0
    for pkg in ${lib.concatStringsSep " " (map toString guiPackages)}; do
      name="$(basename "$pkg")"

      if [ ! -d "$pkg/share/gsettings-schemas" ]; then
        echo "ok (no schemas): $name" >&2
        continue
      fi

      wrapped="$(find "$pkg/bin" -maxdepth 1 -name '.*-wrapped' 2>/dev/null | wc -l)"
      if [ "$wrapped" -eq 0 ]; then
        echo "$name ships GSettings schemas but no wrapped binary." >&2
        echo "  Its schemas are at share/gsettings-schemas/, which GLib does" >&2
        echo "  not search, and nothing here adds that to XDG_DATA_DIRS. The" >&2
        echo "  application would abort at startup with" >&2
        echo "  \"Settings schema ... is not installed\"." >&2
        echo "  Expected a .<name>-wrapped sibling in bin/ from wrapGAppsHook." >&2
        fail=1
      else
        echo "ok ($wrapped wrapped): $name" >&2
      fi
    done
    [ "$fail" -eq 0 ] || exit 1
    touch "$out"
  '';
in
{
  # seahorse moves to Nix while gnome-keyring and gcr4 stay on apt, and that
  # is deliberate rather than a half-migration. The coupling is D-Bus, not
  # shared libraries: seahorse is a libsecret client of
  # org.freedesktop.secrets, a stable cross-version API, and Nix's seahorse
  # links Nix's own gcr inside its own process. Nothing requires a client and
  # a daemon to come from the same packaging system.
  #
  # gnome-keyring cannot move -- pam_gnome_keyring.so is in /etc/pam.d/greetd
  # and pointing PAM at a store path risks a machine that cannot log in. See
  # CLAUDE.md. seahorse is 47.0.1 on both sides, so this is a pure lateral
  # move and nothing here can be blamed on a version change.
  #
  # The guard is referenced from home.packages so nothing can install these
  # applications without having passed it.
  home.packages = guiPackages ++ [
    (pkgs.runCommand "gui-apps-guard" { } "ln -s ${wrappedGuiApps} $out")
  ];
}
```

- [ ] **Step 2: Add the module to the flake**

In `flake.nix`, add `./home/gui-apps.nix` to the `modules` list, after
`./home/audio.nix`.

- [ ] **Step 3: Build**

```bash
sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage'
```

Record as `$NEW`.

- [ ] **Step 4: Prove the guard can fail**

Point the detector at a name no wrapper produces:

```bash
sed -i "s/-name '\.\*-wrapped'/-name '.*-NOT-wrapped'/" home/gui-apps.nix
grep -n 'NOT-wrapped' home/gui-apps.nix
sg nix-users -c 'nix build --no-link .#homeConfigurations."isutton@suffer".activationPackage' 2>&1 | tail -8
```

Expected: the build **fails** with `ships GSettings schemas but no wrapped binary.`

Restore and confirm the same `$NEW`:

```bash
sed -i "s/-name '\.\*-NOT-wrapped'/-name '.*-wrapped'/" home/gui-apps.nix
grep -c 'NOT-wrapped' home/gui-apps.nix
sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage'
```

Expected: `0`, and the identical `$NEW`. A guard never seen to fail is a comment.

- [ ] **Step 5: Read what landed**

```bash
NEW=<path from Step 3>
echo "=== the binary in the profile is the WRAPPER, not the raw ELF"
ls -la "$NEW/home-path/bin/seahorse"
readlink -f "$NEW/home-path/bin/seahorse"
echo "=== and the schema dirs it prefixes"
strings "$(readlink -f "$NEW/home-path/bin/seahorse")" | grep -oE 'gsettings-schemas/[a-z0-9.+-]*' | sort -u
echo "=== the .desktop it ships, and its Exec"
ls -1 "$NEW/home-path/share/applications/" | grep -i seahorse
grep '^Exec' "$NEW/home-path/share/applications/org.gnome.seahorse.Application.desktop"
echo "=== flake check"
sg nix-users -c 'nix flake check' 2>&1 | tail -1
```

Expected: `bin/seahorse` resolving into the store; four `gsettings-schemas`
directories including `seahorse-47.0.1`; the `.desktop` ID
`org.gnome.seahorse.Application.desktop` with `Exec=seahorse %u`; all checks
passing.

Note the bare-name `Exec`. Until Debian's package is removed, the `.desktop`
that wins is decided by `XDG_DATA_DIRS` and the binary that runs is decided by
`PATH` — independently. Step 7 measures which binary actually runs.

- [ ] **Step 6: The user switches, then removes Debian's seahorse**

```bash
cd /home/isutton/Projects/calango-nix
sg nix-users -c 'home-manager switch --flake .#isutton@suffer'
command -v seahorse; readlink -f "$(command -v seahorse)"
sudo apt remove seahorse
dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' seahorse gnome-keyring gcr4
```

Expected: after the switch `seahorse` resolves into `/nix/store`; afterwards
`seahorse` is `rc` while `gnome-keyring` and `gcr4` remain `ii`.

If `apt remove seahorse` proposes removing `gnome-keyring`, **stop** — that
contradicts the measured dependency direction and the plan needs revisiting.

- [ ] **Step 7: Gate**

```bash
echo "=== which binary a launcher runs"
command -v seahorse; readlink -f "$(command -v seahorse)"
echo "=== exactly one .desktop with that id"
find ~/.nix-profile/share/applications /usr/share/applications ~/.local/share/applications \
  -name 'org.gnome.seahorse.Application.desktop' 2>/dev/null
echo "=== the keyring daemon did NOT move"
busctl --user status org.freedesktop.secrets | head -4
dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' gnome-keyring
```

Then, by hand: **launch seahorse from the launcher** (not from a shell — the
launcher is what resolves the bare-name `Exec`), and confirm it opens and lists
your `login.keyring` contents. While it is open:

```bash
p=$(pgrep -u "$USER" -x seahorse | head -1)
printf 'exe=%s usr-maps=%s\n' "$(readlink -f /proc/$p/exe)" \
  "$(grep -cE '/usr/(lib|bin|libexec)' /proc/$p/maps)"
tr '\0' '\n' < /proc/$p/environ | grep -c gsettings-schemas
```

Expected: the exe under `/nix/store`; `usr-maps=0`; a non-zero count of
`gsettings-schemas` entries in its environment — the wrapper's work, visible on
the running process rather than inferred from the package. And the keyring
still served by Debian's `gnome-keyring-daemon`, which is the whole point.

- [ ] **Step 8: Append to the results document and commit**

Append a `## Phase 1: seahorse` section with Steps 5 and 7's output and the
by-hand result.

```bash
git add home/gui-apps.nix flake.nix docs/2026-08-17-results-suffer-gui-applications.md
git commit -m "gui: take seahorse from Nix, keyring stays on Debian

The first client in this project to cross to Nix while its daemon does
not. seahorse talks to gnome-keyring over libsecret and
org.freedesktop.secrets, a stable cross-version API, so the coupling is
D-Bus rather than shared libraries -- Nix's seahorse links Nix's own gcr
inside its own process. Both sides are 47.0.1, so nothing here can be
blamed on a version change.

The module carries a guard rather than a mechanism. nixpkgs relocates
GSettings schemas to share/gsettings-schemas/<name>, which GLib never
searches, but wrapGAppsHook already wraps each package with those
directories prefixed onto XDG_DATA_DIRS. The guard asserts the wrapper is
there, so a package that forgot the hook is a build failure instead of a
window that never opens. Detected by the .<name>-wrapped sibling, because
makeWrapper emits a shell script and makeBinaryWrapper an ELF, and a
check that understood only one would pass vacuously on the other."
```

---

## Task 3: `gammastep` from Nix, and a live split closed

Spec Phase 2.

**Files:**
- Modify: `home/gui-apps.nix` — add to `guiPackages`
- Modify: `home/services.nix` — `nightLightPath`
- Modify: `docs/2026-08-17-results-suffer-gui-applications.md`

**Interfaces:**
- Consumes: `guiPackages` and `wrappedGuiApps` from Task 2, and Task 1's GL verdict for both gammastep binaries.
- Produces: nothing later tasks depend on.

### The split being closed

Today `pkgs.gammastep` appears only inside `home/services.nix`'s
`nightLightPath`, which becomes the night-light unit's `Environment=PATH`. It
has never been in `home.packages`. So the unit runs Nix's `2.0.11` while a
shell and both `.desktop` entries get Debian's `2.0.9`. Nix's package has full
parity — `gammastep`, `gammastep-indicator`, and both `.desktop` files.

- [ ] **Step 1: Add gammastep to the GUI list**

In `home/gui-apps.nix`, change the list and record why:

```nix
  # gammastep closes a two-provenance split rather than starting a migration.
  # pkgs.gammastep was already reaching the night-light unit through
  # home/services.nix's nightLightPath -- the unit's own Environment=PATH --
  # but never through home.packages, so the unit ran 2.0.11 while a shell and
  # both .desktop entries got Debian's 2.0.9. Nix's package has full parity:
  # gammastep, gammastep-indicator, and both .desktop files.
  #
  # gammastep-indicator is a bash wrapper that prefixes XDG_DATA_DIRS with
  # gtk+3's schema directory, so it satisfies the guard above; gammastep itself
  # ships no schemas and is exempt by the guard's own derivation of the
  # exemption.
  guiPackages = [ pkgs.seahorse pkgs.gammastep ];
```

- [ ] **Step 2: Simplify `nightLightPath`**

In `home/services.nix`, `gammastep` stays in `nightLightPath`. **Do not remove
it.** The unit names its PATH explicitly so that it does not depend on the
profile, and that is the property that made the unit correct all along while
the shell was wrong. Add one line to its comment:

```nix
    gammastep # -m wayland/-l/-t/-O, the whole point of the unit (run.sh:88,93,103)
              # Kept explicit even though home/gui-apps.nix now puts gammastep
              # in the profile: a unit that resolves its own binaries does not
              # depend on PATH order, and this one was right when the shell was
              # wrong.
```

- [ ] **Step 3: Build and check**

```bash
sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage'
sg nix-users -c 'nix flake check' 2>&1 | tail -1
```

Record as `$NEW`. Expected: a store path, and checks passing — the guard now
covers two packages and must still report `ok` for both.

- [ ] **Step 4: Verify what landed**

```bash
NEW=<path from Step 3>
echo "=== both binaries and both .desktop files in the profile"
ls -1 "$NEW/home-path/bin/" | grep gammastep
ls -1 "$NEW/home-path/share/applications/" | grep gammastep
echo "=== the indicator is wrapped; plain gammastep need not be"
file "$NEW/home-path/bin/gammastep-indicator" | cut -c1-90
ls -1a "$(dirname "$(readlink -f "$NEW/home-path/bin/gammastep-indicator")")" | grep -c wrapped
```

Expected: `gammastep` and `gammastep-indicator`; `gammastep.desktop` and
`gammastep-indicator.desktop`; the indicator a bash-script wrapper.

- [ ] **Step 5: The user switches and removes Debian's gammastep**

```bash
cd /home/isutton/Projects/calango-nix
sg nix-users -c 'home-manager switch --flake .#isutton@suffer'
command -v gammastep; readlink -f "$(command -v gammastep)"
sudo apt remove gammastep
dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' gammastep
```

- [ ] **Step 6: Gate**

```bash
echo "=== the split is closed: shell and unit agree"
command -v gammastep; readlink -f "$(command -v gammastep)"
NL=$(systemctl --user show night-light.service -p MainPID --value)
echo "night-light: $(systemctl --user show night-light.service -p ActiveState --value) pid=$NL"
for c in $(cat /proc/$NL/task/$NL/children 2>/dev/null); do
  printf '  child exe=%s usr-maps=%s\n' "$(readlink -f /proc/$c/exe)" \
    "$(grep -cE '/usr/(lib|bin)' /proc/$c/maps)"
done
echo "=== exactly one of each .desktop"
for d in gammastep.desktop gammastep-indicator.desktop; do
  printf '%-32s %s\n' "$d" "$(find ~/.nix-profile/share/applications /usr/share/applications -name "$d" 2>/dev/null | wc -l)"
done
```

Then, by hand: launch `gammastep-indicator` from the launcher and confirm the
tray icon appears; toggle the night light from the shell panel and confirm the
screen warms.

Expected: `gammastep` resolving into `/nix/store`; the night-light child still
a store binary with `usr-maps=0`; exactly `1` for each `.desktop`.

- [ ] **Step 7: Append and commit**

```bash
git add home/gui-apps.nix home/services.nix docs/2026-08-17-results-suffer-gui-applications.md
git commit -m "gui: take gammastep from Nix, closing a two-provenance split

pkgs.gammastep was already reaching the night-light unit through
home/services.nix's nightLightPath, the unit's own Environment=PATH, but
never through home.packages. So the unit ran 2.0.11 while a shell and
both .desktop entries got Debian's 2.0.9 -- the same shape as spec 6's
fumon, in a place nobody had looked.

nightLightPath keeps naming gammastep explicitly. A unit that resolves
its own binaries does not depend on PATH order, and that is exactly why
this unit was right while the shell was wrong."
```

---

## Task 4: The `.desktop` identity checks, at both layers

Spec Phase 3, in the corrected two-layer form. Deliberately last: it needs a
migrated application to be meaningful.

**Files:**
- Modify: `flake.nix` — add `checks.${system}.gui-desktop-ids`
- Modify: `home/apps.nix` — add the activation-time check
- Modify: `docs/2026-08-17-results-suffer-gui-applications.md`

**Interfaces:**
- Consumes: nothing from `home/gui-apps.nix` directly. The build-time check reads the **built generation's** `home-path/share/applications`, the same store path `no-dangling-home-files` already trusts, so it needs no new plumbing and no exported list. The activation check reads the live `~/.config/mimeapps.list` and `XDG_DATA_DIRS`.
- Produces: nothing later tasks depend on.

### Why this is two checks and not one

The obvious form is a flake check that reads `~/.config/mimeapps.list` and
`/usr/share/applications` and asserts every referenced ID resolves. That
cannot exist: a flake check runs in the Nix sandbox, where both paths are
impure and invisible. This is the same trap spec 9 hit with the `/dev/null`
mask — a runtime probe passed and the build question was never asked.

So: a build-time check on what the flake itself ships, and a non-fatal
activation-time check on the live file.

- [ ] **Step 1: Add the build-time check to `flake.nix`**

Beside `no-dangling-home-files` and `no-pulseaudio-daemon`:

```nix
        # The .desktop ids that ~/.config/mimeapps.list names AND that this
        # flake is responsible for providing. Declared here, in Nix, because a
        # flake check cannot read mimeapps.list -- it is outside the sandbox.
        #
        # This catches the failure that matters at the moment a package is
        # added: nixpkgs' signal-desktop ships signal.desktop where Debian's
        # ships signal-desktop.desktop, and mimeapps.list names the Debian id
        # for x-scheme-handler/sgnl and x-scheme-handler/signalcaptcha. Migrate
        # Signal without noticing and both handlers stop resolving, silently.
        #
        # The list is empty of migrated entries today: seahorse and gammastep
        # are named by no handler. It exists now so that the seven follow-on
        # applications cannot be added without it, and the check below proves
        # the machinery works by asserting the ids the flake DOES ship.
        gui-desktop-ids =
          pkgs.runCommand "gui-desktop-ids" { } ''
            apps=${suffer.activationPackage}/home-path/share/applications
            fail=0

            # Every id this flake must ship, with the reason it is required.
            # Format: <desktop-id> <why>
            required="org.gnome.seahorse.Application.desktop seahorse-launcher
            gammastep.desktop gammastep-launcher
            gammastep-indicator.desktop gammastep-indicator-launcher"

            echo "$required" | while read -r id why; do
              [ -n "$id" ] || continue
              if [ ! -e "$apps/$id" ]; then
                echo "missing .desktop id: $id (needed for: $why)" >&2
                echo "  The package that should ship it does not, or ships it" >&2
                echo "  under a different name. nixpkgs and Debian do not" >&2
                echo "  always agree on the id -- signal-desktop is the known" >&2
                echo "  case. Check what the package actually ships." >&2
                exit 1
              fi
            done || fail=1

            [ "$fail" -eq 0 ] || exit 1
            touch "$out"
          '';
```

- [ ] **Step 2: Prove it fails**

```bash
sed -i 's/^            gammastep.desktop gammastep-launcher/            gammastep-WRONG.desktop gammastep-launcher/' flake.nix
sg nix-users -c 'nix flake check' 2>&1 | tail -6
```

Expected: failure naming `missing .desktop id: gammastep-WRONG.desktop`.

```bash
sed -i 's/^            gammastep-WRONG.desktop gammastep-launcher/            gammastep.desktop gammastep-launcher/' flake.nix
grep -c 'gammastep-WRONG' flake.nix
sg nix-users -c 'nix flake check' 2>&1 | tail -1
```

Expected: `0`, then all three checks passing.

- [ ] **Step 3: Add the activation-time check to `home/apps.nix`**

```nix
  # Warn when ~/.config/mimeapps.list names a .desktop id that nothing on
  # XDG_DATA_DIRS provides any more.
  #
  # Non-fatal, deliberately. That file holds ten associations and several name
  # things this flake does not own -- flatpak Slack, claude-code-url-handler --
  # whose absence is none of this flake's business and must never abort a
  # switch. The fatal half of this property is flake.nix's gui-desktop-ids,
  # which asserts what the flake itself ships.
  #
  # This is the layer that can see the live file at all: a flake check runs in
  # the Nix sandbox, where ~/.config and /usr/share are both invisible.
  config.home.activation.mimeappsIds =
    lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      run ${pkgs.bash}/bin/sh -c '
        list="$HOME/.config/mimeapps.list"
        [ -r "$list" ] || exit 0
        missing=0
        ids=$(sed -n "s/^[^=]*=//p" "$list" | tr ";" "\n" | sed "/^$/d" | sort -u)
        for id in $ids; do
          found=0
          IFS=":"
          for d in $XDG_DATA_DIRS $HOME/.local/share; do
            [ -e "$d/applications/$id" ] && { found=1; break; }
          done
          unset IFS
          [ "$found" -eq 1 ] || { echo "mimeapps.list names a missing .desktop id: $id" >&2; missing=$((missing+1)); }
        done
        [ "$missing" -eq 0 ] || echo "$missing unresolved id(s) in mimeapps.list -- handlers for them will do nothing" >&2
      ' || true
    '';
```

- [ ] **Step 4: Build, and read what the activation script would say**

```bash
sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage'
NEW=<that path>
grep -n 'mimeappsIds' "$NEW/activate" | head -2
DRY_RUN=1 "$NEW/activate" 2>&1 | grep -iA3 'mimeapps' | head -10
```

Expected: the hook present in the script; under `DRY_RUN` the `run` wrapper
prints the command rather than executing it, so no warnings appear — which is
the point of `run`, and is why Step 6 checks the real switch instead.

- [ ] **Step 5: Prove the activation check can fire**

```bash
cp ~/.config/mimeapps.list "$CLAUDE_JOB_DIR/tmp/mimeapps.bak" 2>/dev/null || cp ~/.config/mimeapps.list /tmp/mimeapps.bak
printf 'x-scheme-handler/probe=definitely-not-installed.desktop\n' >> ~/.config/mimeapps.list
```

Then the user switches, and the warning must appear:

```bash
sg nix-users -c 'home-manager switch --flake .#isutton@suffer' 2>&1 | grep -i 'missing .desktop'
```

Expected: `mimeapps.list names a missing .desktop id: definitely-not-installed.desktop`,
and the switch **succeeds anyway** — that is the non-fatal requirement.

Restore:

```bash
sed -i '/x-scheme-handler\/probe=/d' ~/.config/mimeapps.list
diff ~/.config/mimeapps.list "$CLAUDE_JOB_DIR/tmp/mimeapps.bak" && echo "restored byte-identical"
```

- [ ] **Step 6: Gate**

```bash
sg nix-users -c 'home-manager switch --flake .#isutton@suffer' 2>&1 | grep -ci 'missing .desktop'
sg nix-users -c 'nix flake check' 2>&1 | tail -1
```

Expected: `0` warnings on the real, unmutated `mimeapps.list` — every id it
names resolves — and all three flake checks passing.

- [ ] **Step 7: Append and commit**

```bash
git add flake.nix home/apps.nix docs/2026-08-17-results-suffer-gui-applications.md
git commit -m "gui: check .desktop identity at both layers

The obvious form of this check cannot exist. A flake check runs in the
Nix sandbox, where ~/.config/mimeapps.list and /usr/share/applications
are both invisible, so \"assert every id in mimeapps.list resolves\" is
not something a flake check can do. Spec 9 paid for this same lesson with
the /dev/null mask: a runtime probe passed and the build question went
unasked.

So it is two checks. gui-desktop-ids asserts, at build time, that the
generation ships every id the flake is responsible for -- the failure
that matters when a package is added, because nixpkgs' signal-desktop
ships signal.desktop where Debian's ships signal-desktop.desktop and
mimeapps.list names the Debian id for two scheme handlers. And a
non-fatal activation hook reads the live file, warning about ids nothing
provides; non-fatal because that file names flatpak Slack and
claude-code-url-handler, which this flake does not own and must not
abort a switch over."
```

---

## Task 5: Close out

**Files:**
- Modify: `docs/2026-08-17-results-suffer-gui-applications.md` — endpoint and defects
- Modify: `CLAUDE.md`
- Modify: `docs/superpowers/specs/2026-08-17-gui-application-migration-design.md` — `## Corrections`, append-only

- [ ] **Step 1: Measure the endpoint**

```bash
cd /home/isutton/Projects/calango-nix
echo "=== apt packages this plan removed"
dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' \
  seahorse gammastep thunar thunar-volman pcmanfm-qt emacs-lucid deskflow 2>&1
echo "=== GUI candidates still on apt, counted from the filesystem"
for p in $(apt-mark showmanual 2>/dev/null); do
  case "$p" in 1password|1password-cli|code|google-chrome-stable|endpoint-verification) continue;; esac
  dpkg -L "$p" 2>/dev/null | grep -q '/usr/share/applications/.*\.desktop' && echo "$p"
done 2>/dev/null | sort
echo "=== flake checks"
sg nix-users -c 'nix flake check' 2>&1 | tail -1
```

Report the real count. The spec predicted **eight** fewer apt packages:
`seahorse` and `gammastep` migrated, five removed (`thunar`, `pcmanfm-qt`,
`emacs-lucid`, `deskflow`, `kitty`), and `thunar-volman` riding along with
Thunar. Count it from `dpkg-query` rather than restating the spec, and if the
number differs say what the difference is.

- [ ] **Step 2: Append `## Endpoint` and `## Defects found`**

`## Defects found` must record, without softening:

1. The spec's mechanism 2 was wrong — a schema mechanism did not need building,
   because `wrapGAppsHook` already wraps each package. The relocation is real;
   the conclusion that nothing handled it was not checked.
2. The spec did not name the two-independent-search-orders risk: same `.desktop`
   ID in both trees plus a bare-name `Exec` means `XDG_DATA_DIRS` picks the
   entry and `PATH` picks the binary.
3. The spec's Phase 3 check could not have existed as written.
4. Anything else measurement overturned during execution.

- [ ] **Step 3: `CLAUDE.md`**

Add to **Mechanisms that are not what they look like**:

```markdown
**nixpkgs relocates GSettings schemas, and then wraps the binary to find
them.** Schemas live at `share/gsettings-schemas/<name>/glib-2.0/schemas`, a
path GLib never searches — but `wrapGAppsHook` produces a `bin/<name>` wrapper
that prefixes `XDG_DATA_DIRS` with every schema directory the application
needs, so a Nix GTK application works on Debian with no help from this flake.
The thing to check is that the wrapper *exists*: a package that missed the hook
aborts at startup with `Settings schema … is not installed`, which reads as a
broken package rather than a missing environment. Detect it by the
`.<name>-wrapped` sibling in `bin/`, not by grepping the binary —
`makeWrapper` emits a shell script and `makeBinaryWrapper` an ELF, and a check
that understands only one passes vacuously on the other.
`flake.nix`'s `gui-desktop-ids` and `home/gui-apps.nix`'s guard are the two
halves of this.

**A `.desktop` file's winning entry and its winning binary are chosen by two
different search paths.** `XDG_DATA_DIRS` decides which `.desktop` a launcher
reads; a bare-name `Exec=` is then resolved through `PATH`. While both a Debian
and a Nix package are installed, those can disagree — Nix's `.desktop` running
Debian's binary, or the reverse. Same shape as spec 6's `fumon`. Removing the
apt package is part of making it deterministic, not cleanup afterwards.

**`.desktop` ids are not stable across the Debian/Nix boundary.** nixpkgs'
`signal-desktop` ships `signal.desktop` where Debian's ships
`signal-desktop.desktop`, and `~/.config/mimeapps.list` names the Debian id for
`x-scheme-handler/sgnl` and `x-scheme-handler/signalcaptcha`. Migrating Signal
without checking kills both handlers silently. Some ids *are* identical —
`firefox-esr.desktop`, `org.gnome.seahorse.Application.desktop` — which is
worse than none being identical, because it invites the assumption.
```

Add to **Standing facts about this machine**:

```markdown
- **`seahorse` is Nix's; `gnome-keyring` and `gcr4` are Debian's, and that is
  correct rather than half-finished.** The coupling is D-Bus — `libsecret`
  talking to `org.freedesktop.secrets`, a stable cross-version API — not shared
  libraries. Nix's seahorse links Nix's own gcr inside its own process. This is
  the first client in this project to cross the boundary while its daemon did
  not, and it is the template for the remaining GUI applications.
- **`gammastep` is entirely Nix's.** It was a two-provenance split until spec
  10: `pkgs.gammastep` reached the night-light unit through
  `home/services.nix`'s `nightLightPath` but never through `home.packages`, so
  the unit ran 2.0.11 while a shell got Debian's 2.0.9. `nightLightPath` still
  names it explicitly on purpose — a unit that resolves its own binaries does
  not depend on `PATH` order.
- **`flatseal` and `fresh-editor` stay on apt.** `flatseal` is absent from
  nixpkgs and is really a flatpak; nixpkgs' `fresh-editor` is 0.3.6 against
  Debian's 0.4.7, so moving it would be a downgrade.
```

- [ ] **Step 4: Append `## Corrections` to the spec**

Append-only. Do not rewrite the spec's prose — it records what was argued at
the time, and rewriting it would erase that mechanism 2 was wrong. Note the two
corrections from this plan's header plus anything execution added, and point at
the results document.

- [ ] **Step 5: Commit**

```bash
git add docs/2026-08-17-results-suffer-gui-applications.md CLAUDE.md \
        docs/superpowers/specs/2026-08-17-gui-application-migration-design.md
git commit -m "gui: close out spec 10

Three mechanisms, and only one of them needed building. GSettings schema
handling turned out to be already solved per package by wrapGAppsHook, so
what shipped is a guard that a GUI package is wrapped rather than a
mechanism to wrap it -- the spec's version of mechanism 2 was a
conclusion nobody had checked. The .desktop identity check could not
exist in the form the spec specified, because a flake check cannot see
~/.config or /usr/share, so it is two checks at two layers.

And a risk the spec never named: the winning .desktop entry and the
winning binary are chosen by two independent search paths, so while both
packages are installed a Nix .desktop can run a Debian binary. Removing
the apt package is part of correctness."
```

---

## Verification summary

Every gate here reads, in this order of trust:

1. **A running process's own state** — `/proc/<pid>/exe`, the `/usr`
   code-mapping count, and for these applications the wrapper's work visible in
   `/proc/<pid>/environ` rather than inferred from the package.
2. **What the search paths actually resolve** — `command -v`, and `find` across
   every `XDG_DATA_DIRS` entry, counted rather than eyeballed.
3. **A window a person opened**, launched from the launcher rather than a shell,
   because the launcher is what resolves a bare-name `Exec=`.

`ldd` appears nowhere as a decision procedure. Each of the three checks
introduced is proven to fail by mutation before being trusted.
