# Spec 15: move syncthing and syncthingtray from Debian to Nix

**Date:** 2026-08-18
**Host:** `suffer`
**Branch:** `syncthing-migration`

---

## Why now

`syncthing` and `syncthingtray` are the last ordinary desktop pair still on apt
that has a working Nix equivalent. They are coupled — `syncthingtray` declares
`Depends: syncthing`, and apt's `syncthing` is automatic, held installed by
nothing else — so they move together or not at all.

This one has been deferred through three specs because it was recorded as
carrying a one-way database conversion. That record was wrong in a way worth
correcting up front, and the correction is what makes the migration ordinary.

```
apt      syncthing 1.29.5~ds1-2      syncthingtray 1.7.5-1
nixpkgs  syncthing 2.1.2             syncthingtray 2.1.0
```

Two majors on each side.

---

## What is measured

Every figure below was taken on `suffer` on 2026-08-18.

### The database conversion is additive, not destructive

The memo carried into this spec said syncthing 2 "converts LevelDB to SQLite
irreversibly, so a backup is the only recovery path". The paths say otherwise:

```sh
# 1.29.5, against a throwaway HOME
/usr/bin/syncthing --paths          # Database location: …/syncthing/index-v0.14.0.db
# 2.1.2, same throwaway HOME
syncthing paths                     # Database location: …/syncthing/index-v2
```

The two versions name **different** databases. Syncthing 2 reads the old
LevelDB and writes a new store beside it; it does not overwrite
`index-v0.14.0.db`. So the 160 MB already on disk is itself the rollback for
the index, and the memo's framing overstated the danger while pointing at the
wrong file.

Note `syncthing paths` is non-destructive — run against a fresh `HOME` it
created nothing — which is why it is safe to ask this question before
committing to anything.

### What is genuinely one-way is `config.xml`

```sh
/usr/bin/grep -oE '<configuration version="[0-9]+"' ~/.local/state/syncthing/config.xml
# 37
syncthing generate --home <throwaway>   # 2.1.2
# <configuration version="52"
/usr/bin/syncthing generate --home <throwaway>   # 1.29.5
# <configuration version="37"
```

Fifteen format versions. 1.29.5 will not read a v52 config back. The file is
16 KB, so securing the recovery path is trivial — but it must be done
deliberately, and it is a different file from the one the memo named.

### Both versions agree on where everything lives

```
Configuration file      ~/.local/state/syncthing/config.xml
Device key & cert       ~/.local/state/syncthing/{key,cert}.pem
GUI key & cert          ~/.local/state/syncthing/https-{key,cert}.pem
```

Identical between 1.29.5 and 2.1.2, and identical to what is on disk. There is
no `~/.config/syncthing`. So the device identity is found in place and no
`--home` flag is needed anywhere. This is the fact that makes the migration
ordinary rather than a re-pairing exercise.

### The peer

One remote device, `epiphany`, running 1.27 or newer (user-supplied). Syncthing
2.x keeps wire compatibility with 1.27+, so only this machine moves.

### The unit today

```
FragmentPath      /usr/lib/systemd/user/syncthing.service
UnitFileState     enabled
MainPID           3429
ExecStart         /usr/bin/syncthing serve --no-browser --no-restart --logflags=0
```

Debian's unit carries three hardening directives: `SystemCallArchitectures`,
`MemoryDenyWriteExecute`, `NoNewPrivileges`.

### Two hand-made files, both from 2026-07-15 16:04

```sh
ls -l ~/.config/systemd/user/default.target.wants/syncthing.service
# isutton:isutton -> /usr/lib/systemd/user/syncthing.service
ls -l ~/.config/autostart/syncthingtray.desktop
# isutton:isutton, Exec="/usr/bin/syncthingtray" qt-widgets-gui --single-instance --wait
```

Neither is Home Manager's — its links are `isutton:nix-users` and point into
`home-manager-files` — so `no-dangling-home-files` cannot see either. Same
species as the `pipewire-session-manager.service` alias, in a new place.

