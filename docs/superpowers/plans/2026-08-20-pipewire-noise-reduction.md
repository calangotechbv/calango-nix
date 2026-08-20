# PipeWire Noise-Canceling Source Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a selectable "Noise Canceling source" microphone to this desktop, built from RNNoise and PipeWire's own builtin `noisegate`, guarded at build time.

**Architecture:** A single `filter-chain.conf.d` fragment defines a two-node graph. `filter-chain.service` already exists, is already enabled, and already runs an empty graph, so no unit is created. A `filter-chain.service.d` drop-in supplies `LADSPA_PATH` (without which the plugin is not found) and `X-Restart-Triggers` (without which sd-switch never restarts the service after a config-only change). One `runCommand` in `home.packages` parses the fragment by syntax and asserts every plugin, label and control name it uses really exists in the libraries that must provide them.

**Tech Stack:** Nix, standalone Home Manager, PipeWire 1.6.6, `pkgs.rnnoise-plugin` 1.10 (LADSPA), systemd user units, `awk`/`grep` inside a Nix builder.

**Spec:** `docs/superpowers/specs/2026-08-20-pipewire-noise-reduction-design.md`

## Global Constraints

These apply to every task. They are this repository's standing rules, copied from `CLAUDE.md`, plus the spec's own decisions.

- **Wrap every `nix` and `home-manager` command in `sg nix-users -c '…'`.** A process without that group fails on the daemon socket and the error reads like a broken Nix install.
- **`grep` in the interactive shell is ugrep, not GNU grep, and it silently returns 0 for a pattern containing `${`.** Use `/usr/bin/grep`, with `-F` for a literal, whenever a count is load-bearing. Inside a Nix builder the shell is the real one and plain `grep` is correct.
- **A Nix builder runs with `set -e` and `pipefail`.** Never write `n="$(grep -c … )"` in a builder: a zero count aborts the build before any message prints. Put every grep in a condition — `if grep -qaF … ; then`.
- **Nix cannot see untracked files in a git flake.** `git add` every new file before the first `nix build`, or the build fails with a missing-path error that reads like a typo.
- **Commit the real work before any mutation test**, so every revert is recoverable.
- **Revert a mutation with `git restore --worktree <path>` only.** Adding `--staged` changes the source to HEAD, which deletes a file new to this branch and destroys uncommitted work. Re-read the file after every revert.
- **`nix flake check` must still report 8.** This work adds no `checks` entry. Verify with `sg nix-users -c 'nix flake check' 2>&1 | /usr/bin/grep -c '^checking derivation checks\.'`.
- **`ActiveEnterTimestamp`, never `NRestarts`,** is the property that proves a unit restarted. sd-switch stops and starts the unit, and a fresh start resets that counter.
- **The switch command is** `sg nix-users -c 'home-manager switch --flake .#isutton@suffer'`.
- Values fixed by the spec: mono graph; capture node `effect_input.rnnoise` with `node.passive = true` and **no** `target.object`; playback node `effect_output.rnnoise` with `media.class = Audio/Source`; description `"Noise Canceling source"`; LADSPA plugin `librnnoise_ladspa`, label `noise_suppressor_mono`; builtin label `noisegate`.

---

## File Structure

| File | Responsibility |
|---|---|
| `pipewire/50-noise-canceling-source.conf` | **New.** The filter graph, as plain PipeWire config text. Holds no store path, so it can be read and edited by a person. Sits beside the existing `pipewire/20-block-source-volume.conf`, which is installed the same way. |
| `home/audio.nix` | **Modified.** Three additions in three places: two `let` bindings plus a guard derivation; one `home.packages` entry; two `xdg.configFile` entries. |
| `docs/2026-08-20-results-suffer-pipewire-noise-reduction.md` | **New.** The results document. Its existence is what makes this spec 21 — `ls -1 docs/*results-suffer-*.md \| wc -l` is the authority on the count. |
| `CLAUDE.md` | **Modified.** Three entries: the new LADSPA path trap, the measured sd-switch drop-in answer, and the corrected guard enumeration. |

**A note on why `nofail` is omitted.** PipeWire's shipped example, `share/pipewire/filter-chain/source-rnnoise.conf`, carries `flags = [ nofail ]`. This plan does not. With `nofail` a broken graph produces a running service that serves nothing, which is the failure this project keeps paying for. Without it, `pipewire` exits and systemd marks the unit failed. That is bounded, not a restart loop: `filter-chain.service` carries `Restart=on-failure` with `RestartUSec=100ms` and `StartLimitBurst=5`, so it gives up inside a second and lands in `failed`, where `systemctl --user status` shows it. This is a deliberate departure from upstream's example and is recorded in the results document.

---

## Task 1: The config file, installed, with its drop-in

**Files:**
- Create: `pipewire/50-noise-canceling-source.conf`
- Modify: `home/audio.nix` — the `let` block above `in {`, and the `xdg.configFile` attribute set
- Test: no test file; the assertion is a shell command against the built generation

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: two `let` bindings that Task 2 uses by name — `noiseCancelingSource` (a path to the config file) and `ladspaPath` (a string, the directory holding `librnnoise_ladspa.so`).

- [ ] **Step 1: Write the failing test**

Save this as a shell function you re-run by hand; it is not committed.

```bash
check_task1() {
  A=$(sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage') || return 1
  H="$A/home-files/.config"
  echo "--- the fragment ---"
  cat "$H/pipewire/filter-chain.conf.d/50-noise-canceling-source.conf"
  echo "--- the drop-in ---"
  cat "$H/systemd/user/filter-chain.service.d/10-noise-canceling-source.conf"
}
check_task1
```

- [ ] **Step 2: Run it to verify it fails**

