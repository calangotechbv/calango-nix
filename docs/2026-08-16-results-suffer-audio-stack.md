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

## Phase 1: the switch

### What sd-switch intended

`sd-switch` extracted from the live activation script (0.6.3), **not** from
`nixpkgs#sd-switch` — the registry and this flake's pinned input give
different versions, and dry-running with a different binary than the switch
will use is worthless:

```
sd-switch 0.6.3, --dry-run --verbose
  old: /nix/store/03ckq61w77vcp61k12gwx67wddrgz8dd-home-manager-generation
  new: /nix/store/w0lv4m5b0sgaqfbs7bi0bm201zphpfrr-home-manager-generation

Keeping unchanged units: app-graphical.slice, background-graphical.slice,
  bt-agent.service, fumon.service, hypridle.service, hyprpolkitagent.service,
  night-light.service, nm-secret-agent.service, quickshell.service,
  wayland-session-bindpid@3035.service,
  wayland-session-envelope@hyprland\x2dnixgl.desktop.target,
  wayland-session-pre@hyprland\x2dnixgl.desktop.target,
  wayland-session-xdg-autostart@hyprland\x2dnixgl.desktop.target,
  wayland-session@hyprland\x2dnixgl.desktop.target,
  wayland-wm-env@hyprland\x2dnixgl.desktop.service,
  wayland-wm@hyprland\x2dnixgl.desktop.service,
  xdg-desktop-portal-gtk.service, xdg-desktop-portal-hyprland.service,
  xdg-desktop-portal.service, xdg-document-portal.service,
  xdg-permission-store.service
Starting units: filter-chain.service, pipewire-pulse.service,
  pipewire-pulse.socket, pipewire.service, pipewire.socket,
  xdg-desktop-portal-rewrite-launchers.service
```

The compositor unit (`wayland-wm@hyprland\x2dnixgl.desktop.service`) is under
**Keeping unchanged units** and appears in no stop list — the brief's abort
condition, which would have forced a TTY switch, is not met.

**Nothing is stopped at all.** `wireplumber.service` is correctly absent from
the start list: it carries `WantedBy=pipewire.service`, so starting pipewire
pulls it in. `pipewire-session-manager.service` is correctly absent too, for
a different reason — it is no longer a file in the generation at all; the
alias is written by an activation hook, not installed as a unit.
`xdg-desktop-portal-rewrite-launchers.service` in the start list is a
pre-existing finished oneshot unrelated to this change, a no-op here.

### Warm check

After `home-manager switch --flake .#isutton@suffer`, before the reboot:

```
Id=wireplumber.service
Names=wireplumber.service pipewire-session-manager.service
readlink → wireplumber.service
```

**The `home.activation` hook produced a genuine alias.** This is the
vindication of the Task 1 finding: the plan's original `xdg.configFile` entry
would have had its first hop land in `/nix/store`, which systemd loads as a
second, independent wireplumber unit under the alias name — the shape
measured and rejected during the Task 1 probe. A relative `ln -s
wireplumber.service`, written from `home.activation` after `linkGeneration`,
instead produces one unit registered under two names. This is a warm check
and proves less than the cold gate below — socket activation and alias
registration are both boot-path behaviour a warm restart does not exercise —
but it is already the answer the whole task hangs on, ahead of schedule.

## Phase 2: the cold gate

The gate below is the second cold boot, captured 2026-08-16T13:57:28-03:00 at
generation `1b2qxmz8ayp74h3n3lvwigpfpv3q08bq` — after the
`WIREPLUMBER_DATA_DIR` fix described under item 7. The first cold boot, on
the generation the switch above actually produced, failed that gate; its
failure, root cause and fix are the subject of that section.

### 1. Provenance

