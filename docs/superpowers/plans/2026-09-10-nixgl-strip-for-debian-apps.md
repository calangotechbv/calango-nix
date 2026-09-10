# nixGL Strip For Debian GL Applications — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make 1Password open a window when it is the first instance, by launching it without the five nixGL variables the session inherits.

**Architecture:** A declarative table in `home/apps.nix` names applications that must not inherit the nixGL environment. Each entry generates a shim package on PATH and a `.desktop` override, covering a typed launch and a launcher launch. The list of variables to strip is read out of `nixGLIntel`'s own script at build time, so it cannot drift from what nixGL actually exports.

**Tech Stack:** Nix, standalone Home Manager, POSIX sh.

**Spec:** `docs/superpowers/specs/2026-09-10-nixgl-strip-for-debian-apps-design.md`

## Global Constraints

- Wrap every `nix` and `home-manager` invocation in `sg nix-users -c '…'`.
- Use `/usr/bin/grep` explicitly, with `-F` for a literal, whenever a count is load-bearing **in an interactive shell**. The interactive `grep` is ugrep and returns `0` for patterns containing `${`.
- **Inside a Nix builder, use plain `grep`.** The builder's shell is the real one, so the ugrep rule does not apply — and `/usr/bin/grep` is not in the sandbox, so naming it there is an impurity that fails the build.
- Inside a Nix builder, `set -e` and `pipefail` are ON. A bare `n=$(… | grep -c …)` aborts the build when the pattern does not match, rather than yielding `0`. Assign with `|| true` and test the variable, or put the grep in an `if` condition.
- Inside an activation hook's `run … sh -c '…'` child, `errexit` and `pipefail` are OFF (`$-` is `hBc`). Each step carries its own `|| exit 0`.
- Every guard is proven able to fail by mutation before it is trusted.
- Stage good content before mutating, revert with `git restore --worktree`, then re-read the file and confirm a count. `git restore --staged --worktree` restores from HEAD and destroys uncommitted work.
- `~/.config/autostart` is out of scope. Do not create, modify or link anything there.

---

### Task 1: The shim, and the guard that it strips anything at all

**Files:**
- Modify: `home/apps.nix` — add the `nixgl` import, the `glStripped` table, the `glStripShim` function, and the shims in `home.packages`

**Interfaces:**
- Produces: `glStripped` — an attrset of `name -> { binary, desktopId, reason }`, read by Task 2 and Task 3.
- Produces: `glStripShims` — a list of packages, each with `bin/<name>`.

- [ ] **Step 1: Add the nixgl import**

`home/apps.nix` opens `{ config, lib, pkgs, ... }:` and does not import nixgl. Add it as the first binding in the `let` block, matching `home/quickshell.nix`:

```nix
  nixgl = import ./../lib/nixgl.nix { inherit pkgs; };
```

- [ ] **Step 2: Add the table**

```nix
  # Applications that must NOT inherit the session's nixGL environment.
  #
  # The compositor is nixGL-wrapped, so every session child inherits the five
  # variables nixGLIntel exports. __EGL_VENDOR_LIBRARY_FILENAMES points libglvnd
  # at Nix's mesa vendor JSON and LD_LIBRARY_PATH puts Nix's mesa first, so a
  # Debian-linked process loads a Nix libEGL, its GPU process dies during
  # initialisation, and Electron creates no window -- while staying alive to
  # serve its tray icon and its SSH agent, which is why this hides so well.
  #
  # An explicit table, not a predicate. home/gui-apps.nix's wrapExemptions
  # shipped as a derived rule and was deleted after review: a predicate exempts
  # every future package that satisfies it by accident, and nobody is asked a
  # question at that moment. A name here is typed by a person who then writes
  # the sentence beside it.
  #
  # Chrome and Slack are Debian-linked too and are deliberately absent. Both
  # measure healthy -- their gpu-process maps libgallium 6 times and swiftshader
  # 0 -- so something in their own startup sanitises the environment. That is
  # luck rather than design; they are absent because nothing is broken, not
  # because they are immune.
  glStripped = {
    "1password" = {
      binary    = "/opt/1Password/1password";
      desktopId = "1password.desktop";
      reason = ''
        Debian-linked Electron. With the session's nixGL variables set its GPU
        process dies during initialisation -- "Initialization of all (2) EGL
        display types failed" -- and no window is ever created. Measured
        2026-09-10: no window with them, a window in 1.6 s without.
      '';
    };
  };
```

