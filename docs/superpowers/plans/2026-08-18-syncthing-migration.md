# Syncthing Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move `syncthing` and `syncthingtray` from Debian to Nix, using Home Manager's `services.syncthing` module, without any part of this flake ever writing the live `config.xml`.

**Architecture:** A new `home/syncthing.nix` calls the module with `settings`, `guiCredentials` and `guiAddress` deliberately absent, because their absence is what stops the module's `syncthing-init` config writer from existing at all. Two `assertions` entries — the first use of `assertions` in this flake — check that property at eval time. The tray comes from the same module, which needs one line in `home/quickshell.nix` to activate a `tray.target` that has been inactive on this machine since it was created.

**Tech Stack:** Nix flakes, standalone Home Manager `release-26.05`, nixpkgs `nixos-26.05`, `services.syncthing`, syncthing 2.1.2, syncthingtray 2.1.0.

**Spec:** `docs/superpowers/specs/2026-08-18-syncthing-migration-design.md`

## Global Constraints

- Wrap **every** `nix` and `home-manager` invocation: `sg nix-users -c 'nix build ...'`. A bare call fails on the daemon socket directory and reads as a broken Nix install.
- Never read a package version from `nixpkgs#<pkg>`. That is the flake registry, not this flake's pinned input. Use `nix eval --raw .#homeConfigurations."isutton@suffer".pkgs.<name>.version`.
- **No agent runs any of these.** `home-manager switch`; any mutating `apt`, `apt-get`, `dpkg`, `apt-mark` or `flatpak` command; `systemctl` with `start`, `stop`, `restart`, `enable`, `disable` or `daemon-reload`; `reboot`; `fusermount`; the activation script without `DRY_RUN=1`. The user runs all of them.
- **No agent runs any syncthing 2.x binary against the live state directory**, and no agent edits `~/.local/state/syncthing/` at all. `syncthing paths` and `syncthing generate` against a throwaway `HOME` are fine and are how the spec's figures were taken.
- **No agent writes the GUI API key anywhere.** `~/.local/state/syncthing/config.xml` contains it. Do not paste config.xml contents into a report, a commit message or a source file.
- Do not modify `~/.config/mimeapps.list`.
- No path containing `.superpowers/` may appear in any committed file.
- **`grep` in this shell is NOT GNU grep.** It is a function backed by ugrep and it silently returns `0` for a pattern containing `${` even on a file that provably holds it. Use `/usr/bin/grep`, with `-F` for a literal, whenever a count is load-bearing.
- A Nix builder runs with `set -e` and `pipefail`. Put every `grep` in a **condition** (`if grep -q … ; then`), never in a bare assignment.
- **Prove every guard by mutation, and confirm the mutation by a count before the build runs.**
- Build with `sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage'`.
- Commit after each task. Do not squash tasks together.

---

## File Structure

| file | responsibility | task |
|---|---|---|
| `home/syncthing.nix` | **new.** Calls `services.syncthing`; holds the two assertions; adds the tray in Task 2. | 1, 2 |
| `flake.nix` | one line adding `./home/syncthing.nix` to the module list | 1 |
| `home/quickshell.nix` | `Unit.Wants = [ "tray.target" ]` — quickshell owns `org.kde.StatusNotifierWatcher`, so it is what makes a tray exist | 2 |
| `CLAUDE.md` | the module-versus-verbatim-copy precedent, the `syncthing-init` trap, `tray.target`, and syncthing as a standing fact | 3 |

Nothing else changes. The live `config.xml`, `~/.local/state/syncthing/` and `~/.config/syncthingtray.ini` are untouched by every task in this plan.

---

## What is true before Task 1

Measured 2026-08-18, on `main` at `d96b253` plus the spec commit:

