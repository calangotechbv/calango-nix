# nixGL Consolidation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the five nixGL wrapper sites one shared source, guard the property so a sixth cannot appear silently, and correct three passages in the tree that assert things later measurements retired.

**Architecture:** A new plain Nix file `lib/nixgl.nix` exports `wrap`, `wrapBin` and `bin`. Four of the five sites adopt a function; `home/session.nix` keeps its bespoke body and takes `bin`. A `runCommand` in `home.packages` then fails the build if `${pkgs.nixgl.nixGLIntel}` appears anywhere under `home/`. Three of the five wrapper store paths are byte-identical afterwards and two move, and those exact hashes are the acceptance test.

**Tech Stack:** Nix flakes, standalone Home Manager `release-26.05`, nixpkgs `nixos-26.05`, `pkgs.nixgl` overlay, `pkgs.symlinkJoin` + `makeWrapper`.

**Spec:** `docs/superpowers/specs/2026-08-17-nixgl-consolidation-design.md`

## Global Constraints

- Wrap **every** `nix` and `home-manager` invocation: `sg nix-users -c 'nix build ...'`. A bare call fails on the daemon socket directory and reads as a broken Nix install.
- Never read a package version from `nixpkgs#<pkg>`. That is the flake registry, not this flake's pinned input. Use `nix eval --raw .#homeConfigurations."isutton@suffer".pkgs.<name>.version`.
- **No agent runs any of these.** `home-manager switch`; any mutating `apt`, `apt-get`, `dpkg`, `apt-mark` or `flatpak` command; `systemctl` with `start`, `stop`, `restart`, `enable`, `disable` or `daemon-reload`; `reboot`; `fusermount`; the activation script without `DRY_RUN=1`. The user runs all of them.
- Do not modify `~/.config/mimeapps.list`.
- No path containing `.superpowers/` may appear in any committed file.
- A Nix builder runs with `set -e` and `pipefail`. Put every `grep` in a **condition** (`if grep -q … ; then`), never in a bare assignment: `n="$(grep -c … )"` aborts the build before any message prints.
- **Prove every guard by mutation, and confirm the mutation by a count before the build runs.** Three checks in this project passed while the property they stood for was false.
- **Ask what else answers to the needle.** A guard that greps for a string can be satisfied by the tree's own prose, or by the guard's own source.
- **`grep` in this shell is not GNU grep.** It is a shell function backed by ugrep, and it silently returns `0` for a pattern containing `${` even on a file that provably holds it. Measured during Task 1: `grep -c '${pkgs.nixgl.nixGLIntel}' lib/nixgl.nix` reports `0` where `/usr/bin/grep -cF` reports `1`. Every count in this plan that searches for a literal therefore calls `/usr/bin/grep -F` explicitly. Do not "simplify" one back to a bare `grep`: the failure is silent and reads as the property holding.
- Build with `sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage'`.
- Commit after each task. Do not squash tasks together.

---

## File Structure

| file | responsibility | task |
|---|---|---|
| `lib/nixgl.nix` | **new.** The only place naming `pkgs.nixgl.nixGLIntel`. Exports `bin`, `wrap`, `wrapBin`. | 1 |
| `home/default.nix` | imports the helper; builds `hyprpolkitagent-nixgl`; carries the guard and the corrected unit-versus-application comment | 1, 2 |
| `home/quickshell.nix` | adopts `wrap` | 1 |
| `home/portals.nix` | adopts `wrap` | 1 |
| `home/hyprland.nix` | adopts `wrapBin` | 1 |
| `home/session.nix` | keeps its bespoke body, takes `bin` | 1 |
| `home/gui-apps.nix` | two comment passages corrected | 3 |
| `home/lf.nix` | `lfWrapped` becomes a `symlinkJoin` so lf-41's `share/` survives | 4 |
| `CLAUDE.md` | the flatpak override rule, the gammastep-indicator finding, the new guard in the guard enumeration | 5 |

---

## The store paths this plan is measured against

Captured from the running generation on 2026-08-17, before any edit:

| wrapper | path today | after |
|---|---|---|
| `hyprpolkitagent-nixgl` inner script | `9ayhrdmccrhirg1rbiv67iqjb9kyyrlc-hyprpolkitagent` | **unchanged** |
| `hyprpolkitagent-nixgl` runCommand | `x2h9v7fppkfwy34djl02c28hmb2y53rq-hyprpolkitagent-nixgl` | **unchanged** |
| `hyprlock` | `7kwkl1i594z75hqj8dfp4xbp2z31f1wr-hyprlock` | **unchanged** |
| `hyprland-nixgl` | `rav6aqkhg43lhdzyvkfmsrhxlk0z6qzh-hyprland-nixgl` | **unchanged** |
| `quickshell-nixgl` | `zzn9z2lgx7wv3vvfzjgiyxg5sqyagdfp-quickshell-nixgl` | `76czdlp8mv4x8ynvz5xxbvbf6kf2p6g3-quickshell-nixgl` |
| `xdg-desktop-portal-hyprland-nixgl` | `h7jyg8d29m4a0l8yrw822nlhv72wdhrh-…` | moves; record the new value |