- [ ] **Step 3: Add the shim generator, with its vacuity anchor**

```nix
  # The variables to strip are READ OUT OF nixGL, not written here.
  #
  # lib/nixgl.nix is the one file that decides which GL wrapper this machine
  # uses, and it does not name these variables at all -- nixGLIntel exports them
  # at runtime. A hand-written list here would be a second declaration with
  # nothing checking it. nixGLIntel is a bash script, so the names are readable
  # at build time, and a sixth variable would be stripped with no edit here.
  #
  # `|| true` on the assignment is load-bearing and is not defensive noise. A
  # builder runs with `set -e` and `pipefail`, so a grep that matches nothing
  # aborts the assignment before the check below can print anything -- the guard
  # would read as a counting guard and behave as an unconditional failure. The
  # emptiness test is the vacuity anchor: without it, a change in nixGL's script
  # shape yields a shim that strips nothing, launches the application exactly as
  # before, and passes every check.
  glStripShim = name: entry:
    pkgs.runCommand "calango-${name}" { } ''
      vars=$(grep -oE '^export [A-Z_]+' ${nixgl.bin} | cut -d' ' -f2 | sort -u) || true
      if [ -z "$vars" ]; then
        echo "calango-${name}: no exported variables found in" >&2
        echo "  ${nixgl.bin}" >&2
        echo "  The shim would strip nothing and the application would fail" >&2
        echo "  exactly as it does without it. Check whether nixGL still" >&2
        echo "  writes 'export NAME=' at the start of a line." >&2
        exit 1
      fi

      flags=""
      for v in $vars; do flags="$flags -u $v"; done

      mkdir -p "$out/bin"
      printf '#!%s\nexec %s/bin/env%s %s "$@"\n' \
        "${pkgs.runtimeShell}" "${pkgs.coreutils}" "$flags" "${entry.binary}" \
        > "$out/bin/${name}"
      chmod 555 "$out/bin/${name}"
    '';

  glStripShims = lib.mapAttrsToList glStripShim glStripped;
```

- [ ] **Step 4: Put the shims on PATH**

`home/apps.nix` already has `config.home.packages = [ calangoOpen codeShim ];`. Change it to:

```nix
  config.home.packages = [ calangoOpen codeShim ] ++ glStripShims;
```

`uwsm/env` prepends `~/.nix-profile/bin` to PATH, so the shim wins over `/usr/bin/1password`.

- [ ] **Step 5: Build it and read the generated script**

```bash
sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage' >/dev/null
S=$(sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".pkgs.hello' >/dev/null; \
    sg nix-users -c 'nix eval --raw .#homeConfigurations."isutton@suffer".config.home.path')
cat "$S/bin/1password"
```

Expected: a two-line script whose `exec env` names five `-u` flags and ends `/opt/1Password/1password "$@"`.

- [ ] **Step 6: Confirm the five flags by count, not by eye**

```bash
/usr/bin/grep -c -- '-u __EGL_VENDOR_LIBRARY_FILENAMES' "$S/bin/1password"   # 1
tr ' ' '\n' < "$S/bin/1password" | /usr/bin/grep -cx -- '-u'                  # 5
```

- [ ] **Step 7: Prove the vacuity anchor can fire**

Stage the good content first, because the revert below restores from the index:

```bash
git add home/apps.nix
```

Then mutate the pattern so it matches nothing — change `'^export [A-Z_]+'` to `'^exportNOTHING [A-Z_]+'` — and build:

```bash
sg nix-users -c 'nix build --no-link .#homeConfigurations."isutton@suffer".activationPackage' 2>&1 | tail -6
```

Expected: the build FAILS with `calango-1password: no exported variables found in`.

If it succeeds, the anchor is written so it cannot fire. Do not proceed; fix it.

- [ ] **Step 8: Revert the mutation and confirm the revert**

```bash
git restore --worktree home/apps.nix
/usr/bin/grep -c "'\^export \[A-Z_\]+'" home/apps.nix    # 1
```