Run: `check_task1`
Expected: FAIL. `cat: …/50-noise-canceling-source.conf: No such file or directory`. The build itself succeeds, because nothing references the file yet.

- [ ] **Step 3: Create the config file**

Create `pipewire/50-noise-canceling-source.conf`:

```
# A noise-canceling capture source, from two filters PipeWire already carries.
#
# Two problems, two filters, and only one of them is a denoiser:
#
#   rnnoise   removes steady noise -- a fan, the street, a keyboard.
#   noisegate closes the microphone while nobody near it speaks, which is
#             what keeps a colleague's conversation off the far end.
#
# The gate is the half that matters for a shared room, and it is free:
# `noisegate` is a builtin of PipeWire's own filter-graph plugin, not a
# package. RNNoise cannot do this job on its own -- it is trained to KEEP
# speech and discard everything else, so another person's voice passes
# straight through it. Neither filter removes a colleague who talks while you
# talk; nothing in open-source PipeWire does.
#
# The plugin name below is deliberately NOT a path. PipeWire appends ".so" and
# looks the result up in a directory list; an absolute path is refused:
#
#   [E] plugin_ladspa.c: failed to load plugin '/nix/store/...librnnoise_ladspa'
#       in '/usr/lib64/ladspa:/usr/lib/ladspa:/nix/store/...-pipewire-1.6.6/lib'
#
# home/audio.nix therefore sets LADSPA_PATH in a filter-chain.service drop-in.
# That drop-in also carries X-Restart-Triggers naming this file's store path,
# without which sd-switch leaves the service running the previous graph.
#
# No `flags = [ nofail ]`, unlike PipeWire's own example. With nofail a broken
# graph yields a running service that filters nothing. Without it the unit
# fails visibly and stops after five attempts.
#
# The controls below are upstream's defaults. Tune them by reading gate:Level
# while you speak and while only the room speaks; see the results document.
context.modules = [
    { name = libpipewire-module-filter-chain
        args = {
            node.description = "Noise Canceling source"
            media.name       = "Noise Canceling source"
            filter.graph = {
                nodes = [
                    {
                        type    = ladspa
                        name    = rn
                        plugin  = "librnnoise_ladspa"
                        label   = noise_suppressor_mono
                        control = { "VAD Threshold (%)" = 50.0 }
                    }
                    {
                        type    = builtin
                        name    = gate
                        label   = noisegate
                        control = {
                            "Open Threshold"  = 0.04
                            "Close Threshold" = 0.03
                            "Attack (s)"      = 0.005
                            "Hold (s)"        = 0.05
                            "Release (s)"     = 0.01
                        }
                    }
                ]
                links = [ { output = "rn:Output" input = "gate:In" } ]
            }
            audio.position = [ MONO ]
            capture.props  = { node.name = "effect_input.rnnoise" node.passive = true }
            playback.props = { node.name = "effect_output.rnnoise" media.class = Audio/Source }
        }
    }
]
```

- [ ] **Step 4: Make the file visible to Nix**

A git flake cannot see an untracked file. Without this the next build fails with a missing-path error.

```bash
git add pipewire/50-noise-canceling-source.conf
```

- [ ] **Step 5: Add the two `let` bindings to `home/audio.nix`**

Insert immediately **before** the closing `in` of the `let` block — that is, after the `pulseaudioClients` derivation ends with `'';` and before the line reading `in`.

```nix
  # The noise-canceling source, and the one directory its LADSPA plugin lives
  # in. Both are bound here rather than written out at each use, because the
  # drop-in below has to name the same store path that xdg.configFile installs:
  # X-Restart-Triggers works by naming a path that MOVES when the content
  # changes, so two independent references to the same file would be a defect
  # waiting for someone to edit one of them.
  noiseCancelingSource = ./../pipewire/50-noise-canceling-source.conf;

  # LADSPA_PATH, not an absolute plugin path. PipeWire appends ".so" to the
  # `plugin` field and searches a directory list -- measured, with an absolute
  # path, as: failed to load plugin '<abs path>' in
  # '/usr/lib64/ladspa:/usr/lib/ladspa:<pipewire libdir>'. None of those three
  # is a directory this flake controls, so the search path itself must be set.
  #
  # Same species as home/uwsm.nix's ExecStart=fumon defect -- a name resolved
  # against a search path no /nix/store entry will ever join -- with the
  # opposite fix, because here an absolute path is the thing that is refused.
  ladspaPath = "${pkgs.rnnoise-plugin}/lib/ladspa";
```

- [ ] **Step 6: Add the two `xdg.configFile` entries**

In `home/audio.nix`, the `xdg.configFile` attribute set currently reads
`xdg.configFile = unitFiles // wantLinks // { … }` and holds two
`wireplumber…/10-data-dir.conf` entries. Add these two entries inside the same
braces, after the existing pair:

```nix
    # The filter graph. A .d fragment merges into the filter-chain.conf that
    # pipewire finds in its own compiled-in share directory, so no base config
    # is needed here -- verified by running `pipewire -c filter-chain.conf`
    # against a scratch XDG_CONFIG_HOME holding only this fragment, which
    # produced the source `fragtest_output.rnnoise` with an empty log.
    "pipewire/filter-chain.conf.d/50-noise-canceling-source.conf".source =
      noiseCancelingSource;

    # Two directives that look unrelated and are both mandatory.
    #
    # LADSPA_PATH: see the ladspaPath binding above. Without it the graph does
    # not load and the unit fails.
    #
    # X-Restart-Triggers: sd-switch restarts a unit when the unit FILE changes,
    # never when a file the unit reads changes. A change confined to the
    # fragment above leaves filter-chain.service byte-identical, sd-switch
    # correctly does nothing, and the service goes on serving the previous
    # graph from a store path nothing points at any more. The switch succeeds
    # and the edit has no effect -- the defect every quickshell change in this
    # flake carried until spec 11. Naming the config's store path here makes
    # this drop-in's own text move whenever the config's content moves.
    #
    # X- keys are ignored by systemd itself, which is why this is the
    # conventional spelling; see home/quickshell.nix's Unit.X-Restart-Triggers.
    "systemd/user/filter-chain.service.d/10-noise-canceling-source.conf".text = ''
      [Unit]
      X-Restart-Triggers=${noiseCancelingSource}

      [Service]
      Environment=LADSPA_PATH=${ladspaPath}
    '';
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `check_task1`

Expected: PASS. The fragment prints in full. The drop-in prints as:

```
[Unit]
X-Restart-Triggers=/nix/store/<hash>-50-noise-canceling-source.conf

[Service]
Environment=LADSPA_PATH=/nix/store/<hash>-rnnoise-plugin-1.10/lib/ladspa
```

Confirm by eye that the store path after `X-Restart-Triggers=` ends in
`-50-noise-canceling-source.conf`, and that the `LADSPA_PATH` directory really
holds the object:

```bash
ls "$(sg nix-users -c 'nix eval --raw .#homeConfigurations."isutton@suffer".pkgs.rnnoise-plugin')/lib/ladspa"
# librnnoise_ladspa.so
```

- [ ] **Step 8: Commit**

```bash
git add pipewire/50-noise-canceling-source.conf home/audio.nix
git commit -m "audio: a noise-canceling source, from rnnoise and the builtin gate

The graph is two nodes: rnnoise for steady noise, and PipeWire's own
builtin noisegate for the room. The gate is the half that answers
colleagues talking, and it costs no package.

