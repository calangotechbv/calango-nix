# calango-nix spec 3: the Hyprland configuration from Nix

**Goal:** Replace spec 1's three-keybind placeholder with calango-desktop's
real Hyprland configuration — `hyprland.lua`, its per-host outputs, and its
idle and lock behaviour — owned by Home Manager, with its runtime-written
state where Home Manager cannot turn it read-only.

**Depends on:** spec 1 (`2026-08-14-base-and-session-design.md`), spec 2
(`2026-08-14-quickshell-design.md`), and their results in
`docs/2026-08-14-results-suffer-nix-session.md` and
`docs/2026-08-14-results-suffer-quickshell.md`.

## What specs 1 and 2 established that this spec depends on

**A Nix GUI application needs `nixGL`, and a systemd unit needs its own
explicit `PATH`.** Wrapping the compositor does nothing for a unit; a unit
runs exactly what `ExecStart` names, on a `PATH` nothing here populates.

**Started is not working.** quickshell reached `active (running)` and drew a
layer-shell surface while six packages were missing from its `PATH` and four
bar widgets were silently dead. The screen is not the test; the journal is.

**The recurring defect in this project is incomplete enumeration.** Three
times now, something was catalogued by grepping one syntactic form of it and
the catalogue looked complete. Paths hid in QML string concatenation and in
third-party TOML. Commands hid inside `sh -c` strings. Each time the count
was plausible and the failure was silent. This spec is written to make that
mistake structurally harder — see decision 7.

## Two defects this spec inherits and must fix

Both were found while designing it, both are live, and neither is caused by
anything this spec does.

**1. `hyprland.lua` reads a path spec 2 emptied.** Line 1141 reads
`~/.config/quickshell/bar.conf` to size the bar's reserved area. Spec 2 moved
that file to `~/.local/state/quickshell/bar.conf`. Spec 2 enumerated
quickshell's *writers* and never asked who *reads* its state from outside the
tree. The break is dormant only because `hyprland.lua` is not yet loaded.

**2. hypridle locks the screen with apt's `hyprlock`.** Spec 1 configured
`lock_cmd = pidof hyprlock || hyprlock` as bare names. `hypridle.service` has
`Environment=` empty, so it inherits a default unit `PATH` of
`/usr/local/bin:/usr/bin:/bin:…`, on which `hyprlock` resolves to
`/usr/bin/hyprlock` — Debian's 0.55.2 from `trixie-backports`, not the Nix
build in the profile. It works today only because that package is installed.
Spec 6 removes `trixie-backports`, and at that moment the screen stops
locking with no error anywhere.

This is the same shape as spec 1's own findings: a bare command name resolving
to something other than what was meant.

## Decisions

**1. `hyprland.lua` replaces `hyprland.conf`.** Hyprland 0.55.4 links liblua
5.4 and 5.5 and documents a Lua configuration; calango-desktop's config is
already 56KB of it. Spec 1's minimal `hyprland.conf` is deleted rather than
kept alongside — a leftover `.conf` that silently won would restore spec 1's
three keybinds with no error to explain it.

**2. The host is resolved at build time.** `mkHome` gains a host parameter,
so `mkHome "isutton" "suffer"` bakes `hosts/suffer.lua` in. `hyprland.lua`'s
`/etc/hostname` read, its domain-stripping, its `pcall` and its fail-loud
banner all disappear: an unknown host becomes an evaluation error instead of
a runtime surprise.

`hosts/epiphany.lua` still ships, so that machine is one `mkHome` line away,
but no `epiphany` configuration is declared until it is actually ported.

**3. `require()` becomes `dofile()` with absolute paths.** Three call sites:
`hosts.<host>` (line 74), `monitors` (93), `workspace-layouts` (563).

`require` searches `package.path`, and two problems follow from that. It
could not be determined from the Hyprland binary whether that path is seeded
from the config's location or its realpath in the store. And after decision 4
the two state modules live outside the store entirely, so `require` would
need two roots. `dofile` with computed absolute paths removes the question
rather than answering it.

**4. State lives in `~/.local/state/hypr`, symmetric with quickshell.** Four
files: `theme-borders.conf`, `hyprlock.conf`, `monitors.lua`,
`workspace-layouts.lua`. Home Manager manages none of them.