- [ ] **Step 9: Commit**

```bash
git add home/apps.nix
git commit -m "apps: strip the nixGL environment for Debian GL applications"
```

---

### Task 2: The `.desktop` override, so the launcher uses the shim

**Files:**
- Create: `data/1password.desktop`
- Modify: `home/apps.nix` — the `desktopEntries` builder and the `xdg.dataFile` entries

**Interfaces:**
- Consumes: `glStripped` and `glStripShim` from Task 1.
- Produces: `~/.local/share/applications/1password.desktop`, shadowing `/usr/share/applications/1password.desktop`.

- [ ] **Step 1: Create the override**

A copy of the vendor's ten lines with only `Exec` changed. `MimeType` is load-bearing: drop it and `xdg-mime query default x-scheme-handler/onepassword` stops resolving, which is the trap `CLAUDE.md` records for Signal.

Create `data/1password.desktop`:

```
[Desktop Entry]
Name=1Password
Exec=@onePasswordShim@ %U
Terminal=false
Type=Application
Icon=1password
StartupWMClass=1Password
Comment=Password manager and secure wallet
MimeType=x-scheme-handler/onepassword;x-scheme-handler/onepassword8;
Categories=Office;
```

- [ ] **Step 2: Substitute the shim path into it**

In `home/apps.nix`'s `desktopEntries` builder, beside the existing `code.desktop` block, add:

```nix
    cp ${./../data/1password.desktop} "$out/1password.desktop"
```

with the other `cp` lines, and after the `code.desktop` substitution add:

```nix
    substituteInPlace "$out/1password.desktop" \
      --replace-fail 'Exec=@onePasswordShim@ %U' \
                     'Exec=${glStripShim "1password" glStripped."1password"}/bin/1password %U'
```

The builder's existing `@[a-zA-Z]*@` loop then covers this file too, so a forgotten token fails the build.

- [ ] **Step 3: Link it into place**

Beside the existing `xdg.dataFile` entries:

```nix
  config.xdg.dataFile."applications/1password.desktop".source =
    "${desktopEntries}/1password.desktop";
```

There is no clobber: `~/.local/share/applications/1password.desktop` is absent, measured 2026-09-10.

- [ ] **Step 4: Build and confirm the entry names the shim**

```bash
D=$(sg nix-users -c 'nix eval --raw .#homeConfigurations."isutton@suffer".config.xdg.dataFile."applications/1password.desktop".source')
/usr/bin/grep -E '^(Exec|MimeType)' "$D"
```

Expected: `Exec=/nix/store/…-calango-1password/bin/1password %U`, and the `MimeType` line intact.

- [ ] **Step 5: Confirm no token survived**

```bash
/usr/bin/grep -c '@[a-zA-Z]*@' "$D"    # 0
```

- [ ] **Step 6: Run the full check suite**

```bash
sg nix-users -c 'nix flake check' 2>&1 | tee /tmp/check.log | tail -3
/usr/bin/grep -c '^checking derivation checks\.' /tmp/check.log
```

Expected: exit 0. Report the count you read; do not assert nine.

- [ ] **Step 7: Commit**

```bash
git add data/1password.desktop home/apps.nix
git commit -m "apps: point 1Password's launcher entry at the stripping shim"
```

---

### Task 3: The two activation warnings

No Nix builder may read `/opt`, so these two properties can only be checked at switch time. Both are non-fatal, for the reason `home/apps.nix` already gives about `mimeappsIds`: a fatal version aborts every switch on a machine where the corp package is simply not installed.

**Files:**
- Modify: `home/apps.nix` — add `config.home.activation.glStrippedTargets`

**Interfaces:**
- Consumes: `glStripped` from Task 1.
- Produces: nothing. It writes to stderr only.

- [ ] **Step 1: Write the hook**

`entryAfter [ "linkGeneration" ]`, because it reads `~/.local/share/applications`, which `linkGeneration` creates. Nothing downstream reads what it produces, so there is no `before` edge — `entryBetween [] xs` is by definition `entryAfter xs`, and declaring an empty edge would state a constraint that does not exist.

