# Spec 21 — a noise-canceling microphone source: results

Branch `pipewire-noise-reduction`. A selectable "Noise Canceling source"
microphone, built from a PipeWire filter-chain graph of two LADSPA plugins:
`librnnoise_ladspa` (`noise_suppressor_mono`) for steady noise, and
swh-plugins' `gate_1410` (label `gate`) for the room. `filter-chain.service`
already existed on this machine and was already enabled, so no new unit was
created — only a `filter-chain.service.d` drop-in, supplying `LADSPA_PATH`
(two directories) and `X-Restart-Triggers`.

Commits: `da7eec9`, `6abe40f`, `decc66f`, `d368198`, plus three plan
corrections, `059121d`, `e95ab38`, `0885424`.

This is a success report and a failure report in equal measure, and it reads
that way on purpose. The first configuration this branch shipped made the
machine's microphone permanently silent, every automated check passed while it
did, and a person found it by listening. The controller then measured levels
with a broken instrument and twice declared a working headset microphone dead.
Both are recorded here at length, because this project's `CLAUDE.md` exists to
stop exactly this shape of mistake from being paid for twice.

## THE HEADLINE DEFECT: PipeWire's builtin noisegate cannot open

This is the most important thing in this document.

The first shipped configuration used PipeWire 1.6.6's builtin `noisegate` at
upstream's own default Open Threshold of 0.04. It made the microphone
permanently silent, and **a person found it by listening** — no guard caught
it, and the build was green throughout.

PipeWire's own loader says why:

```
using port 2 ('Level') as control 0 nan/0.000000/0.000000
using port 3 ('Open Threshold') as control 1 0.040000/0.000000/1.000000
loaded n_input:1 n_output:1 n_control:6 n_notify:0
```

`Level` loads as an **input control** with range `0.000000/0.000000`, and the
node declares `n_notify:0` — no output controls at all. So `Level` is not a
meter the gate writes; it is a value the gate reads, and it can only ever be
0. Any Open Threshold above 0 holds the gate shut for ever.

Measured against a microphone reading peak 32768, input and output captured
in the same instant:

| builtin gate configuration | output | non-zero samples |
|---|---|---|
| Open Threshold 0.04 (upstream's default, what shipped) | digital silence | 0 % |
| Open Threshold 0.001 | digital silence | 0 % |
| Open and Close both 0.0 | audio | 99.6 % |
| `Level` supplied as 1.0 | digital silence | 0 % (clamped to the port max of 0) |

Only a threshold of exactly zero passes audio, which is not gating at all.

The recording that started the investigation was 5267500 bytes holding **one
distinct byte value**, `0x00`, across 27.4 seconds.

This is an upstream defect worth reporting to PipeWire. Until then,
`pipewire/50-noise-canceling-source.conf` carries a comment forbidding a
return to the builtin.

## Why no guard caught it, and what that teaches

The build-time guard checks that every name the config hands a library exists
in that library. Every name did exist. **A name-existence guard cannot detect
a filter that loads, runs, and emits silence.** Its declared scope was
narrower than the property anyone cared about — the same shape as the three
cases `CLAUDE.md` already records under "Prove a check can fail before
trusting it", and this one reached a live machine.

## The replacement, proven in both directions

swh-plugins 0.4.17 (`pkgs.ladspaPlugins`), `gate_1410.so`, label `gate`:

```
port 2 ('Threshold (dB)')  control 2  -70.000000/-70.000000/20.000000
port 6 ('Range (dB)')      control 6  -90.000000/-90.000000/0.000000
port 8 ('Input')           input 0
port 9 ('Output')          output 0
loaded n_input:1 n_output:1 n_control:8 n_notify:0
```

| threshold | output | non-zero |
|---|---|---|
| -60 dB | rms 171.65 | 6.2 % |
| +10 dB | rms 0.00 | 0 % |
| -70 dB (shipped) | rms 387.84 | 78.1 % |

Three interface differences from the builtin, all load-bearing: the threshold
is in **decibels**, times are in **milliseconds**, and the input port is
named **`Input`**, not `In`.

It ships at -70 dB, which is upstream's default AND the port minimum, so an
untuned gate cannot silence a microphone. Attack 5 ms / Hold 200 ms / Decay
50 ms replace swh's own 250 / 1500 / 2001, which clip the first syllable of
every sentence.

One more interface trap, worth its own line: `gate:LF key filter` reads
**33.599998** and `gate:HF key filter` reads **23520.0** against descriptor
defaults of 0.0007 and 0.49 — so those controls are **fractions of the sample
rate, not hertz** (0.0007 x 48000 = 33.6). Anyone tuning them by typing a
frequency directly is wrong by a factor of 48000.

## The sd-switch drop-in question, ANSWERED

`CLAUDE.md` carried this as an open question — whether sd-switch diffs
drop-ins as well as unit fragments — and told the reader to verify it before
relying on it. It is now measured, on `filter-chain.service.d`:

```
T0 = Mon 2026-08-17 15:27:44 -03   baseline, three days old
T1 = Thu 2026-08-20 15:19:54 -03   first switch (drop-in was new; restart expected either way)
T2 = Thu 2026-08-20 15:19:54 -03   CONTROL: a switch changing nothing -> NO restart
T3 = Thu 2026-08-20 15:20:30 -03   content-only change -> RESTART
T4 = Thu 2026-08-20 15:21:31 -03   probe removed -> RESTART again
```

**Answer: sd-switch DOES diff drop-ins.** The control (T2 == T1) is what makes
it an answer rather than an observation; without it, "the timestamp moved"
could be what every switch does. A fifth confirmation arrived later: the
Task 7 switch restarted the unit at 16:21:03 when only the config's content
had changed.

This matters beyond this branch: `xdg-desktop-portal.service` carries the
identical defect — a verbatim store-copy unit reading a config file at
startup, so editing the config restarts nothing — and was waiting on this
identical question. A drop-in carrying `X-Restart-Triggers` is now a proven
mechanism for fixing it. `CLAUDE.md` is updated with the same evidence.

## The guard, proven by mutation — twice

The guard was proven by three mutations, then **re-proven by three more**
after its selector changed from node type to plugin name (two LADSPA plugins
from two packages meant `type = ladspa` no longer identified which library a
name lived in). Its green line reads
`ok: 2 plugins, 2 labels, 6 controls checked`.

The three mutations: a renamed/nonexistent plugin, a misspelled control name,
and the vacuity anchor (config emptied). Note the vacuity anchor is the one a
reviewer would skip and the one that matters most — without it a config the
parser can no longer read produces zero names, zero failures, and a guard
that passes having asserted nothing. This work adds no `checks` entry — the
guard rides in `home.packages`, the same shape as `pulseaudioClients`, not in
`flake.nix`'s `checks`; see "Reproducing the guard" below for the
`nix flake check` count.

## THE CONTROLLER'S OWN INSTRUMENT ERROR

Record this against ourselves, at length. It is the most transferable lesson
here.

Every level quoted during the investigation used **whole-file rms over raw
interleaved samples**. That is the wrong instrument, for three measured
reasons:

- this laptop's capture carries a **DC offset around -11774** on the louder
  channel (-3001 on the other), and rms includes DC, so a quiet mic reads in
  the thousands;
- `pw-record`'s **first 100 ms block held a 22283 transient**, a startup
  click, which alone dominated a ten-second average;
- the files are **interleaved stereo** and were treated as one flat array.

Proof: `mic-laptop-mic1.wav` read whole-file rms 8903 while its per-100 ms AC
blocks, after the transient, ran 54 to 400 with a median of 179 (-45.2 dB).

The replacement measure: de-interleave, take the louder channel by AC energy,
remove DC, rms per 100 ms block, drop the first three blocks, report
percentiles in dB. That is what a gate's envelope detector actually sees.

**What survived the error, because none of it depended on levels:** the
builtin gate's output was *exact digital zero* — one distinct byte value in
5.2 MB, which no DC offset or transient can manufacture or hide; PipeWire's
loader output; and the swh gate's pass/block results, measured as a *count*
of non-zero samples rather than an average.

**What the error caused:** a wrong conclusion, twice stated — see below.

## A WRONG CONCLUSION, STATED TWICE AND WITHDRAWN

The JBL Tune 520BT's microphone was declared dead, in both Bluetooth
profiles, on the strength of the flawed measure. It is alive. With the
corrected instrument:

| headset mic | median | p90 |
|---|---|---|
| room only | -72.1 dB | -65.3 dB |
| speaking | -51.4 dB | -39.4 dB |

That is a **20.7 dB** median response, 25.9 dB at p90. A Bluetooth card
profile was switched from `a2dp-sink` to `headset-head-unit` and back while
chasing a fault that did not exist. The profile has been restored.

## Task 5: the tuning, and why nothing was tuned

| | speaking | room | separation |
|---|---|---|---|
| headset mic | -51.4 dB | -72.1 dB | 20.7 dB |
| laptop mic 1 | -39.4 dB | -42.5 dB | 3.1 dB |
| laptop mic 2 | -64.4 dB | -64.9 dB | 0.5 dB |
| **filtered output** | -47.4 dB | -101.5 dB | **54.1 dB** |

The filter turns a 3.1 dB separation into 54.1 dB.

**The threshold stays at -70 dB, and that is a decision from the
measurement, not an omission.** The room run already drives the output to
-101.5 dB, fully cut, so raising the threshold buys nothing — and it would
cost something, because during the speaking run the filtered p10 sits at
-69.7 dB, on the threshold, so any increase starts eating the quiet parts of
speech.

The plan's original tuning method is **dead**, and it should be said plainly:
it read `gate:Level`, and swh's gate declares `n_notify:0` and exposes no
level readout at all — the identical shape of trap as the headline defect
above, met a second time on a different plugin.

Also worth recording: the headset is the better input by a wide margin — 20.7
dB of speech-to-room separation against the laptop mic's 3.1 dB — despite its
lower absolute level.

## The nofail departure

The config omits `flags = [ nofail ]`, which PipeWire's own example carries.
With `nofail` a broken graph yields a running service that filters nothing.
Without it the unit fails visibly. Bounded, not a restart loop:
`filter-chain.service` carries `Restart=on-failure`, and systemd's defaults
give five attempts.

Stated honestly: `RestartUSec` and `StartLimitBurst` are **systemd
defaults**, not text in the unit — the shipped unit carries only
`Restart=on-failure`.

## A design subtlety worth a paragraph

`pactl get-default-source` was found reading `effect_output.rnnoise` — the
filter itself. The spec says the filter "follows the default input", and
that becomes **circular** when the filter IS the default: WirePlumber then
chooses which microphone feeds it, rather than the user. Not a defect, but it
is how the filter came to be fed by the microphone the user was not speaking
into during part of this investigation.

## Guard enumeration, re-measured

`CLAUDE.md`'s count of `exit 1` guards inside `home/audio.nix` is corrected
here, re-measured rather than incremented by hand:

```
/usr/bin/grep -c 'exit 1' home/audio.nix
13

sed -n "/pulseaudioClients = pkgs.runCommand/,/^  '';$/p" home/audio.nix | /usr/bin/grep -c 'exit 1'
3
```

13 across the whole file (was 9), 3 unchanged inside `pulseaudioClients`. The
difference is `noiseCancelingGuard`'s own four `exit 1`s, added by this
branch and now another `home.packages` guard alongside `pulseaudioClients`,
`wrappedGuiApps` and `dbusActivatableGuiApps` — not a fourth: `home/default.nix`'s
`nixgl-guard` and `home/deb.nix`'s `calango-deb-guard` are two more, so the
count is at least six. Enumerate rather than trust an ordinal:
`grep -n 'home.packages' home/*.nix`.

## What was NOT measured

Be explicit and complete:

- **The colleague case — the reason this spec exists — is UNTESTED.** During
  the room run rnnoise removed roughly 59 dB of what the laptop mic heard. It
  does that to noise, not to speech, since it is trained to preserve voices.
  So the room content was very probably fans, keyboard and HVAC rather than
  people talking. Nothing in the data proves a second human voice was
  present. This is stated as an inference, not a measurement.
- The CPU cost of RNNoise per stream.
- How the panel row renders beyond its `media.class`.
- Whether a colleague talking *while the user talks* is affected at all —
  nothing in open-source PipeWire does this.

## Reproducing the guard

```sh
sg nix-users -c 'nix flake check'
```

reports `running 8 flake checks` throughout — this work adds no new `checks`
entry. `noiseCancelingGuard` runs as part of every generation build, in
`home.packages`, alongside `pulseaudioClients`.