```
MainPID=3288
NRestarts=0
Id=pipewire.service
ActiveState=active
FragmentPath=/home/isutton/.config/systemd/user/pipewire.service

MainPID=3293
NRestarts=0
Id=pipewire-pulse.service
ActiveState=active
FragmentPath=/home/isutton/.config/systemd/user/pipewire-pulse.service

MainPID=3291
NRestarts=0
Id=wireplumber.service
ActiveState=active
FragmentPath=/home/isutton/.config/systemd/user/wireplumber.service

MainPID=3292
NRestarts=0
Id=filter-chain.service
ActiveState=active
FragmentPath=/home/isutton/.config/systemd/user/filter-chain.service
pipewire         pid=3288    exe=/nix/store/kwcxxq18wrh6s4r5573jy2v2padf8vk3-pipewire-1.6.6/bin/pipewire usr-maps=0
pipewire-pulse   pid=3293    exe=/nix/store/kwcxxq18wrh6s4r5573jy2v2padf8vk3-pipewire-1.6.6/bin/pipewire usr-maps=0
wireplumber      pid=3291    exe=/nix/store/gnvd0pfyxahyw4k7m5kki0ad75mzwws8-wireplumber-0.5.14/bin/wireplumber usr-maps=0
filter-chain     pid=3292    exe=/nix/store/kwcxxq18wrh6s4r5573jy2v2padf8vk3-pipewire-1.6.6/bin/pipewire usr-maps=0
Id=pipewire.socket
ActiveState=active

Id=pipewire-pulse.socket
ActiveState=active
failed units: 0
```

Establishes: all four services `active` with `NRestarts=0` from a cold
boot — the load-bearing figure, since a service that crashed once and came
back reads `active` too — all four exes resolving into `/nix/store`, and
**`usr-maps=0` for every one**, against the non-zero counts Phase 0 recorded
for Debian's binaries (177, 157, 337, 87). Both sockets `active`. Nothing
failed.

### 2. The alias

```
Wants=pipewire.service wireplumber.service
BindsTo=pipewire.service
After=-.mount pipewire.service wireplumber.service basic.target session.slice pipewire-pulse.socket
After=session.slice basic.target -.mount wireplumber.service pipewire.service
Id=wireplumber.service
Names=wireplumber.service pipewire-session-manager.service
LoadState=loaded
FragmentPath=/home/isutton/.config/systemd/user/wireplumber.service
readlink: wireplumber.service
```

`systemctl show -p Wants` reports the resolved canonical id, never the alias
name it was asked for, so that block by itself cannot show
`pipewire-pulse.service` ever asked for `pipewire-session-manager.service` —
only that *something* named `wireplumber.service` was pulled in. Reading it
as proof of the alias would be the same mistake as reading
`show-environment` for a boot-path unit's environment: the wrong instrument,
answering a related but different question. The raw unit file is the other
half:

```
$ grep -E '^(Wants|After|BindsTo)=' /home/isutton/.config/systemd/user/pipewire-pulse.service
Wants=pipewire.service pipewire-session-manager.service
After=pipewire.service pipewire-session-manager.service
BindsTo=pipewire.service

$ grep -E '^(After|BindsTo)=' /home/isutton/.config/systemd/user/filter-chain.service
After=pipewire.service pipewire-session-manager.service
BindsTo=pipewire.service

$ systemctl --user show pipewire-pulse.service -p Wants -p After
Wants=pipewire.service wireplumber.service
After=-.mount pipewire.service wireplumber.service basic.target session.slice pipewire-pulse.socket

$ systemctl --user list-dependencies --after pipewire-pulse.service | grep -i wireplumber
● ├─wireplumber.service
```

Establishes, from the pair together: the unit file is what *asks* for the
alias — `pipewire-pulse.service` and `filter-chain.service` both name
`pipewire-session-manager.service` on disk — and the manager is what
*resolved* it — the same query against the running manager reports
`wireplumber.service`. Neither line alone distinguishes a resolved alias
from a silently dropped one; `Wants=` naming a unit that does not exist is
not an error; systemd drops the dependency and the ordering with it, audio
starts anyway, and `--state=failed` stays empty. Only the pair, read
together, rules that out. `list-dependencies --after` then confirms the
ordering itself took effect, not just the naming: wireplumber does appear
ahead of `pipewire-pulse.service` in the manager's dependency graph. And
`readlink` on the alias file itself still confirms the on-disk link is the
bare string `wireplumber.service`, no directory part, no store path: a true
alias, not a unit that merely mentions the name.

### 3. The seven enablement artifacts

```
/home/isutton/.config/systemd/user/default.target.wants/filter-chain.service
/home/isutton/.config/systemd/user/default.target.wants/pipewire-pulse.service
/home/isutton/.config/systemd/user/default.target.wants/pipewire.service
/home/isutton/.config/systemd/user/pipewire.service.wants/wireplumber.service
/home/isutton/.config/systemd/user/sockets.target.wants/pipewire-pulse.socket
/home/isutton/.config/systemd/user/sockets.target.wants/pipewire.socket
wants links: 6
alias: 1   dangling under $U: 0
Debian's /etc links still present: 6
```