**The first one can break the switch.** Home Manager's syncthing module writes
its own link at that exact path, and Home Manager aborts activation rather than
clobber a file it does not own. It is deleted *before* the switch, not after.

### The Home Manager module

`services.syncthing`, at `modules/services/syncthing.nix` in this release. Its
unit is `WantedBy=default.target` like Debian's, adds `After=network.target`,
and carries **seven** hardening directives — Debian's three plus
`LockPersonality`, `PrivateUsers`, `RestrictNamespaces` and
`SystemCallFilter=@system-service`. Its arguments add `--no-upgrade` and
`--gui-address=`, and drop `--logflags=0`.

The module also owns a config writer, and the condition for it is the single
most important line in the file:

```nix
doUpdateConfig = cleanedConfig != { } || cfg.guiCredentials != null || hasCustomGuiAddress;
syncthing-init = lib.mkIf doUpdateConfig { … };   # a oneshot that PATCHes config over the REST API
```

### `tray.target` exists, is Home Manager's, and nothing wants it

```sh
systemctl --user show tray.target -p FragmentPath -p ActiveState --value
# /home/isutton/.config/systemd/user/tray.target
# inactive
cat ~/.config/systemd/user/tray.target
# [Unit]
# Description=Home Manager System Tray
# Requires=graphical-session-pre.target
```

It is already in this generation's `home-files`. It has no `[Install]` section,
so nothing pulls it in. Meanwhile quickshell is the tray host:

```sh
busctl --user list | /usr/bin/grep StatusNotifier
# org.kde.StatusNotifierHost-855684-…   855684  .quickshell-wra
# org.kde.StatusNotifierWatcher         855684  .quickshell-wra
```

### The folder set

| id | label | path | remote devices |
|---|---|---|---|
| `default` | Default Folder | `/home/isutton/Sync` | epiphany |
| `qqltj-fl2ez` | Dropsolid | `~/Dropsolid` | epiphany |
| `xuhgr-epwn2` | Projects | `~/Projects` | epiphany |
| *(empty)* | *(empty)* | `~` | **none — only `suffer` itself** |

The fourth entry has an empty id, which is not valid in syncthing's own terms.
1.29.5 tolerates it. It has an fsWatcher on the whole of `$HOME` and no remote
device, so it synchronises nothing while indexing everything — likely most of
why the index is 160 MB.

**`~/Projects` is synced to epiphany and is where this repository lives.**
`config.xml` contains the GUI API key. Those two facts together decide where the
backup goes.

---

## Design

### Piece 1 — remove the empty-id folder first, in 1.29.5

User decision, taken before anything else moves. Delete the entry through the
running 1.29.5 web GUI at `127.0.0.1:8384`, while a version that can read a v37
config is still the one in charge. Nothing stops synchronising: the entry has no
remote device.

This is first because carrying an invalid folder id across a fifteen-version
config upgrade risks a failure that would read as "the migration broke
syncthing" rather than "one bad entry was rejected". Removing it also drops an
inotify watch on all of `$HOME`.

### Piece 2 — back up `config.xml`, outside `$HOME`

16 KB, and the only thing standing between a bad outcome and a rollback. It goes
outside `$HOME` — not for tidiness, but because it holds the GUI API key while
`~/Projects` replicates to epiphany and is a git repository, and because the
empty-id folder currently indexes everything else under `~`.

Copy `~/.local/state/syncthing/config.xml` to a location outside `$HOME` that
survives a reboot. The user chooses the exact path and records it in the results
document.

### Piece 3 — the module, and the three options it must not set

```nix
services.syncthing = {
  enable = true;
  package = pkgs.syncthing;
  # settings, guiCredentials and guiAddress are deliberately absent
};
```

`doUpdateConfig` is false only when all three are left alone, and only then does
`syncthing-init` not exist. That oneshot PATCHes the live configuration over the
REST API; with three folders, two devices and an authoritative `config.xml` on
disk, it is the one part of this module that must never run here.