filter-chain.service already exists, is already enabled, and has been
running an empty graph since home/audio.nix landed, so nothing here
creates a unit. The drop-in carries two directives that look unrelated
and are both mandatory: LADSPA_PATH, because an absolute path in the
plugin field is refused, and X-Restart-Triggers, because sd-switch does
not see a config-only change."
```

---

## Task 2: The build-time guard, proven by mutation

**Files:**
- Modify: `home/audio.nix` — one new derivation in the `let` block, one new entry in `home.packages`
- Test: the mutation runs in steps 5 to 10; there is no test file

**Interfaces:**
- Consumes: `noiseCancelingSource` and `ladspaPath` from Task 1.
- Produces: `noiseCancelingGuard`, a derivation whose `$out` is an empty directory. Nothing later consumes it by name; it exists to fail.

**Why this guard exists.** The config names one plugin file, two labels and **six** control strings. Every one of them lives in a library this module does not build and cannot pin the internals of. A rename upstream produces a unit that fails at runtime, long after the build said yes.

Six, not eight. The two filters between them expose eight controls, and `pw-dump` lists all eight at runtime — but the config *sets* six of them, and the guard checks what the config says rather than what the plugins offer. Task 4 step 3 counts the other number, on purpose. Confusing the two is how a count comes to agree with an expectation for the wrong reason.

- [ ] **Step 1: Add the guard derivation to `home/audio.nix`**

Insert in the `let` block, immediately after the `ladspaPath` binding from Task 1.

```nix
  # Every name pipewire/50-noise-canceling-source.conf hands to a library,
  # checked against that library, at build time.
  #
  # The names are read OUT OF THE FILE rather than written here. A list of
  # "the six controls" typed into this derivation would go stale the first
  # time someone edits the config, and would go on passing -- which is the
  # exact failure CLAUDE.md's "enumerate by syntax, never by a remembered
  # list" rule exists to prevent, and which produced ExecStart=fumon.
  #
  # This rides in home.packages rather than in flake.nix's checks so it runs on
  # every generation build, which is strictly more often than anyone types
  # `nix flake check`. Same choice as wrappedGuiApps and pulseaudioClients.
  noiseCancelingGuard =
    pkgs.runCommand "noise-canceling-source-guard"
      {
        conf = noiseCancelingSource;
        rnnoiseDir = ladspaPath;
        builtinSo = "${pkgs.pipewire}/lib/spa-0.2/filter-graph/libspa-filter-graph-plugin-builtin.so";
      }
      ''
        if [ ! -e "$builtinSo" ]; then
          echo "pipewire no longer ships its builtin filter-graph plugin at" >&2
          echo "  $builtinSo" >&2
          echo "That library is where the noisegate filter lives. Find where" >&2
          echo "upstream moved it and update home/audio.nix's builtinSo." >&2
          exit 1
        fi

        # A state machine over the config, not a list of names. `type = ladspa`
        # and `type = builtin` select which library the names that follow must
        # be found in; each node block states its type before its label and its
        # controls, which is what makes one pass enough.
        #
        # A control KEY is quoted and sits left of the `=`. A quoted VALUE sits
        # right of it, so the trailing `=` in the pattern is what tells the two
        # apart -- node.description = "Noise Canceling source" must not be read
        # as a control name.
        awk '
          # Comments first, and this rule is not optional. Without it the
          # parser reads the prose in the config header: a dry run against an
          # early draft emitted LABEL from a sentence that merely mentioned
          # the word, with no node type attached, which lands in the orphan
          # branch below and fails the build over a comment. Same species as
          # the spec 11 appPath guard, which matched the very comment written
          # to describe it.
          #
          # NOTE for anyone editing this awk program: it is inside a
          # single-quoted shell string, so no apostrophe may appear anywhere
          # in it, comments included. One apostrophe ends the string and the
          # rest of the program becomes shell words.
          /^[[:space:]]*#/ { next }
          /type[[:space:]]*=[[:space:]]*ladspa/  { lib = "rnnoise"; next }
          /type[[:space:]]*=[[:space:]]*builtin/ { lib = "builtin"; next }
          match($0, /plugin[[:space:]]*=[[:space:]]*"[^"]+"/) {
            s = substr($0, RSTART, RLENGTH)
            sub(/plugin[[:space:]]*=[[:space:]]*"/, "", s); sub(/"$/, "", s)
            print "PLUGIN " lib " " s; next
          }
          match($0, /label[[:space:]]*=[[:space:]]*[A-Za-z0-9_]+/) {
            s = substr($0, RSTART, RLENGTH)
            sub(/label[[:space:]]*=[[:space:]]*/, "", s)
            print "LABEL " lib " " s; next
          }
          match($0, /"[^"]+"[[:space:]]*=/) {
            s = substr($0, RSTART, RLENGTH)
            sub(/^"/, "", s); sub(/"[[:space:]]*=$/, "", s)
            print "CONTROL " lib " " s
          }
        ' "$conf" > names.txt

        labels=0
        controls=0
        plugins=0
        bad=0

        # Redirected from a file, never piped: a `while read` on the right of a
        # pipe runs in a subshell and every counter below would be discarded.
        while read -r kind lib name; do
          case "$lib" in
            rnnoise) so="$rnnoiseDir/librnnoise_ladspa.so" ;;
            builtin) so="$builtinSo" ;;
            *)
              echo "home/audio.nix's guard read a $kind named '$name' that" >&2
              echo "belongs to no filter node -- no 'type = ladspa' or" >&2
              echo "'type = builtin' line preceded it in the config. Either a" >&2
              echo "node lost its type, or a new node type was added and this" >&2
              echo "guard has not been taught about it." >&2
              exit 1
              ;;
          esac

          case "$kind" in
            PLUGIN)
              plugins=$((plugins + 1))
              # A plugin is a FILE, so this is an existence test rather than a
              # content one -- and it is what makes the LADSPA_PATH drop-in
              # honest: the directory it names must really hold this object.
              if [ ! -e "$rnnoiseDir/$name.so" ]; then
                echo "The config names the LADSPA plugin '$name', but" >&2
                echo "  $rnnoiseDir/$name.so" >&2
                echo "does not exist. pkgs.rnnoise-plugin has moved or renamed" >&2
                echo "it. Note the config must NOT be changed to an absolute" >&2
                echo "path -- pipewire refuses one; fix ladspaPath instead." >&2
                bad=1
              fi
              ;;
            LABEL)
              labels=$((labels + 1))
              # A condition, not a bare grep: this builder runs with errexit,
              # and a grep that matches nothing exits 1.
              if ! grep -qaF -e "$name" "$so"; then
                echo "The config uses the filter label '$name', which does" >&2
                echo "not appear in $so." >&2
                echo "Upstream renamed or dropped it. The config's flags do" >&2
                echo "NOT include nofail, so this would fail the unit at" >&2
                echo "runtime rather than pass silently." >&2
                bad=1
              fi
              ;;
            CONTROL)
              controls=$((controls + 1))
              if ! grep -qaF -e "$name" "$so"; then
                echo "The config sets the control '$name', which does not" >&2
                echo "appear in $so." >&2
                echo "A control pipewire does not know is ignored, so the" >&2
                echo "filter would run at its default instead of the value" >&2
                echo "the config asks for -- silently." >&2
                bad=1
              fi
              ;;
          esac
        done < names.txt

        # The vacuity anchor. Without it a config the parser cannot read at all
        # -- a reformat, a renamed key, a file replaced by an empty one --
        # produces zero names to check, zero failures, and a guard that reports
        # success having asserted nothing. Same anchor gui-desktop-ids and
        # no-pulseaudio-daemon carry.
        if [ "$plugins" -eq 0 ] || [ "$labels" -eq 0 ] || [ "$controls" -eq 0 ]; then
          echo "The guard parsed $plugins plugin(s), $labels label(s) and" >&2
          echo "$controls control(s) out of" >&2
          echo "  $conf" >&2
          echo "and at least one of those is zero, so it checked nothing." >&2
          echo "The config's syntax has changed under the parser above. Read" >&2
          echo "the file and update the awk program, and do not delete this" >&2
          echo "check -- it is the only thing standing between a reformat and" >&2
          echo "a guard that passes vacuously for ever." >&2
          exit 1
        fi

        [ "$bad" -eq 0 ] || exit 1

        echo "ok: $plugins plugin, $labels labels, $controls controls checked"
        mkdir -p "$out"
      '';
```

- [ ] **Step 2: Add it to `home.packages`**

Change the existing line

```nix
  home.packages = [ pkgs.pipewire pkgs.wireplumber pulseaudioClients ];
```

to

```nix
  home.packages = [ pkgs.pipewire pkgs.wireplumber pulseaudioClients noiseCancelingGuard ];
```

- [ ] **Step 3: Build, and read the guard's own line**

Run:

```bash
sg nix-users -c 'nix build --no-link -L .#homeConfigurations."isutton@suffer".activationPackage' 2>&1 | /usr/bin/grep -F 'noise-canceling-source-guard>'
```

Expected: PASS, with a line ending

```
ok: 1 plugin, 2 labels, 6 controls checked
```

If the counts differ from 1 / 2 / 6, stop: the parser is reading something other than what the config says, and every later step would be checking the wrong thing.

- [ ] **Step 4: Commit the real work, before mutating anything**

```bash
git add home/audio.nix
git commit -m "audio: guard every name the noise-canceling config hands a library