Establishes: six `.wants` links plus the one alias, counted rather than
assumed — seven artifacts total. Zero dangling symlinks under
`~/.config/systemd/user`. Debian's six links under `/etc/systemd/user` are
still present and still pointing at `/usr/lib/systemd/user`; they are
untouched by this task and disappear in Task 4. `.wants` links from
different `UnitPath` entries are unioned rather than shadowed, so both sets
naming the same unit is expected — the *fragment* actually run is chosen by
search order, position 5 over position 15.

### 4. Devices and realtime scheduling

```
49	alsa_card.pci-0000_03_00.1	alsa
50	alsa_card.pci-0000_03_00.6	alsa
103	bluez_card.E4_61_F4_29_55_BA	module-bluez5-device.c

57	alsa_output.pci-0000_03_00.6.HiFi__Speaker__sink	PipeWire	s32le 2ch 48000Hz	SUSPENDED
264	bluez_output.E4_61_F4_29_55_BA.1	PipeWire	s16le 2ch 44100Hz	RUNNING

57	alsa_output.pci-0000_03_00.6.HiFi__Speaker__sink.monitor	PipeWire	s32le 2ch 48000Hz	SUSPENDED
58	alsa_input.pci-0000_03_00.6.HiFi__Mic2__source	PipeWire	s32le 2ch 48000Hz	SUSPENDED
59	alsa_input.pci-0000_03_00.6.HiFi__Mic1__source	PipeWire	s32le 2ch 48000Hz	SUSPENDED
106	bluez_input.E4:61:F4:29:55:BA	PipeWire	float32le 1ch 48000Hz	SUSPENDED
264	bluez_output.E4_61_F4_29_55_BA.1.monitor	PipeWire	s16le 2ch 44100Hz	RUNNING

Server Name: PulseAudio (on PipeWire 1.6.6)
pipewire       pid 3288's current scheduling policy: SCHED_OTHER|SCHED_RESET_ON_FORK;pid 3288's current scheduling priority: 0;pid 3288's current runtime parameter: 2800000
module-rt      pid 3313's current scheduling policy: SCHED_OTHER|SCHED_RESET_ON_FORK;pid 3313's current scheduling priority: 0;pid 3313's current runtime parameter: 2800000
data-loop.0    pid 3318's current scheduling policy: SCHED_RR|SCHED_RESET_ON_FORK;pid 3318's current scheduling priority: 20
ActiveState=active
FragmentPath=/usr/lib/systemd/system/rtkit-daemon.service
```

Establishes: the same two ALSA cards Phase 0 recorded
(`pci-0000_03_00.1`, `pci-0000_03_00.6`), plus a third card and its
sink/source pair for the JBL, which was connected for this capture and was
not for Phase 0's — one physical sink and three physical sources still hold
under the ALSA cards, with the bluez entries additional. `Server Name` reads
`PulseAudio (on PipeWire 1.6.6)`, the version to read — `Server Version`
stays `15.0.0` before and after this task, since it reports the emulated
PulseAudio protocol version and not PipeWire's. `data-loop.0` still runs
`SCHED_RR` at priority 20: `rtkit-daemon.service`, Debian's system unit,
`active`, granted realtime scheduling over the system bus to a Nix binary.
By hand: sound from the speakers, **YES**.

### 5. The shell and the Chrome mic rule

```
lrwxrwxrwx 1 isutton nix-users 129 Aug 16 13:44 /home/isutton/.config/pipewire/pipewire-pulse.conf.d/20-block-source-volume.conf -> /nix/store/xnb16l33hz72zq7lysczknql7d8990da-home-manager-files/.config/pipewire/pipewire-pulse.conf.d/20-block-source-volume.conf
rule occurrences: 2
Nix's pipewire-pulse.conf names the drop-in dir: 2
```

Establishes: the drop-in symlink still resolves into the store, its rule
matched twice, and Nix's own `pipewire-pulse.conf` names the same drop-in
directory — the file being present is only a proxy, and the two by-hand
checks are the property itself. By hand, reported by the user: the
quickshell volume OSD and audio panel work, **YES** — the first time client
and server are both Nix packages, built against the same libpipewire. Chrome
does not walk the microphone gain back up after it is lowered by hand,
**YES**.

### 6. Bluetooth