The alternative — leaving them in `~/.config/hypr` as a mixed directory of
symlinks and real files, which is demonstrably the shape that directory has
today — was rejected for consistency with spec 2. The cost is real and is
accepted: it forces edits into spec 2's already-merged tree.

**5. quickshell's five references to `~/.config/hypr` are repointed.** Four
are writes. The fifth is not, and is the reason this is a decision rather
than a chore — see design section 3.

**6. hypridle stays a Home Manager module, with absolute store paths.**
calango-desktop's `hypridle.conf` is translated into
`services.hypridle.settings` rather than forked as a file. Every command in
it becomes an absolute store path, which is what fixes inherited defect 2. A
configuration this project generates should name what it means.

**7. The runtime closure is derived by the implementation, not transcribed
from this spec.** This spec deliberately contains no table of packages.

Spec 2 shipped one, it was built by grepping a single call form, and six
packages were missing — the bar drew anyway and four widgets were dead. A
table in a design document is an invitation to transcribe it, and
transcription is how that defect reached production. The plan must instead
derive the list mechanically from the tree and prove every candidate resolves.
See design section 5 for the method that is required.

## Non-goals

- The terminals, `lf`, the GTK theming, `~/.local/bin` shims, the `.desktop`
  entries, the autostart stubs, the pipewire drop-in, and `uwsm/env`. Spec 4.
  `uwsm/env` belongs there because its content — putting `~/.local/bin` on
  `PATH` and unsetting the input-method modules — exists to serve those shims
  and stubs.
- `night-light.service`, `nm-secret-agent.service`, `bt-agent.service` and
  `quickshell.service.d/killmode.conf`. Spec 5.
- Removing `trixie-backports` and deleting `nixtest`. Spec 6.
- Any change to the calango-desktop repository.
- Simplifying `idle-sleep.sh`. See open items.

## Design

### 1. Repository layout

```
~/Projects/calango-nix/
  hypr/
    hyprland.lua          56KB, forked, loading logic rewritten
    hosts/suffer.lua
    hosts/epiphany.lua    ships, unused until that machine is ported
    idle-sleep.sh         267 lines, forked as-is, PATH-wrapped
  home/
    hyprland.nix          the derivation, hypridle, the closure
```

Not forked: `hypridle.conf` (becomes Nix), the four state files, and
`systemd/` (spec 5).

### 2. The state contract

| File | Exists today | Written by |
|---|---|---|
| `theme-borders.conf` | yes, 113 B | quickshell theme switcher |
| `hyprlock.conf` | yes, 1377 B | quickshell theme switcher |
| `monitors.lua` | no | quickshell monitor panel |
| `workspace-layouts.lua` | no | quickshell layout switcher |

The two that exist are seeded once, by a plan step. The two that do not are
created on first use of their panels; their absence is correct and there is
nothing to seed.

Home Manager's only involvement is a `.keep` forcing the directory to exist.
`hyprland.lua` reads these with `dofile`, and `dofile` on a missing file
raises — so each load stays wrapped in `pcall`, exactly as the `require`
calls are today. A machine that has never opened the monitor panel must still
start.

### 3. The cross-spec edit

Five references in `calango-nix/quickshell/`, in three syntactic forms.

| File | Line | What | Form |
|---|---|---|---|
| `settings/MonitorService.qml` | 108 | writes `monitors.lua` | Python one-liner |
| `layout-switcher/LayoutSwitcher.qml` | 36 | writes `workspace-layouts.lua` | QML concatenation |
| `theme-switcher/Theme.qml` | 109 | writes `theme-borders.conf` | shell string |
| `theme-switcher/Theme.qml` | 217 | writes `hyprlock.conf` | shell string |
| `settings/MonitorService.qml` | 160 | **probes** `hyprland.lua` | shell string |

`common/Paths.qml` gains `hyprStateDir` beside `stateDir` and `sourceDir`, so
the fallback logic exists once.

The fifth is a semantic change, not a path change:

```qml
"grep -q 'require.*monitors' \"$HOME/.config/hypr/hyprland.lua\" && echo yes || echo no"
```