One plugin file, two filter labels and six control strings, all read
out of the config by syntax rather than listed here, all checked against
the library that must provide them. Rides in home.packages so it runs on
every generation build, not only under nix flake check.

The vacuity anchor is the part that matters: without it a config the
parser can no longer read produces zero names, zero failures, and a
guard that passes having asserted nothing."
```

- [ ] **Step 5: Mutation 1 — a renamed filter label must fail the build**

```bash
sed -i 's/label   = noise_suppressor_mono/label   = noise_suppressor_stereophonic/' \
  pipewire/50-noise-canceling-source.conf
/usr/bin/grep -c 'noise_suppressor_stereophonic' pipewire/50-noise-canceling-source.conf
# 1  -- confirm the mutation landed BEFORE building; a sed that matched
#        nothing would make the build below pass for the wrong reason
```

- [ ] **Step 6: Run the build to verify it fails**

Run: `sg nix-users -c 'nix build --no-link -L .#homeConfigurations."isutton@suffer".activationPackage' 2>&1 | tail -20`

Expected: FAIL, with the guard's own message:

```
The config uses the filter label 'noise_suppressor_stereophonic', which does
not appear in /nix/store/…/lib/ladspa/librnnoise_ladspa.so.
```

- [ ] **Step 7: Revert, and re-read the file**

```bash
git restore --worktree pipewire/50-noise-canceling-source.conf
/usr/bin/grep -c 'noise_suppressor_mono' pipewire/50-noise-canceling-source.conf
# 1  -- the revert took
/usr/bin/grep -c 'noise_suppressor_stereophonic' pipewire/50-noise-canceling-source.conf
# 0
```

Do **not** add `--staged`. That restores from HEAD, and on a file new to this branch it deletes the file outright.

- [ ] **Step 8: Mutation 2 — a control name that does not exist must fail**

```bash
sed -i 's/"Open Threshold"  = 0.04/"Open Threshhold" = 0.04/' \
  pipewire/50-noise-canceling-source.conf
/usr/bin/grep -c 'Threshhold' pipewire/50-noise-canceling-source.conf
# 1
sg nix-users -c 'nix build --no-link -L .#homeConfigurations."isutton@suffer".activationPackage' 2>&1 | tail -10
```

Expected: FAIL with `The config sets the control 'Open Threshhold', which does not appear in …libspa-filter-graph-plugin-builtin.so.`

Then revert and re-read:

```bash
git restore --worktree pipewire/50-noise-canceling-source.conf
/usr/bin/grep -c 'Open Threshold' pipewire/50-noise-canceling-source.conf   # 1
```

- [ ] **Step 9: Mutation 3 — the vacuity anchor must fire**

This is the mutation that matters most, because it is the one a reviewer would skip. Empty the file of everything the parser recognises, while leaving it a valid file:

```bash
printf '# nothing here\n' > pipewire/50-noise-canceling-source.conf
sg nix-users -c 'nix build --no-link -L .#homeConfigurations."isutton@suffer".activationPackage' 2>&1 | tail -12
```

Expected: FAIL with `The guard parsed 0 plugin(s), 0 label(s) and 0 control(s) …`.

A guard that passed here would be a guard that can never fail.

- [ ] **Step 10: Revert, rebuild green, and record the proof**

```bash
git restore --worktree pipewire/50-noise-canceling-source.conf
/usr/bin/grep -c 'noisegate' pipewire/50-noise-canceling-source.conf   # 1
sg nix-users -c 'nix build --no-link -L .#homeConfigurations."isutton@suffer".activationPackage' 2>&1 | /usr/bin/grep -F 'noise-canceling-source-guard>'
# ok: 1 plugin, 2 labels, 6 controls checked
```

- [ ] **Step 11: Confirm the flake check count did not move**

Run: `sg nix-users -c 'nix flake check' 2>&1 | /usr/bin/grep -c '^checking derivation checks\.'`
Expected: `8`. This work adds no `checks` entry, and a 9 would mean something else changed.

- [ ] **Step 12: Commit (nothing to commit if the reverts were clean)**

```bash
git status --short
# expect empty output; the three mutations were all reverted
```

If `git status` shows a modified file, a revert did not take. Stop and fix it before Task 3.

---

## Task 3: Measure whether sd-switch diffs a drop-in

**Files:**
- Modify: `pipewire/50-noise-canceling-source.conf` (one comment line, added and then removed)
- Test: the measurement is the deliverable

**Interfaces:**
- Consumes: everything from Tasks 1 and 2, switched onto the live machine.
- Produces: a yes/no answer recorded in Task 6. If **no**, Task 3b runs.

**Why this is a task and not a footnote.** `CLAUDE.md` states plainly that whether sd-switch diffs drop-ins as well as fragments *has not been measured here*, and tells you to verify it before relying on it. This design relies on it. The same answer also unblocks `xdg-desktop-portal.service`, which carries the identical defect and waits on the identical question.

**Before you switch.** A switch restarts units whose files changed. This change touches `filter-chain.service.d` only, so audio filters restart and nothing else should. Run a dry activation first and read what it intends to do.

- [ ] **Step 1: Dry-run the switch and read the plan**

```bash
sg nix-users -c 'home-manager switch --flake .#isutton@suffer --dry-run' 2>&1 | tail -30
```

Expected: it names the new files and the units it will restart. If it proposes to restart anything belonging to the compositor or to quickshell, stop and find out why before continuing.

- [ ] **Step 2: Record the baseline timestamp**

```bash
systemctl --user show filter-chain.service -p ActiveEnterTimestamp --value
# e.g. Wed 2026-08-20 06:11:42 -03      <- call this T0
```

- [ ] **Step 3: Switch, and confirm the first switch restarts the service**

```bash
sg nix-users -c 'home-manager switch --flake .#isutton@suffer'
systemctl --user show filter-chain.service -p ActiveEnterTimestamp --value    # T1
systemctl --user is-active filter-chain.service                               # active
```

Expected: T1 is later than T0. This proves nothing about drop-in diffing yet — the *fragment* did not change, but the drop-in is brand new, so a restart here is expected either way. It is the baseline for the two comparisons that follow.

- [ ] **Step 4: The control — a switch that changes nothing must not restart it**

```bash
sg nix-users -c 'home-manager switch --flake .#isutton@suffer'
systemctl --user show filter-chain.service -p ActiveEnterTimestamp --value    # T2
```

Expected: T2 equals T1. Without this control, "the timestamp moved" in the next step would say nothing at all — it could simply be what every switch does.

- [ ] **Step 5: The measurement — change only the config's content**

```bash
printf '\n# Touched to measure whether sd-switch diffs drop-ins.\n' \
  >> pipewire/50-noise-canceling-source.conf
