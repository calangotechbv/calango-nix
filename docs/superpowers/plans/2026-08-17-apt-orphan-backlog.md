# Apt Orphan Backlog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring `apt-get -s autoremove` to zero removals on `suffer`, with every currently-orphaned package either deliberately removed or deliberately marked manual with a recorded reason.

**Architecture:** An audit, a decision gate, a user-run mutation, and a guard. The audit is read-only and produces a verdict-per-package table. The mutation is two `sudo` commands the user runs, never an agent. The guard is a non-fatal Home Manager activation hook, because a flake check cannot see `/var/lib/dpkg` from the Nix sandbox — the same two-layer conclusion spec 10 reached for `.desktop` identity.

**Tech Stack:** Nix flakes, standalone Home Manager (`release-26.05`), `dpkg-query`, `apt-get -s`, `apt-mark`, `/proc`.

**Spec:** `docs/superpowers/specs/2026-08-17-apt-orphan-backlog-design.md`

## Global Constraints

- Every `nix` and `home-manager` invocation is wrapped: `sg nix-users -c '...'`.
- **No agent runs a mutating `apt`, `apt-get`, `dpkg` or `apt-mark` command.** Simulations (`apt-get -s`, `apt-mark showmanual`, `dpkg-query`, `dpkg -L`, `dpkg -S`) are read-only and permitted. The two mutating commands in this plan are a user gate.
- No agent runs `home-manager switch`, `systemctl` with `start`/`stop`/`restart`/`enable`/`disable`/`daemon-reload`, `reboot`, or `fusermount`. The activation script only as `DRY_RUN=1`.
- Package presence is read with `dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\n'`, never a bare version query — that exits `0` for `rc` packages and there are 128 of those here.
- Never read a package version from `nixpkgs#<pkg>`; only `.#homeConfigurations."isutton@suffer".pkgs.<pkg>.version`.
- No path under the plan's git-ignored scratch directory appears in any committed file. Spec 11 had to correct spec 7's record for citing one: the reader who follows it finds nothing, because the directory is ignored and does not travel with the repository. Refer to a working artefact by describing it, never by its scratch path. (`.gitignore` names that directory, and is the only committed file that should.)
- **A hit from the in-use check is not a keep.** Every hit is classified by *why* the file is held. See the spec.
- **Conservatism:** anything whose role cannot be explained is marked manual, not removed. Anything removed carries a recorded reason.
- Enumerate by syntax at every step. Never consult a package list a previous step saved — a saved list is what created this backlog.
- **`grep -c` exits 1 at zero matches, and both Nix builders and the Home Manager activation script run with `set -e` and `pipefail` on** (measured: `activate` lines 2-3 are `set -eu` and `set -o pipefail`). Guard every count, or the abort happens before any message prints.

---

## File Structure

- **Create:** `home/apt-hygiene.nix` — one activation hook, warning when packages are autoremovable. One responsibility, so it is its own module rather than a lodger in `home/apps.nix`, which owns desktop entries.
- **Modify:** `flake.nix` — add `./home/apt-hygiene.nix` to the module list at lines 134-146.
- **Create:** `docs/2026-08-17-results-suffer-apt-orphan-backlog.md` — the audit table, the decisions, the endpoint.
- **Modify:** `CLAUDE.md` — the standing facts this produces.
- **Modify:** `docs/superpowers/specs/2026-08-17-apt-orphan-backlog-design.md` — append-only `## Corrections`.

---

## Task 1: The audit

Read-only. Produces a verdict for every orphaned package and a decision list for the user. Nothing is marked or removed in this task.

**Files:**
- Create: `docs/2026-08-17-results-suffer-apt-orphan-backlog.md`

**Interfaces:**
- Consumes: nothing.
- Produces: the decision list Task 3's gate acts on, and the keeper list Task 3 marks. Both live in the results document, not in a scratch file.

- [ ] **Step 1: Census, by syntax**

```bash
cd /home/isutton/Projects/calango-nix
apt-get -s autoremove 2>/dev/null | awk '/^Remv /{print $2}' | sort -u > /tmp/orphans.$$
wc -l < /tmp/orphans.$$
```