quickshell greps the compositor's source to decide whether monitor
persistence is available. Decision 3 replaces `require` with `dofile`, so
this stops matching and the panel reports unavailable — no error, no log
line, just a feature that quietly says no.

The probe is rewritten to test what it actually cares about: that the state
file is loadable. Checking for `monitors.lua` under `hyprStateDir` is correct
after this change and survives the next refactor of `hyprland.lua`.

This file has now produced two silent failures in two specs: line 160's
`grep` was also the source of spec 2's `grep: command not found`.

### 4. hypridle

Translated from calango-desktop's four listeners: lock at 300s, DPMS off at
330s, `idle-sleep.sh` at 900s, and `after_sleep_cmd` to restore DPMS. Every
command an absolute store path:

```nix
lock_cmd = "${pkgs.procps}/bin/pidof hyprlock || ${pkgs.hyprlock}/bin/hyprlock";
```

`idle-sleep.sh` is forked unchanged and wrapped in a generated script that
sets `PATH`, the same treatment quickshell's binary received. It shells out
to `sleep`, `cat`, `printf`, `rm`, `test`, `systemctl`, `loginctl`, `busctl`,
`grep`, `awk` and `pkill`, and the unit's default `PATH` is not a thing to
rely on.

### 5. Deriving the closure

Required method, because decision 7 forbids a table here.

`hyprland.lua` names something in the order of thirty binaries, but an
unknown number of those appear in prose — its comments discuss `kitty`,
`rofi`, `waybar` and `nm-applet` as alternatives the config does not use.
Grepping for binary names alone therefore over-counts, and grepping only
`exec` lines under-counts, because commands also appear in `bind` dispatchers
and in `$variable` definitions.

The derivation must:

1. Extract every command from `exec`, `exec-once`, `exec-shutdown`, `bind`
   dispatchers and variable definitions — the actual call sites, not free
   text.
2. Resolve each against the compositor's real environment, and record which
   ones were checked rather than assumed.
3. State explicitly, for each name found in prose only, why it is excluded.

Two are already known not to be plain packages: `~/.cargo/bin/wl-clip-persist`
is `wl-clip-persist` 0.5.0 in nixpkgs — another cargo install Nix absorbs —
and `~/.local/bin/apply-gtk-theme` is spec 4's shim and will not resolve until
then. The plan records that gap rather than papering over it.

Availability confirmed while writing this spec: `wl-clip-persist` 0.5.0,
`grim` 1.5.0, `slurp` 1.5.0, `playerctl` 2.4.1, `wireplumber` 0.5.14 (for
`wpctl`), `cliphist` 0.7.0, `foot` 1.27.0.

### 6. Verification

The rule inherited from spec 2: a thing that starts is not a thing that
works.

| Check | What it catches |
|---|---|
| `hyprctl getoption` on a value only `hyprland.lua` sets | a stale `.conf` silently winning |
| `~/.config/hypr/hyprland.conf` absent | the same, from the other side |
| a keybind unique to the real config dispatches | the config loaded but did not apply |
| write a monitor layout, then read `~/.local/state/hypr/monitors.lua` | the silent state-write mode |
| monitor panel reports persistence **available** | the rewritten probe of section 3 |
| bar reserved area correct | inherited defect 1, the `bar.conf` read |
| lock the session; confirm the lock binary is the Nix one | inherited defect 2 |
| `journalctl` clean of `command not found` after exercising binds | the closure, which the screen will not reveal |

The last two matter most. Both inherited defects are invisible on screen: the
lock screen appears either way, and a missing command produces a keybind that
does nothing.

## Open items

- **`idle-sleep.sh` could be simpler under Nix.** Its header explains it
  decides laptop-versus-desktop at runtime because "hypridle.conf is one file
  on every host… the repo's per-host mechanism is not reachable from
  hypridle." Home Manager generates that file per host, so the laptop check
  could move to build time. The battery check cannot — that is genuinely
  runtime. Deliberately not done here: this spec ports, it does not redesign.
- **Whether Hyprland prefers `.lua` over `.conf` when both exist** is
  unverified. The plan deletes the `.conf` rather than depending on the
  answer, but the answer is worth recording when observed.
- **`apply-gtk-theme` will not resolve until spec 4.** A keybind or exec that
  calls it fails until then; the plan records which.