/usr/bin/grep -c 'Touched to measure' pipewire/50-noise-canceling-source.conf   # 1
sg nix-users -c 'home-manager switch --flake .#isutton@suffer'
systemctl --user show filter-chain.service -p ActiveEnterTimestamp --value    # T3
```

- [ ] **Step 6: Read the result**

- **T3 later than T2 → sd-switch does diff drop-ins.** The design stands as written. Record the positive result; Task 3b does not run.
- **T3 equal to T2 → sd-switch does not diff drop-ins.** The design's restart path does not work and Task 3b is mandatory. Record the negative result with equal care: it is what tells the next person not to attempt the same fix on `xdg-desktop-portal.service`.

Either way, capture the three timestamps verbatim for the results document.

- [ ] **Step 7: Remove the probe comment and switch back**

```bash
git restore --worktree pipewire/50-noise-canceling-source.conf
/usr/bin/grep -c 'Touched to measure' pipewire/50-noise-canceling-source.conf   # 0
sg nix-users -c 'home-manager switch --flake .#isutton@suffer'
```

---

## Task 3b: Fallback, ONLY if Task 3 measured "no"

**Skip this task entirely if T3 moved.**

**Files:**
- Modify: `home/audio.nix` — the `audioUnits` derivation

**Interfaces:**
- Consumes: `noiseCancelingSource` from Task 1.
- Produces: a `filter-chain.service` copy whose text carries the trigger, so the mechanism already proven for fragments applies.

- [ ] **Step 1: Append the trigger to the unit copy**

In `home/audio.nix`'s `audioUnits` derivation, after the `chmod -R u+w "$out"` line and before Guard 1, add:

```sh
    # The trigger lives in the unit's own text because sd-switch was measured
    # NOT to diff drop-ins (see docs/2026-08-20-results-suffer-pipewire-noise-reduction.md).
    # A fragment's text is diffed, so putting it here works where the drop-in
    # did not. The [Unit] section already exists in this file; appending a key
    # to the end of the file would land it in [Install] instead, so the key is
    # inserted after the Description line.
    sed -i '/^Description=PipeWire filter chain daemon$/a X-Restart-Triggers=${noiseCancelingSource}' \
      "$out/filter-chain.service"
    if ! grep -qF 'X-Restart-Triggers=' "$out/filter-chain.service"; then
      echo "The X-Restart-Triggers insertion into filter-chain.service did" >&2
      echo "not land. Upstream changed the Description line this sed anchors" >&2
      echo "on. Read the shipped unit and re-anchor it." >&2
      exit 1
    fi
```

- [ ] **Step 2: Remove the now-dead `X-Restart-Triggers` from the drop-in**

In the `xdg.configFile` entry from Task 1, delete the `[Unit]` section and its
`X-Restart-Triggers` line, leaving only:

```nix
    "systemd/user/filter-chain.service.d/10-noise-canceling-source.conf".text = ''
      [Service]
      Environment=LADSPA_PATH=${ladspaPath}
    '';
```

Update the comment above it so it no longer claims the drop-in carries the
trigger. A comment describing a mechanism the file no longer has is the defect
this repository has recorded three times.

**Two comments, not one.** `pipewire/50-noise-canceling-source.conf` also
carries the claim, in its header:

```
# home/audio.nix therefore sets LADSPA_PATH in a filter-chain.service drop-in.
# That drop-in also carries X-Restart-Triggers naming this file's store path,
# without which sd-switch leaves the service running the previous graph.
```

Rewrite the second and third lines to say the trigger sits in
`filter-chain.service` itself, and why. Then confirm neither file still claims
otherwise:

```bash
/usr/bin/grep -rn 'drop-in also carries' pipewire/ home/
# no output
```

- [ ] **Step 3: Re-run Task 3's steps 4 to 6**

Expected this time: the control leaves the timestamp still, and the content
change moves it.

- [ ] **Step 4: Commit**

```bash
git add home/audio.nix
git commit -m "audio: carry the restart trigger in the unit, not the drop-in

