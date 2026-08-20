# Spec 21: a noise-canceling source, built from what PipeWire already ships

> **ERRATUM, 2026-08-20, added after implementation.** This design's gate is
> PipeWire's builtin `noisegate`, and the builtin **cannot open**: its `Level`
> port loads as an INPUT control with range 0.0-0.0 and the node declares
> `n_notify:0`, so the level it compares against its own threshold is
> permanently zero and any threshold above zero holds it shut forever. It made
> the machine's microphone permanently silent, every guard in this document's
> plan passed while it did, and a person found it by listening. The shipped
> gate is swh-plugins' `gate_1410`, label `gate`, from `pkgs.ladspaPlugins` —
> **not** the builtin, and **not** a drop-in replacement: its controls are in
> DECIBELS and MILLISECONDS, not the linear amplitude and seconds tables below,
> and its input port is named `Input`, not `In`. Every control table, every
> tuning formula and every `gate:Level`/`gate:Open Threshold`/`gate:Close
> Threshold` reference below describes the superseded builtin and must not be
> applied to the shipped config. The authority for what was actually built and
> shipped is `docs/2026-08-20-results-suffer-pipewire-noise-reduction.md`.

**Branch:** `worktree-pipewire-noise-reduction`
**Written:** 2026-08-20
**Status:** implemented, with deviation — see the erratum above and the results document
**Follows:** spec 20, `docs/superpowers/specs/2026-08-20-vm-harness-python-design.md`

---

## The problem

Two things reach the far end of a call that should not: steady noise — a fan, the
street, a keyboard — and colleagues talking in the same room.

Those are two different problems and only one of them has a denoiser-shaped
answer. **RNNoise is trained to keep speech and discard everything else, so a
colleague's voice passes straight through it.** So does DeepFilterNet, for the
same reason. Any spec that promises "noise reduction" and stops there has
answered half the request and will be read as having answered all of it.

The other half is a gate. A gate closes the microphone while you are not
speaking, which is where the far end hears the room. It does nothing about a
colleague who talks *while you talk*, and nothing in open-source PipeWire does.
That limit is stated here rather than discovered later.

## What the machine already has

Four measurements taken before the design, because three of them changed it.

**`filter-chain.service` is already installed, enabled and running.** It comes
from `home/audio.nix`'s existing unit set, it is listed in
`wants."default.target.wants"`, and it has been running an empty graph since
that module landed — `git log -S 'filter-chain.service' -- home/audio.nix`
returns exactly one commit, `54b1442`, which added it and was never followed:

```
ExecStart={ path=/nix/store/…-pipewire-1.6.6/bin/pipewire ;
            argv[]=…/bin/pipewire -c filter-chain.conf }
ActiveState=active   SubState=running   NRestarts=0
FragmentPath=/home/isutton/.config/systemd/user/filter-chain.service
```

`~/.config/pipewire/filter-chain.conf.d/` does not exist, so it loads no filter.
The unit half of this work is already done and must not be redone.

**PipeWire 1.6.6 ships a `noisegate` builtin.** It is in
`lib/spa-0.2/filter-graph/libspa-filter-graph-plugin-builtin.so`, with controls
`Open Threshold`, `Close Threshold`, `Attack (s)`, `Hold (s)`, `Release (s)`.
The gate therefore costs no package at all. This was found by reading the
library, not by remembering a feature list.

**The pinned nixpkgs has `rnnoise-plugin-1.10`,** which ships exactly one LADSPA
object, `lib/ladspa/librnnoise_ladspa.so`, exporting `noise_suppressor_mono` and
`noise_suppressor_stereo`. It also has `deepfilternet-0.5.6`, whose derivation
packages *only* the LADSPA plugin (`buildAndTestSubdir = "ladspa"`). Read those
through this flake's own `pkgs`, never through `nixpkgs#` — see `CLAUDE.md`.

**The graph runs, and it was run before it was written down.** A throwaway
`pipewire -c` client, pointed at a scratch `XDG_CONFIG_HOME` holding the
fragment, produced a real source alongside the real devices:

```
$ pactl list short sources
…
1401  fragtest_output.rnnoise  PipeWire  float32le 1ch 48000Hz  SUSPENDED
```

with an empty log. Both probes were removed afterwards and the session's own
`pipewire`, `wireplumber` and `filter-chain` units stayed `active` throughout.

