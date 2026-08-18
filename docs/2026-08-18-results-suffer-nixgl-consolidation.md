# Spec 14 results: the nixGL consolidation, on `suffer`

**Spec:** `docs/superpowers/specs/2026-08-17-nixgl-consolidation-design.md`
**Plan:** `docs/superpowers/plans/2026-08-17-nixgl-consolidation.md`
**Branch:** `nixgl-consolidation`, merged to `main` fast-forward, 15 commits
**Executed:** 2026-08-17, closed out 2026-08-18

---

## What changed

`pkgs.nixgl.nixGLIntel` was spelled out at five sites in `home/`. A helper for
exactly that existed at `home/default.nix:21` with one caller, and two of the
other four carried a body byte-identical to it, hand-written. The cost was never
the duplication: it was that changing the GL wrapper meant moving five places
with nothing reading the fifth.

Now `lib/nixgl.nix` is the only file that names it. It exports `wrap` (a bare
script), `wrapBin` (a package with `bin/<name>`) and `bin` (the raw path, for
the one caller that can use neither). `home/session.nix` keeps its bespoke body
— it prepends `compositorPath` and passes four extra arguments to
`start-hyprland` — and takes `bin`.

`nixglSingleSource` in `home/default.nix` fails the build when the literal
appears anywhere under `home/`. It rides in `home.packages` rather than in
`flake.nix`'s `checks`, because the person who adds a sixth wrapper is editing a
module and building a generation, and may never run `nix flake check`.

Four comment passages were corrected, `home/lf.nix` was fixed so lf-41's
`share/` tree reaches the profile, and apt's `lf` was removed with the five
packages behind it.

## The property, live on `main`

```sh
/usr/bin/grep -rnF '${pkgs.nixgl.nixGLIntel}' home lib
# lib/nixgl.nix:25:  bin = "${pkgs.nixgl.nixGLIntel}/bin/nixGLIntel";
/usr/bin/grep -rn 'nixgl\.\(wrap\|wrapBin\|bin\)' home/*.nix | /usr/bin/grep -cv 'echo '
# 5
```

One definition, five call sites. The `grep -v 'echo '` is not cosmetic: the
guard's own failure message names all three exports so a person reading a broken
build knows what to write, and those two lines answer to the enumeration pattern
without being call sites.

## The switch, and the restart prediction

The spec predicted three store paths would hold and two would move, and that
exactly two units would therefore restart. Measured after the user's switch,
using `ActiveEnterTimestamp` rather than `NRestarts` — sd-switch stops and
starts a unit, which resets that counter:

| unit | ActiveEnterTimestamp | ExecStart |
|---|---|---|
| `quickshell` | Tue 2026-08-18 06:06:51 | `76czdlp8…-quickshell-nixgl` |
| `xdg-desktop-portal-hyprland` | Tue 2026-08-18 06:06:51 | `6hq8sc4v…-xdg-desktop-portal-hyprland-nixgl` |
| `hyprpolkitagent` | Mon 2026-08-17 15:27:47 | `x2h9v7fp…-hyprpolkitagent-nixgl` |

`hyprpolkitagent` did not restart, and its timestamp is from the previous day's
boot. That is the criterion, proven live: an unmoved store path means an unmoved
unit file, which means sd-switch correctly did nothing. Two moved paths prove
the consolidation reached the two hand-written sites; three unmoved ones prove
the helper's body is byte-identical to what the tree wrote before.

`hyprland-nixgl` moved once more, in the lf task, from `rav6aqkh…` to
`m2ahfwdj…`, because `home/session.nix:47` puts `config.calango.lf` in
`compositorPath`. That was checked against the login path before being accepted:
greetd's root-owned `/usr/local/share/wayland-sessions/hyprland-nix.desktop`
names `hyprland-nixgl.desktop` by id and contains zero `/nix/store` references,
so a moved wrapper cannot break login.

## lf

`home/lf.nix` built `lfWrapped` with `writeShellScriptBin`, which produces a
package holding exactly one file. lf-41's whole `share/` tree therefore never
reached the profile, and **apt's `lf` was the only source of lf completions on
this machine** — a fact discovered while writing the spec, not during the
removal. Replacing it with a `symlinkJoin` plus `wrapProgram` keeps the tree and
the `PATH`.

Live, after the switch and the removal:

```sh
readlink -f ~/.nix-profile/bin/lf
# /nix/store/zb9rclgvl64n007p97irld06ia6x8bls-lf-wrapped/bin/lf
man -w lf
# /nix/store/ph6b79ayda4y8bjj20bsk35rbijf1i2i-lf-41/share/man/man1/lf.1.gz
```

Files present is not completion working, so the loader was tested rather than
inferred:

```sh
bash -lic '. /usr/share/bash-completion/bash_completion; _comp_load lf; complete -p lf'
# complete -o filenames -F _lf lf
```

Note the file is `share/bash-completion/completions/lf.bash`, not `…/lf`. A
first check looked for the un-suffixed name, found nothing, and briefly read as
a missing completion.

## The removal

Six packages went: `lf`, and `ueberzug`, `libxres1`, `python3-attr`,
`python3-docopt`, `python3-xlib` behind it. They formed a closed chain — only
`lf` needed `ueberzug`, and only `ueberzug` needed the other four. This
repository's `lf/preview` calls `chafa`, `kitty` and `sixel`, never `ueberzug`.

