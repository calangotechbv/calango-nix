# Spec 14: consolidate the nixGL wrapper, and correct what the tree says about it

**Date:** 2026-08-17
**Host:** `suffer`
**Branch:** `nixgl-consolidation`

---

## Why now

`pkgs.nixgl.nixGLIntel` is spelled out at five sites in `home/`. A helper for
exactly this, `nixglWrap`, exists at `home/default.nix:21` and has one caller.
Two of the other four sites carry a body byte-identical to the helper's,
hand-written.

The cost is not the duplication. It is that changing which GL wrapper this
machine uses means moving five places, and nothing checks the fifth. That is
the same shape as every defect this project has paid for: a property held by
five copies of a decision, with no instrument that reads the property.

Three smaller things ride along, because they are the same code and the same
argument:

- Two comments in the tree assert things later measurements retired.
  `CLAUDE.md` flags both as known stale and both results documents for spec 13
  repeat the flag. They have outlived two specs.
- The gammastep-indicator question — whether it is the GTK-application-with-no-
  schemas shape — has been open since spec 13 and blocks one of those comments.
  It is settled below.
- apt's `lf` is a live two-provenance split, the same shape spec 10 found with
  gammastep.

---

## What is measured

Every number below was taken on `suffer` on 2026-08-17. Nothing in this spec
rests on a figure quoted from another document.

### The five sites

```sh
grep -c 'nixGLIntel' home/*.nix | grep -v ':0' | awk -F: '{s+=$2} END {print s}'
# 10   -- counts prose; useless as a property
/usr/bin/grep -rcF '${pkgs.nixgl.nixGLIntel}' home/*.nix | /usr/bin/grep -v ':0' | awk -F: '{s+=$2} END {print s}'
# 5    -- the interpolated form, code only; one per module
grep -rn '^\s*pkgs\.nixgl\.nixGLIntel\s*$' home/*.nix
# home/default.nix:110    -- a home.packages entry, not a wrapper
```

**The second command names `/usr/bin/grep -F` for a reason, and this document
originally did not.** `grep` in this shell is a function backed by ugrep, and it
returns `0` for a pattern containing `${` even against a file that provably
holds it. The count of 5 is correct — re-derived per module with real GNU grep —
but the command first published beside it printed nothing at all, which would
have read as "the property already holds". Found during spec 14's own execution,
by an implementer who noticed its expected `1` came back `0`. Any literal search
in this project must call `/usr/bin/grep -F` explicitly.

| site | current shape | what it produces |
|---|---|---|
| `home/default.nix:21` `nixglWrap` | `writeShellScript` | a script, symlinked into `$out/libexec` by a `runCommand` |
| `home/quickshell.nix:203` | `writeShellScript`, body identical to the helper's | an `ExecStart` target |
| `home/portals.nix:37` | `writeShellScript`, body identical to the helper's | an `ExecStart` target |
| `home/hyprland.nix:104` | `writeShellScriptBin "hyprlock"` | a package with `bin/hyprlock` |
| `home/session.nix:116` | `writeShellScriptBin`, plus `export PATH=` and four extra arguments | a package with `bin/hyprland-nixgl` |

The sixth reference, `home/default.nix:110`, puts `nixGLIntel` itself on the
user's `PATH`. It is legitimate and is not a wrapper site. Because it is not
interpolated, the needle chosen above excludes it with no special case.

### The gammastep-indicator question, settled

Spec 13 left this undecided, and the note that carried it forward described
`.gammastep-indicator-wrapped` as "a 16-line launcher stub with no toolkit
token in it". That is true of the stub and is the wrong file. The wrapper is
its sibling:

```sh
GA=/nix/store/bcrxrws5kwvkrgifs0fw6p4vna412l04-gammastep-2.0.11
wc -l < "$GA/bin/gammastep-indicator"            # 118   -- the makeWrapper script
wc -l < "$GA/bin/.gammastep-indicator-wrapped"   # 16    -- the python launcher
grep -oE '^export [A-Z_]+' "$GA/bin/gammastep-indicator" | sort -u
# GDK_PIXBUF_MODULE_FILE  GIO_EXTRA_MODULES  GI_TYPELIB_PATH  PATH
# PYTHONNOUSERSITE  XDG_DATA_DIRS
```

The question is which of those the application needs. Answer it by adding each
one back to the bare stub, one at a time, instead of stripping them — this
shell has none of them set, so a strip test measures nothing and returns a
uniform failure that reads like a result:

```
nothing set (baseline)             exit=1    traceback at gi.require_version('Gtk', '3.0')
GI_TYPELIB_PATH only               exit=255  runs; gammastep's own --help behaviour
XDG_DATA_DIRS only                 exit=1    unchanged
GDK_PIXBUF_MODULE_FILE only        exit=1    unchanged
```

