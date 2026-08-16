# Spec 9: the audio stack — suffer

2026-08-16

Spec 8 finished the portal subsystem. What remains on Debian's side of the
session divides into clusters, and audio is the largest: `pipewire`,
`pipewire-pulse`, `wireplumber` and `filter-chain`, all user services from
`/usr/lib/systemd/user`.

This spec moves them to Nix.

It is the riskiest migration so far, for three reasons that are worth stating
before anything else: it is an **upgrade** rather than a lateral move, the
units are **not** identical to Debian's beyond `ExecStart`, and the failure
mode is "no audio".

## Scope, in one sentence

Move the four audio services and their two sockets to Nix, then remove the six
Debian packages behind them, leaving audio entirely Nix's.

## The inventory, measured

### Seven units, not four

```
$ systemctl --user list-unit-files | grep -E 'pipewire|wireplumber|filter-chain'
filter-chain.service      enabled
pipewire-pulse.service    enabled
pipewire.service          enabled
wireplumber.service       enabled
wireplumber@.service      disabled
pipewire-pulse.socket     enabled
pipewire.socket           enabled
```

Two of them are **sockets**, which the portal work did not have to deal with.
All are `enabled` rather than `static`, so each needs an enablement link — the
unit file alone does not enable any of them.

Three of the four services run the *same binary*: `pipewire-pulse` and
`filter-chain` are `/usr/bin/pipewire` invoked with different configuration.

### This is an upgrade, not a lateral move

| | Debian | nixpkgs (pinned input) |
|---|---|---|
| `pipewire` | `1.4.2-1` | **`1.6.6`** |
| `wireplumber` | `0.5.8-2` | `0.5.14` |

Every previous migration in this project was version-neutral — uwsm `0.26.4`
on both sides, the gtk portal `1.15.3` on both sides, the portal frontend a
patch bump. That mattered more than it looked: it meant any breakage was
provenance, never behaviour.

Here it can be either. The user has accepted the upgrade; pinning `1.4.x`
through an overlay was considered and rejected, because it would add a pin
nobody remembers to remove. The design compensates with a rehearsal phase
instead — see Phase 0.

Both versions come from the same nixpkgs revision, so `1.6.6` and `0.5.14` are
the pairing upstream ships and tests together. That fact drives the sequencing
decision below.

### The units differ structurally, which is new

Every prior migration copied units that were identical to Debian's apart from
`ExecStart`. These are not:

| Unit | Difference |
|---|---|
| `pipewire.service` | Debian sets `RestrictNamespaces=yes`; Nix does not. Nix adds `mincore` to `SystemCallFilter`. |
| `pipewire-pulse.service` | Debian: `Wants/After=pipewire.service wireplumber.service pipewire-media-session.service`. Nix: `Wants/After=pipewire.service pipewire-session-manager.service`, plus `BindsTo=pipewire.service`. |
| `wireplumber.service` | Nix adds `After=dbus.service`, adds `mincore`, and adds **`Alias=pipewire-session-manager.service`**. |
| `pipewire.socket`, `pipewire-pulse.socket`, `filter-chain.service` | identical apart from `ExecStart`/`Environment` |

The `Alias=` is the trap. Nix's dependency model routes `pipewire-pulse`
through a generic `pipewire-session-manager.service` name, which only exists
because `wireplumber.service` declares that alias — and an alias becomes a
real name only when systemd writes the alias symlink at enable time.

This spec installs units declaratively rather than running `systemctl enable`,
so **the alias link must be created explicitly**. If it is missing,
`pipewire-pulse` will `Wants=` a unit that does not exist. `Wants=` on a
missing unit is **not** an error: the dependency is simply dropped, the
ordering with it, and audio starts anyway with the session manager no longer
sequenced ahead of the pulse shim. Nothing appears in `--state=failed`.

### The enablement surface is seven artifacts

```
$ find /etc/systemd/user -name '*.wants' -type d | xargs ls
sockets.target.wants/     pipewire.socket   pipewire-pulse.socket
default.target.wants/     pipewire.service  pipewire-pulse.service  filter-chain.service
pipewire.service.wants/   wireplumber.service
```

Six links today, plus the alias makes seven the flake must own.

### Configuration

Debian's `/usr/share/pipewire` holds 12 files and `/usr/share/wireplumber`
holds 3; there is no `/etc/pipewire`, no `/etc/wireplumber`, and no
`~/.config/wireplumber`. Everything is package default with exactly one
exception, and the flake already owns it:

```
~/.config/pipewire/pipewire-pulse.conf.d/20-block-source-volume.conf
  -> /nix/store/…-home-manager-files/…
```

That is the rule in `home/apps.nix` that stops Chrome walking the capture
device's gain back up between calls. Nix's `pipewire-pulse.conf` documents the
same drop-in directory (`~/.config/pipewire/pipewire-pulse.conf.d/`), so the
fragment keeps applying unchanged. Verified by reading Nix's shipped conf, not
assumed from the path being conventional.