```
plugins on disk: 14  (Debian's libspa-0.2-bluetooth: 9)
mapped into pipewire with no device connected: 0
ActiveState=active
FragmentPath=/usr/lib/systemd/system/bluetooth.service
```

Establishes: 14 bluez5 plugins on disk against Debian's 9, zero mapped into
the running pipewire before any Bluetooth device is present — expected,
since the plugins are `dlopen`ed on demand and linkage alone says nothing —
and `bluetooth.service` still `active` at Debian's
`/usr/lib/systemd/system/bluetooth.service`, permanently on apt because
`bluetoothd` is a system service and standalone Home Manager writes only
user units. By hand, with the JBL Tune 520BT connected: playback over A2DP,
**YES**; a real call using the JBL's microphone over HFP, **YES** — the
codec path Debian's `libspa-0.2-bluetooth` never shipped.

### 7. Script provenance — the fix

**The first cold gate FAILED gate 7.** Nix's wireplumber 0.5.14 binary was
running Debian's 0.5.8 Lua scripts: 8 `state-routes.lua:119` tracebacks,
against 0 on the previous boot, when Debian's binary ran Debian's scripts.

Root cause: wireplumber resolves its data tree — the Lua script directory —
through `XDG_DATA_DIRS`. `wireplumber.service` carries
`WantedBy=pipewire.service` and starts from `default.target` at user-manager
start, at 13:27:33; `graphical-session.target`, and with it uwsm's session
environment update, only reached `active` at 13:27:36 — three seconds later.
The unit was started, and had already resolved its data tree, before uwsm
ever set `~/.nix-profile/share` into the session environment. A later boot's
`ActiveEnterTimestamp`s, read from the manager rather than from prose,
corroborate the same three-second gap:

```
$ systemctl --user show wireplumber.service -p ActiveEnterTimestamp --value
Sun 2026-08-16 13:46:52 -03
$ systemctl --user show graphical-session.target -p ActiveEnterTimestamp --value
Sun 2026-08-16 13:46:55 -03
```

(13:27:33 / 13:27:36 are the failing boot that produced the 8 tracebacks;
13:46:52 / 13:46:55 are a later boot, captured after the fix — the shape
repeats.)

The Task 2 comment claiming `pkgs.wireplumber` in `home.packages` fixes this
was **wrong**. The error was made by reading
`systemctl --user show-environment`, which reports the manager's environment
*as it is now* — after uwsm has already mutated it — not what a unit
starting at boot, ahead of that mutation, actually inherited. The
authoritative source is the unit's own `/proc/<MainPID>/environ`, read at
its `ActiveEnterTimestamp`. This is the same trap `CLAUDE.md` already
records for `systemd-analyze --user unit-paths` reporting the caller's
environment rather than the manager's — walked into again, in a new place.

The fix: a `wireplumber.service.d/10-data-dir.conf` drop-in, installed
through `xdg.configFile`, setting `WIREPLUMBER_DATA_DIR` to the package's
store path — proven by hand, running the binary against the unit's own
broken `XDG_DATA_DIRS` with only `WIREPLUMBER_DATA_DIR` added, before any
Nix expression was written. The clinching evidence, from the fixed cold
boot:

```
state-routes tracebacks this boot: 0
  previous boot, Nix binary + Debian scripts: 8
  boot before that, Debian binary + Debian scripts: 0
XDG_DATA_DIRS=/home/isutton/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share/:/usr/share/
WIREPLUMBER_DATA_DIR=/nix/store/gnvd0pfyxahyw4k7m5kki0ad75mzwws8-wireplumber-0.5.14/share/wireplumber
journal lines: 20
```

Zero tracebacks — **and** the unit's own `XDG_DATA_DIRS` still has no
`~/.nix-profile/share` in it, unchanged from the boot that failed. That
second fact is what makes this evidence rather than coincidence: the
mechanism that was blamed and corrected (`XDG_DATA_DIRS`) is demonstrably
still broken, and the drop-in's `WIREPLUMBER_DATA_DIR` is demonstrably what
is doing the work. The journal is non-empty (20 lines), ruling out an empty
journal as the reason the traceback count reads zero.

The positive half completes the same point with the script tree itself:

```
$ journalctl --user -u wireplumber.service -b | wc -l
21

$ ls ~/.nix-profile/share/wireplumber/scripts/device/state-routes.lua
/home/isutton/.nix-profile/share/wireplumber/scripts/device/state-routes.lua

$ grep -c 'get_count' <that file>   # the 0.5.14 form
1

$ grep -c 'next (selected_routes)' /usr/share/wireplumber/scripts/device/state-routes.lua   # Debian's 0.5.8 form
ugrep: warning: /usr/share/wireplumber/scripts/device/state-routes.lua: No such file or directory

$ ls -d /usr/share/wireplumber
ls: cannot access '/usr/share/wireplumber': No such file or directory
```

A non-empty journal (21 lines this time), Nix's own script present with
the 0.5.14 `get_count` form (count 1) — both rule out "zero tracebacks
because there was nothing to traceback from." The fourth counter-check,
grepping Debian's `next (selected_routes)` form, can no longer run: the
Task 4 apt removal has since deleted `/usr/share/wireplumber` entirely.
When Gate 7 was evaluated, that tree was still present — which is precisely
why a count of zero tracebacks meant something at that moment, rather than
meaning the comparison script was simply gone. Its absence now is a Task 4
property, not a Task 3 one, and it is the strongest argument for keeping
the `WIREPLUMBER_DATA_DIR` drop-in explicit rather than relying on
`XDG_DATA_DIRS` ever picking up Nix's tree by accident: with Debian's
`/usr/share/wireplumber` gone, wireplumber now falls back to its
compiled-in store path regardless, and would *appear* to fix itself even
without the drop-in — an implicit fix would have been indistinguishable
from the explicit one, on this machine, from this boot forward.

### Gate 8, withdrawn

An `api.alsa.acp.device` create failure was observed during the Task 1
rehearsal and made into a gate expecting zero failures from cold. The first
cold boot under the real units produced 2:

```
api.alsa.acp.device failures, this boot:            2
api.alsa.acp.device failures, Debian's 0.5.8 boot:  6
 0 [Generic        ]: HDA-Intel - HD-Audio Generic
                      HD-Audio Generic at 0x605c8000 irq 72
 1 [Generic_1      ]: HDA-Intel - HD-Audio Generic
                      HD-Audio Generic at 0x605c0000 irq 73
 2 [acp63          ]: acp63 - acp63
                      HP-HPOmniBook5Laptop16_bc1xxx-Type1ProductConfigId-8E02
```

Debian's own 0.5.8 boot logged the same failure 6 times — more often, not
less. It is pre-existing, not a regression. `/proc/asound/cards` lists three
cards: 0 and 1 are HDA-Intel, 2 is `acp63`, AMD's audio coprocessor; pipewire
enumerates two, on both stacks.

The gate was invented from the rehearsal without checking the baseline
first — the same error as item 7, in the other direction: a warning seen
under Nix, attributed to Nix, without asking what Debian did. It is
withdrawn.

## Phase 3: the apt removal

### The removal set, and why it is six and not five

`apt-get -s remove pipewire pipewire-bin pipewire-pulse wireplumber
libspa-0.2-bluetooth libcanberra-pulse`, re-verified against the live
machine rather than trusted from the spec, gave `6 to remove, 0 newly
installed` and **zero `Inst` lines** anywhere in the output.

`libcanberra-pulse` is in the set for one reason: it declares
`Depends: pipewire-pulse | pulseaudio`. Removing `pipewire-pulse` without
it leaves that dependency satisfiable the other way, and apt installs
PulseAudio to close it — two sound servers on one socket. With
`libcanberra-pulse` in the set, the simulation installs nothing, and the
package state captured after the real removal confirms it:

```
un  pulseaudio
```

`pulseaudio` reads `un`, not `rc` and not `ii` — dpkg has no record of it
ever having been installed. `libcanberra-pulse` did its job.

### The two keepers, marked manual before anything was removed

Both `rtkit` and `pulseaudio-utils` appeared in the removal's "no longer
required" list. Neither would have gone today — both would have gone to
some later, unrelated `apt autoremove`, at which point whatever broke
would have been blamed on this migration's version bump rather than on
the mark. Both were made manual before the six packages were removed, to
close that off in advance rather than after the fact.

**`rtkit`.** `rtkit-daemon` is a *system* service, at
`/usr/lib/systemd/system/rtkit-daemon.service`, active, and it is what
grants pipewire's `data-loop.0` thread `SCHED_RR` priority 20 — measured
on this boot, under Nix's pipewire, in Gate 4 below. Standalone Home
Manager writes only user units and cannot replace a system service, so
`rtkit` is a permanent apt dependency in the same way `bluez` is.

