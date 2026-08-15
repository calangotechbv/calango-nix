# Session Scaffolding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move uwsm's fourteen systemd user unit templates from apt's package to Nix's, prove they run the session across a reboot, then remove the apt package.

**Architecture:** A new `home/uwsm.nix` installs Nix's unit templates into `~/.config/systemd/user` (position 5 on the user manager's `UnitPath`) where they win over apt's `/usr/lib/systemd/user` (position 15). A `runCommand` derivation copies uwsm's own unit directory and refuses to build if the set of units ever changes, so upstream drift is a build error rather than a silently missing unit. The switch is sequenced — dry run, then a TTY switch with no graphical session running — because the units being installed are the ones running the session.

**Tech Stack:** Nix flakes, standalone Home Manager (`release-26.05`), nixpkgs `nixos-26.05`, systemd user manager, uwsm 0.26.4, Debian 13 (trixie).

**Spec:** `docs/superpowers/specs/2026-08-15-uwsm-session-scaffolding-design.md`

## Global Constraints

- **Every `nix` invocation must be wrapped in `sg nix-users -c '...'`.** This shell's process predates the user's addition to the `nix-users` group; a bare `nix` fails with `getting status of '/nix/var/nix/daemon-socket/socket': Permission denied`.
- **Agents must never run:** `home-manager switch`, any `apt`/`apt-get`/`dpkg` command, `systemctl` with `start`/`stop`/`restart`/`enable`/`disable`, `reboot`, `loginctl terminate-session`, or the activation script without `DRY_RUN=1`. Every one of those belongs to the user in this plan.
- **All fourteen units are installed, not only the five that differ.** Overriding only the divergent units leaves nine resolving to apt's copies, which vanish with the package.
- **The unit-set assertion uses `LC_ALL=C` collation on both `ls` and `sort`.** Under the machine's locale `ls` returns `wayland-session@.target` before `wayland-session-waitenv.service`; under C it does not, because `-` (0x2D) sorts before `@` (0x40).
- **Nix's uwsm is 0.26.4**, the same upstream version as Debian's `0.26.4+ds-2~bpo13+1`. That coincidence is why the current hybrid works and is not to be relied on after this plan.
- **`graphical-session.target` and `graphical-session-pre.target` belong to `systemd`, not `uwsm`.** They are expected to keep resolving under `/usr/lib/systemd/user` at every checkpoint. A check that demands they move is a wrong check.
- **Phase order is the safety property, not a preference.** Task 3 must not run before Task 2 has been read; Task 5 must not run before Task 4 has passed.

---

### Task 1: `home/uwsm.nix` — the units and the assertion

**Files:**
- Create: `home/uwsm.nix`
- Modify: `flake.nix:133-142` (the `mkHome` module list)
- Modify: `home/session.nix:73-74` (stale comment premise)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `~/.config/systemd/user/<14 units>` and `~/.config/systemd/user/graphical-session.target.wants/fumon.service` in the built generation's `home-files` tree. Task 2 reads that tree; Tasks 3–6 depend on it being activated.

This task is pure flake work. It changes no running state — building a generation does not activate it.

- [ ] **Step 1: Confirm the source directory and the exact unit set**

```bash
cd /home/isutton/Projects/calango-nix
# uwsm is already in home.packages (home/default.nix:38), so the profile link
# resolves to the exact store path this flake builds against. Do not use
# `nixpkgs#uwsm` -- that reads the registry, which need not match the flake's
# pinned nixpkgs, and the whole point is to enumerate the units this
# configuration will actually install.
UWSM=$(readlink -f ~/.nix-profile/bin/uwsm | sed 's|/bin/uwsm$||')
echo "uwsm: $UWSM"
(cd "$UWSM/share/systemd/user" && LC_ALL=C ls -1 | LC_ALL=C sort)
```

Expected: exactly these fourteen lines, in this order.

```
app-graphical.slice
background-graphical.slice
fumon.service
session-graphical.slice
wayland-session-bindpid@.service
wayland-session-envelope@.target
wayland-session-pre@.target
wayland-session-shutdown.target
wayland-session-waitenv.service
wayland-session-xdg-autostart@.target
wayland-session@.target
wayland-wm-app-daemon.service
wayland-wm-env@.service
wayland-wm@.service
```

If the set differs, stop and report — the plan's hardcoded list is the spec's and a mismatch means uwsm moved.

- [ ] **Step 2: Create `home/uwsm.nix`**

```nix
{ lib, pkgs, ... }:

let
  # Every unit template uwsm 0.26.4 ships, in LC_ALL=C order. Written out by
  # name rather than read from the store directory with builtins.readDir: that
  # would be import-from-derivation, and it would trade a loud build failure
  # for a silent change in what gets installed. The uwsmUnits derivation below
  # cross-checks this list against the real directory, so a list that goes
  # stale is a build error rather than a unit that quietly stops existing.
  #
  # This project's signature defect is incomplete enumeration -- cataloguing by
  # one syntactic form and missing the rest. A hardcoded list with no
  # cross-check is that defect in a new place, which is why the check exists.
  #
  # C collation is not incidental. Under the machine's locale `ls` returns
  # wayland-session@.target before wayland-session-waitenv.service; under C it
  # does not, because '-' (0x2D) sorts before '@' (0x40). A list transcribed
  # from unsorted `ls` output would fail the check on a correct tree.
  unitNames = [
    "app-graphical.slice"
    "background-graphical.slice"
    "fumon.service"
    "session-graphical.slice"
    "wayland-session-bindpid@.service"
    "wayland-session-envelope@.target"
    "wayland-session-pre@.target"
    "wayland-session-shutdown.target"
    "wayland-session-waitenv.service"
    "wayland-session-xdg-autostart@.target"
    "wayland-session@.target"
    "wayland-wm-app-daemon.service"
    "wayland-wm-env@.service"
    "wayland-wm@.service"
  ];

  # A copy of uwsm's unit directory that refuses to build if the set of units
  # has changed. The files are copied rather than symlinked so the check sits
  # in the path of the files themselves -- nothing can consume the units
  # without having passed it. Copying preserves the absolute /nix/store paths
  # written inside each unit, which is the entire point of using Nix's copies
  # instead of Debian's: the only difference between the two sets is that
  # Debian's say /usr/bin/uwsm where these say the store path.
  uwsmUnits = pkgs.runCommand "uwsm-session-units" { } ''
    expected="${lib.concatStringsSep " " unitNames}"
    actual="$(cd ${pkgs.uwsm}/share/systemd/user && LC_ALL=C ls -1 | LC_ALL=C sort | tr '\n' ' ')"
    actual="''${actual% }"
    if [ "$expected" != "$actual" ]; then
      echo "uwsm's unit set has changed." >&2
      echo "  expected: $expected" >&2
      echo "  actual:   $actual" >&2
      echo "Update unitNames in home/uwsm.nix, then check that every added or" >&2
      echo "removed unit is accounted for in the session before shipping it." >&2
      exit 1
    fi
    mkdir -p "$out"
    cp ${pkgs.uwsm}/share/systemd/user/* "$out/"
  '';

  unitLinks = lib.listToAttrs (map
    (n: lib.nameValuePair ".config/systemd/user/${n}" {
      source = "${uwsmUnits}/${n}";
    })
    unitNames);
in
{
  # The fourteen templates at ~/.config/systemd/user -- position 5 on the user
  # manager's UnitPath, against /usr/lib/systemd/user at position 15. That
  # ordering is what makes these win; nothing has to be removed for them to
  # take effect, which is what makes the switch reversible.
  #
  # home.file rather than systemd.user.*, to avoid re-describing fourteen
  # upstream units in Nix and drifting from them.
  #
  # This does NOT keep them away from sd-switch. sd-switch is invoked on
  # $generation/home-files/.config/systemd/user, which is precisely where
  # home.file entries land, so it sees all fourteen as newly added and acts on
  # them. That matters because wayland-session-shutdown.target carries
  # Conflicts=graphical-session.target: if sd-switch starts it, systemd tears
  # the session down to satisfy the conflict. The protection is sequencing --
  # a dry run that is read, then a first switch from a TTY with no session to
  # lose. See the plan's Task 2 and Task 3.
  home.file = unitLinks // {
    # fumon.service's enablement, owned here rather than inherited.
    #
    # It is currently enabled by a root-owned symlink at
    # /etc/systemd/user/graphical-session.target.wants/fumon.service, written
    # by apt's 80-fumon.preset and pointing into /usr/lib/systemd/user.
    # Removing the package either deletes that link or leaves it dangling, and
    # neither outcome should decide whether fumon runs.
    #
    # fumon.service's ExecStart is the bare name `fumon`, resolved against the
    # user manager's PATH. uwsm's store bin is already on it (home/session.nix
    # puts uwsm in compositorPath), so the bare name reaches Nix's copy both
    # before and after the apt package goes.
    ".config/systemd/user/graphical-session.target.wants/fumon.service".source =
      "${uwsmUnits}/fumon.service";
  };
}
```

- [ ] **Step 3: Add the module to the flake**

In `flake.nix`, in the `mkHome` module list, add `./home/uwsm.nix` after `./home/services.nix`:

```nix
          ./home/apps.nix
          ./home/services.nix
          ./home/uwsm.nix
```

- [ ] **Step 4: Build, and verify the units landed**

```bash
cd /home/isutton/Projects/calango-nix
GEN=$(sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage')
echo "generation: $GEN"
LC_ALL=C ls -1 "$GEN/home-files/.config/systemd/user/" | LC_ALL=C sort
```

Expected: the fourteen unit names above, plus the eight Home Manager already
installs (`bt-agent.service`, `hypridle.service`, `hyprpolkitagent.service`,
`night-light.service`, `nm-secret-agent.service`, `quickshell.service`,
`tray.target`, `xdg-desktop-portal-hyprland.service`) and the
`graphical-session.target.wants` directory — twenty-three entries in all.

- [ ] **Step 5: Verify the units carry Nix's paths, not Debian's**

```bash
grep -h "ExecStart" "$GEN/home-files/.config/systemd/user/wayland-wm@.service" \
                    "$GEN/home-files/.config/systemd/user/wayland-wm-env@.service" \
                    "$GEN/home-files/.config/systemd/user/wayland-session-waitenv.service"
```

Expected: every line names a `/nix/store/...-uwsm-0.26.4/bin/uwsm` path.
Required: **no line contains `/usr/bin/uwsm`.** If any does, the wrong
directory was copied.

- [ ] **Step 6: Verify the `fumon` enablement link merged with Home Manager's own**

```bash
LC_ALL=C ls -1 "$GEN/home-files/.config/systemd/user/graphical-session.target.wants/"
```

Expected: `fumon.service` alongside Home Manager's six
(`bt-agent.service`, `hypridle.service`, `hyprpolkitagent.service`,
`night-light.service`, `nm-secret-agent.service`, `quickshell.service`).

This is the spec's open item about two mechanisms writing one directory. If
the build failed with a collision error instead, stop and report — the
fallback is enabling `fumon.service` from an activation hook, and that is a
design change the controller must rule on.

- [ ] **Step 7: Prove the assertion actually fires**

Temporarily delete one entry from `unitNames` in `home/uwsm.nix` — remove the
line `"fumon.service"` — then build:

```bash
sg nix-users -c 'nix build --no-link .#homeConfigurations."isutton@suffer".activationPackage' 2>&1 | tail -20
```

Expected: the build **fails**, and the output contains
`uwsm's unit set has changed.` together with the `expected:` and `actual:`
lines. A build that succeeds means the check is inert and the task is not
done.

- [ ] **Step 8: Restore the entry and rebuild**

Put `"fumon.service"` back in its original position (third, between
`background-graphical.slice` and `session-graphical.slice`), then:

```bash
sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage'
```

Expected: build succeeds.

- [ ] **Step 9: Commit the units**

```bash
cd /home/isutton/Projects/calango-nix
git add home/uwsm.nix flake.nix
git commit -m "uwsm: install Nix's session units where systemd will find them

The fourteen unit templates go to ~/.config/systemd/user, position 5 on
the user manager's UnitPath, against apt's /usr/lib/systemd/user at
position 15. Nothing has to be removed for them to win.

Every difference between the two sets is one substitution: Debian's units
say /usr/bin/uwsm where Nix's say the store path. Nine of fourteen are
byte identical. The session already runs Nix's uwsm binary, so this
closes a split that ran down the middle of one tool.

The unit list is written out by name and cross-checked at build time
against uwsm's own directory, under LC_ALL=C collation. A hardcoded list
with no check is this project's enumeration defect in a new place; with
the check, upstream drift is a build failure instead of a unit that
quietly stops existing.

fumon.service's enablement moves here too. It currently rides on a
root-owned symlink written by apt's preset, which the coming removal
either deletes or orphans."
```

- [ ] **Step 10: Correct the stale comment in `home/session.nix`**

At `home/session.nix:73-74`, replace:

```
  # Prepended, not appended: apt's Hyprland, hyprctl and hyprlock are all
  # still installed under /usr/bin, and an appended path would let them win.
```

with:

```
  # Prepended, not appended. The original reason was that apt's Hyprland,
  # hyprctl and hyprlock sat in /usr/bin and an appended path would let them
  # win. That premise expired with spec 5: none of those three exists any
  # more, and /usr/share/wayland-sessions is not even a directory. Prepending
  # stays because the guarantee is what matters -- this list is derived from
  # the config and is meant to be the answer, not a suggestion ranked below
  # whatever a future apt package happens to install.
```

- [ ] **Step 11: Verify the comment change did not alter the build**

```bash
sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage'
```

Expected: the same store path as Step 8 printed. A comment change inside a
Nix file does change the file's hash but must not change the built
`activationPackage` output path, because comments do not reach the output.
If the path differs, something other than a comment was edited.

- [ ] **Step 12: Commit the comment correction**

```bash
git add home/session.nix
git commit -m "session: correct a comment whose premise expired in spec 5

The compositorPath comment justified prepending by pointing at apt's
Hyprland, hyprctl and hyprlock in /usr/bin. All three are gone, and
/usr/share/wayland-sessions is not a directory any more.

The conclusion still holds for a better reason, so the code is unchanged
and only the reasoning is corrected."
```

---

### Task 2: Read `sd-switch`'s plan without changing anything

**Files:**
- Create: `docs/2026-08-15-results-suffer-uwsm-scaffolding.md` (started here, finished in Task 7)

**Interfaces:**
- Consumes: the generation built in Task 1.
- Produces: a recorded answer to "would `sd-switch` start `wayland-session-shutdown.target`?", which Task 3 reads before the user switches.

This task is read-only by construction. It invokes `sd-switch` directly with
`--dry-run` rather than running the activation script, so there is no path by
which a typo performs a switch.

> **Why this matters.** `wayland-session-shutdown.target` declares
> `Conflicts=graphical-session-pre.target graphical-session.target
> xdg-desktop-autostart.target` and `StopWhenUnneeded=yes`. If `sd-switch`
> starts it when it appears, systemd stops `graphical-session.target` to
> satisfy the conflict, taking quickshell, the portal, `hypridle` and
> `hyprpolkitagent` with it. All fourteen units are in `sd-switch`'s set —
> it runs against `home-files/.config/systemd/user`, which is exactly where
> `home.file` lands.

- [ ] **Step 1: Locate the old generation and the sd-switch binary**

```bash
cd /home/isutton/Projects/calango-nix
OLD=$(readlink -f ~/.local/state/nix/profiles/home-manager)
NEW=$(sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage')
SDSW=$(grep -o '/nix/store/[^ ]*sd-switch[^ /]*/bin/sd-switch' "$NEW/activate" | head -1)
echo "old:  $OLD"
echo "new:  $NEW"
echo "sd-switch: $SDSW"
```

Expected: three non-empty paths. If `OLD` is empty, the profile symlink has a
different name — list `~/.local/state/nix/profiles/` and use the
`home-manager` link there.

- [ ] **Step 2: Run the dry run**

```bash
"$SDSW" --dry-run --verbose \
  --old-units "$OLD/home-files/.config/systemd/user" \
  --new-units "$NEW/home-files/.config/systemd/user" 2>&1 | tee /home/isutton/.claude/jobs/314fc88d/tmp/sd-switch-plan.txt
