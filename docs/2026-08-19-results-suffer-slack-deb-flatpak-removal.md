# Spec 17 results: Slack to a standalone `.deb`, and flatpak out, on `suffer`

**Spec:** `docs/superpowers/specs/2026-08-18-slack-deb-flatpak-removal-design.md`
**Plan:** `docs/superpowers/plans/2026-08-18-slack-deb-flatpak-removal.md`
**Branch:** `slack-deb-flatpak-removal`, merged to `main` as `27a5f98`, 11 commits,
plus `05f69a4` on `main` afterwards
**Executed and closed out:** 2026-08-19

---

## What changed

Slack was the one member of the corp set that `CLAUDE.md` called "permanently
apt" while not being on apt at all. It was a flatpak, and the last one. It now
comes from Slack's own standalone `.deb`, and flatpak is gone root and branch.

Unusually for this project, **apt was the freshest source and Nix the stalest**:
4.51.180 upstream against nixpkgs' unfree 4.49.89. So this is not a migration
*to* Nix; it is the corp-set rule finally being true of its last exception.

The flake gained one capability on the way. `lib/deb.nix` could only make a
conffile out of a ufw profile, because the ufw profiles were the only `/etc`
payload it had ever had. It now derives `DEBIAN/conffiles` from **every**
`calango.deb.files` key beginning `etc/`, by path syntax, which is what lets
`calango-desktop` own `/etc/default/slack` — the file this whole spec turns on.

| declaration | mechanism | enforced by |
|---|---|---|
| `slack-desktop` kept | `Depends:` | apt cannot autoremove a dependency of a manual package |
| `flatpak`, `flatseal` banned | `Conflicts:` | apt removed both when the metapackage was installed |
| `/etc/default/slack` | conffile in the package | dpkg, which prompts rather than clobbering a local edit |
| staleness reported | `bin/slack-latest` | a human, on demand; no network in a build or a switch |

## The property, live

```sh
dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' \
  slack-desktop calango-desktop flatpak flatseal
# ii  slack-desktop 4.51.180
# ii  calango-desktop 0.273
# rc  flatpak 1.16.6-1~deb13u1
# un  flatseal

dpkg -S /etc/default/slack
# calango-desktop: /etc/default/slack        <- owned; it was unowned before
cat /etc/default/slack
# repo_add_once="false"
# repo_reenable_on_distupgrade="false"
dpkg -V calango-desktop
#                                           <- silent: the prompt was answered Y

dpkg-query -W -f='${Conffiles}\n' calango-desktop
# /etc/ufw/applications.d/calango 2e75f2e1…
# /etc/default/slack 710ad775…               <- the new derivation, no extra declaration

xdg-mime query default x-scheme-handler/slack
# slack.desktop                              <- was com.slack.Slack.desktop

slack-latest
# slack-desktop 4.51.180 is current (upstream 4.51.180)
```

```
keep set            : 22 declared, 22 of 22 auto, verified one at a time
calango-desktop     : still apt-mark manual (or all 22 orphan at once)
autoremove proposes : 0
rc packages         : 151   (150 before)
dangling user links : 0
manual total        : 348   (349 before AND after the migration; see defect 5)
flatpak             : binary absent, /var/lib/flatpak gone, no units, no /etc residue
reclaimed           : 1.7 G + 711 M + 822 M + 104 K
nix flake check     : 4 checks, exit 0
calangoDeb          : builds, bit-reproducible, 0 store paths in the manifest
```

## The step that nearly undid the whole spec

`/etc/default/slack` already existed, owned by no package, carrying
`repo_reenable_on_distupgrade="true"`. The new package ships that same path as a
conffile with both knobs `"false"`. So installing it **prompts**:

```
*** slack (Y/I/N/O/D/Z) [default=N] ?
```

**dpkg's default is `N` — keep the existing armed file.** Press Enter and you
get a package that installed cleanly, the exact apt transaction the plan
predicted, and a cron job that goes on recreating a retired packagecloud repo
and its two signing keys every day. Nothing fails. Nothing warns. The one
mechanism `home/slack.nix` calls the load-bearing part of the spec is simply off.

Neither the spec nor the plan mentioned the prompt until the final whole-branch
review measured it in a scratch root. Same species as the `deb-systemd-helper`
trap already in `CLAUDE.md` — a `rm` that a maintainer's own automation
undoes — except the automation here is cron, and the trap is armed by *accepting
a default* rather than by doing anything.

Detection is `dpkg -V calango-desktop` printing `??5?????? c /etc/default/slack`.
Recovery is `sudo mv /etc/default/slack.dpkg-dist /etc/default/slack` and
**never** a deletion: with the file absent, the cron job recreates it with both
knobs `"true"` and writes `slack.list` active.

## Defects, and their owners