**`GI_TYPELIB_PATH` is the load-bearing variable, and `XDG_DATA_DIRS` — the
schema half — is not.** `gammastep-indicator` is a PyGObject application:
`statusicon.py` calls `gi.require_version('Gtk', '3.0')` at import time, which
fails without the typelib path. Its module has zero `Gio`, `Settings` or
`GSettings` references:

```sh
M="$GA/lib/python3.13/site-packages/gammastep_indicator"
grep -ohE 'Gio|Settings|GSettings' "$M"/*.py | sort | uniq -c    # no output
```

So the indicator is not the GTK-application-with-no-schemas shape. It reads no
schemas at all. Its wrapper is still load-bearing, for a reason the tree does
not currently name.

### apt's `lf`, and the five packages behind it

```sh
dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' lf   # ii lf 34+ds-2+b1
apt-mark showmanual | grep -x lf                                    # lf  -- manual
apt-cache rdepends --installed lf                                   # none
command -v lf     # /nix/store/…-lf/bin/lf   (PATH position 22 against /usr/bin at 26)
```

`apt-get -s remove lf` reports five packages become orphaned:

```
libxres1 python3-attr python3-docopt python3-xlib ueberzug
```

They form a closed chain hanging off `lf` alone — `ueberzug` is required only
by `lf`, and the other four only by `ueberzug`. This repository's `lf/preview`
never calls it:

```sh
grep -oE '\b(ueberzug|chafa|kitty|sixel)\b' lf/preview | sort | uniq -c
# 13 chafa    11 kitty    10 sixel
```

`chafa` is a separate apt package, marked manual, and is untouched by this.
The union in-use instrument — a `/proc` walk over `maps` and `exe` unioned
with the first field of `ps -eo args` for every process, 1495 unique paths —
returns zero held files for all six, and no `ueberzug` process exists. That
last point needs the union rather than a `/proc` walk, because `ueberzug` is a
Python program and the walk is blind to interpreted programs.

### The `lf` wrapper drops everything except the binary

This was not in the plan for this spec and is the reason the `lf` piece is
larger than one `apt remove`.

```sh
ls /nix/store/ph6b79ayda4y8bjj20bsk35rbijf1i2i-lf-41/share
# applications  bash-completion  fish  man  zsh
ls /nix/store/w1wiksbpk7ywy6dysa7aki0yhcymmf0p-lf        # the installed wrapper
# bin           -- and nothing else
find ~/.nix-profile/share -iname '*lf*'                  # no output
```

`home/lf.nix:69` builds `lfWrapped` with `writeShellScriptBin`, which produces
a package holding one file. `home.packages` gets that and never `pkgs.lf`, so
the profile carries `bin/lf` and none of lf-41's completions, man page or
`lf.desktop`. apt's `lf` ships bash, fish and zsh completions today, so **it is
currently the only source of lf completions on this machine**. Removing it
without changing the wrapper loses them, and the man page stays missing either
way.

### The flatpak override directory is shared

```sh
ls ~/.local/share/flatpak/overrides/
# com.google.Chrome  com.google.ChromeDev  com.slack.Slack
# io.github.ungoogled_software.ungoogled_chromium  io.gitlab.librewolf-community
# org.chromium.Chromium  org.mozilla.firefox
```

Six of the seven are 61-byte files from 2026-08-06, for applications not
installed as flatpaks, owned by nobody. Only `com.slack.Slack` is from the
2026-08-17 fix.

### No `calango.*` option is a function

```sh
grep -rn 'options.calango' home/*.nix     # lf.nix:75, quickshell.nix:208, hyprland.nix:108
grep -rn 'types\.raw\|functionTo\|types\.unspecified' home/*.nix flake.nix   # no output
```

All three existing options publish a store path or a string. The convention
exists to hand data from one module to another.

---

## Design

### Piece 1 — the helper

A new file `lib/nixgl.nix`, taking `{ pkgs }` and returning three attributes.
It is a plain Nix function, not a Home Manager module. `flake.nix` lists its
modules one by one, so a file absent from that list is visibly not one, and
`lib/` sits beside `bin/`, `data/` and `system/`, which are already
non-module directories.

| export | shape | callers |
|---|---|---|
| `wrap name exe` | `writeShellScript` | `home/default.nix`, `home/quickshell.nix`, `home/portals.nix` |
| `wrapBin name exe` | `writeShellScriptBin` | `home/hyprland.nix` |
| `bin` | the string `<store>/bin/nixGLIntel` | `home/session.nix` |

`wrap` and `wrapBin` derive their command line from one private binding, so
`${pkgs.nixgl.nixGLIntel}` is written **once** in the whole repository. `bin`
exists for the single caller that cannot use either function, and it is a
deliberate export rather than a leak: the property this consolidation buys is
that *one file decides which GL wrapper this machine uses*, not that one file
spells the `exec` line.