```

`--dry-run` is documented as "Print, but do not perform, the switch actions."
Nothing is started, stopped or reloaded.

- [ ] **Step 3: Answer the one question that decides Task 3's risk**

```bash
grep -iE "shutdown|start|stop|restart|reload" /home/isutton/.claude/jobs/314fc88d/tmp/sd-switch-plan.txt
```

Record, in the results document, the verbatim plan and specifically:

- whether `wayland-session-shutdown.target` appears in any *start* action
- whether any currently-running session unit appears in a *stop* or *restart*
  action — `wayland-wm@hyprland\x2dnixgl.desktop.service`,
  `wayland-wm-env@…`, `wayland-session-envelope@…`, `wayland-session@…`
- what it intends for `fumon.service`

- [ ] **Step 4: Start the results document**

Create `docs/2026-08-15-results-suffer-uwsm-scaffolding.md` with a heading, the
date, and a section titled `## What sd-switch said it would do` containing the
verbatim dry-run output and the three answers above. The rest of the document
is written in Task 7.

- [ ] **Step 5: Commit**

```bash
git add docs/2026-08-15-results-suffer-uwsm-scaffolding.md
git commit -m "docs: record sd-switch's dry-run plan before the switch

The fourteen units land in home-files/.config/systemd/user, which is the
directory sd-switch compares, so all of them are in its set. The question
that decides whether a live switch is safe is whether it would start
wayland-session-shutdown.target, which conflicts with
graphical-session.target. Recorded here before anything is activated."
```