`ueberzug` is a Python program, so its absence could not be established by a
`/proc` walk. The union instrument — `maps` and `exe` unioned with the first
field of `ps -eo args` for every process, 1495 unique paths — returned zero held
files for all six.

Afterwards:

```
autoremove proposes : 0     -- spec 12's endpoint survives
rc packages         : 147   -- unchanged
dangling user links : 0
```

`dpkg-query` finds no trace of any of the six: not `ii`, not `rc`, not `un`.
The `rc` reading did not move at all, which is the cleanest illustration yet of
`CLAUDE.md`'s rule that **`rc` is not a running total of what has been
removed** — six packages left and the number stood still, because none carried
conffiles. Spec 13 removed two and moved it by two; that agreement was the
coincidence, not the rule.

---

## Defects, and their owners

Every one of these was found by a check, a reviewer or an implementer refusing
to write down something it had disproved. None reached `main` uncorrected.

| # | defect | owner | how it was caught |
|---|---|---|---|
| 1 | `grep` here is a ugrep-backed shell function returning `0` for a pattern containing `${`, even on a file that holds it. The spec published a command whose stated output was `5`; run as written it printed nothing. | controller | Task 1's implementer, whose expected `1` came back `0` |
| 2 | Task 3's "activation store path is unchanged" invariant was false. Task 2's guard takes all of `home/` as an input, so a comment moves the path. | controller | Task 3's implementer, which declined to commit a message asserting it |
| 3 | The `wrapProgram --prefix` entry written into `CLAUDE.md` inverted its own conclusion: the script lines are reversed, the effective `PATH` is not. | controller | final whole-branch review, which ran the second command |
| 4 | `home/default.nix` said the wrapped things are "the session and four units". Three units wrap themselves; the fifth is `hyprlock`, which hypridle's `lock_cmd` launches. | controller | final whole-branch review |
| 5 | Two passages in `home/gui-apps.nix` cited "the gammastep comment above" for schema-centric reasoning that comment no longer contained. | pre-existing, exposed by Task 3 | Task 3's review, reading past its own scope |
| 6 | The flatpak entry read "One Home Manager-managed file among them…", meaning "were one managed" — asserting a managed file that does not exist. | controller | Task 5's reviewer, which reported the non-existent file as live state |
| 7 | `CLAUDE.md` hardcoded five `file:line` call sites, against the file's own rule to enumerate by syntax. | controller | final whole-branch review |
| 8 | `lib/nixgl.nix`'s header said the guard "fails the build if a sixth appears", over-stating a guard that only reads `home/` and does not distinguish a call site from a comment. | controller | final whole-branch review |

**Seven of the eight are mine, and six are documentation.** The code was sound at
every task review; the reviewers found no Critical or Important defect in any
`.nix` file this branch wrote. What kept going wrong was the sentence next to the
measurement.

Defect 3 is the one worth keeping. The section of `CLAUDE.md` it landed in
exists to catalogue exactly this — a real command, real output, and a conclusion
the output does not license — and the entry was itself an instance of it. I read
`grep '^PATH='` on the generated wrapper, saw `coreutils, glib, xdg-utils, file`
where `lfPath` declares `file, xdg-utils, glib, coreutils`, and wrote that a
name collision would resolve backwards. Evaluating the blocks shows the
effective `PATH` is the declared order, because each block prepends and the last
applied ends up leftmost. The reversal cancels itself. The entry now documents
the trap and its own instance of the trap.

Defect 2 is the second worth keeping, for a different reason: it is a
cross-task interaction that the pre-flight scan looked straight at. The scan's
T2→T3 row said "Clean" on the strength of the ordering being right. Ordering was
not the question.

## Guards added

| guard | property | where | proven by |
|---|---|---|---|
| `nixglSingleSource` leak branch | no file under `home/` names the wrapper directly | `home.packages` | a real wrapper site added to `home/foot.nix`, build failed |
| `nixglSingleSource` vacuity branch | `lib/nixgl.nix` still names it, so the leak branch means something | `home.packages` | `bin` replaced with `/usr/bin/true`, build failed |

Each mutation was confirmed by a count before its build ran, and each modified a
**tracked** file — a flake build of a dirty tree does not see untracked
additions, so an untracked-file mutation would prove nothing while appearing to
pass.

The needle is built as `"$" + "{pkgs.nixgl.nixGLIntel}"`. Written plainly, Nix
interpolates it and the guard hunts an expanded store path no source file
contains, passing for ever; written with a backslash escape, the guard's own
source contains the needle and it fails for ever. Both fail silently, in
opposite directions.

## Known holes, accepted

- **The guard reads `home/` only.** A wrapper written into `flake.nix`, or into
  a second file in `lib/`, would escape it. Widening it is not free: the guard's
  failure message names the three exports, so a guard that read its own module
  would match itself. Recorded in `lib/nixgl.nix`'s header.
- **The guard does not distinguish a call site from a comment.** A comment
  containing the literal fails the build. Also recorded.
- **`--force-nixgl`** — letting `start-hyprland` do its own nixGL handling and
  dropping the flake's `nixgl` input — remains the tidier end state and remains
  unproven here. Not re-opened.
