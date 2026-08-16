# Results: the audio stack — suffer

2026-08-16

Spec: `docs/superpowers/specs/2026-08-16-audio-stack-design.md`
Plan: `docs/superpowers/plans/2026-08-16-audio-stack.md`

## Phase 0: baseline and rehearsal

### Pinned versions

```
$ sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".pkgs.pipewire'
/nix/store/50nsbrhj7b4kv16p3xarhgrdylzfaymw-pipewire-1.6.6-man
/nix/store/kwcxxq18wrh6s4r5573jy2v2padf8vk3-pipewire-1.6.6

$ sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".pkgs.wireplumber'
/nix/store/gnvd0pfyxahyw4k7m5kki0ad75mzwws8-wireplumber-0.5.14

$ sg nix-users -c 'nix eval --raw .#homeConfigurations."isutton@suffer".pkgs.pipewire.version'; echo
1.6.6

$ sg nix-users -c 'nix eval --raw .#homeConfigurations."isutton@suffer".pkgs.wireplumber.version'; echo
0.5.14
```

`$PW=/nix/store/kwcxxq18wrh6s4r5573jy2v2padf8vk3-pipewire-1.6.6` (the package
output, not `-man`) and `$WP=/nix/store/gnvd0pfyxahyw4k7m5kki0ad75mzwws8-wireplumber-0.5.14` —
every later step in this task uses these two paths.

`nixpkgs#pipewire` and `nixpkgs#wireplumber` read the flake registry
(nixpkgs-unstable), not this flake's pinned input, and report `1.6.8` and
`0.5.15` respectively — a different pair of versions from what actually gets
installed. `1.6.6` / `0.5.14` are the pinned input's versions, confirmed by
`nix build` rather than `nix eval`: `eval` prints a path without realising it,
and this task needed the binaries to actually exist for Steps 7–9.

### The Debian baseline

Recorded read-only, before anything was stopped:

```
=== Debian package versions
ii  libcanberra-pulse 0.30-18
ii  libspa-0.2-bluetooth 1.4.2-1
ii  pipewire 1.4.2-1
ii  pipewire-bin 1.4.2-1
ii  pipewire-pulse 1.4.2-1
ii  pulseaudio-utils 17.0+dfsg1-2+b1
ii  rtkit 0.13-5.1
ii  wireplumber 0.5.8-2

=== unit files
UNIT FILE              STATE    PRESET
filter-chain.service   enabled  enabled
pipewire-pulse.service enabled  enabled
pipewire.service       enabled  enabled
wireplumber.service    enabled  enabled
wireplumber@.service   disabled enabled
pipewire-pulse.socket  enabled  enabled
pipewire.socket        enabled  enabled

7 unit files listed.

=== running state
MainPID=3007
NRestarts=0
Id=pipewire.service
ActiveState=active
FragmentPath=/usr/lib/systemd/user/pipewire.service

MainPID=3012
NRestarts=0
Id=pipewire-pulse.service
ActiveState=active
FragmentPath=/usr/lib/systemd/user/pipewire-pulse.service

MainPID=3011
NRestarts=0
Id=wireplumber.service
ActiveState=active
FragmentPath=/usr/lib/systemd/user/wireplumber.service

MainPID=3009
NRestarts=0
Id=filter-chain.service
ActiveState=active
FragmentPath=/usr/lib/systemd/user/filter-chain.service

=== which binary is actually serving
pipewire         pid=3007    exe=/usr/bin/pipewire usr-maps=177
pipewire-pulse   pid=3012    exe=/usr/bin/pipewire usr-maps=157
wireplumber      pid=3011    exe=/usr/bin/wireplumber usr-maps=337
filter-chain     pid=3009    exe=/usr/bin/pipewire usr-maps=87

=== realtime scheduling
pipewire       pid 3007's current scheduling policy: SCHED_OTHER|SCHED_RESET_ON_FORK;pid 3007's current scheduling priority: 0;pid 3007's current runtime parameter: 2800000
module-rt      pid 3015's current scheduling policy: SCHED_OTHER;pid 3015's current scheduling priority: 0;pid 3015's current runtime parameter: 2800000
data-loop.0    pid 3016's current scheduling policy: SCHED_RR|SCHED_RESET_ON_FORK;pid 3016's current scheduling priority: 20

=== devices
48	alsa_card.pci-0000_03_00.1	alsa
49	alsa_card.pci-0000_03_00.6	alsa
56	alsa_output.pci-0000_03_00.6.HiFi__Speaker__sink	PipeWire	s32le 2ch 48000Hz	SUSPENDED
56	alsa_output.pci-0000_03_00.6.HiFi__Speaker__sink.monitor	PipeWire	s32le 2ch 48000Hz	SUSPENDED
57	alsa_input.pci-0000_03_00.6.HiFi__Mic2__source	PipeWire	s32le 2ch 48000Hz	SUSPENDED
58	alsa_input.pci-0000_03_00.6.HiFi__Mic1__source	PipeWire	s32le 2ch 48000Hz	SUSPENDED

(cards: 2 lines; sinks: 1 line; sources: 3 lines — monitor + Mic2 + Mic1 —
counted explicitly by splitting the combined "=== devices" block from the
three separate pactl invocations)

=== bluez5 plugin counts
nix    14
debian 9

=== apt marks
pulseaudio-utils
rtkit
```