| # | defect | owner | how it was caught |
|---|---|---|---|
| 1 | **The dpkg conffile prompt, undocumented, default answer disables the spec.** Above. | controller | final whole-branch review, by reproducing the install in a scratch root |
| 2 | **`/etc/cron.daily/google-chrome` was cited as "the identical script" and as the control proving the knob reading. It is a later revision** in which `install_key` runs unconditionally before any knob test, with no `install_new_key`, `update_bad_sources` or `handle_distro_upgrade` — 4 of 9 function names shared. Under it, both knobs `"false"` would still write the keyring, so the control corroborated nothing. Read correctly it is a warning that upstream has already moved this script in the one direction that breaks the approach. | controller | final whole-branch review; the wrong claim had been reached from a `readlink` confirming the file exists |
| 3 | **The GL check this project published could not fail.** `grep -cE 'swiftshader\|libEGL_mesa\|iris_dri'` over `/proc/<pid>/maps` returns `0` for the hardware path *and* for software. Not because the files are missing — the pinned mesa ships 61 `*_dri.so` — but because they are aliases: `iris_dri.so` is a symlink to `libdril_dri.so`, so the loader mmaps the real object and `maps` names *that*, never the alias. | controller | running the branch's own verification after the migration, against a known-good case |
| 4 | **The recovery command written to fix defect 1 was inoperable and destructive.** `sudo rm -f /etc/default/slack && sudo apt install --reinstall calango-desktop` — the package has no repository, so apt refuses, the `rm` has already run, and the machine is left in the state this document calls the worst available. | controller | the scoped re-review of the fix wave |
| 5 | **`CLAUDE.md`'s "there is no longer a file outside `$HOME` that no package owns" was false**, by 182 dpkg-unowned files under `/etc` alone — and that figure is a floor, since unprivileged `find` cannot descend six directories. Most are legitimately unowned; what was wrong was stating a survey of *this project's* files as a survey of the filesystem. | controller | spec writing, then the final review for the floor |
| 6 | **`installed=${status#ii }` strips a fixed three-character prefix from a field whose own third column is a space**, so an `ii` version arrived with a leading space. The `ii`/"is current" branch had never been exercised at all. | controller | Task 2's reviewer, which noticed the doubled space in the implementer's own quoted output |
| 7 | **`xdg-mime query default` does not report what `mimeapps.list` says.** It skips a `[Default Applications]` entry whose `.desktop` id does not exist and falls through — here to `mimeinfo.cache`, where flatpak's export had registered the scheme from its own `MimeType=`. So `x-scheme-handler/slack` was never a dead association: `xdg-open slack:` opened flatpak Slack, and the `mimeappsIds` hook's message "handlers for them will do nothing" is wrong for that id. | controller | Task 4's implementer, from an unexpected Step 9 reading; mechanism traced further by the controller |
| 8 | **"`flatseal` and `fresh-editor` stay on apt" was half false** — flatseal does not stay. | controller | plan writing, after the spec had already been approved |
| 9 | **`lib/deb.nix`'s heading `Refused, because the Nix side owns them now:` contradicted two of its own 21 entries**, and `apt show` renders it. | controller | final whole-branch review |
| 10 | **A shipped reason string said `apt remove flatpak` "took `calango-desktop` and all 22 keeps with it".** It removes three packages and *orphans* 22 — different events separated by an `autoremove`, a distinction this project has a whole section about. | controller | final whole-branch review |
| 11 | **`4.51.180` was stated as a bare fact** in a file whose thesis is that a claim carries its command. The number was right and had been measured twice; only the citation was missing. | controller | Task 4's reviewer |
| 12 | **The plan's step 1 could not be run as written.** It opens with `slack-latest`, which reaches `PATH` only after a `home-manager switch` — the plan's step 8. | controller | writing the hand-over runbook, after the branch had merged |
| 13 | Smaller claim defects: a mutation count stated as 2 when it is 7; a `CLAUDE.md` headline re-tensed *forward* to "at least one dead association" while two ids still resolved to nothing; a correction count that disagreed across spec, plan and what shipped. | controller | implementers and reviewers, one each |

**Thirteen entries, every one a claim, none in the `.nix` or shell code.** No
reviewer found a Critical or Important defect in `lib/deb.nix`, `home/slack.nix`,
`bin/slack-latest`, the `home/deb.nix` changes or the flake wiring; all were
approved as written under independent re-measurement. What failed, thirteen
times, was the sentence beside the measurement.

That is the same distribution as spec 16's eleven, which stops it being a
coincidence and makes it the argument for the review discipline.

**Defect 3 is the one worth keeping.** This file's opening rule is to prove a
check can fail before trusting it, and its closing section enumerates three
earlier checks that passed while the property was false. What is new is *where*
this one lived: the others were written in a spec and caught by a reviewer or a
mutation. This one was written in `CLAUDE.md` — and `CLAUDE.md` is what spec 17
copied it from, into a plan, into a runbook, and into a terminal, before anyone
ran it against a case whose answer was already known. A rule being documented is
not a rule being followed; an instrument being documented is not an instrument
being tested.

**Defect 1 is second**, and for the reason spec 16's defect 9 was second: every
other defect here stayed inside a document. That one would have shipped into the
running machine, silently, by way of the most natural keystroke available.

