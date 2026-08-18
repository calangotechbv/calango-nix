# Spec 15 results: syncthing and syncthingtray, on `suffer`

**Spec:** `docs/superpowers/specs/2026-08-18-syncthing-migration-design.md`
**Plan:** `docs/superpowers/plans/2026-08-18-syncthing-migration.md`
**Branch:** `syncthing-migration`, merged to `main` fast-forward, 11 commits
**Switched:** 2026-08-18 10:58

---

## What changed

`syncthing` 1.29.5 and `syncthingtray` 1.7.5 were Debian's, coupled by
`syncthingtray Depends: syncthing`. They now run from Nix, through Home
Manager's `services.syncthing` module rather than a copied unit — which is also
how `services.hypridle` and `services.hyprpolkitagent` already ran here.

`home/syncthing.nix` calls the module with `settings`, `guiCredentials` and
`guiAddress` **absent**. That absence is the safety property: the module creates
`syncthing-init`, a oneshot that PATCHes the live `config.xml` over syncthing's
REST API, whenever any of the three is set to something other than its default.
This machine's config is the authority for its folders and devices, and nothing
in this flake may write it. Two `assertions` guard that — the first guard here
that is not a derivation.

The tray comes from the same module. `home/quickshell.nix` gained
`Wants = [ "tray.target" ]`, because quickshell owns
`org.kde.StatusNotifierWatcher` and is therefore the thing that makes a tray
exist.

## The switch, measured

```
unit          /home/isutton/.config/systemd/user/syncthing.service
binary        /nix/store/pca0kc6…-syncthing-2.1.2/bin/syncthing
state         active, NRestarts=0, zero journal warnings since 10:58
config        version 37 → 52
migration     425,423 files in 22 seconds, no errors
peer          epiphany reconnected, running v2.1.1
tray          tray.target active, syncthingtray.service active
```

Restart prediction held: `quickshell.service` restarted at 10:58:57 because its
unit text changed; `hyprpolkitagent.service` did not, and still carries the
previous day's timestamp.

The sandbox went on as shipped — `PrivateUsers`, `LockPersonality` and
`RestrictNamespaces` all on, `SystemCallFilter=@system-service` applied — and
none of the four checks the spec set out failed, so the documented fallback to
Debian's three directives was never needed. `inotify_add_watch` is inside the
permitted syscall set, which is the fsWatcher question answered directly rather
than inferred from "it seems to work".

## The database, and the correction that matters

The spec said the conversion is additive and the old LevelDB is the rollback.
That is right, and the path it gave is wrong. Syncthing **renames** the old
database:

```
index-v0.14.0.db-migrated   163 MB, 90 .ldb files, intact
index-v2                    446 MB, the new store
```

The close-out check handed to the user was `ls -d …/index-v0.14.0.db`, which
fails. Run as written it reads as *the rollback is gone*, and on first
inspection after the switch that is exactly how it read — the wrong conclusion
was one `ls` away from being reported. The lesson is narrow and worth keeping:
**a check for a file's absence proves nothing unless you know every name the
file could have.**

`config.xml` has its own rollback too, and not because anyone arranged it:
syncthing wrote `~/.local/state/syncthing/config.xml.v37` itself, mode 600, at
migration time. Nothing was placed at the backup path the plan suggested. It did
not matter, but it did not matter by luck.

## Two folders, not the two intended

Comparing syncthing's own pre-migration snapshot against the live config shows
**`default` / "Default Folder" was removed, and the blank-id folder survived** —
the opposite way round from the plan's step 1.

The instruction named the target as "the folder whose id and label are both
blank", which is a poor way to point at something in a GUI that lists folders by
label: the folder with no label is precisely the one that cannot be named. No
data was lost — `~/Sync` exists and is empty on this machine — but that folder no
longer syncs with `epiphany`, which may still hold content under its copy. Left
as an open item for the user rather than reversed.

**The blank-id folder is inert under 2.1.2, which answers the spec's open
question.** It is in `config.xml` with `paused=false` and `fsWatcherEnabled=true`
and one device — this machine — and syncthing 2.1.2 loads only two folders:

```
folder.id=qqltj-fl2ez   folder.label=Dropsolid
folder.id=xuhgr-epwn2   folder.label=Projects
```