Expected: a count. It was **137** on 2026-08-17. If it differs, use the measured number and say so in the document — do not quote 137.

- [ ] **Step 2: The union in-use check**

`/proc/<pid>/maps` is unreadable for other users' processes and root outnumbers the user roughly 3:1 here, so the `ps` half is not optional.

```bash
{ for p in /proc/[0-9]*; do
    readlink "$p/exe" 2>/dev/null
    awk '{print $NF}' "$p/maps" 2>/dev/null | grep '^/'
  done
  ps -eo args= 2>/dev/null | awk '{print $1}' | grep '^/'
} | sort -u | grep -E '^/(usr|etc|lib|bin|sbin|opt)' > /tmp/inuse-files.$$
wc -l < /tmp/inuse-files.$$

xargs -a /tmp/inuse-files.$$ -d '\n' dpkg -S 2>/dev/null \
  | sed 's/:.*//' | tr ',' '\n' | sed 's/ //g' | sort -u > /tmp/inuse-pkgs.$$
comm -12 /tmp/orphans.$$ /tmp/inuse-pkgs.$$
```

Expected on 2026-08-17, six packages: `gir1.2-notify-0.7`, `gvfs-fuse`, `libmng1`, `python3-cups`, `qt6-image-formats-plugins`, `xscreensaver`.

- [ ] **Step 3: For each hit, name the holding process**

```bash
for pkg in $(comm -12 /tmp/orphans.$$ /tmp/inuse-pkgs.$$); do
  echo "=== $pkg"
  for f in $(dpkg -L "$pkg" 2>/dev/null | grep -Ff /tmp/inuse-files.$$ - 2>/dev/null); do
    for p in /proc/[0-9]*; do
      if grep -qF "$f" "$p/maps" 2>/dev/null || [ "$(readlink $p/exe 2>/dev/null)" = "$f" ]; then
        printf '  %s <- pid %s: %s\n' "$f" "${p#/proc/}" \
          "$(tr '\0' ' ' < $p/cmdline 2>/dev/null | cut -c1-70)"
      fi
    done
  done | sort -u
done
```

- [ ] **Step 4: Classify every hit by why**

For each, assign exactly one:

- **dead / stale process** — the holder is a process of a package that is already removed. Check with `dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' <holder-package>`; a `rc` or absent status means the holder is a ghost. Measured example: `libmng1` and `qt6-image-formats-plugins` are held by pid 3790 `/usr/bin/deskflow`, and `deskflow` was removed in spec 10.
- **dead / fontconfig mmap** — the held file is under a `fonts/` path. A running process keeps deleted fonts mmapped. Measured example: `xscreensaver` is held by `foot` through `/usr/share/fonts/xscreensaver/gallant12x22.ttf`.
- **decision needed** — a live consumer that is a real feature. Measured examples: the printer applet (pid 3823 `system-config-printer/applet.py`) and `gvfs-fuse` (pid 4116 `gvfsd-fuse`).
- **keep, unexplained** — the conservative default. Anything not fitting the three above.

- [ ] **Step 5: Read the 30 non-obvious packages by hand**

The automated check sees only this moment. A package used by an application that is not running now will not appear, so the group that is neither a library nor data of something already gone is read individually:

```bash
for p in $(grep -vE 'l10n$|^lib|(-data|-common)$|^lxqt|^gir1\.2-|^python3-' /tmp/orphans.$$); do
  printf '%-30s %s\n' "$p" "$(dpkg-query -W -f='${binary:Summary}' "$p" 2>/dev/null)"
done
```

For each, decide whether anything on this machine still wants it. Record the reason, not just the verdict.

- [ ] **Step 6: Write the audit table and commit**

Append to `docs/2026-08-17-results-suffer-apt-orphan-backlog.md`: the census count and how it was derived, every hit with its holder and classification, the hand-read verdicts for the 30, and two explicit lists — **keepers** and **removals**. Then the decision list for the user, as its own section.

```bash
git add docs/2026-08-17-results-suffer-apt-orphan-backlog.md
git commit -m "apt: audit the 137 orphans, with a reason for each verdict"
```