---

### Task 3: Phase 1 — the switch, from a TTY (user-run)

**Files:**
- Modify: `docs/2026-08-15-results-suffer-uwsm-scaffolding.md`

**Interfaces:**
- Consumes: Task 1's generation, Task 2's recorded plan.
- Produces: an activated generation whose uwsm units are Nix's.

**An agent must not perform any step in this task.** It logs the user out of
their graphical session and runs `home-manager switch`. The agent's role is to
present the steps, then read back what the user reports.

> **The TTY is the safety property.** Task 2 may well show that `sd-switch`
> leaves the shutdown target alone, and the switch would then be safe in a
> live session. The switch still happens from a TTY. Reading a dry run
> correctly and having no session to lose are different kinds of assurance,
> and this step costs one logout.

- [ ] **Step 1: The user records the before state**

```bash
{
  echo "== BEFORE =="; date
  echo "-- uwsm package"; dpkg-query -W -f='${Version}\n' uwsm
  echo "-- live session units"
  systemctl --user list-units --all --plain --no-legend \
    | awk '{print $1}' | grep -E 'wayland|fumon|graphical' \
    | while read -r u; do
        printf '%-58s %s\n' "$u" "$(systemctl --user show -p FragmentPath --value "$u")"
      done
  echo "-- failed units"; systemctl --user list-units --state=failed --no-legend | wc -l
} | tee /tmp/uwsm-before.txt
```