Measured: sd-switch does not diff drop-ins, only fragments. The
X-Restart-Triggers key therefore has to live in filter-chain.service's
own text, which is diffed. Recorded in the results document, because
xdg-desktop-portal.service was waiting on the same answer and must not
be given the drop-in treatment."
```

---

## Task 4: Verify the filter actually runs

**Files:** none. This task only measures.

**Interfaces:**
- Consumes: a switched generation from Task 3 (or 3b).
- Produces: the live evidence the results document quotes.

- [ ] **Step 1: The unit is running, not failed**

```bash
systemctl --user show filter-chain.service -p ActiveState -p SubState -p NRestarts
```

Expected: `ActiveState=active`, `SubState=running`. If it reads `failed`, the graph did not load; read `journalctl --user -u filter-chain.service -n 30` and expect a `plugin_ladspa.c` or `filter-graph.c` line naming what was not found.

- [ ] **Step 2: The source exists**

```bash
pactl list short sources | /usr/bin/grep effect_output.rnnoise
```

Expected: one line, ending `float32le 1ch 48000Hz` and a state of `SUSPENDED` or `IDLE`. Mono is correct — the graph is mono by design, and a stereo device downmixes on the way in.

- [ ] **Step 3: All eight controls are present and hold the configured values**

```bash
pw-dump > /tmp/nr-dump.json
/usr/bin/grep -oE '"(rn|gate):[^"]*"' /tmp/nr-dump.json | sort -u
```

Expected exactly nine lines: the eight controls plus `"gate:Level"`, which is a read-out rather than a control.

```
"gate:Attack (s)"
"gate:Close Threshold"
"gate:Hold (s)"
"gate:Level"
"gate:Open Threshold"
"gate:Release (s)"
"rn:Retroactive VAD Grace (ms)"
"rn:VAD Grace Period (ms)"
"rn:VAD Threshold (%)"
```

A missing name here means the config set a control PipeWire ignored — which the Task 2 guard should have caught at build time. If it did not, the guard has a hole and that is more important than this task.

- [ ] **Step 4: The loop guard is in place**

```bash
python3 - <<'PY'
import json
d = json.load(open('/tmp/nr-dump.json'))
for o in d:
    p = (o.get("info") or {}).get("props") or {}
    if "effect_" in str(p.get("node.name", "")):
        print(p.get("node.name"), "link-group:", p.get("node.link-group"))
PY
```

Expected: both nodes print the **same** `node.link-group`. That is what stops WirePlumber linking the filter's capture side to the filter's own output if the source is ever made the default.

- [ ] **Step 5: The panel row is present, and is accepted**

Open the audio panel. "Noise Canceling source" appears twice: once in the input-device list, which is the point, and once as a row in the recording-stream list, which is the accepted cost recorded in the spec. Confirm it is only these two, and that no third copy appears.

- [ ] **Step 6: A human listens**

Select "Noise Canceling source" as the input in one application. Record yourself
while a colleague talks nearby, then play it back. This step cannot be
automated and its result may be negative — the spec says so.

```bash
pw-record --target effect_output.rnnoise /tmp/nr-test.wav     # ctrl-c to stop
pw-play /tmp/nr-test.wav
```

Record what you hear, in plain words, for the results document. "The fan is
gone and the room drops out when I stop talking" and "it clips the first
syllable of every sentence" are both useful; only one of them is good news.

---

## Task 5: Tune the thresholds, then commit the numbers

**Files:**
- Modify: `pipewire/50-noise-canceling-source.conf`

**Interfaces:**
- Consumes: a running filter from Task 4.
- Produces: the shipped values. Nothing consumes them but a person.

**Why this is a separate task.** The file lands with upstream's defaults because a threshold chosen before anyone measured a level is a guess wearing the costume of a decision.

- [ ] **Step 1: Read the level while you speak**

```bash
for i in $(seq 1 30); do
  pw-dump | python3 -c '
import json, sys
def walk(x):
    if isinstance(x, dict):
        for k, v in x.items():
            if k == "params" and isinstance(v, list):
                for i in range(0, len(v) - 1, 2):
                    if v[i] == "gate:Level":
                        print(round(v[i + 1], 4))
            else:
                walk(v)
    elif isinstance(x, list):
        for y in x:
            walk(y)
walk(json.load(sys.stdin))
'
  sleep 0.5
done
```

Speak normally for the whole fifteen seconds. Write down the **lowest** number you see. Call it `SPEECH_MIN`.

Note the filter must be *in use* for a level to appear — start `pw-record --target effect_output.rnnoise /dev/null` in another terminal first, or the node is suspended and the number does not move.

- [ ] **Step 2: Read the level while only the room speaks**

Run the identical loop and say nothing. Let colleagues talk. Write down the **highest** number. Call it `ROOM_MAX`.

- [ ] **Step 3: Decide, and check the decision is possible**

If `ROOM_MAX` is greater than or equal to `SPEECH_MIN`, the gate cannot separate the two on level alone. Stop, record that as the finding, and leave the defaults in place — a threshold picked anyway would cut your own speech. This is a real possible outcome, not a failure of the work.

Otherwise:

```
Open Threshold  = SPEECH_MIN * 0.7        (rounded to two significant figures)
Close Threshold = Open Threshold * 0.75   (hysteresis: it must be lower, or the gate chatters)
```

Both must sit above `ROOM_MAX`. If `Close Threshold` lands below `ROOM_MAX`, raise both until it does not.

- [ ] **Step 4: Write the numbers into the config**

Edit `pipewire/50-noise-canceling-source.conf`, replacing the two values, and replace the comment line about defaults with the actual readings, for example:

```
                            # Measured 2026-08-20: speech floor 0.11, room peak 0.02.
                            "Open Threshold"  = 0.077
                            "Close Threshold" = 0.058
```

- [ ] **Step 5: Switch and confirm the new values are live**

```bash
sg nix-users -c 'home-manager switch --flake .#isutton@suffer'
pw-dump | /usr/bin/grep -A1 '"gate:Open Threshold"'
```

Expected: the new value. If it still reads `0.04`, the service did not restart and Task 3's answer was wrong — go back to it.

- [ ] **Step 6: Commit**

```bash
git add pipewire/50-noise-canceling-source.conf
git commit -m "audio: the gate's thresholds, from two measured levels