The module-option alternative was considered and rejected. `calango.*` publishes
data a later module consumes; a curried builder is not data, it would need
`lib.types.raw` — a first in this tree — and every consumer would have to take
`config` to reach a function that depends on nothing but `pkgs`. An overlay
attribute was also rejected: this flake's three overlays all do one job, which
is to replace a NixOS-only path so a package works on Debian.

### Piece 2 — the five call sites

Four sites adopt the helper. `home/session.nix` keeps its own body — the
`export PATH=` line and the `--no-nixgl -- --config` arguments — because its
comment defends that path as verified across three specs and it is the user's
only session. Its single edit replaces
`${pkgs.nixgl.nixGLIntel}/bin/nixGLIntel` with `${nixgl.bin}`, which expands to
the same string.

**Three of the five store paths must not move, and two must.** Identical script
text means an identical hash, so this is checkable rather than arguable. The
split falls out of how each site is written today:

| site | body today | after | path |
|---|---|---|---|
| `hyprpolkitagent` | already the helper's body | unchanged | **must not move** |
| `hyprlock` | one line, identical to the helper's body | unchanged | **must not move** |
| `hyprland-nixgl` | bespoke; one token replaced by `${nixgl.bin}` | same text | **must not move** |
| `quickshell-nixgl` | a `\` line continuation the helper does not use | collapses to one line | moves |
| `portal-nixgl` | the same continuation | collapses to one line | moves |

This is a stronger criterion than "it still builds". Three unmoved paths prove
the helper's body was preserved byte for byte, and an unmoved `hyprland-nixgl`
proves the session's critical path was not touched. Two moved paths prove the
consolidation actually reached the two sites that were hand-written. Capture
all five before and after; do not infer any of them from reading the edit.

A moved `ExecStart` changes the unit text, so sd-switch restarts
`quickshell.service` and `xdg-desktop-portal-hyprland.service`. That is correct
behaviour and is what those units want. `hyprpolkitagent.service` should not
restart, because its path does not move.

### Piece 3 — the guard

A `runCommand` in `home.packages`, in `home/default.nix`.

It goes in `home.packages` and not in `flake.nix`'s `checks` deliberately. The
failure it prevents is a sixth wrapper site, and the person who adds one is
editing a module and building a generation. They may never run
`nix flake check`. A `home.packages` guard runs on every generation build,
which is strictly more often.

Two branches:

| branch | fires when | message |
|---|---|---|
| leak | `${pkgs.nixgl.nixGLIntel}` appears anywhere under `home/` | names the file and line, and says to use `lib/nixgl.nix` |
| vacuity | `lib/nixgl.nix` contains no occurrence | the helper has moved or been deleted, so the leak branch proves nothing |

The needle is the interpolated form, for the reason measured above: a bare
`nixGLIntel` grep returns ten and reads the tree's own prose, which is how
spec 11's `appPath` guard came to match its own comments. The vacuity anchor is
the same one `gui-desktop-ids`, `no-pulseaudio-daemon` and `wrappedGuiApps` each
carry.

Both branches get proven by mutation before the guard is trusted, and the
mutation gets confirmed by a count before the build runs. Inside the builder,
put the grep in a condition — `if grep -rq … ; then` — because a builder runs
with `errexit` and `pipefail`, where a bare `n="$(grep -c …)"` aborts the
assignment before any message prints.

### Piece 4 — the three stale passages

`CLAUDE.md` names two of these. The third, the gammastep argument, is stale for
a reason only today's measurement exposes.

**`home/default.nix:18-20`** currently reads "This generalises: every Nix GUI
application on this machine needs the wrapper". `foot` disproves it — it is
Nix's, it draws through wayland shm, and `home/default.nix:53-55` keeps it
precisely as the control for this question. The replacement states the rule
that is actually true: a session child inherits the five GL variables from the
compositor's own wrap, and a systemd user unit inherits none of them, which is
why five things carry their own wrapper and nothing else needs one.

**`home/gui-apps.nix:16-38`** currently argues that gammastep's wrappers matter
because "the ones that matter to this package come from its dependencies",
naming the two schema directories each wrapper prefixes. The measurement above
contradicts the specific claim: `XDG_DATA_DIRS` alone changes nothing for the
indicator, and `GI_TYPELIB_PATH` alone is sufficient. The conclusion survives —
the guard should require a wrapped binary from every member — but for a
stronger reason than the one written down, because wrapper necessity turns out
not to be a function of schemas at all.

**`home/gui-apps.nix:57-60`** says "Neither needs the nixGL wrapper", citing the
bare run of Signal and Bitwarden in the live session. That test was real and
its conclusion is one step too wide: the run happened inside the Hyprland
session, so both binaries inherited the five variables. It shows they need no
wrapper **of their own**, not that they need no nixGL environment. Stripping
those variables from Signal produced
`MESA-LOADER: failed to open dri: /run/opengl-driver/lib/gbm/dri_gbm.so`.

### Piece 5 — the flatpak override stays out of the flake

**Decision: this flake does not own it.** Three reasons.

Slack leaves flatpak in the next queued spec, so a managed file would be
written and deleted within two specs. The overrides directory holds six files
this flake does not own and never should, and one managed file among them
reproduces the shape of the `pipewire-session-manager.service` alias — a link
Home Manager's own manifest cannot see, dangling forever when its module
leaves. And the durable thing here is the reason, not the file.

So it goes to `CLAUDE.md` as a standing fact, with the command, stated as a
rule for any future flatpak application rather than as a note about Slack.

### Piece 6 — apt's `lf`, and keeping what it ships

Two parts, in this order.

**First, make the Nix side complete.** Replace `home/lf.nix`'s
`writeShellScriptBin` with a `symlinkJoin` over `pkgs.lf` plus `wrapProgram`,
so the package keeps lf-41's `share/` tree — bash, fish and zsh completions,
the man page and `lf.desktop` — while `bin/lf` still carries the `PATH` that
`lfrc`'s commands need. `calango.lf` stays `types.package` and `session.nix`'s
consumer is unaffected, because the result is still a package with `bin/lf`.

Verify by property, not by shape: the new package must contain
`share/bash-completion`, `share/man/man1` and `share/applications/lf.desktop`,
and `bin/lf` must still export the four store paths `lfPath` names.

**Then remove apt's `lf`.** Six packages go: `lf`, `ueberzug`, `libxres1`,
`python3-attr`, `python3-docopt`, `python3-xlib`. Re-read the "no longer
required" list at the moment of removal rather than trusting the list above —
that is the standing rule, and the whole reason the orphan backlog reached 137.
Re-run the union in-use check at that moment too.

The user runs every `apt` command. No agent runs one.

---

## Out of scope

- **Scrubbing the session's GL environment.** It looks like a leak and it is
  load-bearing for every Nix GL application launched as a session child, which
  is every one the Applications panel starts. A spec to clean it up was one
  command from being written during spec 13.
- **`--force-nixgl`.** Letting `start-hyprland` do its own nixGL handling and
  dropping the flake's `nixgl` input is the tidier end state.
  `home/session.nix:107-113` records it as unproven here and deliberately not
  taken. This spec does not re-open it.
- **Whether Signal or Bitwarden are GPU-accelerated.** Unmeasured, and the
  check needs one of them running.
- **Moving Slack to the `.deb`.** Its own spec.

---

## Acceptance criteria

1. `${pkgs.nixgl.nixGLIntel}` appears exactly once in the repository, in
   `lib/nixgl.nix`.
2. The guard's leak branch and vacuity branch each fail under mutation, with
   the mutation confirmed by a count before the build runs.
3. All five wrapper store paths are captured before and after. The
   `hyprpolkitagent`, `hyprlock` and `hyprland-nixgl` paths are unchanged; the
   `quickshell-nixgl` and `portal-nixgl` paths have moved.
4. `nix flake check` exits 0 and reports three checks.
5. The generation builds. The two moved scripts differ from today's only in
   that a `\` line continuation has become a space.
6. `home/default.nix:18-20`, `home/gui-apps.nix:16-38` and
   `home/gui-apps.nix:57-60` each state only what a measurement in this
   document supports.
7. The package `home/lf.nix` puts in `home.packages` contains
   `share/bash-completion`, `share/man/man1` and
   `share/applications/lf.desktop`, and its `bin/lf` still sets the four store
   paths `lfPath` names.
8. `CLAUDE.md` carries the flatpak override rule, the corrected
   gammastep-indicator finding, and the new guard in its enumeration of
   `home.packages` guards.
9. After the user removes apt's `lf`, `apt-get -s autoremove` still proposes
   zero packages.

---

## Risks

**The compositor.** Piece 2 touches `home/session.nix`, which starts the user's
only session. The edit is one token and criterion 3 proves the output is
byte-identical, but a mistake here costs a login. Do that edit first and check
the store path before anything else changes.

**Two units restart on switch.** `quickshell.service` and
`xdg-desktop-portal-hyprland.service` get a new `ExecStart`. That is intended.
Switch from a tty. If `hyprpolkitagent.service` also restarts, the helper's
body was not preserved and criterion 3 has failed.

**The guard could pass vacuously.** It is a grep for a string, which is the
exact shape that failed three times in this project — spec 6 looked at the
wrong thing, spec 10 looked in the wrong place, spec 11 found the right string
in the wrong role. The vacuity branch and the mutation requirement are the
answer, and neither is optional.

**`ueberzug` is interpreted.** Its absence cannot be established by a `/proc`
walk. Use the union, and ask `dpkg -S` about full command lines.