Expected: every `wayland-*` unit and `fumon.service` resolving under
`/usr/lib/systemd/user`; `graphical-session.target` and
`graphical-session-pre.target` also under `/usr/lib/systemd/user` (they are
systemd's and stay there); zero failed units.

- [ ] **Step 2: The user logs out of Hyprland**

Session menu → Log out, back to greetd.

- [ ] **Step 3: The user logs in on tty1**

`Ctrl+Alt+F1`, then log in. greetd is on VT7, so tty1 is free and its getty is
active and enabled.

- [ ] **Step 4: The user runs the switch from tty1**

```bash
cd /home/isutton/Projects/calango-nix
sg nix-users -c 'home-manager switch --flake .#isutton@suffer' 2>&1 | tee /tmp/uwsm-switch.txt
```

- [ ] **Step 5: The user reports the switch output**

Specifically whether `sd-switch`'s real actions matched Task 2's dry-run plan.
Any divergence is recorded before going further.

- [ ] **Step 6: The user verifies the units resolve to Nix's**

Still on tty1:

```bash
systemctl --user cat wayland-wm@.service | head -1
systemctl --user cat fumon.service | head -1
```

Expected: both name a path under `/home/isutton/.config/systemd/user`, not
`/usr/lib/systemd/user`.

- [ ] **Step 7: The user logs out of tty1 and logs in through greetd**

`Ctrl+Alt+F7` for the greeter, then the normal Hyprland (Nix) session.

- [ ] **Step 8: The agent records the outcome**

Append to the results document what the user reported: the switch output, the
two `systemctl cat` results, and whether the session came back normally.

- [ ] **Step 9: Commit**

```bash
git add docs/2026-08-15-results-suffer-uwsm-scaffolding.md
git commit -m "docs: the Phase 1 switch, run from a TTY"
```

---

### Task 4: Phase 2 — prove it across a reboot (user-run)

**Files:**
- Modify: `docs/2026-08-15-results-suffer-uwsm-scaffolding.md`

**Interfaces:**
- Consumes: Task 3's activated generation.
- Produces: the gate that Task 5's irreversible step depends on.

**An agent must not reboot the machine.** The user reboots; the agent supplies
and interprets the verification.

- [ ] **Step 1: The user reboots**

```bash
sudo systemctl reboot
```

- [ ] **Step 2: The user logs in through greetd as normal**

The Hyprland (Nix) session, the same entry as always.

- [ ] **Step 3: The agent runs the fragment check**

```bash
systemctl --user list-units --all --plain --no-legend \
  | awk '{print $1}' | grep -E 'wayland|fumon|graphical' \
  | while read -r u; do
      printf '%-58s %s\n' "$u" "$(systemctl --user show -p FragmentPath --value "$u")"
    done
```

**The gate:** every listed unit must resolve under
`/home/isutton/.config/systemd/user`, with exactly two permitted exceptions —
`graphical-session.target` and `graphical-session-pre.target`, which belong to
`systemd` and stay under `/usr/lib/systemd/user`.

The rule is stated this way rather than as a count on purpose: instance names
vary (`wayland-session-bindpid@<pid>.service` carries a different PID each
boot) and `session-graphical.slice` may or may not be loaded, so a fixed
number would fail for the wrong reason.

"Most of them" is not a pass. If any `wayland-*` unit or `fumon.service` still
resolves under `/usr/lib/systemd/user`, Task 5 does not run.

- [ ] **Step 4: The agent verifies the session is healthy**

```bash
for u in fumon.service quickshell.service xdg-desktop-portal-hyprland.service \
         hypridle.service hyprpolkitagent.service; do
  printf '%-40s %s\n' "$u" "$(systemctl --user is-active $u)"
done
echo "-- failed units --"
systemctl --user list-units --state=failed --no-legend
echo "-- compositor --"
pgrep -af 'bin/Hyprland' | head -1
```

Expected: all five active, no failed units, the compositor running from the
Nix store.

- [ ] **Step 5: The agent verifies the session is running Nix's uwsm end to end**

```bash
pgrep -af "uwsm" | grep -v pgrep
```

Expected: the `aux waitpid` process now runs Nix's uwsm, not
`/usr/bin/python3 /usr/bin/uwsm`. That single line is the clearest evidence
the scaffolding changed hands — before this plan it read
`/usr/bin/python3 /usr/bin/uwsm aux waitpid <pid>`.

- [ ] **Step 6: The agent records the gate result**

Append a `## Phase 2: the gate` section to the results document with the full
fragment-path table and the health checks. State explicitly whether the gate
passed.

- [ ] **Step 7: Commit**

```bash
git add docs/2026-08-15-results-suffer-uwsm-scaffolding.md
git commit -m "docs: Phase 2, Nix's units proven across a reboot"
```

---

### Task 5: Phase 3 — remove the package (user-run, irreversible)

**Files:**
- Modify: `docs/2026-08-15-results-suffer-uwsm-scaffolding.md`

**Interfaces:**
- Consumes: Task 4's passed gate.
- Produces: a system with no apt `uwsm`.

**An agent must not run any `apt` or `dpkg` command in this task.** Every step
below is the user's.

> **This step cannot be undone by apt.** The backports source went in spec 5
> and no `.deb` is cached:
>
> ```
> $ apt-get install --reinstall --print-uris -y uwsm
> Reinstallation of uwsm is not possible, it cannot be downloaded.
> ```
>
> The only remaining source is `/var/lib/dpkg/status` — the installed files
> themselves. Step 1 turns those files back into a `.deb` while they still
> exist. It is the only restore path that will exist afterwards.

- [ ] **Step 1: The user reconstructs a restorable package, before removing anything**

```bash
sudo apt install dpkg-repack
mkdir -p ~/pkg-archive
cd ~/pkg-archive
sudo dpkg-repack uwsm
ls -l ~/pkg-archive/uwsm*.deb
```

Expected: a `uwsm_0.26.4+ds-2~bpo13+1_*.deb` in `~/pkg-archive`. If
`dpkg-repack` produces nothing, **stop** — removal without a restore path is
not authorised by this plan.

`~/pkg-archive` is outside the git repo deliberately: a binary artifact does
not belong in source.

- [ ] **Step 2: The user checks what removal will take with it**

```bash
apt-get -s remove uwsm
```

Expected: `uwsm` alone, and no other package. `apt-cache rdepends --installed
uwsm` was measured empty. If the simulation proposes removing anything else,
stop and report.

- [ ] **Step 3: The user removes the package**

```bash
sudo apt remove uwsm
```

- [ ] **Step 4: The user records what became of the root-owned enablement link**

```bash
ls -l /etc/systemd/user/graphical-session.target.wants/fumon.service
```

Both outcomes are acceptable — deleted, or left dangling at a path that no
longer exists — because the flake now owns its own link at position 5. Which
one happened gets written down rather than assumed.

- [ ] **Step 5: The user confirms apt's units are gone**

```bash
ls /usr/lib/systemd/user/wayland-wm@.service 2>&1
dpkg -l uwsm 2>&1 | tail -2
```

Expected: the unit file does not exist; `dpkg -l` shows the package removed
(`rc` or absent).

- [ ] **Step 6: The agent records the removal**

Append a `## Phase 3: the irreversible step` section with the repack result,
the simulation output, and the state of the `/etc` symlink.

- [ ] **Step 7: Commit**

```bash
git add docs/2026-08-15-results-suffer-uwsm-scaffolding.md
git commit -m "docs: Phase 3, apt's uwsm removed with a repacked restore path"
```

---

### Task 6: Phase 4 — verify after a second reboot (user-run)

**Files:**
- Modify: `docs/2026-08-15-results-suffer-uwsm-scaffolding.md`

**Interfaces:**
- Consumes: Task 5's removal.
- Produces: the final measured state for Task 7's document.

**An agent must not reboot the machine.**

- [ ] **Step 1: The user reboots and logs in**

```bash
sudo systemctl reboot
```

Then the normal Hyprland (Nix) session through greetd.

> **If the session does not come back:** `Ctrl+Alt+F1` reaches tty1, whose
> getty is active and enabled. From there, in order: edit the flake and
> `sg nix-users -c 'home-manager switch --flake .#isutton@suffer'` to fix
> forward; or `sudo dpkg -i ~/pkg-archive/uwsm*.deb` to put apt's units back.
> **Do not roll back to a previous Home Manager generation** — it has no uwsm
> units and apt's are now gone, so a rollback produces a system with no
> session scaffolding at all. That inverts the rule every earlier spec relied
> on.

- [ ] **Step 2: The agent re-runs the Phase 2 gate**

```bash
systemctl --user list-units --all --plain --no-legend \
  | awk '{print $1}' | grep -E 'wayland|fumon|graphical' \
  | while read -r u; do
      printf '%-58s %s\n' "$u" "$(systemctl --user show -p FragmentPath --value "$u")"
    done
```

Same rule as Task 4 Step 3: everything under
`/home/isutton/.config/systemd/user` except systemd's two
`graphical-session*` targets.

- [ ] **Step 3: The agent verifies the package is gone and counts the survivors**

```bash
dpkg -l uwsm 2>&1 | tail -2
echo "-- remaining backports survivors --"
for p in libcpptrace1 libxkbcommon0 libxkbcommon-x11-0 quickshell uwsm ydotool; do
  v=$(dpkg-query -W -f='${Version}' "$p" 2>/dev/null || echo "GONE")
  printf '  %-22s %s\n' "$p" "$v"
done
```

Expected: `uwsm` reports `GONE`; the other five still carry their
`~bpo13+1` versions. Five survivors, not six.

- [ ] **Step 4: The agent verifies session health and the binaries in use**

```bash
for u in fumon.service quickshell.service xdg-desktop-portal-hyprland.service \
         hypridle.service hyprpolkitagent.service; do
  printf '%-40s %s\n' "$u" "$(systemctl --user is-active $u)"
done
systemctl --user list-units --state=failed --no-legend
echo "-- fumon's bare name resolved to --"
readlink -f /proc/$(pgrep -x fumon | head -1)/exe 2>/dev/null
echo "-- uwsm processes --"
pgrep -af uwsm | grep -v pgrep
```

Expected: all five active; no failed units; `fumon` resolving into the Nix
store (this is the bare-name check — the unit says `ExecStart=fumon` and
nothing in `/usr/bin` provides it any more); no `/usr/bin/uwsm` anywhere.

- [ ] **Step 5: The agent confirms the flake still evaluates and builds**

```bash
cd /home/isutton/Projects/calango-nix
sg nix-users -c 'nix eval .#homeConfigurations --apply builtins.attrNames'
sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage'
```

Expected: `[ "isutton@suffer" ]` and a store path.

- [ ] **Step 6: Commit**

```bash
git add docs/2026-08-15-results-suffer-uwsm-scaffolding.md
git commit -m "docs: Phase 4, verified after the second reboot"
```

---

### Task 7: Finish the results document

**Files:**
- Modify: `docs/2026-08-15-results-suffer-uwsm-scaffolding.md`

**Interfaces:**
- Consumes: every prior task's recorded measurements.

The document is the deliverable that outlives the branch. It follows the house
shape set by the five existing results documents in `docs/`: a
did-it-work table, the headline, the defects with owners, what is still true,
and what the next spec inherits.

- [ ] **Step 1: Write the `## Did it work?` table**

A before/after table covering: what runs the session's unit templates; what
`wayland-session-bindpid@` executes; the uwsm package state; the backports
survivor count; and whether the version-skew risk still exists.

- [ ] **Step 2: Write `## Every defect, and who owns it`**

Include, at minimum, the one this plan already knows about: **the spec's first
draft asserted that `home.file` units sit outside `sd-switch`'s set, and that
was false.** Reading the generated activation script disproved it —
`sd-switch` is invoked on directories, not on Home Manager's module list.
Record it as a design error caught before implementation, and name what it
would have cost: a `home-manager switch` that started
`wayland-session-shutdown.target` and tore down the running session.

Add any defect found during Tasks 1–6, with the same honesty.

- [ ] **Step 3: Write `## What is still true`**

The five remaining backports survivors and who holds each. Note that the
xkbcommon pins are held by `google-chrome-stable`, `deskflow`, `kwin-x11` and
`code` — **four** holders, correcting spec 5's results document, which listed
three and missed `kwin-x11`.

Note that `/usr/local/share/wayland-sessions/hyprland-nix.desktop` remains the
only file this project installs outside `$HOME`.

- [ ] **Step 4: Write `## What the next spec inherits`**

Carry forward, with the measurements this plan produced:

- `ydotool`: no consumer anywhere in the flake, `ydotoold` running as two
  processes, no Nix counterpart in this configuration. Probably a single
  commit rather than a spec.
- `ttyautolock` and `wait-tray` are gone with this removal; neither has a Nix
  counterpart in `pkgs.uwsm` if either turns out to be wanted.
- `/run/opengl-driver`: still open, still demoted — `mesa-26.1.5` carries no
  `/run/opengl-driver` reference, so only libglvnd's EGL vendor lookup is
  covered. See the amended bullet in spec 5's results document.
- The rollback rule changed permanently: after this spec, a previous Home
  Manager generation is not a recovery path for the session scaffolding.

- [ ] **Step 5: Verify every claim in the document has a measurement behind it**

Re-read the finished document and check each factual assertion against a
command output recorded in Tasks 1–6. Anything that cannot be traced to one
gets removed or marked as unverified. This project's results documents are
load-bearing for later specs, and spec 5's produced three claims that had to
be corrected in spec 6 — two of which sent the estimate in the wrong
direction.

- [ ] **Step 6: Commit**

```bash
git add docs/2026-08-15-results-suffer-uwsm-scaffolding.md
git commit -m "docs: results for spec 6, the session scaffolding

Nix's uwsm units now run the session, and apt's package is gone. Records
the sd-switch design error caught before implementation, the four holders
of the xkbcommon pins, and the rollback rule that this spec inverts."
```

---

## Notes for the executor

**The `sg nix-users -c '...'` wrapper is not optional.** Every `nix` and
`home-manager` invocation needs it. A bare `nix` fails with a permission error
on the daemon socket that looks like a broken installation and is not one.

**Tasks 3, 4, 5 and 6 belong to the user.** An agent may compose the commands,
read the results and write them down. An agent may not run `home-manager
switch`, any `apt`/`dpkg` command, or `reboot`. Task 2 is agent-safe
specifically because it calls `sd-switch --dry-run` directly rather than the
activation script.

**The gate in Task 4 is a gate.** If any `wayland-*` unit or `fumon.service`
still resolves under `/usr/lib/systemd/user`, Task 5 does not run — the
removal has no restore path through apt, so the only acceptable time to take
it is after the replacement is proven.

**Two units are expected never to move.** `graphical-session.target` and
`graphical-session-pre.target` belong to `systemd`. A verification that
demands they move under `~/.config` is wrong and will produce a false failure.
