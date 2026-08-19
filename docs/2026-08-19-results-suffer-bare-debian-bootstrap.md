# Spec 18 results: a bootstrap from bare Debian 13, rehearsed in qemu

**Spec:** `docs/superpowers/specs/2026-08-19-bare-debian-bootstrap-design.md`
**Plan:** `docs/superpowers/plans/2026-08-19-bare-debian-bootstrap.md`
**Branch:** `bare-debian-bootstrap`, 26 commits over `main` at `cb53d9b`
**Executed:** 2026-08-19. Six tasks on suffer, then one rehearsal in a VM.

---

## What changed

Seventeen specs had moved this machine from apt to Nix and none of them could be
run forwards on a new one. The knowledge sat in three places, and the worst of
them was `/etc/greetd/config.toml`: `calango-desktop`'s reference copy, comments
and all, naming `../install.sh` in its own header. The file deciding whether this
machine can log in was defined by a repository the README says is not an input to
this build.

`home/bootstrap.nix` now declares that content, four deb822 apt sources carrying
inline keys, the Stage A package list, the corp package list and the group list.
It renders one store directory holding the greetd file, the sources, and a
`RUNBOOK.md` generated from the same option values — so the prose and the flake
cannot disagree. A non-fatal activation hook reports where live `/etc` has
drifted. A new flake check requires a `hypr/hosts/<name>.lua` for every
configured host.

| artifact | what it is |
|---|---|
| `packages.x86_64-linux.calangoBootstrap` | the rendered tree: greetd config, 4 apt sources, `RUNBOOK.md` |
| `checks…host-config-files` | fifth check; a configured host with no `hosts/` file fails the build |
| `home.activation.bootstrapDrift` | three subjects, ABSENT and DIFFERS distinguished, non-fatal |
| `test/apt-sources.sh` | fetches `InRelease` per source; fails on a bad key **and** on an unreachable host |

## The rehearsal, and why it was not optional

The branch passed six task reviews, a whole-branch review and a scoped
re-review before a single line of it had run on a bare machine. Then it ran, and
**it broke three times.** Every one of those breakages was in something a
reviewer had read and approved.

A preseeded Debian 13.6 netinst in qemu with KVM, `-vga none -device
virtio-gpu-gl-pci -display egl-headless,gl=on`, driven over ssh. The preseed
sets a root password **deliberately**, because Debian then leaves the first user
out of `sudo` — the machine class the runbook's own Stage A paragraph describes.
Predictions were written to a file before any of it ran.

### Finding 1 — `sudo` was missing from `packages.base`

Predicted, then measured. Stage A added the user to the `sudo` group and Stage C
died at its first command:

```
sudo install -Dm644 ...    -> bash: sudo: command not found   exit 127
sudo usermod -aG sudo ...  -> bash: sudo: command not found   exit 127
```

The remedy the runbook offered failed for the same reason as the thing it was
meant to fix. `sudo` is `Priority: optional`; adding a group membership without
the binary fixes nothing.

**This was residual R1 of the final review, parked on the reviewer's judgement
that it did not block. One real machine disproved that judgement.**

### Finding 2 — the scaffolding collision is an apt ERROR, not a warning

The spec, the module comment and the runbook all said the scaffolding files
become "a duplicate source apt warns about", to be deleted at the end of the
stage. What actually happens, mid-stage:

```
   != /usr/share/keyrings/google-chrome.gpg
E: The list of sources could not be read.
```

Chrome's `postinst` writes its own source file naming a keyring, where the
scaffolding file carries an inline key. apt treats one repository reached
through two different `Signed-By` values as an error and then **refuses to read
any source at all** — so the next two `apt install` commands returned exit 100
and nothing further in the stage could run. The deletion moved to immediately
after the corp packages install.

**No review could have found this.** It needs a machine where the vendor's own
maintainer script actually runs.

### Finding 3 — only two of four vendors replace their source file

The fix for finding 2 was then wrong in the other direction. Deleting all four
scaffolding files leaves `code` and `endpoint-verification` installed with no
candidate version at all:

```
1password              candidate-from=https://downloads.1password.com/...
google-chrome-stable   candidate-from=https://dl.google.com/...
code                   candidate-from=(none)     and ships no sources file
endpoint-verification   candidate-from=(none)     and ships no sources file
```

So the four files are two classes. `calango.bootstrap.aptSourcesTransient` names
the two the vendor replaces, with the reason beside each and an assertion that
refuses a name `aptSources` does not define. The runbook derives both the `rm`
command and the keep list; neither is written by hand.