---

## Task 2: The autoremovable warning

Built before the removal, deliberately, so it can observe the count both before and after.

**Files:**
- Create: `home/apt-hygiene.nix`
- Modify: `flake.nix` (module list, lines 134-146)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: nothing later tasks depend on. Task 3's endpoint check reads its output as a convenience, not as its only evidence.

- [ ] **Step 1: Write the module**

```nix
{ lib, pkgs, ... }:

{
  # Warn when apt considers packages unnecessary.
  #
  # This exists because 137 of them accumulated silently. Four specs removed
  # packages, each printed a "no longer required" list, and none of them was
  # acted on -- so a single `apt autoremove` became able to sweep 137 packages
  # at once, at which point the breakage would look like whatever changed most
  # recently. CLAUDE.md recorded that hazard twice, with rtkit and
  # pulseaudio-utils, before this happened anyway.
  #
  # Non-fatal, and the reason is the same one home/apps.nix's mimeappsIds gives:
  # this is apt's state, not this flake's. A switch must never abort because the
  # Debian side has cruft on it.
  #
  # Activation and not a flake check, because a flake check cannot see
  # /var/lib/dpkg -- the Nix sandbox has no view of apt at all. Same two-layer
  # conclusion spec 10 reached for .desktop identity: the fatal half asserts
  # what the flake ships, and only the activation half can observe the machine.
  #
  # `|| true` on the count, and this is load-bearing rather than defensive:
  # `grep -c` prints 0 and exits 1 when it matches nothing, and the activation
  # script runs with `set -eu` and `set -o pipefail` both on (activate lines
  # 2-3). Without it, a machine with a clean orphan list would abort its own
  # switch, and the failure would arrive with no message at all. This is the
  # same trap spec 11 hit inside a Nix builder; it applies here for the same
  # reason.
  #
  # Costs about one second per switch, measured: `apt-get -s autoremove` took
  # 989 ms. It needs no privileges -- verified as uid 1000, exit 0.
  config.home.activation.aptOrphanWarning =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${pkgs.bash}/bin/sh -c '
        [ -x /usr/bin/apt-get ] || exit 0
        n=$(/usr/bin/apt-get -s autoremove 2>/dev/null | grep -c "^Remv " || true)
        [ -n "$n" ] || n=0
        [ "$n" -eq 0 ] && exit 0
        echo "apt: $n package(s) are autoremovable." >&2
        echo "  Read \`apt-get -s autoremove\` before anything runs it for you." >&2
        echo "  An unmarked orphan gets swept at some later moment, and the" >&2
        echo "  breakage then looks like whatever changed most recently." >&2
        echo "  See docs/2026-08-17-results-suffer-apt-orphan-backlog.md." >&2
      ' || true
    '';
}
```

- [ ] **Step 2: Register the module, and stage it**

Add to `flake.nix`, after `./home/gui-apps.nix` on line 145:

```nix
          ./home/apt-hygiene.nix
```

Then **stage the new file before building**:

```bash
git add -N home/apt-hygiene.nix
```

This is not optional and it is not tidiness. A flake sees only what git tracks,
so an untracked module is invisible to the evaluation no matter that it sits in
the working tree. Skipping it produces a failure that reads as though the file
were missing rather than unstaged, which is exactly what happened while this plan
was being verified:

```
error: path '/nix/store/…-source/home/apt-hygiene.nix' does not exist
```

`git add -N` records the intent to add without staging content, which is enough.

- [ ] **Step 3: Build, and confirm the hook is present**

```bash
NEW=$(sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage' | tail -1)
grep -c 'aptOrphanWarning' "$NEW/activate"
```

Expected: `1` or more. If `0`, the module is not in the list.

- [ ] **Step 4: Prove the hook's body fires, without a switch**

`run` prints rather than executes under `DRY_RUN=1`, so the body is extracted and run directly. Extract it rather than retyping it, or the test proves nothing about the shipped code:

```bash
sed -n "/aptOrphanWarning/,/^fi$/p" "$NEW/activate" | grep -A12 "bash.*sh -c" > /tmp/hookbody.$$
sh -c "$(sed -n "s/^run [^ ]*\/sh -c '//;/^' || true/q;p" /tmp/hookbody.$$)" 2>&1 | head -5
```

Expected: the `apt: 137 package(s) are autoremovable.` message on stderr.

- [ ] **Step 5: Prove it stays silent at zero**

The count cannot be zero on this machine yet, so substitute a command that reports nothing and confirm the hook exits silently rather than aborting:

```bash
sh -c '
  n=$(true | grep -c "^Remv " || true)
  [ -n "$n" ] || n=0
  [ "$n" -eq 0 ] && { echo "SILENT, exit 0"; exit 0; }
  echo "would have warned"
'; echo "exit=$?"
```

Expected: `SILENT, exit 0` then `exit=0`. This is the branch that would abort the switch without `|| true`; verify it by removing that `|| true` from the snippet and re-running under `set -eo pipefail`:

```bash
sh -ec 'set -o pipefail; n=$(true | grep -c "^Remv "); echo "reached: $n"'; echo "exit=$?"
```

Expected: no `reached:` line, and a non-zero exit — which is the abort this guard is written to avoid.

- [ ] **Step 6: Commit**

```bash
git add home/apt-hygiene.nix flake.nix
git commit -m "apt: warn at activation when packages are autoremovable

A flake check cannot see /var/lib/dpkg, so activation is the only layer
that can observe apt's state -- the same two-layer split spec 10 reached
for .desktop identity. Non-fatal for the reason mimeappsIds is: this is
apt's state, not the flake's.

The \`|| true\` on the count is load-bearing. grep -c prints 0 and exits
1 at zero matches, and the activation script runs set -eu with pipefail,
so a machine with a clean orphan list would otherwise abort its own
switch with no message. Same trap spec 11 hit in a Nix builder."
```

---

## Task 3: Mark, remove, verify

The two mutating commands are a **user gate**. An agent reaching this task hands the block over and stops.

**Files:**
- Modify: `docs/2026-08-17-results-suffer-apt-orphan-backlog.md`

**Interfaces:**
- Consumes: Task 1's keeper list and the user's answers to its decision list.
- Produces: the endpoint the close-out records.

- [ ] **Step 1: Record the plan before it runs**

```bash
apt-get -s autoremove 2>/dev/null | tee /tmp/plan-before.$$ | grep -c '^Remv '
```

Append that full simulated plan to the results document. It is the only way to compare intent against outcome afterwards.

- [ ] **Step 2: Hand the gate to the user**

The keeper list comes from Task 1 and the user's decisions. The command shape:

```bash
sudo apt-mark manual <keeper> <keeper> ...
```

Then re-derive the census, because marking changes what is orphaned:

```bash
apt-get -s autoremove 2>/dev/null | awk '/^Remv /{print $2}' | sort -u
```

Read that list in full. Then, and only then:

```bash
sudo apt autoremove
```

- [ ] **Step 3: Restart before removing fonts**

If any font package is in the removal list — `xscreensaver` was, through
`/usr/share/fonts/xscreensaver/`— close and reopen terminals and GUI applications
first. A running process keeps a deleted font mmapped and looks fine until it is
next launched.

- [ ] **Step 4: Endpoint**

```bash
apt-get -s autoremove 2>/dev/null | grep -c '^Remv ' || echo 0
```

Expected: `0`.

- [ ] **Step 5: Verify the desktop after a reboot, not before**

Absence is only measurable once the session ends. After the reboot, confirm the
bar, the panel, notifications, screen sharing, audio and Bluetooth still work,
and that no unit is failed:

```bash
systemctl --user --state=failed --no-pager
```

- [ ] **Step 6: Record the outcome and commit**

Compare the recorded plan against what actually went. Note any package the user
chose to keep and why.

```bash
git add docs/2026-08-17-results-suffer-apt-orphan-backlog.md
git commit -m "apt: record the marking, the removal, and the endpoint"
```

---

## Task 4: Close out