```nix
  # Two properties no build-time guard can reach, because a Nix builder may not
  # read /opt.
  #
  # 1. The vendor binary moved. The shim would exec nothing, and the symptom is
  #    an application that does not start rather than one that fails visibly.
  # 2. The vendor .desktop drifted from our copy. Ours shadows it, so an upgrade
  #    that adds a MimeType or an Action would be dropped silently.
  #
  # Non-fatal, and the body runs under `sh -c`, which inherits neither errexit
  # nor pipefail from the activation script -- `$-` is `hBc` there, measured --
  # so each step carries its own guard rather than relying on inherited options.
  config.home.activation.glStrippedTargets =
    lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      run ${pkgs.bash}/bin/sh -c '
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: entry: ''
          if [ ! -x "${entry.binary}" ]; then
            echo "${name}: ${entry.binary} is missing or not executable." >&2
            echo "  The shim on PATH execs it and will fail." >&2
          fi
          vendor="/usr/share/applications/${entry.desktopId}"
          ours="$HOME/.local/share/applications/${entry.desktopId}"
          if [ -r "$vendor" ] && [ -r "$ours" ]; then
            a=$(grep -v "^Exec=" "$vendor" | sort) || a=""
            b=$(grep -v "^Exec=" "$ours"   | sort) || b=""
            if [ "$a" != "$b" ]; then
              echo "${entry.desktopId}: the vendor entry differs from ours on a field other than Exec." >&2
              echo "  Ours shadows it, so the difference is being dropped." >&2
              echo "  Compare: diff <(sort $vendor) <(sort $ours)" >&2
            fi
          fi
        '') glStripped)}
      ' || true
    '';
```

- [ ] **Step 2: Switch, and read the hook's output**

Run the `sd-switch` dry run first, per this project's rule. Confirm no `wayland-*` unit is in the stop set before switching from inside Hyprland.

```bash
sg nix-users -c 'home-manager switch --flake .#isutton@suffer' 2>&1 | tail -20
```

Expected: exit 0, and no warning — `/opt/1Password/1password` exists and the entries match apart from `Exec`.

- [ ] **Step 3: Prove the missing-binary branch can fire**

```bash
git add home/apps.nix data/1password.desktop
```

Change `binary = "/opt/1Password/1password";` to `binary = "/opt/1Password/does-not-exist";`, then switch again.

Expected: the switch still exits 0, and prints:

```
1password: /opt/1Password/does-not-exist is missing or not executable.
```

If the switch aborts instead, the hook is fatal and must be fixed.

- [ ] **Step 4: Prove the drift branch can fire**

Revert the mutation from Step 3 first. Then temporarily append a line to `data/1password.desktop` — `Categories=Office;Utility;` replacing the existing `Categories` line — rebuild and switch.

Expected: the switch exits 0 and prints `1password.desktop: the vendor entry differs from ours on a field other than Exec.`

- [ ] **Step 5: Revert both mutations and confirm**

```bash
git restore --worktree home/apps.nix data/1password.desktop
/usr/bin/grep -c 'binary    = "/opt/1Password/1password";' home/apps.nix   # 1
/usr/bin/grep -c '^Categories=Office;$' data/1password.desktop             # 1
```

- [ ] **Step 6: Switch once more to a clean state, then commit**

```bash
sg nix-users -c 'home-manager switch --flake .#isutton@suffer' 2>&1 | tail -5
git add home/apps.nix
git commit -m "apps: warn when a stripped application's binary or entry drifts"
```

---

### Task 4: Live verification, and the record

**Files:**
- Modify: `CLAUDE.md` — one entry under "Mechanisms that are not what they look like"

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Verify the typed path**

```bash
command -v 1password
```

Expected: a path under `~/.nix-profile/bin`, not `/usr/bin/1password`.

- [ ] **Step 2: Verify the launcher path, from no running instance**

This step is void if an instance is already running. 1Password is single-instance, and a second invocation merely asks the first to show a window — which tests the path that already works and proves nothing.

Kill by pid. Do **not** use `pkill -f '/opt/1Password/1password'`: that pattern matches the issuing shell's own command line and kills it, exit 144, and every later line of the script silently never runs.

```bash
for p in $(pgrep -x 1password); do kill "$p"; done
sleep 3
pgrep -cx 1password    # 0
```