**The trap is that the safe-looking setting is the dangerous one.** The module's
`guiAddress` default is `127.0.0.1:8384` — verified by eval — which is exactly
what `config.xml` serves and what `syncthingtray.ini` connects to. Writing that
same value in explicitly to "make it match" sets `hasCustomGuiAddress`, which
turns `syncthing-init` **on**. Matching by omission is the only correct way to
match.

**Guard: two entries in Home Manager's `assertions`.**

```nix
assertions = [
  {
    assertion = config.systemd.user.services ? syncthing;
    message = "services.syncthing produced no syncthing unit, so the assertion below asserts nothing.";
  }
  {
    assertion = !(config.systemd.user.services ? syncthing-init);
    message = "services.syncthing produced syncthing-init, which PATCHes config.xml over the REST API. Something set settings, guiCredentials or guiAddress -- note that setting guiAddress to its own default value is enough.";
  }
];
```

**Not a `runCommand` in `home.packages`, and the reason generalises.** Every
build-time guard this project has written so far inspects a *package* —
`wrappedGuiApps` reads `bin/`, `pulseaudioClients` reads its own output — which
is why they can ride in `home.packages`. This property is about the generation
itself, and a derivation inside the generation cannot inspect the generation it
belongs to. `config.systemd.user.services` is readable at eval time, though;
measured, it returns the seven service names this configuration defines. So the
property gets checked where it is decided rather than where it is observed.

Proven by mutation in both directions: setting `guiAddress` to its own default
value must fire the second assertion, and `services.syncthing.enable = false`
must fire the first.

### Piece 4 — the sandboxing, verified rather than assumed

The module's unit adds four hardening directives Debian's lacks. This spec takes
the module as shipped and establishes whether that is safe, rather than
pre-emptively overriding it or hoping:

| directive | what to check |
|---|---|
| `SystemCallFilter=@system-service` | a file changed in a synced folder is noticed — inotify survives the filter |
| `PrivateUsers` | files syncthing writes are still owned by `isutton` |
| `RestrictNamespaces`, `LockPersonality` | the unit reaches `active (running)` and stays there |

Plus: the GUI answers on `127.0.0.1:8384`, and the tray connects.

**The fallback is written down now so it is not invented under pressure.** If
any check fails, override the `Service` block to Debian's three directives —
`SystemCallArchitectures=native`, `MemoryDenyWriteExecute=true`,
`NoNewPrivileges=true` — and re-test. Record which directive was responsible;
that is the useful output either way.

`--logflags=0` is dropped by the module. Cosmetic: journald stamps its own
times.

### Piece 5 — the tray, through the module

```nix
services.syncthing.tray = {
  enable  = true;
  package = pkgs.syncthingtray;
  command = "syncthingtray qt-widgets-gui --single-instance --wait";
};
```

Both overrides are load-bearing and neither is obvious:

- `tray.package` defaults to **`syncthingtray-minimal`**, a different build from
  the one running today. Accepting the default would swap it silently.
- `tray.command` defaults to `syncthingtray --wait`, dropping the
  `qt-widgets-gui` and `--single-instance` the current autostart entry passes.
  `qt-widgets-gui` is still a valid operation in 2.1.0 — checked against the
  binary's own help.

**And one line in `home/quickshell.nix`:** `Unit.Wants = [ "tray.target" ]`.
The module's tray unit is `Requires=tray.target` and `After=tray.target`, and
nothing on this machine wants that target, so without this the unit can never
start. quickshell owns `org.kde.StatusNotifierWatcher`, which makes it the thing
that causes a tray to exist and therefore the right unit to declare it.

Ordering is not guaranteed against quickshell being *ready* rather than merely
started. That is what `--wait` is for, and the check is that the tray icon
appears.

**One consequence, accepted deliberately.** `tray.enable` installs
`cfg.tray.package` through the module's own `home.packages`, so `syncthingtray`
sits outside this flake's `guiPackages` list and `wrappedGuiApps` does not cover
it. It is wrapped today — `.syncthingtray-wrapped` and `.syncthingctl-wrapped`
both exist — so nothing is broken; what is given up is a build failure if a
future nixpkgs bump drops the wrapper. The user chose the simpler configuration
over that coverage.