**Files:**
- Modify: `CLAUDE.md`
- Modify: `docs/2026-08-17-results-suffer-apt-orphan-backlog.md`
- Modify: `docs/superpowers/specs/2026-08-17-apt-orphan-backlog-design.md` — append-only

- [ ] **Step 1: `CLAUDE.md` — extend the existing orphan entry**

The entry beginning **"An apt removal orphans packages the Nix side still needs"**
already exists. Extend it rather than adding a second one, and record that the
rule was documented and then not applied for four specs, reaching 137. Add the
three false-positive shapes as a named list, because a bare in-use hit is what
would have kept six packages for four wrong reasons:

- a stale process of an already-removed package
- a font held by fontconfig mmap
- a live consumer that is itself orphaned

- [ ] **Step 2: `CLAUDE.md` — extend the `pipefail` entry**

The entry added by spec 11 says the "count explicitly" rule inverts inside a Nix
builder. It also inverts in the **Home Manager activation script**, measured:
`activate` lines 2-3 are `set -eu` and `set -o pipefail`. Name both contexts.

- [ ] **Step 3: `CLAUDE.md` — add the standing facts**

Whatever Task 3 settled: which packages are now permanently manual and why. Write
each as a fact with its reason, so a later spec does not re-litigate it. If the
printer applet was kept, say that `system-config-printer` and its dependencies are
deliberate. If `gvfs-fuse` was dropped, say what used to want it.

- [ ] **Step 4: Recount the spec number**

```bash
ls -1 docs/*results-suffer-*.md | wc -l
```

Set the header's count to that number. **Count it; do not increment it** — spec 10
and spec 11 both got this wrong in opposite directions.

- [ ] **Step 5: Append `## Corrections` to the spec**

Append-only. Do not rewrite the spec's prose; it records what was argued at the
time. Note anything execution overturned, including any package the audit found
that this plan's expectations did not.

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md docs/2026-08-17-results-suffer-apt-orphan-backlog.md \
        docs/superpowers/specs/2026-08-17-apt-orphan-backlog-design.md
git commit -m "apt: close out spec 12"
```

---

## Self-review

**Spec coverage.** The spec's seven phases map onto the tasks: Phase 1-3 and 5 are Task 1's steps 1-5, Phase 4 is Task 1 step 6 plus Task 3 step 2, Phase 5-6 are Task 3, Phase 7 is Task 2. The spec's conservatism rule appears in Global Constraints and in Task 1 step 4's "keep, unexplained" default.

**Placeholder scan.** Every step carries the command or the Nix it needs. Task 1 step 6 and Task 4 step 3 describe content rather than showing it, because their content is the audit's output and cannot be written before the audit runs — the alternative would be inventing verdicts.

**Type consistency.** `home/apt-hygiene.nix` takes `{ lib, pkgs, ... }` and uses both; it does not read `config`, so it does not take it. The hook name `aptOrphanWarning` is used identically in the module, in Task 2 step 3's grep, and in step 4's `sed`.

**Ordering.** Task 2 precedes Task 3 on purpose, so the guard exists before the count changes and can be seen to go from 137 to 0. Task 1 precedes both because its output is what Task 3 acts on.

**One known asymmetry.** Task 2 step 5 proves the zero-count branch with a substituted command rather than a real empty orphan list, because the machine cannot produce one until Task 3 has run. After Task 3, the guard's silence is observable for real — Task 3 step 4 is that observation.

**Task 2's Nix was built before this plan was committed**, rather than written and hoped for. Spec 10 shipped two defects in plan code that had never been evaluated — a `touch "$out"` where `buildEnv` needed a directory, and an infinite recursion — so the module above was created, registered, built, and its emitted hook body run directly, then reverted so Task 2 does the work as written. What that verification produced:

- the generation built and `activate` contained `aptOrphanWarning` once;
- the emitted body printed `apt: 137 package(s) are autoremovable.` and exited `0`;
- the zero-count branch exited `0` silently;
- the same branch **without** `|| true`, under `set -e` and `pipefail`, exited `1` — which is the abort the guard is written to avoid, and the reason that clause is load-bearing rather than defensive;
- and the build failed first, because the new module was untracked. That is now Task 2 step 2.