### Finding 4 — `fuse3` was missing too

A clean bootstrap ended with one failed unit. Proven by cause, not correlation:

```
xdg-document-portal.service   code=exited status=6      (fuse3 absent)
apt-get install fuse3 ; systemctl --user start ...  ->  active
```

`xdg-desktop-portal` mounts its document store through `fusermount3`. `fuse3` is
installed on suffer for historical reasons, **which is exactly how a list
derived from that machine came to omit it** — the second instance of the
hypothesis `home/bootstrap.nix` labels itself with.

### Finding 5 — `home-manager` is not on `PATH` after the first switch

`~/.nix-profile/bin/home-manager` answers `--version` by full path while a login
shell reports it absent. This flake manages no shell initialisation, so nothing
sources `hm-session-vars.sh`. Stage D now says so and gives the full-path form,
because a second switch is the very next thing a reader does.

## What the rehearsal confirmed

| claim | measured |
|---|---|
| Gate A's socket note | `nix-daemon.service` active, `nix-daemon.socket` **inactive** on a working install |
| ordering constraint 4 | the metapackage before the corp packages: exit 100, all seven named "not installable", nothing installed |
| no `/etc/default/slack` prompt | the file did not exist; **0** conffile prompts; both knobs land `"false"` |
| the per-host guard | fired on the real new host `debian`, naming it, with the passing row for `suffer` beside it |
| the drift hook | DIFFERS and ABSENT both fired against the **real root-owned** file, distinguishably; silent once the declaration matched |
| `pgrep -x .Hyprland-wrapp` | matches (962); `pgrep -x Hyprland` matches **nothing** — the documented truncation, confirmed |
| the nixGL mechanism | 5 of 5 variables in the compositor's `environ` |
| hardware GL | `libgallium` 6, `swiftshader` 0 in its maps |
| `bootstrapDir` reproducibility | identical store path on suffer and in the VM |

### Final state in the VM

```
compositor          : hyprland-0.55.4 under nixGLIntel, 5 of 5 variables
GL path             : libgallium=6  swiftshader=0
failed user units   : 0
calango-desktop     : ii
autoremove proposes : 0
session entry       : /usr/share/wayland-sessions/hyprland-nix.desktop present
greetd conffile     : ??5?????? c  (modified, as designed)
apt sources         : 2 vendor-written + 2 durable scaffolding
tray host           : 2 StatusNotifier names on the session bus
```

## Defects, and their owners

| # | defect | owner | how it was caught |
|---|---|---|---|
| 1 | A `pkgs.writeText` output in `home.packages`; `buildEnv` refuses a single-file store path | controller | pre-flight, by measurement |
| 2 | `substituteInPlace` cannot carry a value containing an apostrophe; four reason strings have one | controller | pre-flight, by measurement |
| 3 | The duplicate-attribute constraint I wrote at pre-flight was over-general — true for a static path, false for a computed key | controller | Task 2's implementer |
| 4 | `git checkout` on a staged file silently reverts nothing | controller | Task 2's implementer |
| 5 | `git restore --staged --worktree` **deletes** a file new to its task; it cost a 232-line hand-recreation | controller | Task 3's implementer |
| 6 | The same command destroys uncommitted work, which read as an activation hook never having run | controller | Task 4's implementer |
| 7 | The check code used `lib.*` in `flake.nix`, which had no `lib` binding at all | controller | Task 5's implementer |
| 8 | Stage C's heading sent the reader into a shell where `$B` was undefined | controller | Task 3's implementer, reproduced by its reviewer |
| 9 | `home/session.nix` asserted P and not-P seven lines apart — created by the task that was fixing stale prose | controller | Task 6's implementer |
| 10 | `test/apt-sources.sh` reported success for an unreachable repository, and `keys/README.md` cited it as the reason not to verify fingerprints | controller | final review |
| 11 | `CLAUDE.md` claimed the session-path guard covered every `wayland-sessions` entry; it reads one of two shipping mechanisms in the same module | controller | final review |
| 12 | `README.md`'s Bootstrap section could not be run: no clone, no `cd`, and "five commands" above six | controller | final review |
| 13 | The file-only filter and the count "Five" were hardcoded in a file whose header says it cannot disagree with the flake | controller | final review |
| 14 | `home.packages = [ bootstrapDir ]` was redundant and put `etc/greetd` and `RUNBOOK.md` into the profile | controller | final review |
| 15 | **`sudo` missing from `packages.base`** | controller | **the rehearsal** |
| 16 | **The scaffolding collision is an apt error, and the deletion was in the wrong place** | controller | **the rehearsal** |
| 17 | **Only two of four vendors replace their source file; deleting the other two strands two packages** | controller | **the rehearsal** |
| 18 | **`fuse3` missing from `packages.base`** | controller | **the rehearsal** |
| 19 | **`home-manager` not on `PATH` after the first switch** | controller | **the rehearsal** |