The two moving paths move because those two sites use a `\` line continuation the helper does not. The unchanged ones prove the helper's body is byte-identical to what the tree writes today. That identity was measured before this plan was written, by building three candidate bodies:

```
current  (hand-written, one line)          7kwkl1i594z75hqj8dfp4xbp2z31f1wr-hyprlock
indented string with trailing newline      7kwkl1i594z75hqj8dfp4xbp2z31f1wr-hyprlock
plain string, NO trailing newline          x3ymc3ksqzdy7vm7aj305ls2b7c2mfgf-hyprlock
```

**The trailing newline is load-bearing.** Use the indented-string form given in Task 1 verbatim.

---

### Task 1: The helper, and all five call sites

**Files:**
- Create: `lib/nixgl.nix`
- Modify: `home/session.nix:116`
- Modify: `home/hyprland.nix:103-105`
- Modify: `home/default.nix:1-32`
- Modify: `home/quickshell.nix:200-205`
- Modify: `home/portals.nix:36-39`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `lib/nixgl.nix`, a function `{ pkgs }: { bin, wrap, wrapBin }` where
  `bin` is a string, `wrap = name: exe: <script derivation>` and
  `wrapBin = name: exe: <package with bin/name>`. Task 2's guard asserts that
  `${pkgs.nixgl.nixGLIntel}` appears in this file and nowhere under `home/`.

Do the edits in the order below. `home/session.nix` starts the user's only session, so it goes first and gets checked before anything else moves.

- [ ] **Step 1: Record the five paths before touching anything**

Every path check in this task uses the same five commands. Run them against a
build of the **current** tree first, so the before-and-after comparison is
like for like. All five were confirmed to work on 2026-08-17.

```bash
cd /home/isutton/Projects/calango-nix
A=$(sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage')
readlink -f "$A/home-path/bin/hyprland-nixgl"
readlink -f "$A/home-path/bin/hyprlock"
grep -h '^ExecStart' "$A"/home-files/.config/systemd/user/{quickshell,hyprpolkitagent,xdg-desktop-portal-hyprland}.service
```

Expected, exactly:

```
/nix/store/rav6aqkhg43lhdzyvkfmsrhxlk0z6qzh-hyprland-nixgl/bin/hyprland-nixgl
/nix/store/7kwkl1i594z75hqj8dfp4xbp2z31f1wr-hyprlock/bin/hyprlock
ExecStart=/nix/store/zzn9z2lgx7wv3vvfzjgiyxg5sqyagdfp-quickshell-nixgl
ExecStart=/nix/store/x2h9v7fppkfwy34djl02c28hmb2y53rq-hyprpolkitagent-nixgl/libexec/hyprpolkitagent
ExecStart=/nix/store/h7jyg8d29m4a0l8yrw822nlhv72wdhrh-xdg-desktop-portal-hyprland-nixgl
```

If any value differs, stop — the branch is not on the commit this plan was
written against, and every expected hash below is void.

- [ ] **Step 2: Create `lib/nixgl.nix`**

```nix
# The one place that decides which nixGL wrapper this machine uses.
#
# Before spec 14, five sites in home/ spelled `pkgs.nixgl.nixGLIntel` out for
# themselves. Changing the GL wrapper meant moving five places and nothing read
# the fifth. `nixglSingleSource` in home/default.nix now fails the build if a
# sixth appears.
#
# This is a plain Nix function, NOT a Home Manager module. flake.nix lists its
# modules one by one, so a file absent from that list is visibly not one, and
# lib/ sits beside bin/, data/ and system/, which are already non-module
# directories.
#
# `bin` is exported deliberately rather than leaked. home/session.nix can use
# neither function -- it prepends compositorPath and passes four extra
# arguments to start-hyprland -- so it takes the raw path. The property this
# file buys is that ONE file decides which GL wrapper is used; it is not that
# one file spells the exec line.
{ pkgs }:

let
  bin = "${pkgs.nixgl.nixGLIntel}/bin/nixGLIntel";

  # An indented string with a trailing newline, and both halves of that are
  # load-bearing. Measured before this file existed, by building three
  # candidate bodies against home/hyprland.nix:104's hand-written form:
  #
  #   hand-written, one line                7kwkl1i594z75hqj8dfp4xbp2z31f1wr-hyprlock
  #   this form                             7kwkl1i594z75hqj8dfp4xbp2z31f1wr-hyprlock
  #   plain string, no trailing newline     x3ymc3ksqzdy7vm7aj305ls2b7c2mfgf-hyprlock
  #
  # Three of the five adopting sites must keep their store path, which is how
  # this consolidation proves it changed nothing it did not mean to. Editing
  # this body -- even the whitespace -- moves all of them.
  body = exe: ''
    exec ${bin} ${exe} "$@"
  '';
in
{
  inherit bin;

  # A bare script. Use for an ExecStart or as a symlink target.
  wrap = name: exe: pkgs.writeShellScript name (body exe);

  # A package with bin/<name>. Use for home.packages.
  wrapBin = name: exe: pkgs.writeShellScriptBin name (body exe);
}
```

- [ ] **Step 3: Point `home/session.nix` at `nixgl.bin`**

Add the import as the first binding of the `let` block. `home/session.nix:3` is `let`; insert immediately after it:

```nix
  nixgl = import ./../lib/nixgl.nix { inherit pkgs; };
```

Then change the one line at `home/session.nix:116`. From:

```nix
    exec ${pkgs.nixgl.nixGLIntel}/bin/nixGLIntel \
```

To:

```nix
    exec ${nixgl.bin} \
```

Nothing else in that derivation changes. `${nixgl.bin}` expands to the identical string, so the text is unchanged and the store path must be unchanged.

- [ ] **Step 4: Verify the session path did not move**

```bash
cd /home/isutton/Projects/calango-nix
A=$(sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage')
readlink -f "$A/home-path/bin/hyprland-nixgl"
```

Expected:
`/nix/store/rav6aqkhg43lhdzyvkfmsrhxlk0z6qzh-hyprland-nixgl/bin/hyprland-nixgl`
— the same value Step 1 recorded.

If it moved, revert step 3 and stop. Do not proceed with a moved compositor
wrapper.

- [ ] **Step 5: Commit the session edit on its own**

```bash
git add lib/nixgl.nix home/session.nix
git commit -m "nixgl: one file decides which GL wrapper this machine uses

home/session.nix keeps its bespoke body -- compositorPath and four extra
arguments to start-hyprland -- and takes the raw path. Its store path is
unchanged at rav6aqkh..., which is the evidence the session's critical
path was not touched."
```

- [ ] **Step 6: Adopt `wrapBin` in `home/hyprland.nix`**

Add to the `let` block, after `quickshellState`:

```nix
  nixgl = import ./../lib/nixgl.nix { inherit pkgs; };
```

Replace `home/hyprland.nix:103-105`. From:

```nix
  hyprlock-nixgl = pkgs.writeShellScriptBin "hyprlock" ''
    exec ${pkgs.nixgl.nixGLIntel}/bin/nixGLIntel ${pkgs.hyprlock}/bin/hyprlock "$@"
  '';
```

To:

```nix
  hyprlock-nixgl = nixgl.wrapBin "hyprlock" "${pkgs.hyprlock}/bin/hyprlock";
```

Leave the comment block above it exactly as it is. It is about PAM, not about nixGL.

- [ ] **Step 7: Adopt `wrap` in `home/quickshell.nix`**

Add to the `let` block as its first binding, immediately after `let`:

```nix
  nixgl = import ./../lib/nixgl.nix { inherit pkgs; };
```

Replace `home/quickshell.nix:202-205`. From:

```nix
  quickshell-nixgl = pkgs.writeShellScript "quickshell-nixgl" ''
    exec ${pkgs.nixgl.nixGLIntel}/bin/nixGLIntel \
      ${pkgs.quickshell}/bin/quickshell "$@"
  '';
```

To:

```nix
  quickshell-nixgl = nixgl.wrap "quickshell-nixgl" "${pkgs.quickshell}/bin/quickshell";
```

- [ ] **Step 8: Adopt `wrap` in `home/portals.nix`**

Add to the `let` block as its first binding, immediately after `let`:

```nix
  nixgl = import ./../lib/nixgl.nix { inherit pkgs; };
```

Replace `home/portals.nix:36-39`. From:

```nix
  portal-nixgl = pkgs.writeShellScript "xdg-desktop-portal-hyprland-nixgl" ''
    exec ${pkgs.nixgl.nixGLIntel}/bin/nixGLIntel \
      ${pkgs.xdg-desktop-portal-hyprland}/libexec/xdg-desktop-portal-hyprland "$@"
  '';
```

To:

```nix
  portal-nixgl = nixgl.wrap "xdg-desktop-portal-hyprland-nixgl"
    "${pkgs.xdg-desktop-portal-hyprland}/libexec/xdg-desktop-portal-hyprland";
```

- [ ] **Step 9: Adopt `wrap` in `home/default.nix`, and correct its comment**

Replace `home/default.nix:1-32` — the header, the whole comment block, `nixglWrap`, and `hyprpolkitagent-nixgl` — with:

```nix
{ pkgs, ... }:

let
  nixgl = import ./../lib/nixgl.nix { inherit pkgs; };

  # Qt Quick builds an OpenGL scenegraph the moment it shows its first window,
  # so a Nix Qt6 application needs the same GL wrapper the compositor needs.
  # Wrapping the compositor is not enough: a systemd user unit runs whatever
  # ExecStart names, and the home-manager module names the bare store binary.
  #
  # Unwrapped, hyprpolkitagent starts, registers with polkit, and then aborts
  # the instant it is asked to draw:
  #
  #   polkit-agent-helper-1: pam_unix(polkit-1:auth): conversation failed
  #   hyprpolkitagent.service: Main process exited, code=dumped, status=6/ABRT
  #
  # No dialog is ever presented, so PAM's conversation returns no password.
  # The cause is the same /run/opengl-driver/lib that Task 6 rung 1 hit.
  #
  # The rule is about UNITS, not about applications. An earlier version of this
  # comment said "every Nix GUI application on this machine needs the wrapper",
  # generalised from two crashes, and that is false. A session child inherits
  # the five GL variables from the compositor's own wrap -- a plain shell in
  # the session carries 5 of 5 -- while a systemd user unit inherits none of
  # them, because the user manager never carried them:
  #
  #   systemctl --user show-environment | grep -cE '^(LIBGL_DRIVERS_PATH|…)='
  #   # 0
  #
  # So the things that wrap themselves are the session and four units, and a
  # session child needs no wrapper of its own. foot is the control and is Nix's
  # own counterexample: it draws through wayland shm rather than GL and needs
  # no wrapper at all (see the home.packages comment below).
  hyprpolkitagent-nixgl = pkgs.runCommand "hyprpolkitagent-nixgl" { } ''
    mkdir -p "$out/libexec"
    ln -s ${
      nixgl.wrap "hyprpolkitagent" "${pkgs.hyprpolkitagent}/libexec/hyprpolkitagent"
    } "$out/libexec/hyprpolkitagent"
  '';
in
{
```

- [ ] **Step 10: Confirm the interpolated form is gone from `home/`**

```bash
cd /home/isutton/Projects/calango-nix
/usr/bin/grep -rcF '${pkgs.nixgl.nixGLIntel}' home/*.nix | /usr/bin/grep -v ':0' | awk -F: '{s+=$2} END {print s+0}'
/usr/bin/grep -rcF '${pkgs.nixgl.nixGLIntel}' lib/nixgl.nix
```

Expected: `0` then `1`.

- [ ] **Step 11: Build and compare all five paths**

Run the same five commands from Step 1:

```bash
cd /home/isutton/Projects/calango-nix
A=$(sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage')
readlink -f "$A/home-path/bin/hyprland-nixgl"
readlink -f "$A/home-path/bin/hyprlock"
grep -h '^ExecStart' "$A"/home-files/.config/systemd/user/{quickshell,hyprpolkitagent,xdg-desktop-portal-hyprland}.service
```

Expected, exactly:

```
/nix/store/rav6aqkhg43lhdzyvkfmsrhxlk0z6qzh-hyprland-nixgl/bin/hyprland-nixgl    <- unchanged
/nix/store/7kwkl1i594z75hqj8dfp4xbp2z31f1wr-hyprlock/bin/hyprlock                <- unchanged
ExecStart=/nix/store/76czdlp8mv4x8ynvz5xxbvbf6kf2p6g3-quickshell-nixgl           <- moved, as predicted
ExecStart=/nix/store/x2h9v7fppkfwy34djl02c28hmb2y53rq-hyprpolkitagent-nixgl/…    <- unchanged
ExecStart=/nix/store/<new>-xdg-desktop-portal-hyprland-nixgl                     <- moved
```

The portal's new hash must **not** be `h7jyg8d29m4a0l8yrw822nlhv72wdhrh`.
Record the value it does take in the task report.

Three unchanged paths prove the helper's body is byte-identical to what the
tree wrote by hand. Two moved paths prove the consolidation reached the two
hand-written sites. If `hyprpolkitagent-nixgl` moved, the body was edited —
compare it against Step 2 character by character before doing anything else.

- [ ] **Step 12: Run the flake checks**

```bash
sg nix-users -c 'nix flake check' && echo "FLAKE CHECK OK"
```

Expected: exit 0. The three checks are `no-dangling-home-files`,
`no-pulseaudio-daemon` and `gui-desktop-ids`.

- [ ] **Step 13: Commit**

```bash
git add lib/nixgl.nix home/default.nix home/quickshell.nix home/portals.nix home/hyprland.nix
git commit -m "nixgl: adopt the shared helper at the four remaining sites

hyprpolkitagent, hyprlock and hyprland-nixgl keep their store paths,
which proves the helper's body is byte-identical to the hand-written
form. quickshell-nixgl and the portal move, because those two used a
backslash continuation the helper does not.

Also retires 'every Nix GUI application on this machine needs the
wrapper' in home/default.nix. foot disproves it, and the true rule is
about units: a session child inherits the five GL variables and a unit
inherits none."
```

---

### Task 2: The single-source guard

**Files:**
- Modify: `home/default.nix` — add `nixglSingleSource` to the `let` block and a guard entry to `home.packages`

**Interfaces:**
- Consumes: `lib/nixgl.nix` from Task 1, as a path.
- Produces: nothing later tasks read.

**The trap in this task, stated before the code.** The guard searches for the
literal text `${pkgs.nixgl.nixGLIntel}`. Written naively inside a Nix string,
that text is *interpolated*, so the guard would search for the expanded store
path — which appears in no source file — and pass for ever. Written with a
backslash escape (`"\${pkgs.nixgl.nixGLIntel}"`), the source bytes then contain
the needle as a substring, so the guard matches **its own source** and fails
for ever. Both failures are silent in the sense that matters: one never fires
and one always does.

The form below builds the needle by concatenation, so the literal never appears
in any source file, and Step 3 verifies exactly that.

- [ ] **Step 1: Add the guard derivation to `home/default.nix`'s `let` block**

Insert after `hyprpolkitagent-nixgl`:

```nix
  # Fails the build when a site outside lib/nixgl.nix spells the GL wrapper out
  # for itself. In home.packages rather than in flake.nix's checks on purpose:
  # the person who adds a wrapper is editing a module and building a
  # generation, and may never run `nix flake check`. A home.packages guard runs
  # on every generation build, which is strictly more often.
  #
  # The needle is built by concatenation, and that is not a style choice. The
  # literal `${…}` form cannot be written here: unescaped, Nix interpolates it
  # and the guard searches for an expanded store path that appears in no source
  # file, passing for ever. Escaped as `\${…}`, the source bytes of THIS file
  # contain the needle, so the guard matches itself and fails for ever. Split
  # across a `+`, the needle exists only at build time. Step 3 of this task
  # verifies that by counting.
  #
  # homeSrc is the whole home/ directory, so this rebuilds whenever any module
  # changes. It is one grep; that is the intended trade.
  nixglSingleSource =
    pkgs.runCommand "nixgl-single-source"
      {
        homeSrc = ./.;
        libSrc = ./../lib/nixgl.nix;
        needle = "$" + "{pkgs.nixgl.nixGLIntel}";
      }
      ''
        fail=0

        # A condition, not a bare command. A builder runs with errexit, and a
        # grep that matches nothing exits 1 -- which here is the PASSING case.
        if grep -rn -F -- "$needle" "$homeSrc" >&2; then
          echo "" >&2
          echo "A module above names the nixGL wrapper directly." >&2
          echo "  Every wrapper on this machine must come from lib/nixgl.nix," >&2
          echo "  which exports wrap, wrapBin and bin. Five sites spelled it" >&2
          echo "  out before spec 14 and nothing read the fifth, so changing" >&2
          echo "  the GL wrapper silently left one behind." >&2
          echo "  Use nixgl.wrap for a script, nixgl.wrapBin for a package," >&2
          echo "  or nixgl.bin if neither fits -- home/session.nix is the one" >&2
          echo "  site that needs the raw path, and it says why." >&2
          fail=1
        fi

        # The anti-vacuity anchor, the same one gui-desktop-ids,
        # no-pulseaudio-daemon and wrappedGuiApps each carry. Without it this
        # guard passes when lib/nixgl.nix has stopped naming nixGLIntel at all
        # -- at which point the check above is asserting nothing about
        # anything.
        if ! grep -q -F -- "$needle" "$libSrc"; then
          echo "lib/nixgl.nix does not name the nixGL wrapper." >&2
          echo "  The check above therefore proves nothing: it reports that" >&2
          echo "  no module names a string that nothing names. Either the" >&2
          echo "  helper moved, or this machine stopped using nixGL. Decide" >&2
          echo "  which, on purpose, and update this guard with it." >&2
          fail=1
        fi

        [ "$fail" -eq 0 ] || exit 1

        # A directory, not `touch "$out"`. home/gui-apps.nix records that a
        # file output makes pkgs.buildEnv fail with "is a file and can't be
        # merged into an environment".
        mkdir -p "$out"
      '';
```

- [ ] **Step 2: Put the guard in `home.packages`**

`home/default.nix`'s `home.packages` list is `with pkgs; [ … ]`, so the entry
must be fully qualified. Add it as the last element of that list, mirroring
`home/gui-apps.nix:392`:

```nix
    # Not a program. A build-time assertion that rides in home.packages so it
    # runs on every generation build. See nixglSingleSource above.
    (pkgs.runCommand "nixgl-guard" { } "ln -s ${nixglSingleSource} $out")
```

- [ ] **Step 3: Verify the needle appears nowhere in the source**

```bash
cd /home/isutton/Projects/calango-nix
/usr/bin/grep -rcF '${pkgs.nixgl.nixGLIntel}' home/*.nix | /usr/bin/grep -v ':0' | awk -F: '{s+=$2} END {print s+0}'
```

Expected: `0`. A non-zero count here means the needle was written literally and
the guard will match its own source.

- [ ] **Step 4: Build; the guard must pass**

```bash
sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage' && echo "BUILD OK"
```

Expected: a store path, exit 0.

- [ ] **Step 5: Mutation one — a real sixth site must fail the build**

Add a genuine wrapper site to `home/foot.nix`'s `let` block:

```nix
  mutationProbe = pkgs.writeShellScript "mutation-probe" ''
    exec ${pkgs.nixgl.nixGLIntel}/bin/nixGLIntel /bin/true "$@"
  '';
```

Confirm the mutation landed **before** building:

```bash
/usr/bin/grep -cF '${pkgs.nixgl.nixGLIntel}' home/foot.nix
```

Expected: `1`. Then build:

```bash
sg nix-users -c 'nix build --no-link .#homeConfigurations."isutton@suffer".activationPackage' 2>&1 | tail -20
```

Expected: the build FAILS, and the output contains
`A module above names the nixGL wrapper directly.` and a `home/foot.nix` line
number. Then revert:

```bash
git checkout home/foot.nix
/usr/bin/grep -cF '${pkgs.nixgl.nixGLIntel}' home/foot.nix
```

Expected: `0`.

- [ ] **Step 6: Mutation two — a vacuous helper must fail the build**

In `lib/nixgl.nix`, change the `bin` binding to a literal that does not name
nixGL:

```nix
  bin = "/usr/bin/true";
```

Confirm the mutation landed before building:

```bash
/usr/bin/grep -cF '${pkgs.nixgl.nixGLIntel}' lib/nixgl.nix
```

Expected: `0`. Then build:

```bash
sg nix-users -c 'nix build --no-link .#homeConfigurations."isutton@suffer".activationPackage' 2>&1 | tail -20
```

Expected: the build FAILS with `lib/nixgl.nix does not name the nixGL wrapper.`

This is the branch that separates the guard from a check that passes because
there is nothing left to check. Then revert:

```bash
git checkout lib/nixgl.nix
/usr/bin/grep -cF '${pkgs.nixgl.nixGLIntel}' lib/nixgl.nix
```

Expected: `1`.

- [ ] **Step 7: Rebuild clean and run the flake checks**

```bash
cd /home/isutton/Projects/calango-nix
sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage'
sg nix-users -c 'nix flake check' && echo "FLAKE CHECK OK"
```

Expected: a store path, then exit 0.

- [ ] **Step 8: Commit**

```bash
git add home/default.nix
git commit -m "nixgl: fail the build when a sixth site names the wrapper

Both branches proven by mutation, each mutation confirmed by a count
before the build ran: a real wrapper site added to home/foot.nix fails
with the leak message, and a lib/nixgl.nix that has stopped naming
nixGLIntel fails with the vacuity message.

The needle is built by concatenation. Written literally it would be
interpolated and the guard would search for a store path no source file
contains; written with a backslash escape it would match its own source.
Both spellings fail silently in opposite directions."
```

---

### Task 3: The two stale passages in `home/gui-apps.nix`

**Files:**
- Modify: `home/gui-apps.nix:16-38` — the gammastep wrapper argument
- Modify: `home/gui-apps.nix:57-60` — the Signal and Bitwarden nixGL claim

**Interfaces:**
- Consumes: nothing.
- Produces: nothing. Comments only. No derivation may change.

This task changes no code. Verify that by store path at the end.

- [ ] **Step 1: Replace the gammastep wrapper argument**

`home/gui-apps.nix:16-38` currently argues that gammastep's wrappers matter
because the schema directories they prefix come from its dependencies. That
specific claim is false. Replace from `# Both bin/gammastep and` through
`# included, and gammastep supplies two.` with:

```nix
  # Both bin/gammastep and bin/gammastep-indicator are wrapGAppsHook wrappers
  # (.gammastep-wrapped and .gammastep-indicator-wrapped siblings exist), and
  # this entry is why the guard below has no "ships no schemas" exemption.
  #
  # An earlier version of this comment argued that the wrappers matter because
  # the schema directories they prefix come from gammastep's dependencies. That
  # is measured and false. Each wrapper does prefix XDG_DATA_DIRS with gtk+3's
  # and gsettings-desktop-schemas' directories, and gammastep ships none of its
  # own:
  #
  #   $ G=/nix/store/bcrxrws5kwvkrgifs0fw6p4vna412l04-gammastep-2.0.11
  #   $ find $G -path '*gsettings-schemas*' | wc -l
  #   0
  #
  # But the indicator does not read a schema, from any source. Its module has
  # zero Gio, Settings or GSettings references, and adding the wrapper's
  # variables back to the bare stub one at a time -- adding rather than
  # stripping, because a shell that has none of them set returns the same
  # failure whatever you strip -- isolates the one that matters:
  #
  #   nothing set                 exit=1    traceback at gi.require_version('Gtk','3.0')
  #   GI_TYPELIB_PATH only        exit=255  runs; gammastep's own --help behaviour
  #   XDG_DATA_DIRS only          exit=1    unchanged
  #   GDK_PIXBUF_MODULE_FILE only exit=1    unchanged
  #
  # So the wrapper IS load-bearing and GI_TYPELIB_PATH is what carries it:
  # gammastep-indicator is a PyGObject application and gi.require_version fails
  # without the typelib path. That makes the case against a derived exemption
  # stronger than the old comment made it, not weaker -- whether a package
  # needs its wrapper turns out not to be a function of schemas at all. The
  # guard below therefore requires a wrapped binary from every member,
  # gammastep included, and gammastep supplies two.
```

- [ ] **Step 2: Replace the Signal and Bitwarden nixGL claim**

`home/gui-apps.nix:57-60` currently reads "Neither needs the nixGL wrapper".
Replace those four comment lines with:

```nix
  # Neither needs a nixGL wrapper OF ITS OWN, which is a narrower claim than
  # the one this comment used to make. The user ran both binaries bare from a
  # terminal in the live Hyprland session and both windows drew -- but a
  # session child inherits the five GL variables from the compositor's own
  # wrap, so that run says nothing about the variables themselves. Stripped of
  # them, Signal reports
  #   MESA-LOADER: failed to open dri: /run/opengl-driver/lib/gbm/dri_gbm.so
  # and its GPU process exits. The measurement was still worth taking, because
  # `ldd` cannot answer the question at all -- Electron dlopens its GL and
  # platform plugins.
```

- [ ] **Step 3: Prove no derivation changed**

```bash
cd /home/isutton/Projects/calango-nix
sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage'
```

Expected: **the same store path as Task 2 Step 7 printed.** A Nix `#` comment
is not part of any derivation, so an unchanged path is the proof this task
changed only prose. If the path moved, a comment edit escaped into a `''…''`
string that becomes a `buildCommand`; find it before committing.

- [ ] **Step 4: Commit**

```bash
git add home/gui-apps.nix
git commit -m "gui: the gammastep wrapper is load-bearing for typelibs, not schemas

The old argument said the schema directories each wrapper prefixes come
from gammastep's dependencies. Measured: the indicator reads no schema
from any source, and GI_TYPELIB_PATH alone is what its wrapper is for.
The conclusion survives and the case against a derived exemption gets
stronger -- wrapper necessity is not a function of schemas.

Also narrows 'Neither needs the nixGL wrapper' to 'neither needs one of
its own'. The bare run happened inside the session, so both inherited
the five variables.

Comments only; the activation package's store path is unchanged."
```

---

### Task 4: Keep lf-41's `share/` tree

**Files:**
- Modify: `home/lf.nix:69-72` — `lfWrapped`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `lfWrapped`, still a package with `bin/lf`, so
  `config.calango.lf` stays `types.package` and `home/session.nix:45`'s
  consumer is unaffected.

`writeShellScriptBin` produces a package holding one file, so the profile gets
`bin/lf` and none of lf-41's completions, man page or `lf.desktop`. apt's `lf`
is therefore the only source of lf completions on this machine today, and the
removal at close-out would lose them.

- [ ] **Step 1: Confirm the gap before fixing it**

```bash
P=$(sg nix-users -c 'nix eval --raw .#homeConfigurations."isutton@suffer".pkgs.lf')
ls "$P/share"
ls "$(readlink -f ~/.nix-profile/bin/lf | xargs dirname | xargs dirname)"
find ~/.nix-profile/share -iname '*lf*' | wc -l
```

Expected: `applications bash-completion fish man zsh`; then `bin` alone; then `0`.

- [ ] **Step 2: Replace `lfWrapped`**

`home/lf.nix:69-72` currently reads:

```nix
  lfWrapped = pkgs.writeShellScriptBin "lf" ''
    export PATH=${lfPath}''${PATH:+:$PATH}
    exec ${pkgs.lf}/bin/lf "$@"
  '';
```

Replace with:

```nix
  # A symlinkJoin rather than a writeShellScriptBin, and the difference is
  # everything except the binary. writeShellScriptBin produces a package
  # holding one file, so lf-41's share/ tree -- bash, fish and zsh
  # completions, lf.1.gz and lf.desktop -- never reached the profile:
  #
  #   $ ls /nix/store/…-lf-41/share
  #   applications  bash-completion  fish  man  zsh
  #   $ find ~/.nix-profile/share -iname '*lf*' | wc -l
  #   0
  #
  # apt's lf was the only source of lf completions on this machine until spec
  # 14, which is why this had to be fixed before that package could be removed.
  #
  # --prefix, not --suffix: the writeShellScriptBin form prepended lfPath, so
  # a suffix here would silently change which copy of file, gio and xdg-open
  # lfrc's commands resolve to.
  lfWrapped = pkgs.symlinkJoin {
    name = "lf-wrapped";
    paths = [ pkgs.lf ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram "$out/bin/lf" --prefix PATH : ${lfPath}
    '';
  };
```

- [ ] **Step 3: Verify the package now carries `share/`, and still carries the PATH**

```bash
cd /home/isutton/Projects/calango-nix
L=$(sg nix-users -c 'nix eval --raw .#homeConfigurations."isutton@suffer".config.calango.lf')
echo "$L"
ls "$L/share"
ls "$L/share/man/man1" "$L/share/applications"
/usr/bin/grep -c 'file-5\|xdg-utils\|glib-2\|coreutils-9' "$L/bin/lf"
```

Expected: `applications bash-completion fish man zsh`; then `lf.1.gz` and
`lf.desktop`; then a count of at least `1` — `bin/lf` is now a makeWrapper
script naming the four store paths `lfPath` lists.

- [ ] **Step 4: Verify the four `lfPath` entries individually**

```bash
cd /home/isutton/Projects/calango-nix
L=$(sg nix-users -c 'nix eval --raw .#homeConfigurations."isutton@suffer".config.calango.lf')
for d in file xdg-utils glib coreutils; do
  printf '%-12s %s\n' "$d" "$(grep -c "/nix/store/[a-z0-9]\{32\}-$d-" "$L/bin/lf")"
done
```

Expected: each prints a count of `1` or more. A zero means `wrapProgram` did
not receive that element of `lfPath`.

- [ ] **Step 5: Build and run the flake checks**

```bash
sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage'
sg nix-users -c 'nix flake check' && echo "FLAKE CHECK OK"
```

Expected: a store path, then exit 0. `gui-desktop-ids` checks a `required`
list; `lf.desktop` is an addition to the tree and is not on that list, so the
check is unaffected.

- [ ] **Step 6: Commit**

```bash
git add home/lf.nix
git commit -m "lf: keep lf-41's share tree, which the wrapper was dropping

writeShellScriptBin produces a package holding one file, so the profile
carried bin/lf and none of lf-41's completions, man page or lf.desktop.
apt's lf was the only source of lf completions on this machine, and
removing it would have been a silent loss. symlinkJoin plus wrapProgram
keeps the tree and the PATH.

--prefix rather than --suffix, because the old form prepended."
```

---

### Task 5: `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: the facts established in Tasks 1 to 4.
- Produces: nothing.

Four edits. Every one of them replaces or extends an existing passage; do not
append a new section at the end of the file.

- [ ] **Step 1: Add the new guard to the `home.packages` guard enumeration**

The passage beginning `Further build-time guards ride in `home.packages`` tells
the reader to enumerate by syntax, with
`grep -n 'home.packages' home/*.nix`. That instruction still stands and needs
no change. Add one sentence to that passage recording that
`home/default.nix`'s `nixglSingleSource` now joins them, and that it is a
source-text guard rather than a package-inspecting one — the first of that kind
here.

- [ ] **Step 2: Correct the nixGL standing fact**

The bullet beginning `**A Nix binary that actually uses GL needs nixGL's
*environment*.` tells the reader to enumerate the wrapper sites with
`grep -rn 'bin/nixGLIntel' home/*.nix`, `which returns 5`. That command now
returns 0, because every site goes through `lib/nixgl.nix`. Replace the
enumeration instruction with the current one and say what changed:

```
/usr/bin/grep -rn 'nixgl\.\(wrap\|wrapBin\|bin\)' home/*.nix   # the five call sites
/usr/bin/grep -c 'pkgs.nixgl.nixGLIntel' lib/nixgl.nix         # 1 -- the only definition
```

Keep every measurement in that bullet. The 5-of-5 and 0-of-5 table, the two
portal units, the foot control and the `signal-desktop` stripped-environment
output are all still true and were not re-measured by this spec.

- [ ] **Step 3: Retire the two "known stale" comment flags**

That same bullet ends with: `Two comments in the tree still carry the retired
reasoning and are known stale: home/default.nix:18-20 … and
home/gui-apps.nix:57-60 … Fix them with the nixGL consolidation.` Both are
fixed. Replace that paragraph with the settled gammastep-indicator finding,
which is what the second comment was waiting on:

```
**gammastep-indicator's wrapper is load-bearing, and GI_TYPELIB_PATH is what
carries it.** Spec 13 left this open and the note that carried it forward
described `.gammastep-indicator-wrapped` as a 16-line stub with no toolkit
token. That is the python launcher; the wrapper is its 118-line sibling
`bin/gammastep-indicator`. Adding its variables back to the bare stub one at a
time -- adding, not stripping, because a shell with none of them set returns
the same failure whatever you strip -- gives GI_TYPELIB_PATH alone as
sufficient and XDG_DATA_DIRS as irrelevant. The indicator reads no GSettings
schema from any source. So "ships no schemas" is not just an unsafe exemption
predicate, it is not the right question at all.
```

- [ ] **Step 4: Add the flatpak override rule**

The bullet beginning `**That same inheritance breaks flatpak** already carries
the reproduction and the `flatpak override --user --unset-env=…` command. Add
the ownership decision to it, as a rule rather than as a note about Slack:

```
**This flake does not own those overrides, deliberately.**
`~/.local/share/flatpak/overrides/` held seven files on 2026-08-17 and six were
61-byte browser overrides from 2026-08-06, for applications not installed as
flatpaks and owned by nobody. One Home Manager-managed file among them
reproduces the `pipewire-session-manager.service` alias shape: unmanageable by
`no-dangling-home-files`, and dangling for ever when its module leaves. Run the
override by hand for every flatpak application, and record it here.
```

- [ ] **Step 5: Confirm no `.superpowers/` path entered the file**

```bash
cd /home/isutton/Projects/calango-nix
/usr/bin/grep -c '\.superpowers/' CLAUDE.md
```

Expected: `0`.

- [ ] **Step 6: Verify the counts CLAUDE.md now claims**

```bash
cd /home/isutton/Projects/calango-nix
/usr/bin/grep -rn 'nixgl\.\(wrap\|wrapBin\|bin\)' home/*.nix | wc -l
/usr/bin/grep -c 'pkgs.nixgl.nixGLIntel' lib/nixgl.nix
/usr/bin/grep -n 'home.packages' home/*.nix | wc -l
```

Expected: `5`, `1`, and a count the sentence added in Step 1 must agree with.
Read the third number rather than quoting it — that is the rule the passage
itself states.

- [ ] **Step 7: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: record the consolidation, and settle gammastep-indicator

Retires both 'known stale' comment flags, because both comments are now
fixed. Replaces the enumeration command for the wrapper sites, which
returned 5 and now returns 0.

The flatpak override entry gains the ownership decision as a rule: this
flake does not own those files, because the directory holds six it never
should and one managed file among them dangles for ever when its module
leaves."
```

---

## Close-out — after the tasks, with the user

These steps need the user. No agent runs them.

- [ ] **The user switches, from a tty.**
  `quickshell.service` and `xdg-desktop-portal-hyprland.service` restart,
  because their `ExecStart` moved. `hyprpolkitagent.service` must **not**
  restart. Check with `ActiveEnterTimestamp`, not `NRestarts` — sd-switch
  stops and starts a unit, and a fresh start resets that counter.

- [ ] **Confirm the session and the lock screen still work.** The compositor's
  wrapper path did not move, so nothing about the session should change. The
  lock screen is `hyprlock`, whose path also did not move.

- [ ] **Confirm lf's completions and man page arrived.**

```bash
find ~/.nix-profile/share -iname '*lf*'
man -w lf
```

- [ ] **The user removes apt's `lf`.** Re-read the "no longer required" list at
  that moment rather than trusting this plan's copy of it — that is the
  standing rule, and letting it slide is how the orphan backlog reached 137.
  Expected today: `libxres1 python3-attr python3-docopt python3-xlib ueberzug`.
  Re-run the union in-use check at that moment too, because `ueberzug` is a
  Python program and a `/proc` walk alone cannot see it.

- [ ] **Confirm the census is still zero.**

```bash
apt-get -s autoremove | grep -c '^Remv'
```

Expected: `0`.

- [ ] **Write the results document** to
  `docs/2026-08-17-results-suffer-nixgl-consolidation.md`, recording every
  defect and its owner, in the shape the thirteen existing results documents
  use. Then `ls -1 docs/*results-suffer-*.md | wc -l` is the authority for the
  count in `CLAUDE.md`'s opening paragraph — read it, do not increment it.

---

## Acceptance criteria

Mapped from the spec.

1. `${pkgs.nixgl.nixGLIntel}` appears exactly once in the repository, in `lib/nixgl.nix` — Task 1 Step 10, Task 2 Step 3.
2. Both guard branches fail under mutation, each mutation confirmed by a count before the build — Task 2 Steps 5 and 6.
3. All five wrapper store paths captured before and after; three unchanged, two moved — Task 1 Steps 1 and 11.
4. `nix flake check` exits 0 and reports three checks — Task 1 Step 12, Task 2 Step 7, Task 4 Step 5.
5. The generation builds; the two moved scripts differ only in a `\` continuation becoming a space — Task 1 Step 11.
6. `home/default.nix:18-20`, `home/gui-apps.nix:16-38` and `home/gui-apps.nix:57-60` each state only what a measurement supports — Task 1 Step 9, Task 3 Steps 1 and 2.
7. The `lf` package carries `share/bash-completion`, `share/man/man1` and `share/applications/lf.desktop`, and `bin/lf` still sets the four `lfPath` entries — Task 4 Steps 3 and 4.
8. `CLAUDE.md` carries the flatpak override rule, the gammastep-indicator finding, and the new guard — Task 5.
9. After the user removes apt's `lf`, `apt-get -s autoremove` proposes zero packages — close-out.