## The GL answer, since it was open from spec 13

Slack draws through **Nix's mesa 26.1.5**, hardware, not software:

```sh
GPU=$(pgrep -f 'slack --type=gpu-process')
grep -cE 'swiftshader|libEGL_mesa|iris_dri' /proc/$GPU/maps   # 0   <- the stale pattern
grep -c  'libgallium'                       /proc/$GPU/maps   # 6   <- the real signal
grep -oE '/nix/store/[^ ]*mesa[^ ]*' /proc/$GPU/maps | sort -u
# …-mesa-26.1.5/lib/libgallium-26.1.5.so
```

with `libxcb-dri3` corroborating and 101 store mappings in that process. The
session's five nixGL variables are inherited by a host Slack and now *resolve*,
because there is no sandbox to hide the store from them — which is the same
inheritance that broke Slack **as a flatpak** and required a per-application
`--unset-env` override. The override is moot; the inheritance is not, and must
not be scrubbed.

`signal-desktop` and `bitwarden` remain unmeasured. They are now measurable with
the corrected instrument, which they were not before.

## Guards added

| guard | property | where | proven by |
|---|---|---|---|
| `/etc` ⊆ conffiles | every `/etc` payload path is listed in `DEBIAN/conffiles` | `lib/deb.nix` `buildCommand` | a `files` entry excluded from the derivation while still shipping; guard fires naming the path |
| no conffiles file | `/etc` payload with no `DEBIAN/conffiles` at all | same | forcing the emission off |
| `/etc` non-empty | the vacuity anchor | same | a fixture with `ufwProfiles` and `files` both empty |
| `@token@` residue | the helper ships no unsubstituted token | `home.packages` | dropping one substitution from the Nix side |

The check is inside `buildCommand` rather than in `guards`, and that is forced:
`guards` are *inputs* to the deb derivation, so a guard cannot inspect the
artifact it gates. Being the same derivation, it runs on `nix build .#calangoDeb`
and on the activation build alike — which is precisely spec 16's defect 10.

Each mutation was confirmed present with `/usr/bin/grep` **before** its build was
read as evidence, because spec 16 had two mutations that turned a build red
without ever reaching the guard.

And the reverse direction needs no guard: `dpkg-deb --build` errors with
`conffile '/etc/absent' does not appear in package` and exit 2, three lines
below, in the same builder.

## Known limitations, accepted

- **707 MB and 14 MB of reclaimable residue remain.**
  `~/.config/Slack.flatpak-backup` is the pre-migration profile, kept
  deliberately until Slack was proven and now removable. `~/.var/app` still
  holds data for **seven** flatpaks — `com.google.Chrome`,
  `com.google.ChromeDev`, `io.github.ungoogled_software.ungoogled_chromium`,
  `io.gitlab.librewolf-community`, `org.chromium.Chromium`,
  `org.gnome.Snapshot`, `org.mozilla.firefox` — none installed, and now
  unrunnable, since flatpak is gone. The runbook named only Slack's directory.
  Same shape as the seven orphaned `flatpak override` files this flake
  deliberately never owned. Enumerate with `ls -1 ~/.var/app`: this sentence
  first said "six" and omitted librewolf, which is the reason to run the
  command rather than read the sentence.
- **The installed 4.51.180's `/etc/cron.daily/slack` has not been read.** The
  knob trace in `CLAUDE.md` and in `home/slack.nix` is scoped to 4.50.143's
  copy, the one that was on disk. Defect 2 is the reason this matters: upstream
  has already moved this script once. Re-read it after each Slack upgrade;
  `sudo /etc/cron.daily/slack` followed by checking nothing reappeared is the
  empirical backstop and does not depend on reading it at all.
- **`eu.calangotech.KBrowserSelector.desktop` is still a dead id**, and whether
  the `mimeappsIds` hook's message overstates for *it* the way defect 7 shows it
  does for `slack.desktop` is **unmeasured**. The hook's code was deliberately
  left alone: correcting an activation hook's behaviour inside a documentation
  task would have shipped an unreviewed change.
- **The `apt-mark showmanual` total cannot be reconciled across the migration.**
  It read 349 before and 349 after while the composition changed —
  `slack-desktop` arrived `manual` from a file install, two installed packages
  left — and apt prunes `/var/lib/apt/extended_states` on removal, so a removed
  package's former mark is unrecoverable. Flipping `slack-desktop` to `auto`
  afterwards moved it to 348, and *that* single change is attributable because
  it was watched. A count that agrees is not a count that did not move.
- **`slack-desktop` has no upgrade path.** No repository stands behind it, so
  `apt upgrade` will never mention it. `bin/slack-latest` asks Slack's feed and
  prints the two commands; a human runs them. That is the real cost of the move
  and it was accepted when the move was decided.
- **Removing the metapackage is still a 22-package operation**, and the
  membership changed rather than shrank: `flatseal` left, `slack-desktop`
  arrived. `apt-mark showmanual calango-desktop` remains the check that matters
  before trusting any of it.