## Decisions

| # | Decision | Excludes |
|---|---|---|
| 1 | **RNNoise plus the builtin `noisegate`**, in one graph | A denoiser alone, which answers half the request |
| 2 | The capture side names **no target**, so it follows the default input | A per-device filter, and a config that breaks when the headset is off |
| 3 | The filtered source is an **extra device**, selected in the audio panel | Making it the default, where a filter failure means no microphone at all |
| 4 | The plugin is found through **`LADSPA_PATH` in a unit drop-in** | An absolute path in the config, which does not work |
| 5 | The same drop-in carries **`X-Restart-Triggers`**, and whether sd-switch honours a drop-in is **measured, not assumed** | A silent no-op switch |
| 6 | One **build-time guard**, parsing the config by syntax | A hand-written list of plugin labels and control names |
| 7 | The file lands with upstream defaults; **tuning is a second commit** | A threshold guessed before anyone measured a level |

## The graph

```
default input device
  └─► effect_input.rnnoise        capture, node.passive = true, no target.object
        └─► rn    ladspa   librnnoise_ladspa / noise_suppressor_mono
              └─► gate  builtin  noisegate
                    └─► effect_output.rnnoise
                          media.class = Audio/Source
                          node.description = "Noise Canceling source"
```

Mono throughout. The Bluetooth headset is already `float32le 1ch`; the two
internal analogue microphones are 2ch and the adapter downmixes them on the way
in. Mono is correct for a microphone and halves the filter work.

**The loop question is answered by `node.link-group`.** If the filtered source
ever becomes the default, its own capture node must not link to it. Measured on
the running probe, both nodes carry the same group:

```
node.name = test_effect_input.rnnoise    node.link-group = filter-chain-207250-8
node.name = test_effect_output.rnnoise   node.link-group = filter-chain-207250-8
```

WirePlumber does not choose a target inside the link group it is linking from,
so the loop cannot form. This is recorded because decision 3 keeps the filter
off the default *by policy*, and policy can change; the mechanism is what makes
that change safe.

> **SUPERSEDED — describes the builtin `noisegate`, not the shipped gate.**
> The table and the `gate:Level` paragraph below are about PipeWire's builtin
> filter, which cannot open (see the erratum at the top of this document) and
> was never shipped tuned. The shipped gate is swh-plugins' `gate_1410`; its
> control names, units (decibels, milliseconds) and tuning method are
> unrelated to what follows. Do not apply any value here to the shipped
> config. See `docs/2026-08-20-results-suffer-pipewire-noise-reduction.md`'s
> tuning section for the real method and the real names.
>
> **All eight controls are node properties, addressable as `<node>:<control>`.**
> Read off the running probe, with upstream's defaults:
>
> | control | default |
> |---|---|
> | `rn:VAD Threshold (%)` | 50 |
> | `rn:VAD Grace Period (ms)` | 500 |
> | `rn:Retroactive VAD Grace (ms)` | 100 |
> | `gate:Open Threshold` | 0.04 |
> | `gate:Close Threshold` | 0.03 |
> | `gate:Attack (s)` | 0.005 |
> | `gate:Hold (s)` | 0.05 |
> | `gate:Release (s)` | 0.01 |
>
> `gate:Level` is a ninth entry and is a *read-out*, not a control. It is the
> tuning instrument: read it while you speak, read it again while only the room
> speaks, and the two thresholds go between the two numbers.

## The files

| file | change |
|---|---|
| `pipewire/50-noise-canceling-source.conf` | new; the graph above, as plain text holding no store path |
| `home/audio.nix` | install it into `pipewire/filter-chain.conf.d/`; add a `filter-chain.service.d` drop-in; add the guard |

The config file sits beside `pipewire/20-block-source-volume.conf` and is
installed the same way that file is, through `xdg.configFile` with a `source =`.
Note that both files answer to the `source =` rule at the top of `CLAUDE.md`:
a change to either means the check list applies.

`pkgs.rnnoise-plugin` needs **no `home.packages` entry**. The drop-in names its
store path, so the generation holds the reference and the garbage collector
cannot take it. Adding it to `home.packages` would put a LADSPA object on
`XDG_DATA_DIRS` for no reader.

### Trap 1: an absolute plugin path does not work

PipeWire appends `.so` to the `plugin` field and looks the result up in a
directory list. It does not treat an absolute path as a path. Measured:

```
[E] plugin_ladspa.c: failed to load plugin
    '/nix/store/…-rnnoise-plugin-1.10/lib/ladspa/librnnoise_ladspa' in
    '/usr/lib64/ladspa:/usr/lib/ladspa:/nix/store/…-pipewire-1.6.6/lib'
```

Note what that message proves twice over: the absolute path failed, *and* the
search list contains no `/nix/store` entry that this flake controls. So the
config says `plugin = "librnnoise_ladspa"` and the drop-in sets

```
Environment=LADSPA_PATH=${pkgs.rnnoise-plugin}/lib/ladspa
```

With that variable set, the identical graph loaded with an empty log.

This is the same species as the `ExecStart=fumon` defect in `home/uwsm.nix`: a
name resolved against a search path that no `/nix/store` entry will ever join.
There it was fixed with an absolute path. Here an absolute path is refused, so
the search path itself must be set.

### Trap 2: sd-switch does not see a config-only change

`CLAUDE.md`'s longest-standing mechanism entry: sd-switch restarts a unit when
the unit *file* changes, not when the files the unit reads change. A change
confined to `filter-chain.conf.d/` leaves `filter-chain.service` byte-identical,
sd-switch correctly does nothing, and the service keeps serving the previous
graph from a store path with no symlink pointing at it. The switch succeeds and
the change has no effect. Every quickshell change before spec 11 had this bug.

The fix in `home/quickshell.nix` is `Unit.X-Restart-Triggers` naming the config's
store path. Here that key goes into the drop-in, which raises the question
`CLAUDE.md` explicitly marks unmeasured:

> whether sd-switch diffs drop-ins as well as fragments has not been measured
> here — verify that before relying on it.

**So this spec measures it.** The measurement is one step of the plan, not a
footnote, and its result is a deliverable in its own right:
`xdg-desktop-portal.service` carries the identical defect and the identical fix
is blocked on the identical answer.

- **Method.** Change one comment in `pipewire/50-noise-canceling-source.conf`,
  which changes its store path, which changes the drop-in's text and nothing
  else. Switch. Read `filter-chain.service`'s `ActiveEnterTimestamp`.
- **Not `NRestarts`.** sd-switch stops and starts the unit, and a fresh start
  resets that counter, so `NRestarts=0` is not evidence against a restart.
- **Control.** A second switch that changes nothing must leave the timestamp
  still. Without the control, "the timestamp moved" says nothing.
- **Fallback if the answer is no.** Append the trigger to the
  `filter-chain.service` copy inside the `audioUnits` derivation, where a text
  change is already proven to force a restart. Record the negative result in
  `CLAUDE.md` either way — it is worth as much as the positive one.

## The guard

One `runCommand` in `home/audio.nix`'s `home.packages`, so it runs on **every
generation build** rather than only under `nix flake check`. That is the shape
`CLAUDE.md` describes for `wrappedGuiApps`, `pulseaudioClients`,
`nixglSingleSource` and `noStorePaths`, and it is chosen for frequency.

It parses `pipewire/50-noise-canceling-source.conf` **by syntax** and asserts
what it finds:

1. Extract every `plugin = "…"`, every `label = …`, and every quoted control key.
2. `${pkgs.rnnoise-plugin}/lib/ladspa/librnnoise_ladspa.so` exists, and contains
   the LADSPA label and every rnnoise control name the config uses.
3. PipeWire's `libspa-filter-graph-plugin-builtin.so` contains `noisegate` and
   every gate control name the config uses.
4. **Vacuity anchor:** fail if the parse yields zero labels or zero controls.

Point 4 is not decoration. Without it the guard prints an `ok` line per file and
requires nothing of any of them, which is the defect `gui-desktop-ids` and
`no-pulseaudio-daemon` each carry an anchor to prevent.

Point 1 is the reason this is a guard rather than a comment. A list of control
names written by hand goes stale silently; a list read out of the file cannot
disagree with the file.

**Why a guard at all:** PipeWire's own example config carries
`flags = [ nofail ]`. A label renamed upstream would produce a service that
starts, logs one line and serves no filter — a failure that looks exactly like
success from every angle except a recording.