The config *base* moves with the binary: point the units at Nix's pipewire and
it reads Nix's `/share/pipewire` defaults rather than Debian's. Both trees
carry the same 12 filenames; Nix adds `pipewire-vulkan.conf`.

### Bluetooth: real, and better under Nix

A `JBL Tune 520BT` is paired, wireplumber's journal carries 118 lines
mentioning bluetooth, and the user has confirmed the headset is used for calls
as well as playback — so both A2DP and HFP are in scope.

Bluetooth support in PipeWire is a SPA plugin, and Debian ships it in a
separate package, `libspa-0.2-bluetooth`. Comparing the two builds:

| | plugins | notably |
|---|---|---|
| Nix `1.6.6` | 14 | includes AAC and four HFP codecs — `cvsd`, `msbc`, `lc3-swb`, `lc3-a127` |
| Debian `1.4.2` | 9 | no AAC, no HFP codecs |

Nix's build is a strict superset. Earlier specs deferred this work partly on
the grounds that "PipeWire's A2DP path couples to `bluez`, which stays on
apt". The coupling is real — pipewire talks to `bluetoothd` over D-Bus — but
the codec side lives entirely inside pipewire, and Nix's is richer. That
reason was weaker than it looked, and it is corrected here.

Because Nix's pipewire loads its own SPA plugins, Debian's
`libspa-0.2-bluetooth` becomes dead weight and joins the removal set. The unit
list and the package list are not the same thing in this spec.

### The removal pulls PulseAudio in, unless one more package goes

This is the finding that reshaped Phase 3. The obvious removal set does
something unwanted:

```
$ apt-get -s remove pipewire pipewire-bin pipewire-pulse wireplumber libspa-0.2-bluetooth
Inst pulseaudio (17.0+dfsg1-2+b1 …)
Inst libasound2-plugins (1.2.12-2+b1 …)
```

`libcanberra-pulse` declares `Depends: pipewire-pulse | pulseaudio`, so
removing one makes apt satisfy it with the other. Two sound servers competing
for the same socket would be worse than anything this migration fixes.

Adding `libcanberra-pulse` to the set resolves it:

```
$ apt-get -s remove pipewire pipewire-bin pipewire-pulse wireplumber \
                    libspa-0.2-bluetooth libcanberra-pulse
Remv libcanberra-pulse  libspa-0.2-bluetooth  wireplumber
Remv pipewire-pulse     pipewire              pipewire-bin
0 upgraded, 0 newly installed, 6 to remove
```

`libcanberra` is the GTK event-sound library. No running process maps it.

All six are downloadable from trixie, so **Phase 3 is reversible**.

### Nothing in the login path needs audio

`greetd` has no audio dependency and Hyprland is a Nix package. The worst case
in this spec is "no sound", never "no desktop", and recovery never requires a
TTY.

## Decisions

**All seven units move in one switch**, rather than sequenced.

Spec 8 sequenced three portal services and that was right, because they are
independent: different bus names, different jobs, and each intermediate state
was a coherent system. Audio inverts the argument. `wireplumber` is pipewire's
session manager; `pipewire-pulse` and `filter-chain` are the same binary as
`pipewire` under different configuration. Sequencing would deliberately
construct Nix's `pipewire 1.6.6` under Debian's `wireplumber 0.5.8` — a
pairing nobody runs on purpose and upstream does not test. `1.6.6` with
`0.5.14` is the pairing nixpkgs ships.

**A rehearsal phase comes first.** Because this is an upgrade, a failure could
be provenance or behaviour, and those need separating before the flake is
touched. Phase 0 runs Nix's binaries by hand against the same hardware and the
same configuration. If they misbehave there, it is behaviour, and no flake
change is made.

**Units are copied verbatim**, despite differing from Debian's. The goal is
Nix's coherent set — its dependency model, its alias, its syscall filter —
not a hybrid assembled from two upstreams.

**`pulseaudio-utils` stays.** It orphans when `pipewire-pulse` goes, but it
provides `pactl`, which most of this spec's gate speaks. Nix ships a rich
`pw-*` toolset and no `pactl`. Losing the diagnostic vocabulary at the moment
the sound server changes is a bad trade.

**A new `home/audio.nix`**, following the shape `home/portals.nix` established
in spec 8: one file per subsystem rather than accretion into
`home/services.nix`.

## Non-goals

- **The secrets and agent cluster** — `gnome-keyring-daemon`, `gcr-ssh-agent`,
  `ssh-agent`. `gnome-keyring` also supplies the Secret portal backend.