**`pulseaudio-utils`.** Supplies `pactl`. Nix ships a rich `pw-*`
toolset and no `pactl`, and much of this migration's own gate is written
in `pactl` invocations. Losing the diagnostic vocabulary at the exact
moment the sound server underneath it changes would have been a bad
trade.

### Package state after

```
un  libcanberra-pulse
un  libspa-0.2-bluetooth
rc  pipewire 1.4.2-1
rc  pipewire-bin 1.4.2-1
rc  pipewire-pulse 1.4.2-1
un  pulseaudio
ii  pulseaudio-utils 17.0+dfsg1-2+b1
ii  rtkit 0.13-5.1
rc  wireplumber 0.5.8-2
```

Four of the six removed packages read `rc` (removed, conffiles
retained); the other two — `libcanberra-pulse` and `libspa-0.2-bluetooth`
— read `un`, having shipped no conffiles for dpkg to keep. The two
keepers hold `ii`.

`${db:Status-Abbrev}` is the field that matters, not `${Version}`.
`dpkg-query -W -f='${Version}'` prints a version string and exits `0`
for an `rc` package — exactly the state `apt remove` leaves behind — so
a version-only query cannot tell "still installed" from "removed,
config left on disk." There are 120 `rc` packages on this machine
already; a version-only query would have silently agreed all six were
still there.

### The /etc sweep

dpkg left all six audio `.wants` symlinks dangling under
`/etc/systemd/user` — it creates them as part of installing a unit but
does not own them and does not clean them up on removal, exactly what
`CLAUDE.md` already documents from `fumon`, `ydotool` and
`rewrite-launchers`. The machine's dangling-symlink total went from 8
(pre-existing, unrelated to audio) to 14.

They are inert. The links that actually matter sit at `UnitPath`
position 5 (`~/.config/systemd/user`); these six sit at position 15
(`/etc/systemd/user`, resolving toward `/usr/lib/systemd/user`) and now
point at fragment files that no longer exist on disk. Left in place,
root-owned, outside this flake's territory — not deleted.

### The cold gate, second run

A second reboot, then the whole Task 3 gate re-run unchanged, against a
machine with no Debian audio package installed, no Debian audio unit
file left in `/usr/lib/systemd/user`, and `/usr/share/wireplumber`
deleted. The Task 3 gate had already passed once, with Debian's packages
merely stopped and out-competed on `UnitPath` — passing it then proved
nothing about whether anything was still capable of reaching for them.
Running the identical gate again, with the packages gone rather than
just quiet, is what actually closes that gap.

**Gate 1 — provenance.**
```
pipewire        active   NRestarts=0 pid=2950    usr-maps=0 exe=/nix/store/kwcxxq18wrh6s4r5573jy2v2padf8vk3-pipewire-1.6.6/bin/pipewire
pipewire-pulse  active   NRestarts=0 pid=2955    usr-maps=0 exe=/nix/store/kwcxxq18wrh6s4r5573jy2v2padf8vk3-pipewire-1.6.6/bin/pipewire
wireplumber     active   NRestarts=0 pid=2953    usr-maps=0 exe=/nix/store/gnvd0pfyxahyw4k7m5kki0ad75mzwws8-wireplumber-0.5.14/bin/wireplumber
filter-chain    active   NRestarts=0 pid=2954    usr-maps=0 exe=/nix/store/kwcxxq18wrh6s4r5573jy2v2padf8vk3-pipewire-1.6.6/bin/pipewire
sockets: active active
failed units: 0
```
Same four units, same store paths, `NRestarts=0` from cold, `usr-maps=0`
across the board — unchanged from Phase 2, now with nothing left at
`/usr/lib/systemd/user` for a stray lookup to have quietly resolved to
instead.

**Gate 2 — the alias, both halves.**
```
$ grep -E '^Wants=' /home/isutton/.config/systemd/user/pipewire-pulse.service      # what the unit ASKS for
Wants=pipewire.service pipewire-session-manager.service
$ systemctl --user show pipewire-pulse.service -p Wants   # what the manager RESOLVED
Wants=wireplumber.service pipewire.service
Id=wireplumber.service
Names=wireplumber.service pipewire-session-manager.service
LoadState=loaded
$ systemctl --user list-dependencies --after pipewire-pulse.service | grep -i wireplumber
● ├─wireplumber.service
```
The unit file still asks for the alias by name, the manager still
resolves it to `wireplumber.service`, and the ordering still took effect
— the same three-part proof Phase 2 required, unchanged with the
Debian packages gone.