### Piece 6 — the two hand-made files

`~/.config/systemd/user/default.target.wants/syncthing.service` is deleted
**before** the switch, because Home Manager wants that exact path and aborts
activation on a file it does not own.

`~/.config/autostart/syncthingtray.desktop` is deleted after the tray unit is
confirmed working. Deleting it earlier only loses the fallback while the new
path is unproven.

Neither is replaced. Both were hand-made, and this flake owns units instead.

### Piece 7 — the apt removal

`syncthingtray` is manual; `syncthing` is automatic and required by nothing
else. Both go together. Read the "no longer required" list at that moment rather
than trusting this document, per the standing rule.

Debian's `syncthing.service` is `enabled`, but by the user's own link rather
than a root-owned one — `find /etc/systemd/user -name 'syncthing*'` returns
nothing. So this removal should *not* add to the `/etc/systemd/user` dangling
count, which is a prediction worth checking rather than assuming.

---

## Out of scope

- **Declarative syncthing configuration.** `settings` stays unset permanently,
  not just during the migration. The live `config.xml` is the authority and
  moving it into Nix is a separate decision with its own risks.
- **Deleting `index-v0.14.0.db`.** It is the rollback. It goes only after the
  user is satisfied, in a later session, and reclaiming 160 MB is not a reason
  to hurry.
- **`syncthingtray`'s own config.** `~/.config/syncthingtray.ini` is 87 lines
  and stays where it is, unmanaged, exactly as now.

---

## Acceptance criteria

1. The empty-id folder is gone from `config.xml`, removed through 1.29.5's GUI
   before any 2.x binary runs.
2. `config.xml` is backed up outside `$HOME`, and the path is recorded.
3. `config.systemd.user.services` contains `syncthing` and does **not** contain
   `syncthing-init`, asserted at eval time by two `assertions` entries, each
   proven to fire by mutation.
4. `nix flake check` exits 0 and reports three checks.
5. `syncthing.service` runs from `~/.config/systemd/user`, executes the Nix
   2.1.2 binary, and reaches `active (running)`.
6. `index-v2` exists and `index-v0.14.0.db` still exists.
7. All three real folders reach a synchronised state with `epiphany`.
8. The four sandbox checks in Piece 4 pass, or the fallback is applied and the
   responsible directive is recorded.
9. The tray icon appears, and `syncthingtray.service` is active with
   `tray.target` active.
10. Both hand-made files are gone; `no-dangling-home-files` still passes.
11. Both apt packages are removed, `apt-get -s autoremove` proposes zero, and
    `find /etc/systemd/user -xtype l` still returns zero.
12. `CLAUDE.md` records the module-versus-verbatim-copy precedent, the
    `syncthing-init` trap, `tray.target`, and the first use of `assertions` in
    this flake. Added after the plan's self-review noticed the omission: every
    prior spec here ends with a `CLAUDE.md` edit, and a deliberate departure
    from the copy-verbatim rule is precisely what that file exists to record.

---

## Risks

**The config upgrade is the point of no return.** Everything before the first
2.x start is reversible by doing nothing. After it, `config.xml` is v52 and the
backup from Piece 2 is the only way back. Take that step deliberately, with the
backup already made and its path written down.

**Two variables move at once, and that is unavoidable here.** The version jumps
two majors *and* the unit's sandbox profile changes, because the user chose the
Home Manager module over a verbatim copy. Piece 4's checks exist precisely so
the two can be told apart afterwards; the fallback isolates the sandbox by
reverting only it.

**The tray depends on a target nothing has ever activated.** `tray.target` has
been present and inactive on this machine for as long as it has existed. Making
quickshell want it is a new relationship, not a restoration of an old one, and
it is the first thing to check if the icon does not appear.

**`~/Projects` is synced and is this repository.** A backup placed carelessly
replicates the GUI API key to epiphany and into git history. Piece 2 is written
the way it is for that reason.