- **`dbus-broker`** — the session bus itself. Not a candidate.
- **`foot`'s shadow** — the flake provides `foot`, `/usr/bin/foot` runs,
  `foot-server.service` is Debian's. Same shape, still not this subsystem.
- **The ~21 remaining GUI applications**, minus the corp set.
- **`bluez`** — permanently apt. `bluetoothd` is a system service and
  standalone Home Manager writes only user units. This spec depends on it and
  does not touch it.
- **The unmanaged font piles, the dictionaries, the `rc`-state packages and
  `/run/opengl-driver`** — all inherited unchanged.

## Design

### Phase 0 — rehearse, before touching the flake

Stop the Debian stack and run Nix's binaries in the foreground:

```
systemctl --user stop pipewire.socket pipewire-pulse.socket \
                      pipewire.service pipewire-pulse.service \
                      wireplumber.service filter-chain.service
<nix pipewire>/bin/pipewire &
<nix wireplumber>/bin/wireplumber &
<nix pipewire>/bin/pipewire-pulse &
```

**Pass condition:** the two ALSA cards enumerate, sound plays, and the JBL
connects and produces audio. If any of that fails, the cause is behaviour
rather than provenance, and this spec stops here with nothing written.

Costs one interrupted audio session, at a time the user chooses. Recovery is
`systemctl --user start` on the same units.

### Phase 1 — one switch

`home/audio.nix` adds `pipewire` and `wireplumber` to `home.packages`, then:

- seven `xdg.configFile."systemd/user/<unit>"` entries, sources in the store
- `sockets.target.wants/` → `pipewire.socket`, `pipewire-pulse.socket`
- `default.target.wants/` → `pipewire.service`, `pipewire-pulse.service`,
  `filter-chain.service`
- `pipewire.service.wants/` → `wireplumber.service`
- `systemd/user/pipewire-session-manager.service` → the alias, pointing at
  Nix's `wireplumber.service`

`sd-switch --dry-run` is read before switching, extracted from the live
activation script rather than from `nixpkgs#sd-switch`. Expect it to cycle the
audio units and nothing else; the compositor must not appear in a stop list.

### Phase 2 — reboot, then the gate

A reboot rather than a restart: socket activation and the alias are both
boot-path behaviour, and a warm restart proves neither.

The gate, ordered by what it establishes:

1. All four services running, `/proc/<pid>/exe` under `/nix/store`, `0` `/usr`
   code mappings.
2. **`systemctl --user show pipewire-pulse.service -p Wants` lists
   `pipewire-session-manager.service`, and that name resolves to Nix's
   wireplumber unit.** The silent-failure check.
3. The seven enablement artifacts present, enumerated by listing the `.wants`
   directories rather than from this document.
4. Sound from the speakers; `pactl list sinks short` shows both ALSA cards.
5. The Chrome mic-gain rule still applies.
6. **The JBL, connected: playback, then a real call using its microphone.**
   A2DP and HFP are different code paths and only the second exercises the
   codecs Debian never shipped.

### Phase 3 — remove six packages

```
sudo apt remove pipewire pipewire-bin pipewire-pulse wireplumber \
                libspa-0.2-bluetooth libcanberra-pulse
```

Verified beforehand to install nothing. Then a reboot, and the Phase 2 gate
again from cold — with no Debian unit at position 15 left to cover a gap.

## Verification

The rules in `CLAUDE.md` apply. Three deserve restating because this spec
touches each:

**`ldd` is not the tool for the bluez question.** PipeWire `dlopen`s its SPA
plugins — that is the plugin architecture — so clean linkage proves nothing
about whether bluez5 loads. The check is `pw-dump`, or a connected device.
This project has twice nearly shipped `ldd` as a decision procedure for a
`dlopen`-based question.

**`Wants=` on a missing unit is silent.** The alias check must confirm the
name resolves, not merely that the unit file mentions it.

**Enumerate by listing, not from memory.** The seven enablement artifacts get
counted from the filesystem. Spec 8's results document asserted three
permission-store tables from a remembered list when the live system had four —
inside the spec that states this rule.

## Recovery

| Phase | Recovery |
|---|---|
| 0 | `systemctl --user start` the Debian units. Nothing changed. |
| 1–2 | Remove `home/audio.nix` from the module list and switch. Debian's units at position 15 take over. |
| 3 | `sudo apt install` the six packages, all downloadable from trixie. |

A Home Manager rollback is **not** a recovery path, and this spec adds audio to
what it would strip. The session comes up regardless of audio state, so
recovery never needs a TTY.

## Endpoint

- Audio entirely Nix's: `pipewire 1.6.6`, `wireplumber 0.5.14`, both sockets,
  the filter chain, and a bluez5 plugin set that is a superset of Debian's.
- Six fewer apt packages.
- Debian user services down from 14 to 10, leaving the secrets and agent
  cluster, the session bus, flatpak's own two, and the miscellaneous five.