**Nineteen defects, all mine, none in the `.nix` or shell code as implemented.**
No reviewer rejected an implementation. What failed, nineteen times, was a claim
about a mechanism — and five of those claims survived every review and were
killed by one machine.

Defects 3 through 6 share one root that took four incidents to find: `git
restore`'s `--source` defaults to the **index** with `--worktree` alone and to
**HEAD** as soon as `--staged` is added. The entry was rewritten three times as
a list of cases before anyone looked up the mechanism.

## Guards added

| guard | property | where | proven by |
|---|---|---|---|
| session-path agreement | every `calango.deb.files` entry under `wayland-sessions/` sits in a directory `--sessions` names | `assertions` | moving the entry to `/opt` |
| `greetdConfig` non-empty | vacuity anchor | `assertions` | forcing `""` |
| `groups` non-empty | vacuity anchor | `assertions` | forcing `[ ]` |
| a session entry exists | vacuity anchor for the guard above | `assertions` | shipping no entry |
| transient names are real | a typo would leave a colliding source in place | `assertions` | naming a file `aptSources` lacks |
| `noStorePathsInEtc` | no file under `etc/` names the store | an **input** of `bootstrapDir` | a store path in the greetd file; **both** build targets fail on the same derivation |
| runbook tokens | none survives, and none is deleted from the template | builder + `lib.hasInfix` throw | `@nosuchtoken@`; deleting `@groupsCount@` |
| `host-config-files` | every configured host has a `hosts/` file | `checks` | **the real new host `debian`**, and an emptied `hostConfigs` |
| `bootstrapDrift` | live `/etc` agrees with the declaration | activation hook | five mutations, two of them against the **real** root-owned file |

## Known limitations, accepted

- **No window was ever looked at.** This session has no display. The compositor
  was judged from `/proc/<pid>/environ`, `/proc/<pid>/maps`, unit state and the
  journal. `CLAUDE.md` says the instrument for the per-application GL question
  is one person and one window, and that instrument was not available.
- **The Intel GL path is untested.** The VM proves the nixGL *mechanism* through
  mesa's `virtio_gpu` driver on the virgl path. `iris` and `intel-media-driver`
  are untested by it.
- **The session's `Type` reads `tty`, not `wayland`**, because the login was
  driven by greetd's `initial_session` rather than by a human at the greeter.
  suffer reports `wayland`. Gate D's expectation is unproven for that reason and
  not because of anything the flake does.
- **Four harness deviations, all recorded:** `-y` on apt, `NOPASSWD` sudo for
  the unattended run, greetd `initial_session` autologin, and `ssh-server` in
  the preseed's task list.
- **The four flake checks that predate this branch still read
  `suffer.activationPackage` by name**, so the new host's generation is checked
  by none of them. `host-config-files` is the only host-general one.
- **Three residuals from the final review remain parked**, and one of them —
  Stage A's `sudo` availability — is what finding 15 turned out to be. The other
  two are `README.md`'s SSH clone and `system/README.md`'s stale `## Undo, in
  full` block.

## Instruments that lied, for the record

Four of my own tools failed during the rehearsal, all in this project's
established species:

- **`pgrep -f '<pattern>'` matched the waiting shell's own command line**, so a
  wait loop never exited and a boot never launched.
- **`pkill -f '<pattern>'` killed the shell running it** — exit 144, and a
  cleanup that silently did nothing.
- **`pgrep -x qemu-system-x86_64` matched nothing**: `comm` truncates at 15
  characters. The same trap `CLAUDE.md` records for `.Hyprland-wrapp`, met on a
  non-Nix binary.
- **`nc -z 127.0.0.1 2222` reported the port open** while the guest's sshd was
  unreachable: qemu's slirp accepts on the host side regardless.

And one harness mistake worth naming because it produced a convincing false
failure: with qemu's default VGA left in place beside `virtio-gpu-gl-pci`,
Hyprland picked the bochs device (`pci id 1234:1111, driver (null)`) and crashed
in pixman. That read exactly like a flake defect. `-vga none` fixed it.