The `dpkg-query` command names eight packages
(`pipewire pipewire-bin pipewire-pulse wireplumber libspa-0.2-bluetooth
libcanberra-pulse pulseaudio-utils rtkit`); all eight report `ii` on this
machine. The plan's Step 2 prose says "six `ii` packages plus `rtkit`," which
undercounts its own query by omitting `pulseaudio-utils` from the tally — a
discrepancy in the plan's summary, not a mismatch in what the machine holds.
The baseline recorded here is the full eight, at the versions above.

`pulseaudio-utils` and `rtkit` both print under `apt-mark showauto`: neither
is marked manual today, which is why the plan marks both manual before Task 4
removes anything — `rtkit` grants `data-loop.0` the `SCHED_RR` priority-20
scheduling shown above, and losing it to a later `autoremove` would read as a
regression from the version bump rather than from a package mark.

### The alias, before

```
$ systemctl --user show pipewire-session-manager.service -p Id -p Names -p LoadState
Id=pipewire-session-manager.service
Names=pipewire-session-manager.service
LoadState=not-found
```

Debian's `pipewire-pulse.service` names `wireplumber.service` directly and
never uses the generic alias name, so `pipewire-session-manager.service` is
unloaded today — the property Task 3 will gate on (`LoadState=loaded`) is
**false right now**. Recording the absent state first is what gives a later
`loaded` its meaning: a check that cannot distinguish "the alias resolves"
from "the alias was never tested" is worthless, and this is the measurement
that rules the second reading out.

### The alias probe

Four variants were measured by hand while the Debian stack was stopped, each
created at `~/.config/systemd/user/pipewire-session-manager.service` and read
back with `systemctl --user daemon-reload` in between:

| variant | alias link's immediate target | result |
|---|---|---|
| store path (what `xdg.configFile` produces) | `/nix/store/…-wireplumber-0.5.14/share/systemd/user/wireplumber.service` | `Id=pipewire-session-manager.service` — a second independent unit, NOT an alias |
| store path, with `wireplumber.service` also present in the directory | same | same — so "the target basename names no loadable unit" is excluded as the cause |
| relative link to sibling (`wireplumber.service`) | `wireplumber.service` | `Id=wireplumber.service`, `Names=wireplumber.service pipewire-session-manager.service` — a true alias |
| absolute link to sibling | `/home/isutton/.config/systemd/user/wireplumber.service` | true alias |

The rule this establishes: **systemd decides on the symlink's immediate
target, not the fully chased one.** In the absolute-sibling case the chase
also terminates in the store — `~/.config/systemd/user/wireplumber.service`
is itself the target of a separate symlink into `/nix/store` — and it aliases
anyway. Only the first hop matters.