No "Ready to synchronize" line for the blank entry, no migration line, and no
complaint. The GUI lists loaded folders, so it cannot be found there either.
2.1.2 neither rejects the invalid id nor honours it. Left in place: removing
2,039 bytes that nothing reads would mean stopping the service to hand-edit a
config. Revisit if a future version starts loading it.

This also retires a claim from the spec: that the blank folder was "likely most
of why the index is 160 MB". `index-v2` is 446 MB and covers only the two real
folders, so the old 160 MB was those two as well. The word "likely" was carrying
an estimate that had no measurement behind it.

## Still to do

Both apt packages are still `ii`. `apt-get -s autoremove` proposes 0 and the
`rc` count stands at 147, unchanged. Removing them is the remaining step, and
the "no longer required" list must be read at that moment rather than trusted
from here.

---

## Defects, and their owners

| # | defect | owner | how it was caught |
|---|---|---|---|
| 1 | The spec claimed that writing `guiAddress` to its own default value would switch the config writer on. `hasCustomGuiAddress` compares the **resolved** value, so an explicit assignment equal to the default is a no-op. | controller | Task 1's implementer, which ran the mutation, found the build green, and read the module source rather than trusting the brief |
| 2 | Task 1 Step 6 expected `grep -c 'guiAddress'` to return 1; the bare word appears three times in the file's own comments. | controller | Task 1's implementer, which reported the discrepancy instead of reconciling it |
| 3 | The correction for defect 1 missed a fourth copy, in Task 3's commit-message template. | controller | Task 1's review |
| 4 | The claim that syncthing was the first migration here to adopt an upstream Home Manager module. `services.hypridle` and `services.hyprpolkitagent` came first, both formerly apt. | controller | Task 3's review |
| 5 | The claim that `Requires=tray.target` meant a tray service "could never start". `Requires=` is an activation dependency; the consumer pulls the target in itself. | controller | final whole-branch review |
| 6 | "It had to be `assertions`" — not derived. `flake.nix` reads the generation from outside it in `no-dangling-home-files` and `gui-desktop-ids`, so a check could have done it. | controller | final whole-branch review |
| 7 | "three places" in the sentence correcting defect 6. It is two; the third hit is a comment describing the first. | controller | the scoped re-review of the fix wave |
| 8 | The close-out check named `index-v0.14.0.db`, which no longer exists under that name after migration. | controller | this document's own verification |
| 9 | "Likely most of why the index is 160 MB", of the blank-id folder. Unsupported. | controller | this document's own verification |
| 10 | Step 1's instruction identified a folder by the attribute that makes it unidentifiable in the GUI. | controller | the user, who could not find it |

**All ten are mine, and all ten are claims rather than code.** No reviewer found
a Critical or Important defect in any `.nix` file this branch wrote; the module,
the assertions, the tray configuration and the quickshell line were approved as
written at every gate. Seven of the ten were caught before merge by an
implementer or a reviewer; three surfaced only when the work met the machine.

The shape is identical in every case: a claim asserted without running the
command that would test it. Defect 7 is the sharpest illustration — it is a
wrong count inside the paragraph correcting a wrong claim, written while the
branch's whole subject was this exact failure. Two implementers refused to
commit text they had disproved, which is the behaviour that kept most of these
out of `main`.

## Guards added

| guard | property | where | proven by |
|---|---|---|---|
| `assertions` entry 1 | `services.syncthing` produces a `syncthing` unit | eval time | `enable = false` fails the build |
| `assertions` entry 2 | it does **not** produce `syncthing-init` | eval time | `guiAddress = "127.0.0.1:8385"` fails the build |

Not a `runCommand` in `home.packages`: those guards inspect a *package*, and a
derivation inside the generation cannot inspect the generation. A `checks` entry
could have — `assertions` wins on frequency, since it runs on every generation
build rather than only under `nix flake check`.

## Known holes, accepted

- **`syncthingtray` is outside `guiPackages`**, because the module installs it
  through its own `home.packages`. `wrappedGuiApps` therefore does not check it.
  It is wrapped today; what is given up is a build failure if a future nixpkgs
  bump drops the wrapper.
- **The blank-id folder stays in `config.xml`**, inert.
- **`~/Sync` no longer syncs with `epiphany`.**
- **`index-v0.14.0.db-migrated` stays** until the user is satisfied. It is 163 MB
  and it is the rollback.