```
apt      syncthing 1.29.5~ds1-2 (auto)   syncthingtray 1.7.5-1 (manual)
nixpkgs  syncthing 2.1.2                 syncthingtray 2.1.0
unit     /usr/lib/systemd/user/syncthing.service, enabled, MainPID 3429
tray     ~/.config/autostart/syncthingtray.desktop, hand-made 2026-07-15
enable   ~/.config/systemd/user/default.target.wants/syncthing.service, hand-made 2026-07-15
target   tray.target present, Home Manager's, ActiveState=inactive
```

`config.systemd.user.services` currently has seven entries: `bt-agent`,
`hypridle`, `hyprpolkitagent`, `night-light`, `nm-secret-agent`, `quickshell`,
`xdg-desktop-portal-hyprland`.

---

### Task 1: `home/syncthing.nix`, and the two assertions

**Files:**
- Create: `home/syncthing.nix`
- Modify: `flake.nix` — the `modules` list

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `config.systemd.user.services.syncthing`, which Task 2's tray sits beside in the same file. Task 2 adds `services.syncthing.tray` to this file and must not disturb the assertions.

- [ ] **Step 1: Record what exists before the change**

```bash
cd /home/isutton/Projects/calango-nix
sg nix-users -c 'nix eval --json .#homeConfigurations."isutton@suffer".config.systemd.user.services --apply "s: builtins.attrNames s"'
```

Expected, exactly:

```
["bt-agent","hypridle","hyprpolkitagent","night-light","nm-secret-agent","quickshell","xdg-desktop-portal-hyprland"]
```

If this differs, stop and report — the branch is not on the commit this plan was written against.

- [ ] **Step 2: Create `home/syncthing.nix`**

```nix
# syncthing 2.1.2, through Home Manager's own service module rather than a
# verbatim copy of Debian's unit.
#
# Home Manager's module, not a copy of Debian's unit -- which is also how
# services.hypridle and services.hyprpolkitagent already run here, so this is
# not the departure an earlier version of this comment claimed it was.
#
# What is genuinely new is that this module can write user data:
# `syncthing-init` PATCHes the live config.xml over the REST API. That is what
# the omitted options and the assertions below are about. The module's unit
# also adds four hardening directives Debian's lacks -- LockPersonality,
# PrivateUsers, RestrictNamespaces and SystemCallFilter=@system-service -- on
# top of the three they share; the results document records whether any had to
# be reverted.
{
  config,
  lib,
  pkgs,
  ...
}:

{
  # `settings`, `guiCredentials` and `guiAddress` are ABSENT on purpose, and
  # their absence is the whole safety property of this file.
  #
  # The module computes
  #   doUpdateConfig = cleanedConfig != {} || guiCredentials != null || hasCustomGuiAddress
  # and creates `syncthing-init` -- a oneshot that PATCHes the running
  # configuration over syncthing's REST API -- whenever that is true. This
  # machine's ~/.local/state/syncthing/config.xml holds three folders and two
  # devices and is the authority. Nothing in this flake may write it.
  #
  # The trap is that the safe-looking setting is the dangerous one. The
  # module's guiAddress default is 127.0.0.1:8384, which is exactly what
  # config.xml already serves and what ~/.config/syncthingtray.ini connects
  # to. Writing that same value in explicitly, to "make it match", sets
  # hasCustomGuiAddress and switches syncthing-init ON. Matching by omission
  # is the only correct way to match.
  services.syncthing = {
    enable = true;
    package = pkgs.syncthing;
  };

  # The guard for the paragraph above, and the first use of `assertions` in
  # this flake.
  #
  # Not a runCommand in home.packages, which is where every other build-time
  # guard here lives. Those all inspect a *package* -- wrappedGuiApps reads
  # bin/, pulseaudioClients reads its own output -- and this property is about
  # the generation, which a derivation inside the generation cannot inspect.
  # config.systemd.user.services is readable at eval time, so the property is
  # checked where it is decided rather than where it would be observed.
  assertions = [
    {
      assertion = config.systemd.user.services ? syncthing;
      message = ''
        services.syncthing produced no `syncthing` unit, so the assertion
        below asserts nothing about anything. Either the module was disabled
        or it renamed its unit. Decide which, on purpose, and update this
        pair together.
      '';
    }
    {
      assertion = !(config.systemd.user.services ? syncthing-init);
      message = ''
        services.syncthing produced `syncthing-init`, which PATCHes
        config.xml over syncthing's REST API. Something in home/syncthing.nix
        set `settings`, `guiCredentials` or `guiAddress` to something other
        than its default. This machine's config.xml is the authority: three
        folders and two devices, none of it declared here. Remove the option
        rather than changing its value.
      '';
    }
  ];
}
```