Open Threshold sits below the quietest measured speech and above the
loudest measured room; Close Threshold sits below Open so the gate has
hysteresis and does not chatter on a level sitting on the boundary.
Both numbers come from gate:Level readings, which is why the file
shipped with upstream's defaults until now."
```

---

## Task 6: The results document and the CLAUDE.md corrections

**Files:**
- Create: `docs/2026-08-20-results-suffer-pipewire-noise-reduction.md`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: every measurement from Tasks 2 to 5.
- Produces: the twenty-first results document, which is what makes this spec 21.

- [ ] **Step 1: Write the results document**

Follow the shape of `docs/2026-08-20-results-suffer-vm-harness-python.md`. It must contain, at minimum:

- The three timestamps from Task 3 and the answer they give, stated as an answer to `CLAUDE.md`'s open question, whichever way it came out.
- The three mutations from Task 2, each with the guard message it produced, as the proof that the guard can fail.
- Task 4's live evidence, quoted rather than summarised.
- Task 5's two measured levels, or the finding that they could not be separated.
- The human verdict from Task 4 step 6, in the words it was given, including a negative one.
- The `nofail` departure from upstream's example, and why.
- What was **not** measured: the CPU cost of RNNoise per stream, and how the panel row renders beyond its `media.class`.

- [ ] **Step 2: Correct `CLAUDE.md`'s guard enumeration**

`CLAUDE.md` states a count for `home/audio.nix` that this work moves. Re-measure rather than edit the number by hand:

```bash
/usr/bin/grep -c 'exit 1' home/audio.nix
sed -n "/pulseaudioClients = pkgs.runCommand/,/^  '';$/p" home/audio.nix | /usr/bin/grep -c 'exit 1'
```

The first number was 9 before this work and will be larger. Update the passage that quotes it, and add `noiseCancelingGuard` to the enumeration of guards that ride in `home.packages` — where `pulseaudioClients` is already named.

- [ ] **Step 3: Add the LADSPA path trap to "Tools that answer a different question"**

A new entry, with the measured error text:

```
**A `plugin` field in a PipeWire filter-chain config is not a path.** PipeWire
appends `.so` and looks the result up in a directory list, so an absolute
/nix/store path is refused outright:

    failed to load plugin '/nix/store/…/librnnoise_ladspa' in
    '/usr/lib64/ladspa:/usr/lib/ladspa:/nix/store/…-pipewire-1.6.6/lib'

Note the search list contains no directory this flake controls, so the answer
is to set LADSPA_PATH in the unit's own drop-in — the opposite of the fix for
`ExecStart=fumon`, where an absolute path was the answer.
```

- [ ] **Step 4: Answer the open drop-in question in `CLAUDE.md`**

Find the `xdg-desktop-portal.service` entry that reads "whether sd-switch diffs drop-ins as well as fragments **has not been measured here** — verify that before relying on it." Replace the unmeasured clause with Task 3's result and the three timestamps, and say what it means for the portal fix specifically.

- [ ] **Step 5: Commit**

```bash
git add docs/2026-08-20-results-suffer-pipewire-noise-reduction.md CLAUDE.md
git commit -m "docs: spec 21 results, and the drop-in question answered

The noise-canceling source is live and its guard is proven by three
mutations, one of them the vacuity anchor. The measurement CLAUDE.md
had been carrying as open -- whether sd-switch diffs drop-ins as well
as fragments -- is answered here with three timestamps and a control,
which also settles what xdg-desktop-portal.service can be given."
```

- [ ] **Step 6: Confirm the spec count**

```bash
ls -1 docs/*results-suffer-*.md | wc -l
# 21
```

Count it. Never increment a remembered number: `CLAUDE.md` opens by recording that spec 10 landed saying "Nine" because one document had bumped the count twice and another not at all.

---

## Self-Review

**Spec coverage.** Every section of the spec maps to a task. Decisions 1 and 2 (the graph, following the default input) are Task 1 step 3. Decision 3 (extra device, not default) is realised by *not* changing the default anywhere, and verified in Task 4 step 5. Decision 4 (`LADSPA_PATH`) is Task 1 steps 5 and 6, and re-asserted by the guard's `PLUGIN` branch in Task 2. Decision 5 (measure the drop-in question) is Task 3, with Task 3b as the fallback the spec requires. Decision 6 (the guard) is Task 2, including the vacuity anchor the spec names. Decision 7 (tuning as a second commit) is Task 5. The spec's five tests are Tasks 2, 3 and 4; its "not measured" list is carried into Task 6 step 1 rather than dropped.

**One addition beyond the spec**, called out rather than smuggled in: the config omits `flags = [ nofail ]`, which PipeWire's own example carries. The spec mentioned `nofail` only as the reason a guard is needed. Omitting it makes a broken graph fail the unit loudly instead of producing a service that filters nothing, and the unit's `Restart=on-failure` with `StartLimitBurst=5` bounds that to five attempts rather than a loop. It is recorded in the File Structure note and in Task 6's results document.

**Placeholder scan.** No step defers work. Every code step carries the code. The two conditional paths — Task 3b, and Task 5 step 3's "the levels cannot be separated" branch — each state their trigger and their full content rather than saying "handle this case".

**Name consistency.** `noiseCancelingSource`, `ladspaPath` and `noiseCancelingGuard` are defined in Task 1 and Task 2 and used with those exact spellings in Tasks 1, 2 and 3b. The node names `effect_input.rnnoise` and `effect_output.rnnoise`, the filter node names `rn` and `gate`, and the six control strings the config sets are identical in the config and in the guard's expected output; Task 4's verification counts the eight the plugins expose, which is a different number on purpose.