Then press SUPER+D, choose 1Password, and confirm:

```bash
hyprctl clients -j | python3 -c "
import json,sys
c=next((c for c in json.load(sys.stdin) if c['class']=='1password'),None)
print('window on %s' % c['workspace']['name'] if c else 'NO WINDOW')"
```

Expected: `window on special:magic`. The scratchpad rule sends it there; `SUPER+S` reveals it.

- [ ] **Step 3: Verify the mechanism, not just the outcome**

```bash
P=$(pgrep -x 1password | head -1)
# the gpu-process must be on hardware
for d in /proc/[0-9]*; do
  grep -q -- '--type=gpu-process' "$d/cmdline" 2>/dev/null || continue
  grep -q 1[Pp]assword "$d/cmdline" 2>/dev/null || continue
  echo "libgallium=$(grep -c libgallium $d/maps) swiftshader=$(grep -c swiftshader $d/maps)"
done
```

Expected: `libgallium` non-zero, `swiftshader=0`. Note that `libgallium` alone does **not** prove EGL initialised — it was misread that way during the investigation. The window appearing is the proof; this is corroboration.

- [ ] **Step 4: Verify no regressions**

```bash
xdg-mime query default x-scheme-handler/onepassword    # 1password.desktop
```

And launch `signal-desktop` from SUPER+D. It is the control: a **Nix** application that needs the variables the shim removes, and `CLAUDE.md` measured it failing with the same EGL error when they are stripped. Its window must still open.

- [ ] **Step 5: Record the finding in CLAUDE.md**

Add to "Mechanisms that are not what they look like". The new fact is not that nixGL breaks Debian GL applications — that is already recorded for qemu and flatpak — but that **the Applications panel is a path into it**, and that the usual instrument reads healthy:

```markdown
**The Applications panel hands every launched application the session's five
nixGL variables, which is fatal to a Debian-linked GL application and reads as
healthy.** `AppLaunch.qml:134` launches with
`setsid systemd-run --user --scope`, and `--scope` execs into the application,
so it inherits quickshell's environment -- and quickshell is itself
nixGL-wrapped, at 5 of 5. Measured both ends rather than inferred:

    quickshell.service's own environment                 5 of 5
    a probe launched through systemd-run --user --scope   5 of 5

The XDG autostart path is the opposite and is already clean: the systemd user
manager carries none of them, so an autostart entry launches at 0 of 5.

1Password is the application this killed. Its GPU process dies with
`Initialization of all (2) EGL display types failed` and Electron then creates
no window at all, while the process stays alive serving its tray icon and its
SSH agent. **Every instrument that reads a running process says it is healthy**,
and its gpu-process maps `libgallium` six times -- which reads as hardware
acceleration and was recorded as such mid-investigation before being withdrawn.
A mapped library is not an initialised EGL display. The window appearing is the
only proof; `libgallium` is corroboration at best.

Because 1Password is single-instance, this only bites when the launcher's
invocation is the FIRST one -- normally the autostart instance is already up and
a second invocation merely asks it to show a window. So the bug hid until the
autostart instance died (`status=5/TRAP`, 2026-09-10), and then presented as
"SUPER+D stopped opening 1Password".

`home/apps.nix`'s `glStripped` table is the fix. Do not "simplify" it into a
predicate, and do not scrub the session inheritance instead: it is load-bearing
for every Nix GL application the panel starts.
```

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: the Applications panel is a path into the nixGL/Debian GL fault"
```

---

## Self-review notes

**Spec coverage.** Table (T1), derived strip list (T1), vacuity anchor (T1 steps 7-8), shim on PATH (T1), `.desktop` override with `MimeType` preserved (T2), two activation warnings (T3), each guard mutation-proven (T1 s7, T3 s3-s4), live verification from no running instance (T4 s2), regression checks including the signal-desktop control (T4 s4). Autostart is touched nowhere.

**Naming consistency.** `glStripped` (table), `glStripShim` (function), `glStripShims` (list), `glStrippedTargets` (hook) are used with those exact spellings in every task.

**One thing deliberately not in the plan.** The `SIGTRAP` crash of the autostart instance is not investigated. This work makes the recovery path function; it does not stop the crash.