- [ ] **Step 3: Wire it into `flake.nix`**

The `modules` list currently ends with `./home/uwsm.nix` before the inline
attribute set. Add one line after `./home/uwsm.nix`:

```nix
          ./home/syncthing.nix
```

- [ ] **Step 4: Build, and confirm both units' presence and absence**

```bash
cd /home/isutton/Projects/calango-nix
sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage'
sg nix-users -c 'nix eval --json .#homeConfigurations."isutton@suffer".config.systemd.user.services --apply "s: builtins.attrNames s"'
```

Expected: a store path, then a list that **contains** `syncthing` and **does
not contain** `syncthing-init`. It should be the seven-entry list from Step 1
plus `syncthing`.

- [ ] **Step 5: Confirm the unit runs the Nix binary and not Debian's**

```bash
A=$(sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage')
/usr/bin/grep -h '^ExecStart' "$A/home-files/.config/systemd/user/syncthing.service"
```

Expected: an `ExecStart` naming a `/nix/store/...-syncthing-2.1.2/bin/syncthing`
path, with `serve`, `--no-browser`, `--no-restart`, `--no-upgrade` and
`--gui-address=127.0.0.1:8384`. It must **not** name `/usr/bin/syncthing`.

- [ ] **Step 6: Mutation one — the config writer must fail the build**

Add `guiAddress` to `home/syncthing.nix`'s `services.syncthing` block, set to
a value that is **not** the module's default of `127.0.0.1:8384`. The port is
deliberately one off, so the mutation is as close to a plausible real edit as
it can be while still differing:

```nix
    guiAddress = "127.0.0.1:8385";
```

Confirm the mutation landed before building:

```bash
/usr/bin/grep -c 'guiAddress = ' home/syncthing.nix
```

Expected: `1`. Note the trailing `= ` in the needle: the bare word `guiAddress`
appears three times in this file's own comments, so counting it returns `3` on
a clean file and `4` on a mutated one. Count the assignment.

Then build:

```bash
sg nix-users -c 'nix build --no-link .#homeConfigurations."isutton@suffer".activationPackage' 2>&1 | tail -20
```

Expected: the build FAILS, and the output contains
`services.syncthing produced ` and `syncthing-init`.

This proves the guard fires when the option actually changes something.

**It deliberately does not use the module's own default value**, and the reason
is worth knowing. `hasCustomGuiAddress = cfg.guiAddress != defaultGuiAddress`
compares the resolved value, not whether anyone assigned it, so
`guiAddress = "127.0.0.1:8384"` is a true no-op and would build green. An
earlier version of this plan asserted the opposite and made that spelling the
central mutation; it was wrong, and the guard's own message repeated the error.
The guard asserts on the effect — does `syncthing-init` exist — so it catches
every case where setting the option would do something, and cannot catch a
redundant write. That limit is real and accepted.

Revert by deleting the line you added — not with `git checkout`, which cannot
restore a file that has never been committed, and `home/syncthing.nix` is not
committed until Step 9. Then confirm:

```bash
/usr/bin/grep -c 'guiAddress = ' home/syncthing.nix
```

Expected: `0`.

- [ ] **Step 7: Mutation two — a vacuous assertion must fail the build**