The consequence: `xdg.configFile` always emits
`~/.config/… -> /nix/store/<home-manager-files>/.config/…`, so it can never
produce an alias by itself, however its `.source` is written. Task 2's alias
entry as planned — an `xdg.configFile` pointing straight at
`$WP/share/systemd/user/wireplumber.service` — would have installed a
*second*, independent wireplumber unit under the alias name, and
`pipewire-pulse.service`'s `Wants=pipewire-session-manager.service` would
have started it: two session managers racing against the same pipewire core,
with nothing in `--state=failed` to show it, since `Wants=` on a resolvable
name is silent about which unit it resolved to.

No Home Manager mechanism closes this from inside `xdg.configFile`:
`modules/systemd.nix` has no `Install.Alias` handling at all (`grep -n Alias`
on the fetched source returns no matches), and this project's units bypass
that module's `Install`-handling code (`buildService`) anyway by installing
directly through `xdg.configFile`. `sd-switch` does not help either —
`strings` on the binary shows `daemon-reload` present but `enable`,
`disable`, `Alias`, `Install` and `symlink` all absent; it starts and stops
units between generations and never creates or reasons about alias links.
Even `config.lib.file.mkOutOfStoreSymlink` fails the immediate-target rule:
it is merged into `home.file` and linked through the same store-mediated
`home-files` generation derivation as every other `xdg.configFile` entry, so
hop 1 from `~/.config/systemd/user/…` still lands in `/nix/store` — the
measured failing shape — even though the chain eventually resolves to the
right sibling file three hops later. The only mechanism that produces a true
alias under standalone Home Manager is a raw `ln -s` run from
`home.activation` after `linkGeneration`, bypassing the store-mediated linker
entirely — a pattern this repo already uses in `apps.nix`, `foot.nix`,
`hyprland.nix` and `gtk.nix`.

### The rehearsal

**Attempt 1 (INVALID).** Nix's binaries were started with the session's
ordinary `XDG_DATA_DIRS`, which had no `~/.nix-profile/share/wireplumber`
because `wireplumber` is not in `home.packages` until Task 2 — so
`/usr/share/wireplumber`, Debian's script tree, was the only copy on the
path. Nix's `wireplumber-0.5.14` binary ran Debian's `0.5.8` Lua scripts, and
`wireplumber.service`'s log showed four identical tracebacks:

```
[string "state-routes.lua"]:119: bad argument #1 to 'next' (table expected, got GBoxed)
```

read at the time as a bug in 0.5.14. It is not one. Line 119 differs between
the two script trees:

| | `state-routes.lua:119` |
|---|---|
| Debian 0.5.8 | `if next (selected_routes) == nil then` — the line that threw |
| Nix 0.5.14 | `return` (the guard moved to line 117, `selected_routes:get_count () == 0`) |

0.5.8's script calls Lua's `next()` on what 0.5.14's `wireplumber` binary now
passes as a `Properties` GBoxed object rather than a plain table — a
binary/script version mismatch, not a defect in either version taken alone.
The same log also carried `wp-device: SPA handle 'api.alsa.acp.device' could
not be loaded` and `alsa.lua:392:createDevice: Failed to create
'api.alsa.acp.device' device` — line 392 is Debian's line number, corroborating
that the whole script tree in use was Debian's.

**Attempt 2 (VALID).** Re-run with `XDG_DATA_DIRS` corrected to lead with
Nix's own share trees:

```
XDG_DATA_DIRS=/nix/store/gnvd0pfyxahyw4k7m5kki0ad75mzwws8-wireplumber-0.5.14/share:/nix/store/kwcxxq18wrh6s4r5573jy2v2padf8vk3-pipewire-1.6.6/share:<session default>
```

Log line counts across all four processes:

```
filter-chain.log       lines=0    state-routes=0   acp=0
pipewire.log           lines=0    state-routes=0   acp=0
pipewire-pulse.log     lines=0    state-routes=0   acp=0
wireplumber.log        lines=5    state-routes=0   acp=2
```