**Gate 3 — enablement, with nothing left at position 15.**
```
our .wants links: 6
alias: wireplumber.service
dangling under ~/.config/systemd/user: 0
Debian audio unit files in /usr/lib/systemd/user: 0
Debian .wants links left dangling under /etc/systemd/user: 6
total dangling under /etc/systemd/user: 14   (was 8 before this migration)
```
Six of our own links, zero dangling on our side, and — the fact this run
adds that Phase 2 could not have shown — zero Debian audio unit files
anywhere under `/usr/lib/systemd/user`. Position 15 is now empty. The
six Debian `.wants` links under `/etc/systemd/user`, from the sweep
above, point at nothing.

**Gate 4 — devices and realtime.**
```
49	alsa_card.pci-0000_03_00.1	alsa
50	alsa_card.pci-0000_03_00.6	alsa
76	bluez_card.E4_61_F4_29_55_BA	module-bluez5-device.c

57	alsa_output.pci-0000_03_00.6.HiFi__Speaker__sink	PipeWire	s32le 2ch 48000Hz	SUSPENDED
77	bluez_output.E4_61_F4_29_55_BA.1	PipeWire	s16le 2ch 48000Hz	RUNNING

57	alsa_output.pci-0000_03_00.6.HiFi__Speaker__sink.monitor	PipeWire	s32le 2ch 48000Hz	SUSPENDED
58	alsa_input.pci-0000_03_00.6.HiFi__Mic2__source	PipeWire	s32le 2ch 48000Hz	SUSPENDED
59	alsa_input.pci-0000_03_00.6.HiFi__Mic1__source	PipeWire	s32le 2ch 48000Hz	SUSPENDED
77	bluez_output.E4_61_F4_29_55_BA.1.monitor	PipeWire	s16le 2ch 48000Hz	RUNNING
79	bluez_input.E4:61:F4:29:55:BA	PipeWire	float32le 1ch 48000Hz	SUSPENDED

Server Name: PulseAudio (on PipeWire 1.6.6)
pipewire       pid 2950's current scheduling policy: SCHED_OTHER|SCHED_RESET_ON_FORK;pid 2950's current scheduling priority: 0;pid 2950's current runtime parameter: 2800000
module-rt      pid 2974's current scheduling policy: SCHED_OTHER|SCHED_RESET_ON_FORK;pid 2974's current scheduling priority: 0;pid 2974's current runtime parameter: 2800000
data-loop.0    pid 2979's current scheduling policy: SCHED_RR|SCHED_RESET_ON_FORK;pid 2979's current scheduling priority: 20
ActiveState=active
FragmentPath=/usr/lib/systemd/system/rtkit-daemon.service
```
Both ALSA cards, the JBL connected and `RUNNING`, and `data-loop.0`
still at `SCHED_RR` priority 20 — the property marking `rtkit` manual
exists to protect — holding on this run exactly as Phase 2 recorded it,
still granted by Debian's still-active system unit.

**Gate 7 — script provenance, with Debian's tree deleted.**
```
state-routes tracebacks: 0
journal lines: 7
XDG_DATA_DIRS=/home/isutton/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share/:/usr/share/
WIREPLUMBER_DATA_DIR=/nix/store/gnvd0pfyxahyw4k7m5kki0ad75mzwws8-wireplumber-0.5.14/share/wireplumber
/usr/share/wireplumber exists: NO
```
Zero tracebacks, a non-empty journal, and `/usr/share/wireplumber` — the
tree the Phase 2 regression was reading from — confirmed gone rather
than merely unused. `WIREPLUMBER_DATA_DIR` is still doing the work;
`XDG_DATA_DIRS` still carries no `~/.nix-profile/share`.

**By hand, reported by the user — all four pass again:**
- Sound from the speakers: YES
- quickshell volume OSD and audio panel: YES
- Chrome does not walk the microphone gain back up: YES
- JBL Tune 520BT playback (A2DP) and a real call on its microphone (HFP): YES

Second time these four have been run: once on the Task 3 cold gate with
Debian's packages still installed, and again here with them removed. The
repetition is the point — passing the first time did not prove nothing
was still reaching for Debian's copies.