In `home/syncthing.nix`, change `enable = true;` to `enable = false;`. Confirm:

```bash
/usr/bin/grep -c 'enable = false;' home/syncthing.nix
```

Expected: `1`. Then build:

```bash
sg nix-users -c 'nix build --no-link .#homeConfigurations."isutton@suffer".activationPackage' 2>&1 | tail -20
```

Expected: the build FAILS with `produced no ` and `syncthing` in the message.

Without this branch the first assertion is decoration: it would pass in exactly
the situation where the second one has stopped meaning anything. Restore
`enable = true;` and confirm:

```bash
/usr/bin/grep -c 'enable = true;' home/syncthing.nix
```

Expected: `1`.

- [ ] **Step 8: Rebuild clean and run the flake checks**

```bash
cd /home/isutton/Projects/calango-nix
sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage'
sg nix-users -c 'nix flake check' && echo "FLAKE CHECK OK"
```

Expected: a store path, then exit 0 with three checks
(`no-dangling-home-files`, `no-pulseaudio-daemon`, `gui-desktop-ids`).

- [ ] **Step 9: Commit**

```bash
git add home/syncthing.nix flake.nix
git commit -m "syncthing: adopt Home Manager's module, with its config writer barred

settings, guiCredentials and guiAddress are absent on purpose: the
module creates syncthing-init -- a oneshot that PATCHes config.xml over
the REST API -- whenever any of them is set, and this machine's
config.xml is the authority for three folders and two devices.

The trap is that the safe-looking setting is the dangerous one.
guiAddress defaults to exactly what config.xml already serves, so
writing that value in explicitly turns the writer on. Matching by
omission is the only correct way to match.

Two assertions, the first use of assertions in this flake, both proven
by mutation. They are not a runCommand in home.packages because every
other guard here inspects a package, and a derivation inside the
generation cannot inspect the generation."
```

---

### Task 2: the tray, and the target nothing has ever wanted

**Files:**
- Modify: `home/syncthing.nix` — add `services.syncthing.tray`
- Modify: `home/quickshell.nix` — add `Wants` to the existing `Unit` block

**Interfaces:**
- Consumes: `home/syncthing.nix` from Task 1. The assertions in that file must be left exactly as they are.
- Produces: `config.systemd.user.services.syncthingtray`. Task 3's `CLAUDE.md` text describes it.

- [ ] **Step 1: Add the tray to `home/syncthing.nix`**

Insert this block after the `services.syncthing = { … };` block and before
`assertions`:

```nix
  # The tray, from the same module. Both overrides are load-bearing and
  # neither is obvious from reading the option names.
  #
  # `package` defaults to syncthingtray-MINIMAL, which is a different build
  # from the syncthingtray running here today; accepting the default would
  # swap it silently. `command` defaults to "syncthingtray --wait", dropping
  # the qt-widgets-gui and --single-instance that the hand-made
  # ~/.config/autostart/syncthingtray.desktop has been passing since
  # 2026-07-15. qt-widgets-gui is still a valid operation in 2.1.0, checked
  # against the binary's own --help.
  services.syncthing.tray = {
    enable = true;
    package = pkgs.syncthingtray;
    command = "syncthingtray qt-widgets-gui --single-instance --wait";
  };
```

- [ ] **Step 2: Make quickshell want `tray.target`**

`home/quickshell.nix` has a `config.systemd.user.services.quickshell.Unit`
block starting with `Description = "Quickshell shell";`. Add `Wants` directly
after the existing `After` line, with its comment:

```nix
      # quickshell owns org.kde.StatusNotifierWatcher and
      # org.kde.StatusNotifierHost-* on the session bus, which makes it the
      # thing that causes a tray to exist -- so it is the right unit to
      # declare that one does.
      #
      # tray.target is Home Manager's own, has been present on this machine
      # for as long as it has existed, and has never been active, because it
      # carries no [Install] section and nothing wanted it. syncthingtray's
      # unit is Requires=tray.target and After=tray.target, so without this
      # line it could never start at all.
      #
      # Note this orders nothing against quickshell being *ready* rather than
      # merely started. syncthingtray's --wait is what covers that gap, and
      # the tray icon appearing is the check.
      Wants = [ "tray.target" ];
```