Zero `state-routes.lua` tracebacks. The residual ACP warning is still
present, but its line number moved:

```
W 12:35:03.944151         s-monitors alsa.lua:397:createDevice: Failed to create 'api.alsa.acp.device' device
```

`alsa.lua:397`, not Debian's `:392` — independent evidence, from a source the
rehearsal did not set out to check, that the script tree actually switched
between the two attempts.

Provenance of the four running processes, all `usr-maps=0`:

```
pid=728770  exe=/nix/store/kwcxxq18wrh6s4r5573jy2v2padf8vk3-pipewire-1.6.6/bin/pipewire
pid=728933  exe=/nix/store/gnvd0pfyxahyw4k7m5kki0ad75mzwws8-wireplumber-0.5.14/bin/wireplumber
pid=729109  exe=/nix/store/kwcxxq18wrh6s4r5573jy2v2padf8vk3-pipewire-1.6.6/bin/pipewire
pid=729128  exe=/nix/store/kwcxxq18wrh6s4r5573jy2v2padf8vk3-pipewire-1.6.6/bin/pipewire
```

Devices: both ALSA cards enumerate (`alsa_card.pci-0000_03_00.1` off,
`alsa_card.pci-0000_03_00.6` profile `HiFi (Mic1, Mic2, Speaker)`), plus a
third card and sink/source pair for the JBL once it connected
(`bluez_card.E4_61_F4_29_55_BA`, profile `a2dp-sink`). `pactl info` reports
`Server Name: PulseAudio (on PipeWire 1.6.6)`.

By hand, reported by the user:

1. Sound from the speakers: **YES**.
2. The JBL Tune 520BT connects and plays over A2DP: **YES**.
3. A real call using the JBL's microphone over HFP: **YES** — the codec path
   `libspa-0.2-bluetooth 1.4.2-1` never exercised, since Debian's build ships
   9 bluez5 plugins against Nix's 14.

The one residual: a single `api.alsa.acp.device` create failure roughly two
seconds after pipewire started, which recovered — both cards enumerate and
are profiled by the time the device list above was taken. Under the real
units this ordering is enforced by `After=pipewire.service` plus `BindsTo=`,
not by the hand-run sleep between binaries this rehearsal used.

### Verdict

**GO.** Nix's `pipewire-1.6.6` and `wireplumber-0.5.14` play, connect the
JBL over A2DP, and carry a real HFP call, once run against their own script
tree. Two consequences carry forward into later tasks:

**(a) Task 2's planned comment that `home.packages` "alone changes nothing at
runtime" is false for wireplumber.** Attempt 1 is the proof: adding
`wireplumber` to `home.packages` is what puts Nix's Lua scripts ahead of
Debian's on `XDG_DATA_DIRS`, and without it 0.5.14's binary runs 0.5.8's
scripts and throws. The mechanism holds — the user manager's own
`XDG_DATA_DIRS`, read with `systemctl --user show-environment`, does lead
with `~/.nix-profile/share` — but it holds by mechanism, and Task 2 must
write that down rather than repeat the general claim unqualified. pipewire is
not exposed this way: it resolves `filter-chain.conf` and its other config
through its own compiled-in datadir, not through `XDG_DATA_DIRS`, which is
what Step 7's fourth process (`pipewire -c filter-chain.conf`) was run to
confirm.

**(b) Task 3 gains two gate items, both proven able to fail during this
rehearsal:**
- Zero `state-routes.lua` tracebacks in `wireplumber.service`'s journal —
  attempt 1 produced four.
- Zero `api.alsa.acp.device` create failures after a cold boot — attempt 2
  produced one, recovered, and unexplained by anything other than ordering
  at process start; the real units' `After=`/`BindsTo=` needs to be shown to
  close it, not assumed to.

The alias probe is a separate, harder finding: Task 2's planned
`xdg.configFile` alias entry cannot work as written, in any variant of its
`.source`. `home.activation` with a raw `ln -s` to the sibling unit — already
an established pattern in this repo — is the mechanism that measured true,
and Task 2 needs to move to it before anything is switched.