#### Gate 6: the plan named the wrong process

The plan's check was `grep -c 'spa-0.2/bluez5' /proc/<pipewire-pid>/maps`.
That check is not merely incomplete, it is wrong: pipewire does not load
the bluez5 plugins at all — **wireplumber** does, as the device monitor.
Run against pipewire, the count reads `0` whether Bluetooth works or
not — a check that cannot fail, the exact shape `CLAUDE.md` names as the
thing to never ship. This is not "the check was improved": the plan
named the wrong process, and the check as written could never have
failed either way.

Corrected against wireplumber's own maps:
```
bluez5 map entries in pipewire   (pid 2950): 0
bluez5 map entries in wireplumber (pid 2953): 70

distinct .so loaded, all from /nix/store:
/nix/store/kwcxxq18wrh6s4r5573jy2v2padf8vk3-pipewire-1.6.6/lib/spa-0.2/bluez5/libspa-bluez5.so
/nix/store/kwcxxq18wrh6s4r5573jy2v2padf8vk3-pipewire-1.6.6/lib/spa-0.2/bluez5/libspa-codec-bluez5-aac.so
/nix/store/kwcxxq18wrh6s4r5573jy2v2padf8vk3-pipewire-1.6.6/lib/spa-0.2/bluez5/libspa-codec-bluez5-aptx.so
/nix/store/kwcxxq18wrh6s4r5573jy2v2padf8vk3-pipewire-1.6.6/lib/spa-0.2/bluez5/libspa-codec-bluez5-faststream.so
/nix/store/kwcxxq18wrh6s4r5573jy2v2padf8vk3-pipewire-1.6.6/lib/spa-0.2/bluez5/libspa-codec-bluez5-g722.so
/nix/store/kwcxxq18wrh6s4r5573jy2v2padf8vk3-pipewire-1.6.6/lib/spa-0.2/bluez5/libspa-codec-bluez5-hfp-cvsd.so
/nix/store/kwcxxq18wrh6s4r5573jy2v2padf8vk3-pipewire-1.6.6/lib/spa-0.2/bluez5/libspa-codec-bluez5-hfp-lc3-a127.so
/nix/store/kwcxxq18wrh6s4r5573jy2v2padf8vk3-pipewire-1.6.6/lib/spa-0.2/bluez5/libspa-codec-bluez5-hfp-lc3-swb.so
/nix/store/kwcxxq18wrh6s4r5573jy2v2padf8vk3-pipewire-1.6.6/lib/spa-0.2/bluez5/libspa-codec-bluez5-hfp-msbc.so
/nix/store/kwcxxq18wrh6s4r5573jy2v2padf8vk3-pipewire-1.6.6/lib/spa-0.2/bluez5/libspa-codec-bluez5-lc3.so
/nix/store/kwcxxq18wrh6s4r5573jy2v2padf8vk3-pipewire-1.6.6/lib/spa-0.2/bluez5/libspa-codec-bluez5-ldac.so
/nix/store/kwcxxq18wrh6s4r5573jy2v2padf8vk3-pipewire-1.6.6/lib/spa-0.2/bluez5/libspa-codec-bluez5-opus-g.so
/nix/store/kwcxxq18wrh6s4r5573jy2v2padf8vk3-pipewire-1.6.6/lib/spa-0.2/bluez5/libspa-codec-bluez5-opus.so
/nix/store/kwcxxq18wrh6s4r5573jy2v2padf8vk3-pipewire-1.6.6/lib/spa-0.2/bluez5/libspa-codec-bluez5-sbc.so

plugins on disk: 14   Debian's libspa-0.2-bluetooth shipped 9 and is now uninstalled
files left at /usr/lib/x86_64-linux-gnu/spa-0.2/bluez5/: 0
bluetooth.service: active from /usr/lib/systemd/system/bluetooth.service
```
70 map entries against wireplumber, zero against pipewire, all 14
`.so` files loaded from `/nix/store`, none from Debian's now-empty
directory — including the four HFP codecs (`cvsd`, `msbc`, `lc3-swb`,
`lc3-a127`) and AAC that Debian's 9-plugin build never shipped at all.
`bluetooth.service` remains the one apt-owned piece of the audio path
left, still `active`, from `/usr/lib/systemd/system/bluetooth.service`
— a system unit, permanently out of Home Manager's reach in the same
way `rtkit-daemon` is.