- [ ] **Step 3: Build, and confirm the tray unit exists and names the right package**

```bash
cd /home/isutton/Projects/calango-nix
sg nix-users -c 'nix eval --json .#homeConfigurations."isutton@suffer".config.systemd.user.services --apply "s: builtins.attrNames s"'
A=$(sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage')
/usr/bin/grep -h -E '^(ExecStart|Requires|After|Wants)' "$A/home-files/.config/systemd/user/syncthingtray.service"
```

Expected: the list now also contains `syncthingtray`; and the unit's
`ExecStart` names a `syncthingtray-2.1.0` store path followed by
`qt-widgets-gui --single-instance --wait`, with `Requires=tray.target`.

It must **not** name `syncthingtray-minimal`. Check explicitly:

```bash
/usr/bin/grep -c 'syncthingtray-minimal' "$A/home-files/.config/systemd/user/syncthingtray.service"
```

Expected: `0`.

- [ ] **Step 4: Confirm quickshell's unit now wants the target**

```bash
/usr/bin/grep -h '^Wants' "$A/home-files/.config/systemd/user/quickshell.service"
```

Expected: a line containing `tray.target`.

This also means quickshell's unit text changed, so sd-switch will restart it on
the next switch. That is expected and is noted in the close-out.

- [ ] **Step 5: Confirm the assertions still hold**

Task 2 edits the same file as Task 1's guard. Re-run the check that the guard
protects:

```bash
sg nix-users -c 'nix eval --json .#homeConfigurations."isutton@suffer".config.systemd.user.services --apply "s: builtins.attrNames s"' | /usr/bin/grep -c 'syncthing-init'
```

Expected: `0`. The tray options do not feed `doUpdateConfig`, and this
confirms it rather than assuming it.

- [ ] **Step 6: Run the flake checks**

```bash
sg nix-users -c 'nix flake check' && echo "FLAKE CHECK OK"
```

Expected: exit 0, three checks.

- [ ] **Step 7: Commit**

```bash
git add home/syncthing.nix home/quickshell.nix
git commit -m "syncthing: the tray, and the target nothing had ever wanted

tray.target is Home Manager's, has been on this machine since it was
created, and has never been active -- it carries no [Install] section
and nothing wanted it. syncthingtray's unit is Requires=tray.target, so
one line in quickshell.nix is what makes it startable. quickshell owns
StatusNotifierWatcher, which makes it the right unit to declare that a
tray exists.

Both tray overrides are load-bearing: package defaults to
syncthingtray-minimal, a different build from the one running here, and
command defaults to dropping qt-widgets-gui and --single-instance."
```

---

### Task 3: `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: the facts established in Tasks 1 and 2.
- Produces: nothing.

Four edits. Each extends or sits beside an existing passage; **do not append a
new section at the end of the file.** `CLAUDE.md` is organised by topic and a
fact filed in the wrong place is a fact nobody finds. Read a few neighbouring
entries first and match their voice: they argue rather than assert, show the
command and its real output, and say what a wrong conclusion cost.

- [ ] **Step 1: Record the module-versus-verbatim-copy precedent**

The file states that "every migration in this project copied units verbatim",
in the `gnome-keyring` standing fact, and uses it as an argument. That rule is
narrower than it sounds: **enumerate `home/*.nix` before repeating it**, because
`home/default.nix:231` already declares `services.hyprpolkitagent` and
`home/hyprland.nix:135` already declares `services.hypridle`, and both packages
are `rc` in dpkg. Add a bullet to the **Standing facts** section:

```
- **`syncthing` and `syncthingtray` are Nix's, and they join `hypridle` and
  `hyprpolkitagent` as services this flake runs from an upstream Home Manager
  module rather than a copied unit.** An earlier draft of this entry called
  syncthing the *first* such migration. It is at least the third —
  `home/default.nix:231` declares `services.hyprpolkitagent` and
  `home/hyprland.nix:135` declares `services.hypridle`, and both packages are
  `rc` in dpkg, so both were real apt migrations. The claim was written without
  enumerating `home/*.nix`, which is the rule this file opens with, and it is
  recorded here because that is twice on one branch.

  What IS new with syncthing is narrower and is the part worth carrying: it is
  the first module adopted here that can **write user data**. `services.syncthing`
  creates `syncthing-init` -- a oneshot that PATCHes the live `config.xml` over
  syncthing's REST API -- whenever `settings`, `guiCredentials` or a non-default
  `guiAddress` is set. That is why those options are deliberately omitted in
  `home/syncthing.nix` rather than pinned, and why this flake gained its first
  `assertions`. The module's unit also adds four hardening directives Debian's
  lacks -- `LockPersonality`, `PrivateUsers`, `RestrictNamespaces` and
  `SystemCallFilter=@system-service` -- on top of the three they share; the
  results document records whether any had to be reverted.
```

- [ ] **Step 2: Record what the module's config writer really keys on**

This belongs in **Mechanisms that are not what they look like**. Note the
entry records a correction, because the correction is the useful part:

```
**A Home Manager module's `cfg.<option>` is the resolved value, not a record
that someone set it.** `services.syncthing` creates `syncthing-init` -- a
oneshot that PATCHes the running configuration over syncthing's REST API --
whenever `settings` is non-empty, `guiCredentials` is set, or

    hasCustomGuiAddress = cfg.guiAddress != defaultGuiAddress

is true. Spec 15 first claimed that writing `guiAddress = "127.0.0.1:8384"`
explicitly -- the module's own default -- would trip that and turn the writer
on. It does not: the comparison reads the merged value, so an explicit
assignment equal to the default is indistinguishable from no assignment and is
a genuine no-op. The claim conflated "the option was set" with "the value
differs from the default", reached a spec, a plan and a guard's own error
message, and was caught by an implementer who read the module source instead of
the paragraph describing it.

What is true is smaller and still worth guarding: three unrelated-looking
options each switch on a writer that rewrites a config this flake does not own.
`home/syncthing.nix` asserts on the *effect* -- that `syncthing-init` does not
exist -- which catches every case where setting one of them would do something,
and by construction cannot catch a redundant write. If you need to know whether
an option was written at all rather than what it resolved to, the module system
answers that with `options.<path>.isDefined`, not with a value comparison.
```

- [ ] **Step 3: Record `tray.target`**

Also in **Mechanisms that are not what they look like**:

```
**`tray.target` exists here, is Home Manager's, and was inactive for its whole
life until spec 15.** It is `~/.config/systemd/user/tray.target`, "Home Manager
System Tray", `Requires=graphical-session-pre.target` -- and it carries no
`[Install]` section, so nothing pulled it in. Any Home Manager tray service is
`Requires=tray.target`, which means it could never start. The missing piece is
that the *tray host* has to want it: quickshell owns
`org.kde.StatusNotifierWatcher` and `org.kde.StatusNotifierHost-*` on the
session bus, so `home/quickshell.nix` declares `Wants = [ "tray.target" ]`.
Check with `busctl --user list | grep StatusNotifier` before assuming some
other component is the host.
```

- [ ] **Step 4: Record the first use of `assertions`**

The passage enumerating build-time guards tells the reader to enumerate by
syntax with `grep -n 'home.packages' home/*.nix`. That instruction still
stands. Add one paragraph recording that `home/syncthing.nix` introduces a
guard of a **different kind**, which that grep will never find:

```
`home/syncthing.nix` adds the first guard in this flake that is not a
derivation: two entries in Home Manager's `assertions`, evaluated at build
time. It had to be, and the reason generalises. Every guard above inspects a
*package* -- `wrappedGuiApps` reads `bin/`, `pulseaudioClients` reads its own
output -- so a `runCommand` in `home.packages` can see what it needs. A
property about the *generation* cannot be checked that way, because a
derivation inside the generation cannot inspect the generation it belongs to.
`config.systemd.user.services` is readable at eval, so enumerate assertions
too, with `grep -n 'assertions' home/*.nix`.
```

- [ ] **Step 5: Confirm no `.superpowers/` path entered the file**

```bash
cd /home/isutton/Projects/calango-nix
/usr/bin/grep -c '\.superpowers/' CLAUDE.md
```

Expected: `0`.

- [ ] **Step 6: Verify every count the new text claims**

```bash
cd /home/isutton/Projects/calango-nix
/usr/bin/grep -n 'assertions' home/*.nix
/usr/bin/grep -n 'home.packages' home/*.nix | wc -l
sg nix-users -c 'nix eval --json .#homeConfigurations."isutton@suffer".config.systemd.user.services --apply "s: builtins.attrNames s"'
```

Read what these print and make the prose agree with them. If a number you
wrote disagrees with what a command prints, the command wins — that is the
file's own rule, stated in its opening paragraph.

- [ ] **Step 7: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: syncthing, and three things it taught

syncthing joins hypridle and hyprpolkitagent as services run from an
upstream Home Manager module rather than a copied unit -- it is not the
first, which an earlier draft claimed without enumerating home/*.nix.
What is new is the first guard here that is not a derivation, because a
property about the generation cannot be checked by a derivation inside
it.

Also records what services.syncthing's config writer really keys on.
hasCustomGuiAddress compares the RESOLVED value of cfg.guiAddress, not
whether anyone assigned it, so writing the default back in explicitly is
a genuine no-op -- the opposite of what this plan first claimed, in three
places, before an implementer read the module source."
```

---

## Close-out — with the user, in this order

These steps need the user. No agent runs them. **The order matters: everything
up to and including the switch is reversible by doing nothing, and the first
2.x start is not.**

- [ ] **1. Remove the empty-id folder, in 1.29.5.** Open `http://127.0.0.1:8384`
  while Debian's syncthing is still the one running, and delete the folder with
  an empty id and empty label whose path is `~`. It has no remote device, so
  nothing stops synchronising. Doing this first means an invalid folder id never
  meets a fifteen-version config upgrade.

- [ ] **2. Back up `config.xml`, outside `$HOME`.**

```bash
cp ~/.local/state/syncthing/config.xml /var/tmp/syncthing-config-v37-2026-08-18.xml
```

  16 KB, and the only thing standing between a bad outcome and a rollback. It
  goes outside `$HOME` because it contains the GUI API key, `~/Projects`
  replicates to `epiphany` and is a git repository, and the folder removed in
  step 1 was until moments ago indexing everything else under `~`. Record the
  path chosen — the results document needs it.

- [ ] **3. Delete the hand-made enable link, before switching.**

```bash
rm ~/.config/systemd/user/default.target.wants/syncthing.service
```

  Home Manager writes its own link at that exact path and **aborts activation**
  rather than clobber a file it does not own. This is the difference between a
  clean switch and a failed one.

- [ ] **4. Switch.** `quickshell.service` restarts, because Task 2 changed its
  unit text. Debian's `syncthing.service` at UnitPath position 15 is shadowed by
  the new one at position 5.

- [ ] **5. Verify, before removing anything.**

```bash
systemctl --user show syncthing.service -p FragmentPath -p ExecStart -p ActiveState --value
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8384/
ls -d ~/.local/state/syncthing/index-v2 ~/.local/state/syncthing/index-v0.14.0.db
```

  Expected: the fragment under `~/.config/systemd/user`, an `ExecStart` naming
  the Nix store, `active`; an HTTP code from the GUI; and **both** index paths
  present — the new one created and the old one still there.

  Then the four sandbox checks from the spec's Piece 4: a file changed in a
  synced folder is noticed, files syncthing writes are still owned by `isutton`,
  the unit stays running, and all three real folders reach a synchronised state
  with `epiphany`. If any fails, apply the fallback — override the `Service`
  block to Debian's three directives, `SystemCallArchitectures=native`,
  `MemoryDenyWriteExecute=true`, `NoNewPrivileges=true` — and record which
  directive was responsible.

- [ ] **6. Confirm the tray.** The icon should appear. Check
  `systemctl --user is-active tray.target syncthingtray.service`. If the icon is
  missing, `tray.target` is the first thing to look at: this is a new
  relationship, not a restored one.

- [ ] **7. Delete the hand-made autostart entry**, once the tray unit is proven:

```bash
rm ~/.config/autostart/syncthingtray.desktop
```

  Later than step 3 on purpose — deleting it earlier only loses the fallback
  while the new path is unproven.

- [ ] **8. Remove both apt packages.** Re-read the "no longer required" list at
  that moment rather than trusting this plan, per the standing rule. Then:

```bash
apt-get -s autoremove | /usr/bin/grep -c '^Remv'   # expect 0
find /etc/systemd/user -xtype l                    # expect nothing
```

  The second is a prediction worth checking rather than assuming: Debian's unit
  was enabled by the user's own link, not a root-owned one, so this removal
  should not add to the `/etc/systemd/user` dangling count.

- [ ] **9. Write the results document** to
  `docs/2026-08-18-results-suffer-syncthing-migration.md`, recording every
  defect and its owner, the backup path from step 2, and the sandbox verdict
  from step 5. Then `ls -1 docs/*results-suffer-*.md | wc -l` is the authority
  for the count in `CLAUDE.md`'s opening paragraph — read it, do not increment
  it.

- [ ] **10. Not now: `index-v0.14.0.db`.** It is the rollback. Deleting it to
  reclaim 160 MB is a later, separate decision, taken once the user is
  satisfied.

---

## Acceptance criteria

Mapped from the spec.

1. The empty-id folder is gone from `config.xml`, removed through 1.29.5's GUI before any 2.x binary runs — close-out 1.
2. `config.xml` is backed up outside `$HOME` and the path is recorded — close-out 2, results document.
3. `config.systemd.user.services` contains `syncthing` and not `syncthing-init`, asserted by two `assertions` entries each proven to fire by mutation — Task 1 Steps 4, 6, 7.
4. `nix flake check` exits 0 and reports three checks — Task 1 Step 8, Task 2 Step 6.
5. `syncthing.service` runs from `~/.config/systemd/user`, executes the Nix 2.1.2 binary, and reaches `active (running)` — Task 1 Step 5, close-out 5.
6. `index-v2` exists and `index-v0.14.0.db` still exists — close-out 5.
7. All three real folders reach a synchronised state with `epiphany` — close-out 5.
8. The four sandbox checks pass, or the fallback is applied and the responsible directive is recorded — close-out 5.
9. The tray icon appears and `syncthingtray.service` is active with `tray.target` active — Task 2 Steps 3-4, close-out 6.
10. Both hand-made files are gone and `no-dangling-home-files` still passes — close-out 3, 7, and Task 2 Step 6.
11. Both apt packages are removed, `apt-get -s autoremove` proposes zero, and `find /etc/systemd/user -xtype l` returns nothing — close-out 8.
12. `CLAUDE.md` carries the module-versus-verbatim-copy precedent, the `syncthing-init` trap, `tray.target`, and the first use of `assertions` — Task 3. The spec's own criterion 12, added after this plan's self-review noticed the omission.