**Implementation notes for the builder.** It greps the libraries with
`grep -qaF`, so it needs no `strings` and adds no `nativeBuildInputs`; note
`CLAUDE.md`'s count of two `nativeBuildInputs` is about `flake.nix`, not about
`home/*.nix`. Every test is a **condition** (`if ! grep -qaF … ; then`), because
a builder runs with `set -e` and `pipefail`, and a bare `n="$(grep -c …)"`
aborts the build on a zero count instead of reporting one.

## Tests

1. `nix flake check` still counts **8**. Count it, do not quote it:
   `sg nix-users -c 'nix flake check' 2>&1 | grep -c '^checking derivation checks\.'`
2. The generation builds, and the new guard is in it.
3. **The guard is proven by mutation.** Rename the label in the config, confirm
   the build fails with the guard's own message, then `git restore --worktree`
   — not `--staged --worktree`, which restores from HEAD and deletes a file new
   to the branch. Re-read the file afterwards and confirm the revert took.
   Commit the real work before the mutation, so every revert is recoverable.
4. **The sd-switch measurement**, with its control, as set out above.
5. Live: `pactl list short sources` shows `effect_output.rnnoise`, and `pw-dump`
   shows the eight controls at the values the config sets.
6. **Human, and not automatable:** select "Noise Canceling source" in the audio
   panel, then record while a colleague talks. One person and one recording.

## Tuning is a second commit

> **SUPERSEDED — this method describes the builtin `noisegate`, which exposes
> a `gate:Level` read-out.** The shipped gate, swh's `gate_1410`, declares
> `n_notify:0` like the builtin does — it exposes no level read-out at all —
> so `pw-dump | grep -A1 '"gate:Level"'` finds nothing for it. This is the
> same trap as the headline defect, met a second time on a different plugin.
> See `docs/2026-08-20-results-suffer-pipewire-noise-reduction.md`'s tuning
> section for the method that replaced this one, and for why the shipped
> config's threshold ultimately stayed at its floor.

The file lands with upstream's defaults. A threshold picked before anyone
measured a level is a guess presented as a decision. The method:

```sh
pw-dump | grep -A1 '"gate:Level"'      # while you speak, then while only the room speaks
```

The two thresholds go between the two readings, with `Close Threshold` below
`Open Threshold` so the gate has hysteresis and does not chatter. Then the
numbers go into the config file and the guard re-runs on the next build.

## Out of scope

- **No echo cancellation.** No echo was reported, and
  `libpipewire-module-echo-cancel` is a different module with a different graph.
- **No DeepFilterNet.** It is packaged and available, its LADSPA plugin is the
  only thing nixpkgs builds of it, and the graph shape is identical — so it
  stays a one-node swap if RNNoise disappoints. It needs a Rust build that is
  not in the binary cache, and it would not help with chatter either.
- **No change to the default source.** The raw microphones stay default, per
  decision 3.
- **No quickshell change.** `AudioService.qml` already lists sources and already
  writes `Pipewire.preferredDefaultAudioSource`, so the new device is selectable
  with no code.
- **`pipewire/20-block-source-volume.conf` is untouched.** It solves a different
  problem — Chrome raising the capture device's gain — and the two do not
  interact.

## Known and accepted

**The audio panel gains a permanent row.** The capture node reports
`media.class = Stream/Input/Audio` (measured), and
`quickshell/audio/AudioService.qml:52` builds `recordStreams` from exactly that
class. So a row named "Noise Canceling source" will sit in the recording list
beside Chrome and Slack for as long as the filter exists. Accepted in chat
rather than worked around.

**Nothing here removes a colleague who talks while you talk.** Stated once at
the top and repeated here, because this is the sentence most likely to be
forgotten between the spec and the results document.

## Not measured

Recorded so that no later document mistakes an assumption for a result.

- **Whether sd-switch diffs drop-ins — ANSWERED, this branch.** It does. See
  `docs/2026-08-20-results-suffer-pipewire-noise-reduction.md`'s "The
  sd-switch drop-in question, ANSWERED" section for the T0-T4 measurement and
  its control; the fallback in this document was not needed.
- **How the panel row actually renders.** The `media.class` is measured; the
  QML's treatment of it is read from the source, not seen on screen.
- **CPU cost.** RNNoise per stream was not measured on this machine. It is
  believed small and that belief is untested.
- **Whether the gate helps in practice.** The graph is proven to load and to
  produce a source. That it improves a real call is a human judgement that test
  6 exists to collect, and it may come back negative.
