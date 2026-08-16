# Audio Stack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move `pipewire`, `pipewire-pulse`, `wireplumber` and `filter-chain` — seven unit files and seven enablement artifacts — from Debian to Nix, then remove the six Debian packages behind them, leaving audio entirely Nix's.

**Architecture:** Two Nix packages (`pipewire` 1.6.6, `wireplumber` 0.5.14) supply all seven units. A build-time derivation (`audioUnits`) cross-checks both unit sets against a written list, asserts every `Exec*=` directive is absolute, and asserts `wireplumber.service` still declares `Alias=pipewire-session-manager.service`. The units land at `~/.config/systemd/user` (UnitPath position 5), which beats `/usr/lib/systemd/user` (position 15). Unlike spec 8's portal work, all seven move in **one** switch: `wireplumber` is `pipewire`'s session manager and sequencing would build a `pipewire 1.6.6` / `wireplumber 0.5.8` pairing nobody tests. A hand-run rehearsal comes first, because this is the project's first migration that is an upgrade rather than a lateral move.

**Tech Stack:** Nix flakes, standalone Home Manager (`release-26.05`), nixpkgs `nixos-26.05`, Debian 13 (trixie), systemd user manager, PipeWire, WirePlumber, ALSA, BlueZ (apt, permanently), quickshell.

**Spec:** `docs/superpowers/specs/2026-08-16-audio-stack-design.md`

## Global Constraints

- **Every `nix` and `home-manager` invocation must be wrapped in `sg nix-users -c '...'`.** `/nix/var/nix/daemon-socket/` is `0770 root:nix-users`; a process whose credentials lack the group fails with `getting status of '/nix/var/nix/daemon-socket/socket': Permission denied`, which reads as a broken Nix install and is not one.
- **Never read a package version from `nixpkgs#<pkg>`.** That is the flake *registry*, not this flake's pinned input. Here the registry reports `pipewire` `1.6.8` and `wireplumber` `0.5.15`; the pinned input has **`1.6.6`** and **`0.5.14`**, and those are the versions this plan installs. Use `sg nix-users -c 'nix eval --raw .#homeConfigurations."isutton@suffer".pkgs.<pkg>.version'`. This mistake has been made in specs 6, 7 and 8.
- **Agents must never run:** `home-manager switch`; any mutating `apt`/`apt-get`/`dpkg`/`apt-mark`/`flatpak` command; `systemctl` with `start`/`stop`/`restart`/`enable`/`disable`/`daemon-reload`; `reboot`; or the activation script without `DRY_RUN=1`. Read-only queries (`systemctl show`/`list-units`/`list-unit-files`, `busctl`, `pactl`, `wpctl`, `pw-dump`, `apt-get -s`, `apt-mark showauto`, `dpkg-query`) are the agent's job by design.
- **Tasks 1, 3 and 4 contain user-run steps.** An agent composes the command, the user runs it, the agent reads the output and writes it down.
- **All seven units move in one switch.** Do not sequence them. `wireplumber` is `pipewire`'s session manager, and `pipewire-pulse` and `filter-chain` are the *same binary* as `pipewire` under different configuration. Sequencing would deliberately construct Nix's `pipewire 1.6.6` under Debian's `wireplumber 0.5.8`, a pairing upstream does not test.
- **Units are copied verbatim, never re-described.** Nix's units differ from Debian's beyond `ExecStart` — different `Wants`/`After`, a `BindsTo`, a different `SystemCallFilter`, an `Alias`. The goal is Nix's coherent set, not a hybrid assembled from two upstreams.
- **The alias must be created explicitly.** Nix's `pipewire-pulse.service` carries `Wants=pipewire.service pipewire-session-manager.service` and Nix's `filter-chain.service` carries `After=pipewire.service pipewire-session-manager.service`. That name exists only because `wireplumber.service` declares `Alias=pipewire-session-manager.service`, and an alias becomes a real name only when the alias symlink is written. This plan installs units declaratively, so it writes the symlink itself.
- **`Wants=` and `After=` on a missing unit are silent.** The dependency is dropped, the ordering with it, audio starts anyway, and nothing appears in `--state=failed`. The alias gate must confirm the name **resolves** (`systemctl --user show pipewire-session-manager.service -p Id` returns `Id=wireplumber.service`), not merely that a unit file mentions it. Today that name is `LoadState=not-found`.
- **`ldd` is not a decision procedure for a `dlopen` question.** PipeWire loads its SPA plugins — bluez5 among them — with `dlopen`, so clean linkage proves nothing about Bluetooth. The check is a connected device or `pw-dump`. This project has twice nearly shipped `ldd` as the answer to a `dlopen` question.
- **`rtkit` and `pulseaudio-utils` must be marked manual before the apt removal.** Both are currently `apt-mark showauto`, and `apt-get -s remove` of the six packages lists both as "no longer required". `rtkit-daemon` is a running *system* service owning `org.freedesktop.RealtimeKit1`; it is how PipeWire's `module-rt` gets `SCHED_FIFO` for its data loop (`data-loop.0` is at priority 20 right now). Losing it to a later `apt autoremove` would turn into intermittent audio glitching with no obvious cause. `pulseaudio-utils` supplies `pactl`, which most of this plan's gate speaks; Nix ships a rich `pw-*` toolset and no `pactl`.
- **Gates read a running process's own state.** `/proc/<pid>/exe`, `/usr` code-mapping counts, `NRestarts` after a cold boot — plus one thing a person does. Every check in specs 6, 7 and 8 that compared a path, a name or an exit code eventually lied.
- **Enumerate by listing the filesystem, never from a remembered list.** The seven enablement artifacts get counted with `find`. Spec 8's results document asserted three permission-store tables from memory when the live system had four — inside a document that states this rule.
- **Verify by counting, never by reading empty output as success.** `sed` and other filters exit 0 and mask an upstream `grep`'s status, so "the property holds" and "the pipeline broke" look identical. Use `| wc -l` and compare the number.
- **A Home Manager rollback is not a recovery path.** The current generation carries the uwsm session units, both portal backends, the portal frontend, `hyprland-portals.conf` and the font baseline. This plan adds audio to what a rollback would strip. Recovery is fix-forward.
- **Nothing in the login path needs audio.** `greetd` has no audio dependency and Hyprland is a Nix package. The worst case in this plan is "no sound", never "no desktop", and recovery never needs a TTY.
- **Nothing here is irreversible.** All six Debian packages are downloadable from trixie. Task 1 recovery is `systemctl --user start`; Tasks 2–3 recovery is removing `./home/audio.nix` from the flake's module list and switching; Task 4 recovery is `sudo apt install`.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `home/audio.nix` | The whole audio subsystem: both packages, the `audioUnits` guard derivation, seven unit entries, six `.wants` links, one alias link | **Create** (Task 2) |
| `flake.nix` | Module list, and the comment above `checks.no-dangling-home-files` naming which files it covers | Modify (Task 2) |
| `docs/2026-08-16-results-suffer-audio-stack.md` | The results document | Create (Task 1), appended by Tasks 3–5 |
| `CLAUDE.md` | Project gotchas | Modify (Task 5) |

`home/audio.nix` is a new file rather than an addition to `home/services.nix`, following the shape `home/portals.nix` established in spec 8: one file per subsystem.

`home/apps.nix` is **not** modified. It already owns
`~/.config/pipewire/pipewire-pulse.conf.d/20-block-source-volume.conf`, the
rule that stops Chrome walking the capture device's gain back up between
calls. Nix's `pipewire-pulse.conf` documents the same drop-in directory, so
the fragment keeps applying unchanged — but that is a claim, so Task 3's gate
tests it.

### The unit inventory every task needs

Seven unit files, from two packages:

| Unit file | Package | Enabled by |
|---|---|---|
| `pipewire.service` | `pipewire` | `default.target.wants/` |
| `pipewire.socket` | `pipewire` | `sockets.target.wants/` |
| `pipewire-pulse.service` | `pipewire` | `default.target.wants/` |
| `pipewire-pulse.socket` | `pipewire` | `sockets.target.wants/` |
| `filter-chain.service` | `pipewire` | `default.target.wants/` |
| `wireplumber.service` | `wireplumber` | `pipewire.service.wants/` |
| `wireplumber@.service` | `wireplumber` | nothing — `disabled` on Debian too, installed for parity |

Seven enablement artifacts: the six `.wants` links above, plus
`systemd/user/pipewire-session-manager.service` — the alias.

`wireplumber@.service` is installed even though it is disabled and unused.
Spec 8 made the same call for `xdg-desktop-portal-rewrite-launchers.service`:
dropping something Debian shipped is a behaviour change, and a behaviour
change should not ride along inside a migration.

---

## Task 1: Baseline and rehearsal

Spec Phase 0. Nothing is written to the flake in this task. Its deliverable is
a **go/no-go decision** plus a recorded baseline that every later gate compares
against.

This is the project's first migration that is an upgrade (`1.4.2` → `1.6.6`,
`0.5.8` → `0.5.14`) rather than a lateral move. Every previous one was
version-neutral, which meant any breakage was provenance and never behaviour.
Here it can be either, and those need separating **before** the flake is
touched.

**Files:**
- Create: `docs/2026-08-16-results-suffer-audio-stack.md`

**Interfaces:**
- Produces: the two store paths (`$PW`, `$WP`) that Task 2's module references, the baseline device list that Task 3's gate compares against, and the answer to "does systemd resolve a home-manager-shaped alias symlink".

**Cost:** one interrupted audio session, at a time the user chooses. Chrome and
any other running PulseAudio client will lose audio for the duration and may
need restarting afterwards.

- [ ] **Step 1: Realise both packages from the pinned input**

```bash
sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".pkgs.pipewire'
sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".pkgs.wireplumber'
sg nix-users -c 'nix eval --raw .#homeConfigurations."isutton@suffer".pkgs.pipewire.version'; echo
sg nix-users -c 'nix eval --raw .#homeConfigurations."isutton@suffer".pkgs.wireplumber.version'; echo
```

Expected: two store paths, then `1.6.6` and `0.5.14`.

Record the store paths as `$PW` and `$WP` — every later step in this task uses
them. `nix build` rather than `nix eval` on purpose: `eval` prints a path
without realising it, and the rehearsal needs the binaries to actually exist.

If either version is `1.6.8` or `0.5.15`, the command read the registry rather
than the pinned input. Stop and re-read the Global Constraints.

- [ ] **Step 2: Record the Debian baseline**

```bash
PW=<path from Step 1>
WP=<path from Step 1>

echo "=== Debian package versions"
dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' \
  pipewire pipewire-bin pipewire-pulse wireplumber \
  libspa-0.2-bluetooth libcanberra-pulse pulseaudio-utils rtkit

echo "=== unit files"
systemctl --user list-unit-files 'pipewire*' 'wireplumber*' 'filter-chain*'

echo "=== running state"
systemctl --user show pipewire.service pipewire-pulse.service \
  wireplumber.service filter-chain.service \
  -p Id -p MainPID -p ActiveState -p NRestarts -p FragmentPath

echo "=== which binary is actually serving"
for u in pipewire pipewire-pulse wireplumber filter-chain; do
  pid=$(systemctl --user show "$u.service" -p MainPID --value)
  printf '%-16s pid=%-7s exe=%s usr-maps=%s\n' "$u" "$pid" \
    "$(readlink -f /proc/$pid/exe)" \
    "$(grep -cE '/usr/(lib|bin|libexec)' /proc/$pid/maps)"
done

echo "=== realtime scheduling"
pw=$(systemctl --user show pipewire.service -p MainPID --value)
for t in /proc/$pw/task/*; do
  printf '%-14s %s\n' "$(cat $t/comm)" \
    "$(chrt -p "$(basename $t)" 2>/dev/null | paste -sd';')"
done

echo "=== devices"
pactl list cards short
pactl list sinks short
pactl list sources short

echo "=== bluez5 plugin counts"
printf 'nix    %s\n' "$(ls -1 $PW/lib/spa-0.2/bluez5/ | wc -l)"
printf 'debian %s\n' "$(dpkg -L libspa-0.2-bluetooth | grep -c '\.so$')"

echo "=== apt marks"
apt-mark showauto pulseaudio-utils rtkit
```

Expected, and record verbatim — Task 3 Step 9 and Task 4 Step 8 compare against
these exact values:

- Six `ii` packages plus `rtkit 0.13-5.1`; `pipewire*` at `1.4.2-1`,
  `wireplumber` at `0.5.8-2`.
- Seven unit files: six `enabled`, `wireplumber@.service` `disabled`.
- Four services `active`, `NRestarts=0`, every `FragmentPath` under
  `/usr/lib/systemd/user`.
- Four exes under `/usr/bin`, each with a **non-zero** `/usr` map count. This
  is the "before" side of the provenance check; a Nix binary must read `0`.
- A `data-loop.0` thread at scheduling priority 20 — RTKit granted it.
- Two ALSA cards, one sink, three sources.
- 14 bluez5 plugins on the Nix side against 9 on Debian's.
- Both `pulseaudio-utils` and `rtkit` printed by `showauto`.

- [ ] **Step 3: Confirm the alias name does not exist today**

```bash
systemctl --user show pipewire-session-manager.service -p Id -p Names -p LoadState
```

Expected: `LoadState=not-found`.

This is the "prove the check can fail" half of the alias gate. Debian's
`pipewire-pulse.service` names `wireplumber.service` directly and never uses
the generic name, so the property Task 3 gates on is **false right now**. A
check that cannot distinguish the two states is worthless, and this step is
what shows it can.

- [ ] **Step 4: The user stops the Debian audio stack**

⚠️ **Caution:** this silences the machine and disconnects every running
PulseAudio client. Chrome in particular may need restarting afterwards, even
once audio is back.

```bash
systemctl --user stop pipewire.socket pipewire-pulse.socket \
                      pipewire.service pipewire-pulse.service \
                      wireplumber.service filter-chain.service
systemctl --user is-active pipewire.service pipewire-pulse.service \
                           wireplumber.service filter-chain.service
```

Expected: four lines of `inactive`.

Sockets are listed first: stopping a service while its socket is still
listening lets socket activation start it straight back up.

- [ ] **Step 5: Probe the alias mechanism by hand**

```bash
WP=<path from Step 1>
ln -s "$WP/share/systemd/user/wireplumber.service" \
      ~/.config/systemd/user/pipewire-session-manager.service
systemctl --user daemon-reload
systemctl --user show pipewire-session-manager.service -p Id -p Names -p LoadState -p FragmentPath
```

Expected: `Id=wireplumber.service` — systemd followed the symlink, saw a target
basename different from the link name, and registered the link name as an
alias. `Names=` should list both names, and `LoadState=loaded`.

If instead `Id=pipewire-session-manager.service` with its own `FragmentPath`,
systemd did **not** merge them: it loaded a second, independent copy of
wireplumber's unit under a different name. That is a different and much worse
outcome — two session managers racing for the same pipewire core — and this
plan stops here. Report it; the fallback would be re-describing
`pipewire-pulse.service` and `filter-chain.service` with
`systemd.user.services` to name `wireplumber.service` directly, which the spec
rejected and which would need the user's decision.

`FragmentPath` at this moment points into `/usr/lib/systemd/user` — Debian's
wireplumber, because Nix's unit is not installed yet. That is expected and is
not what this step tests. What it tests is only whether the *name resolves*.

- [ ] **Step 6: Remove the probe symlink**

```bash
rm ~/.config/systemd/user/pipewire-session-manager.service
systemctl --user daemon-reload
systemctl --user show pipewire-session-manager.service -p LoadState
```

Expected: `LoadState=not-found`.

This must happen before Task 3's switch. Home Manager refuses to overwrite a
file at a path it wants to own, and Task 2's module claims exactly this path.

- [ ] **Step 7: The user runs Nix's binaries in the foreground**

In one terminal each, or backgrounded from one:

```bash
PW=<path from Step 1>
WP=<path from Step 1>
"$PW/bin/pipewire" &
"$WP/bin/wireplumber" &
"$PW/bin/pipewire-pulse" &
"$PW/bin/pipewire" -c filter-chain.conf &
```

The fourth line is `filter-chain` — the same binary under a different
configuration. It is included to test one specific claim: that pipewire
resolves the bare name `filter-chain.conf` through its own compiled-in data
directory (`$PW/share/pipewire`) rather than Debian's `/usr/share/pipewire`.
If the config base did not move with the binary, this is where it shows.

- [ ] **Step 8: The pass condition**

```bash
PW=<path from Step 1>
WP=<path from Step 1>
echo "=== provenance of what is running"
for p in $(pgrep -u "$USER" -f "$PW/bin/|$WP/bin/"); do
  printf 'pid=%-7s exe=%s usr-maps=%s\n' "$p" \
    "$(readlink -f /proc/$p/exe)" \
    "$(grep -cE '/usr/(lib|bin|libexec)' /proc/$p/maps)"
done

echo "=== devices"
pactl list cards short
pactl list sinks short
pactl list sources short

echo "=== play something"
"$PW/bin/pw-play" /usr/share/sounds/alsa/Front_Center.wav
```

`pgrep -f` matches on the full command line, not the process name. Nix wraps
binaries and truncates `comm` at 15 characters, so `pgrep -x pipewire` matches
nothing in both the working and the broken state. The pattern is an ERE, and
it carries both store paths — three of the four processes are pipewire's
binary and the fourth is wireplumber's.

Then, by hand:

1. Sound comes out of the speakers.
2. Both ALSA cards enumerate, and the sink and source list matches Step 2's.
3. **The JBL Tune 520BT connects and plays** — A2DP.
4. **A real call using the JBL's microphone** — HFP. This is a different code
   path from playback, and it exercises the four HFP codecs (`cvsd`, `msbc`,
   `lc3-swb`, `lc3-a127`) that Debian's `libspa-0.2-bluetooth` never shipped.
   Playback working says nothing about it.
5. The `usr-maps` count is `0` for every process listed.

**If any of 1–4 fails, the cause is behaviour rather than provenance, and this
plan stops here with nothing written to the flake.** Report which one failed
and what the journal said.

- [ ] **Step 9: The user restores the Debian stack**

```bash
kill %1 %2 %3 %4 2>/dev/null
systemctl --user start pipewire.socket pipewire-pulse.socket \
                       pipewire.service wireplumber.service \
                       pipewire-pulse.service filter-chain.service
systemctl --user is-active pipewire.service pipewire-pulse.service \
                           wireplumber.service filter-chain.service
```

Expected: four lines of `active`. Sound works again. Chrome may need a restart
to reattach to the recreated PulseAudio socket.

- [ ] **Step 10: Write the results document**

Create `docs/2026-08-16-results-suffer-audio-stack.md`:

```markdown
# Results: the audio stack — suffer

2026-08-16

Spec: `docs/superpowers/specs/2026-08-16-audio-stack-design.md`
Plan: `docs/superpowers/plans/2026-08-16-audio-stack.md`

## Phase 0: baseline and rehearsal

### Pinned versions

<Step 1 output>

### The Debian baseline

<Step 2 output, verbatim>

### The alias, before

<Step 3 output>

### The alias probe

<Step 5 and Step 6 output>

### The rehearsal

<Step 8 output, plus a sentence each on the four by-hand checks>

### Verdict

<go or no-go, and why>
```

- [ ] **Step 11: Commit**

```bash
git add docs/2026-08-16-results-suffer-audio-stack.md
git commit -m "audio: rehearse Nix's pipewire and wireplumber by hand

This is the first migration in this project that is an upgrade rather
than a lateral move -- pipewire 1.4.2 to 1.6.6, wireplumber 0.5.8 to
0.5.14 -- so a failure could be provenance or behaviour, and those have
to be separated before the flake is touched. Phase 0 runs Nix's binaries
against the same hardware and the same configuration with nothing
written.

Also probes the alias by hand. Nix's pipewire-pulse.service depends on
pipewire-session-manager.service, a name that exists only because
wireplumber.service declares Alias=. systemd resolves an alias symlink
whose target basename differs from the link name -- confirmed here
rather than assumed, because Wants= on a missing unit is silent and
would have left audio working with the session manager unsequenced."
```

---

## Task 2: `home/audio.nix`, build only

Spec Phase 1's authoring half. **No switch happens in this task**, so nothing
changes at runtime: the deliverable is a *built generation* whose contents are
read and verified.

Splitting authoring from switching is deliberate. The module carries three
build-time guards, and each is worth proving can fail before the machine's
audio depends on it.

**Files:**
- Create: `home/audio.nix`
- Modify: `flake.nix` — the `modules` list, and the comment above `checks.${system}.no-dangling-home-files`

**Interfaces:**
- Consumes: the store paths and versions established in Task 1.
- Produces: `$NEW/home-files/.config/systemd/user/` containing seven unit files, six `.wants` links and `pipewire-session-manager.service`; and `pkgs.pipewire`/`pkgs.wireplumber` in `home.packages`, which put `pw-play`, `pw-dump`, `pw-top` and `wpctl` on `PATH` for Tasks 3 and 4.

- [ ] **Step 1: Create `home/audio.nix`**

```nix
{ lib, pkgs, ... }:

let
  # Both unit sets, written out by name rather than read from the store with
  # builtins.readDir -- that would be import-from-derivation, and it would
  # trade a loud build failure for a silent change in what gets installed.
  # The audioUnits derivation below cross-checks these lists against the real
  # directories, so a list that goes stale is a build error rather than a unit
  # that quietly stops existing.
  #
  # Spec 8 learned this the expensive way from the other direction: its first
  # draft asserted Debian shipped three units from xdg-desktop-portal when
  # dpkg -L showed four, because `systemctl --user list-units` does not show a
  # oneshot that has already finished. Enumerate by listing, never by memory.
  #
  # C collation is not incidental. '-' is 0x2D, '.' is 0x2E and '@' is 0x40,
  # so under LC_ALL=C `pipewire-pulse.service` sorts before `pipewire.service`
  # and `wireplumber.service` before `wireplumber@.service`. A list transcribed
  # from unsorted `ls` output would fail the check on a correct tree.
  pipewireUnits = [
    "filter-chain.service"
    "pipewire-pulse.service"
    "pipewire-pulse.socket"
    "pipewire.service"
    "pipewire.socket"
  ];

  wireplumberUnits = [
    "wireplumber.service"
    "wireplumber@.service"
  ];

  allUnits = pipewireUnits ++ wireplumberUnits;

  # A copy of both unit directories that refuses to build if anything this
  # module depends on has changed upstream. The files are copied rather than
  # symlinked so the checks sit in the path of the files themselves -- nothing
  # can consume a unit without having passed them. Copying preserves the
  # absolute /nix/store paths written inside each unit, which is the entire
  # point of using Nix's copies instead of Debian's.
  audioUnits = pkgs.runCommand "audio-session-units" { } ''
    mkdir -p "$out"

    check_set() {
      pkgdir="$1"; expected="$2"; label="$3"
      actual="$(cd "$pkgdir" && LC_ALL=C ls -1 | LC_ALL=C sort | tr '\n' ' ')"
      actual="''${actual% }"
      if [ "$expected" != "$actual" ]; then
        echo "$label's unit set has changed." >&2
        echo "$expected" | tr ' ' '\n' | LC_ALL=C sort > expected.txt
        echo "$actual"   | tr ' ' '\n' | LC_ALL=C sort > actual.txt
        LC_ALL=C comm -13 expected.txt actual.txt | sed 's/^/  added:   /' >&2
        LC_ALL=C comm -23 expected.txt actual.txt | sed 's/^/  removed: /' >&2
        echo "Update the unit list in home/audio.nix, then check that every" >&2
        echo "added or removed unit is accounted for -- including its" >&2
        echo "enablement link, which this module owns and upstream does not." >&2
        exit 1
      fi
      cp "$pkgdir"/* "$out/"
    }

    check_set ${pkgs.pipewire}/share/systemd/user \
      "${lib.concatStringsSep " " pipewireUnits}" pipewire
    check_set ${pkgs.wireplumber}/share/systemd/user \
      "${lib.concatStringsSep " " wireplumberUnits}" wireplumber

    chmod -R u+w "$out"

    # Guard 1: no relative Exec directive.
    #
    # systemd does NOT resolve a bare program name against the manager's PATH.
    # It uses a search path fixed when systemd was compiled --
    # `systemd-path search-binaries-default` prints
    # /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin -- which contains no
    # /nix/store entry and never will. home/uwsm.nix shipped exactly this bug
    # for two phases: ExecStart=fumon ran Debian's binary under Nix's unit.
    #
    # ^Exec[A-Za-z]*= rather than a list of directive names. Enumerating the
    # directives by hand is what produced that bug. The prefix characters
    # @ - : + ! are systemd's exec modifiers, stripped before the path is read.
    #
    # All seven units are absolute today, filter-chain.service included --
    # its `-c filter-chain.conf` argument is a config name resolved by
    # pipewire's own search path, not by systemd, and only the program word is
    # examined here.
    relative="$(
      grep -hE '^Exec[A-Za-z]*=' "$out"/* \
        | sed -E 's/^Exec[A-Za-z]*=//; s/^[@:+!-]+//' \
        | awk 'NF && $1 !~ /^\// { print }'
    )" || true
    if [ -n "$relative" ]; then
      echo "An audio unit ships an Exec directive that is not absolute:" >&2
      echo "$relative" | sed 's/^/  /' >&2
      echo "systemd resolves these against a compile-time search path, not" >&2
      echo "the manager's PATH, and no /nix/store entry is on it." >&2
      exit 1
    fi

    # Guard 2: the alias still exists upstream.
    #
    # This is the load-bearing one. Nix's pipewire-pulse.service says
    #   Wants=pipewire.service pipewire-session-manager.service
    # and Nix's filter-chain.service says
    #   After=pipewire.service pipewire-session-manager.service
    # Neither name is wireplumber's own; both work only because
    # wireplumber.service declares Alias=pipewire-session-manager.service and
    # something writes the alias symlink. This module writes it (see
    # xdg.configFile below), hardcoding the alias name -- so if upstream ever
    # drops or renames the Alias=, this build must fail rather than keep
    # installing a link nothing declares.
    #
    # The failure it prevents is silent. systemd treats Wants= and After= on a
    # unit that does not exist as satisfied-by-absence: the dependency is
    # dropped, the ordering with it, audio starts anyway with the session
    # manager no longer sequenced ahead of the pulse shim, and nothing appears
    # in `systemctl --user --state=failed`.
    if [ "$(grep -cxF 'Alias=pipewire-session-manager.service' \
              "$out/wireplumber.service")" != 1 ]; then
      echo "wireplumber.service no longer declares" >&2
      echo "  Alias=pipewire-session-manager.service" >&2
      echo "The alias link this module writes is now unfounded. Re-read" >&2
      echo "Nix's pipewire-pulse.service and filter-chain.service to see" >&2
      echo "what name they depend on now, and fix both together." >&2
      exit 1
    fi
  '';

  # The seven unit files, at ~/.config/systemd/user -- UnitPath position 5,
  # against /usr/lib/systemd/user at position 15.
  #
  # Those numbers are `systemctl --user show -p UnitPath --value`, the
  # manager's own property. `systemd-analyze --user unit-paths` looks like the
  # obvious way to check and answers a different question: it computes the
  # list from the *calling* process's environment, reports 18 entries, and
  # invents a ~/.nix-profile/share/systemd/user entry the manager has never
  # seen. In one review cycle a reviewer and the controller drew opposite
  # wrong conclusions from it.
  unitFiles = lib.listToAttrs (map
    (n: lib.nameValuePair "systemd/user/${n}" { source = "${audioUnits}/${n}"; })
    allUnits);

  # Enablement, owned here rather than inherited.
  #
  # Six of the seven units carry [Install] WantedBy=, so the unit file alone
  # enables nothing -- exactly the treatment home/uwsm.nix gives fumon.service
  # and home/portals.nix gives xdg-desktop-portal-rewrite-launchers.service.
  # Debian's package installed root-owned symlinks under /etc/systemd/user for
  # all six; removing the package either deletes them or leaves them dangling,
  # and neither outcome should decide whether audio starts.
  #
  # .wants links from every UnitPath entry are unioned rather than shadowed,
  # so while Debian's package is still installed both sets exist and both name
  # the same unit -- which resolves to the fragment at position 5. No conflict.
  #
  # wireplumber@.service gets no link: it is the split-mode template, disabled
  # on Debian too. Installed for parity, enabled by nothing.
  wants = {
    "sockets.target.wants" = [ "pipewire.socket" "pipewire-pulse.socket" ];
    "default.target.wants" = [
      "pipewire.service"
      "pipewire-pulse.service"
      "filter-chain.service"
    ];
    "pipewire.service.wants" = [ "wireplumber.service" ];
  };

  wantLinks = lib.listToAttrs (lib.concatLists (lib.mapAttrsToList
    (dir: units: map
      (n: lib.nameValuePair "systemd/user/${dir}/${n}" {
        source = "${audioUnits}/${n}";
      })
      units)
    wants));
in
{
  # pipewire brings pw-play, pw-dump, pw-top, pw-cli and the 14 bluez5 SPA
  # plugins; wireplumber brings wpctl. Debian's pulseaudio-utils stays for
  # pactl, which Nix does not ship and which most of this migration's gate
  # speaks -- see the plan's Global Constraints for why it gets marked manual.
  #
  # As with every other package in this flake, this line alone changes nothing
  # at runtime. ~/.nix-profile/share/systemd/user is not on the user manager's
  # UnitPath at all. The xdg.configFile entries below are what switch audio.
  home.packages = [ pkgs.pipewire pkgs.wireplumber ];

  # xdg.configFile rather than home.file.".config/...": home-manager's own
  # systemd module writes user units through xdg.configFile, and sd-switch
  # follows xdg.configHome rather than a literal ".config". Identical today,
  # since xdg.configHome defaults to ~/.config, but a literal path would
  # silently stop being seen by sd-switch if xdg.configHome were ever set
  # elsewhere.
  xdg.configFile = unitFiles // wantLinks // {
    # The alias, written by hand because nothing else will write it.
    #
    # `systemctl enable wireplumber.service` would create this symlink from
    # the unit's Alias= line. This flake installs units declaratively and
    # never runs enable, so the alias would simply not exist -- and its
    # absence is silent (see guard 2 in audioUnits above).
    #
    # A symlink whose name differs from its target's basename is how systemd
    # represents an alias: it resolves the link, sees `wireplumber.service`,
    # and registers `pipewire-session-manager.service` as another name for
    # that same unit rather than as a second unit. Confirmed by hand on this
    # machine before this file was written -- `systemctl --user show
    # pipewire-session-manager.service -p Id` returned `Id=wireplumber.service`
    # -- and not assumed from how systemd documents `enable`.
    "systemd/user/pipewire-session-manager.service".source =
      "${audioUnits}/wireplumber.service";
  };
}
```

- [ ] **Step 2: Add the module to the flake**

In `flake.nix`, add `./home/audio.nix` to the `modules` list, after
`./home/portals.nix`:

```nix
          ./home/services.nix
          ./home/portals.nix
          ./home/audio.nix
          ./home/uwsm.nix
```

- [ ] **Step 3: Update the `no-dangling-home-files` comment**

The comment above `checks.${system}.no-dangling-home-files` in `flake.nix`
names the files it covers. Change:

```
      # Every xdg.configFile/xdg.dataFile ".source" in home/portals.nix and
      # home/uwsm.nix is a bare string pointing into a package output --
```

to:

```
      # Every xdg.configFile/xdg.dataFile ".source" in home/portals.nix,
      # home/audio.nix and home/uwsm.nix is a bare string pointing into a
      # package output --
```

The check itself already walks the whole generation and needs no change; only
the comment enumerates, and an enumeration that goes stale is this project's
signature defect.

- [ ] **Step 4: Build**

```bash
sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage'
```

Expected: one store path. Record it as `$NEW`.

- [ ] **Step 5: Prove guard 2 can fail**

Temporarily break the alias assertion — change the pattern it greps for so it
cannot match. `grep -cxF '` occurs exactly once in the file, which is what
makes this substitution unambiguous:

```bash
grep -c "grep -cxF '" home/audio.nix
sed -i "s/grep -cxF 'Alias=/grep -cxF 'XAlias=/" home/audio.nix
sg nix-users -c 'nix build --no-link .#homeConfigurations."isutton@suffer".activationPackage' 2>&1 | tail -8
```

Expected: `1` occurrence, then the build **fails**, printing
`wireplumber.service no longer declares`.

Then restore it:

```bash
sed -i "s/grep -cxF 'XAlias=/grep -cxF 'Alias=/" home/audio.nix
grep -c "XAlias" home/audio.nix
sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage'
```

Expected: `0` matches remaining, and the same `$NEW` path as Step 4. The path
matching is the restore's proof — a build that merely succeeds could be
succeeding on a different tree.

Three checks in spec 6 passed while the property they stood for was false.
A guard that has never been seen to fail is a comment.

- [ ] **Step 6: Prove guard 1 (the unit-set cross-check) can fail**

```bash
sed -i 's/    "pipewire.socket"$/    "pipewire.socket"\n    "not-a-real.service"/' home/audio.nix
sg nix-users -c 'nix build --no-link .#homeConfigurations."isutton@suffer".activationPackage' 2>&1 | tail -8
```

Expected: the build **fails**, printing `pipewire's unit set has changed.`
and `removed: not-a-real.service`.

Then restore:

```bash
sed -i '/"not-a-real.service"/d' home/audio.nix
grep -c 'not-a-real' home/audio.nix
sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage'
```

Expected: `0`, and the same `$NEW` path as Step 4.

- [ ] **Step 7: Read what actually landed**

```bash
NEW=<path from Step 4>
U="$NEW/home-files/.config/systemd/user"

echo "=== unit files installed (expect 7)"
find "$U" -maxdepth 1 \( -name '*.service' -o -name '*.socket' \) \
  | grep -E 'pipewire|wireplumber|filter-chain' \
  | grep -v 'pipewire-session-manager' | sort
find "$U" -maxdepth 1 \( -name '*.service' -o -name '*.socket' \) \
  | grep -E 'pipewire|wireplumber|filter-chain' \
  | grep -vc 'pipewire-session-manager'

echo "=== enablement artifacts: 6 wants links"
find "$U" -mindepth 2 -path '*.wants/*' \
  | grep -E 'pipewire|wireplumber|filter-chain' | sort
find "$U" -mindepth 2 -path '*.wants/*' \
  | grep -cE 'pipewire|wireplumber|filter-chain'

echo "=== enablement artifacts: the 7th, the alias"
ls -l "$U/pipewire-session-manager.service"

echo "=== every Exec directive"
grep -hE '^Exec[A-Za-z]*=' "$U"/{pipewire,pipewire-pulse,filter-chain,wireplumber}.service \
                           "$U/wireplumber@.service"

echo "=== the alias resolves to wireplumber's unit"
readlink -f "$U/pipewire-session-manager.service"
basename "$(readlink -f "$U/pipewire-session-manager.service")"

echo "=== the dependency the alias exists for"
grep -E '^(Wants|After|BindsTo)=' "$U/pipewire-pulse.service" "$U/filter-chain.service"

echo "=== no Debian path anywhere in the seven"
grep -l '/usr/' "$U"/{pipewire,pipewire-pulse,filter-chain,wireplumber,wireplumber@}.service \
                "$U"/{pipewire,pipewire-pulse}.socket 2>/dev/null | wc -l
```

Expected:

- `7` unit files, then `6` `.wants` links plus the alias — seven enablement
  artifacts. Both counted from the filesystem, not from this document. The
  alias is excluded from the unit-file count because it sits in the same
  directory as the seven and would otherwise read `8`; it is an eighth *file*
  but not an eighth unit, which is the whole point of it.
- Five `ExecStart=` lines, every one an absolute `/nix/store/…` path;
  `filter-chain.service`'s ends `-c filter-chain.conf`.
- The alias resolving to a file whose basename is `wireplumber.service`. This
  is the property systemd uses to decide it is an alias rather than a second
  unit.
- `pipewire-pulse.service` showing
  `Wants=pipewire.service pipewire-session-manager.service` and
  `BindsTo=pipewire.service`; `filter-chain.service` showing
  `After=pipewire.service pipewire-session-manager.service`.
- `0` files containing `/usr/`.

- [ ] **Step 8: Run the flake check**

```bash
sg nix-users -c 'nix flake check'
```

Expected: no output and exit 0. `no-dangling-home-files` walks the built
generation with `find -L … -type l`, which prints only symlinks whose target
does not exist. Home Manager's file builder uses a bare `ln -s` with no
existence test, so a `.source` pointing at a path that is not there builds
fine and switches cleanly — this check is the only thing that catches it, and
this task adds fourteen new `.source` strings.

- [ ] **Step 9: Commit**

```bash
git add home/audio.nix flake.nix
git commit -m "audio: describe the stack in home/audio.nix, without switching

Seven units from two packages, six .wants links and one alias, at
~/.config/systemd/user -- UnitPath position 5 against Debian's
/usr/lib/systemd/user at 15. Nothing switches here; the deliverable is a
built generation whose contents were read.

Three build-time guards, each proven to fail by mutation before being
trusted. The unit sets are cross-checked against a written list, so an
upstream unit appearing or disappearing is a build error rather than a
unit that quietly stops existing. Every Exec directive must be absolute,
enumerated by syntax rather than by a list of directive names -- that
list is what missed ExecStart=fumon. And wireplumber.service must still
declare Alias=pipewire-session-manager.service, because this module
hardcodes that name in a symlink it writes by hand.

The alias is the part with no precedent here. Nix's pipewire-pulse and
filter-chain depend on pipewire-session-manager.service, a name that
exists only through wireplumber's Alias= and only once something writes
the link. systemctl enable would; declarative installation does not. And
Wants= on a unit that does not exist is not an error -- the dependency
and its ordering are dropped, audio starts anyway, and --state=failed
stays empty."
```

---

## Task 3: The switch, the reboot, and the gate

Spec Phase 1's switching half plus Phase 2. This is where audio changes hands.

**Files:**
- Modify: `docs/2026-08-16-results-suffer-audio-stack.md` — append Phases 1–2

**Interfaces:**
- Consumes: `$NEW` from Task 2, and Task 1 Step 2's recorded baseline.
- Produces: a running Nix audio stack, and the gate output Task 4 re-runs from cold.

- [ ] **Step 1: Read what sd-switch intends**

```bash
OLD=$(readlink -f ~/.local/state/nix/profiles/home-manager)
NEW=<path from Task 2 Step 4>
SDSW=$(grep -oE '/nix/store/[a-z0-9]+-sd-switch-[0-9.]+/bin/sd-switch' "$OLD/activate" | head -1)
echo "sd-switch: $SDSW"
"$SDSW" --dry-run --verbose \
  --old-units "$OLD/home-files/.config/systemd/user" \
  --new-units "$NEW/home-files/.config/systemd/user"
```

`sd-switch` is extracted from the live activation script, **not** from
`nixpkgs#sd-switch` — the registry and the pinned input give different
versions, and dry-running with a different binary than the switch will use is
worthless.

Expected: the audio units appear in start/restart lists. The compositor unit
`wayland-wm@hyprland\x2dnixgl.desktop.service` must **not** appear in any stop
list. If it does, stop and report — the switch would then need a TTY, which
this plan does not otherwise require.

Note what sd-switch says about `pipewire-session-manager.service` and record
it verbatim. It is a newly added file that systemd will resolve to an existing
unit, and this is the first time this flake has installed one.

- [ ] **Step 2: Confirm nothing else owns the alias path**

```bash
ls -l ~/.config/systemd/user/pipewire-session-manager.service 2>&1
```

Expected: `No such file or directory`. Task 1 Step 6 removed the hand-made
probe symlink. If it is still there, Home Manager will refuse to claim the
path — remove it and re-run this step.

- [ ] **Step 3: The user switches**

```bash
cd /home/isutton/Projects/calango-nix
sg nix-users -c 'home-manager switch --flake .#isutton@suffer'
```

Audio may drop out during this. That is expected and the reboot in Step 5 is
the real test; do not chase it here.

- [ ] **Step 4: Warm check, before the reboot**

```bash
echo "=== the alias resolves"
systemctl --user show pipewire-session-manager.service -p Id -p Names -p LoadState -p FragmentPath

echo "=== fragments now"
systemctl --user show pipewire.service pipewire-pulse.service \
  wireplumber.service filter-chain.service -p Id -p FragmentPath

echo "=== anything failed"
systemctl --user list-units --all --state=failed
```

Expected: `Id=wireplumber.service` for the alias, with `FragmentPath` now under
`/home/isutton/.config/systemd/user`; all four fragments under
`~/.config/systemd/user`; nothing failed.

This is a warm check and proves less than Step 6 will. `NRestarts=0` after a
cold boot is worth more than `is-active` after a warm start, and socket
activation and alias registration are both boot-path behaviour that a warm
restart does not exercise. Record it anyway — if it is already wrong here,
the reboot will not fix it.

- [ ] **Step 5: The user reboots**

```bash
sudo reboot
```

- [ ] **Step 6: Gate 1 — provenance**

```bash
systemctl --user show pipewire.service pipewire-pulse.service \
  wireplumber.service filter-chain.service \
  -p Id -p MainPID -p ActiveState -p NRestarts -p FragmentPath

for u in pipewire pipewire-pulse wireplumber filter-chain; do
  pid=$(systemctl --user show "$u.service" -p MainPID --value)
  printf '%-16s pid=%-7s exe=%s usr-maps=%s\n' "$u" "$pid" \
    "$(readlink -f /proc/$pid/exe)" \
    "$(grep -cE '/usr/(lib|bin|libexec)' /proc/$pid/maps)"
done

echo "=== sockets"
systemctl --user show pipewire.socket pipewire-pulse.socket -p Id -p ActiveState

echo "=== anything failed"
systemctl --user list-units --all --state=failed
```

Expected: four services `active`, `NRestarts=0`, all four exes under
`/nix/store`, and **`usr-maps=0` for every one** — against the non-zero counts
Task 1 Step 2 recorded. Both sockets `active`. Nothing failed.

`NRestarts=0` from cold is the load-bearing figure. A service that crashed
once and came back reads `active` too.

- [ ] **Step 7: Gate 2 — the alias, the silent-failure check**

```bash
echo "=== what pipewire-pulse depends on"
systemctl --user show pipewire-pulse.service -p Wants -p After -p BindsTo
systemctl --user show filter-chain.service -p After

echo "=== does that name resolve, and to what"
systemctl --user show pipewire-session-manager.service -p Id -p Names -p LoadState -p FragmentPath

echo "=== ordering actually took effect"
systemctl --user list-dependencies --after pipewire-pulse.service | grep -i wireplumber
```

Expected: `Wants=` listing `pipewire-session-manager.service`;
`Id=wireplumber.service` with `LoadState=loaded` and `FragmentPath` under
`~/.config/systemd/user`; and wireplumber appearing in `pipewire-pulse`'s
after-list.

This is the check the whole task hangs on. `Wants=` naming a unit that does
not exist is **not** an error — systemd drops the dependency and the ordering
with it, audio starts anyway, and `--state=failed` is empty. Task 1 Step 3
recorded this same name as `not-found`, which is what makes a `loaded` here
mean something.

Do not accept the unit file merely *mentioning* the name as evidence. The
first two commands read the unit; only the third and fourth read the manager.

- [ ] **Step 8: Gate 3 — the seven enablement artifacts, counted**

```bash
U=~/.config/systemd/user

echo "=== wants links (expect 6)"
find "$U" -mindepth 2 -path '*.wants/*' \
  | grep -E 'pipewire|wireplumber|filter-chain' | sort
find "$U" -mindepth 2 -path '*.wants/*' \
  | grep -cE 'pipewire|wireplumber|filter-chain'

echo "=== the alias (expect 1)"
ls -l "$U/pipewire-session-manager.service"

echo "=== none of them dangling (expect 0)"
find -L "$U" -type l | wc -l

echo "=== Debian's /etc links, still present for now"
find /etc/systemd/user -path '*.wants/*' \
  | grep -E 'pipewire|wireplumber|filter-chain' | sort
```

Expected: 6 links under `~/.config`, plus the alias — seven. Zero dangling.
Debian's six under `/etc/systemd/user` still there and still pointing at
`/usr/lib/systemd/user`; they disappear in Task 4.

`.wants` links from different UnitPath entries are unioned rather than
shadowed, so both sets naming the same unit is fine — the *fragment* is chosen
by search order, and position 5 wins over position 6 and 15.

- [ ] **Step 9: Gate 4 — the devices, against the baseline**

```bash
pactl list cards short
pactl list sinks short
pactl list sources short
pactl info | grep -E 'Server Name|Server Version'

echo "=== realtime scheduling survived"
pw=$(systemctl --user show pipewire.service -p MainPID --value)
for t in /proc/$pw/task/*; do
  printf '%-14s %s\n' "$(cat $t/comm)" \
    "$(chrt -p "$(basename $t)" 2>/dev/null | paste -sd';')"
done
```

Expected: the same two ALSA cards, one sink and three sources Task 1 Step 2
recorded; and a `data-loop.0` thread at scheduling priority 20 — RTKit granted
it, over the system bus, to a Nix binary.

The version to read is **`Server Name`**, which today prints
`PulseAudio (on PipeWire 1.4.2)` and must print
`PulseAudio (on PipeWire 1.6.6)` after this task. **`Server Version` is not
the PipeWire version** — it reads `15.0.0` both before and after, because it
reports the emulated PulseAudio protocol version and pipewire-pulse has always
claimed `15.0.0`. Reading it as the answer would make the gate pass identically
whichever server were running.

Then, by hand: **sound comes out of the speakers.**

- [ ] **Step 10: Gate 5 — the shell, and the Chrome mic rule**

By hand:

1. **The quickshell volume OSD and audio panel still work.** quickshell imports
   `Quickshell.Services.Pipewire` and is a real consumer of this stack — it
   reads the default sink, shows the OSD on a volume key, and its panel lists
   devices and streams. It is a Nix package built against Nix's libpipewire,
   so this is the first time client and server versions match.
2. **The Chrome capture-gain rule still applies.** Open a call in Chrome, lower
   the microphone's device volume by hand with `wpctl` or the shell panel, and
   confirm it does **not** climb back to 100% over the next few seconds.

```bash
echo "=== the drop-in is still linked and still read"
ls -l ~/.config/pipewire/pipewire-pulse.conf.d/20-block-source-volume.conf
grep -c 'block-source-volume' ~/.config/pipewire/pipewire-pulse.conf.d/20-block-source-volume.conf
grep -n 'pipewire-pulse.conf.d' \
  "$(sg nix-users -c 'nix eval --raw .#homeConfigurations."isutton@suffer".pkgs.pipewire.outPath')/share/pipewire/pipewire-pulse.conf"
```

Expected: the symlink resolving into the store, `1` matching rule, and Nix's
own `pipewire-pulse.conf` naming the same drop-in directory.

The file being present is a proxy. Chrome not walking the gain back up is the
property, and only the by-hand check tests it.

- [ ] **Step 11: Gate 6 — Bluetooth, both code paths**

```bash
echo "=== the bluez5 plugin set actually in use"
PW=$(sg nix-users -c 'nix eval --raw .#homeConfigurations."isutton@suffer".pkgs.pipewire.outPath')
ls -1 "$PW/lib/spa-0.2/bluez5/" | wc -l
pw=$(systemctl --user show pipewire.service -p MainPID --value)
grep -c 'spa-0.2/bluez5' /proc/$pw/maps

echo "=== bluetoothd is still Debian's, and still there"
systemctl show bluetooth.service -p FragmentPath -p ActiveState
```

Then, by hand, with the JBL Tune 520BT connected:

1. **Playback** — A2DP.
2. **A real call using the JBL's microphone** — HFP.

Expected: 14 plugins on disk; a non-zero count of bluez5 objects mapped into
the running pipewire *after the headset connects* — that count is `0` before
any Bluetooth device appears, because the plugins are `dlopen`ed on demand;
and `bluetooth.service` still at `/usr/lib/systemd/system/bluetooth.service`,
active. `bluez` stays on apt permanently — `bluetoothd` is a system service and
standalone Home Manager writes only user units. This plan depends on it and
does not touch it.

The two by-hand checks are separate on purpose. A2DP and HFP are different
code paths, and only the second exercises the four HFP codecs (`cvsd`, `msbc`,
`lc3-swb`, `lc3-a127`) that Debian's `libspa-0.2-bluetooth` never shipped.
`ldd` on the pipewire binary says nothing about either: the plugins are
`dlopen`ed, so linkage is clean whether they load or not.

- [ ] **Step 12: Append to the results document and commit**

Append to `docs/2026-08-16-results-suffer-audio-stack.md`:

```markdown
## Phase 1: the switch

### What sd-switch intended

<Step 1 output, verbatim>

### Warm check

<Step 4 output>

## Phase 2: the cold gate

### 1. Provenance

<Step 6 output>

### 2. The alias

<Step 7 output>

### 3. The seven enablement artifacts

<Step 8 output>

### 4. Devices and realtime scheduling

<Step 9 output, plus whether sound played>

### 5. The shell and the Chrome mic rule

<Step 10 output, plus the two by-hand results>

### 6. Bluetooth

<Step 11 output, plus the A2DP and HFP results>
```

```bash
git add docs/2026-08-16-results-suffer-audio-stack.md
git commit -m "audio: take the whole stack from Nix in one switch

Seven units at once rather than sequenced. wireplumber is pipewire's
session manager and pipewire-pulse and filter-chain are the same binary
as pipewire under different configuration, so sequencing would have
constructed pipewire 1.6.6 under wireplumber 0.5.8 -- a pairing upstream
does not test. 1.6.6 with 0.5.14 is what nixpkgs ships together.

A reboot rather than a restart: socket activation and alias registration
are both boot-path behaviour and a warm restart proves neither.

The gate's second item is the one that matters. pipewire-session-manager
.service read not-found before this work; it now resolves to
wireplumber.service with a fragment under ~/.config. Without that, both
pipewire-pulse's Wants= and filter-chain's After= would have been
silently dropped -- audio would still play, the session manager would
just no longer be sequenced ahead of the pulse shim, and nothing would
appear in --state=failed."
```

---

## Task 4: Mark two packages, remove six, gate from cold again

Spec Phase 3.

**Files:**
- Modify: `docs/2026-08-16-results-suffer-audio-stack.md` — append Phase 3

**Interfaces:**
- Consumes: a passing Task 3 gate. Do not start this task if any Task 3 gate item failed.
- Produces: six fewer apt packages, and `/usr/lib/systemd/user` with no audio unit left to cover a gap.

- [ ] **Step 1: Confirm the removal set is still exactly six, installing nothing**

```bash
apt-get -s remove pipewire pipewire-bin pipewire-pulse wireplumber \
                  libspa-0.2-bluetooth libcanberra-pulse 2>&1 | tail -20
```

Expected: `0 upgraded, 0 newly installed, 6 to remove`, and **no `Inst` line
anywhere in the output**.

`libcanberra-pulse` is in the set for one reason. It declares
`Depends: pipewire-pulse | pulseaudio`, so removing `pipewire-pulse` without it
makes apt satisfy the dependency the other way and **install PulseAudio**:

```
Inst pulseaudio (17.0+dfsg1-2+b1 …)
Inst libasound2-plugins (1.2.12-2+b1 …)
```

Two sound servers competing for the same socket would be worse than anything
this migration fixes. If an `Inst` line appears, stop — the dependency graph
has moved since the spec was measured.

- [ ] **Step 2: Read the collateral list**

```bash
apt-get -s remove pipewire pipewire-bin pipewire-pulse wireplumber \
                  libspa-0.2-bluetooth libcanberra-pulse 2>&1 \
  | sed -n '/no longer required/,/^The following packages will be REMOVED/p'
apt-mark showauto rtkit pulseaudio-utils
```

Expected: a "no longer required" list containing both `rtkit` and
`pulseaudio-utils`, and `showauto` printing both.

Nothing is removed by this — it is `apt autoremove` at some unspecified later
date that would take them, which is exactly why this matters now.

- [ ] **Step 3: The user marks the two keepers manual**

```bash
sudo apt-mark manual rtkit pulseaudio-utils
apt-mark showmanual rtkit pulseaudio-utils
apt-mark showauto rtkit pulseaudio-utils
```

Expected: `showmanual` printing both; `showauto` printing neither.

**`rtkit`** is a running *system* service owning `org.freedesktop.RealtimeKit1`
on the system bus. It is how PipeWire's `module-rt` obtains `SCHED_FIFO` for
its data loop — Task 1 Step 2 and Task 3 Step 9 both recorded a `data-loop.0`
thread at priority 20, granted by it. Standalone Home Manager writes only user
units and cannot replace a system service, so this is the same permanent apt
dependency `bluez` is. Losing it to a later `autoremove` would show up as
intermittent audio glitching with no visible cause and no failed unit.

**`pulseaudio-utils`** supplies `pactl`, which most of this plan's gate speaks.
Nix ships a rich `pw-*` toolset and no `pactl`. Losing the diagnostic
vocabulary at the moment the sound server changes is a bad trade.

- [ ] **Step 4: The user removes the six packages**

```bash
sudo apt remove pipewire pipewire-bin pipewire-pulse wireplumber \
                libspa-0.2-bluetooth libcanberra-pulse
```

- [ ] **Step 5: Confirm the removal, and that nothing arrived**

```bash
dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' \
  pipewire pipewire-bin pipewire-pulse wireplumber \
  libspa-0.2-bluetooth libcanberra-pulse rtkit pulseaudio-utils 2>&1
dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' pulseaudio 2>&1
```

Expected: the six now `rc` (removed, conffiles retained) rather than `ii`;
`rtkit` and `pulseaudio-utils` still `ii`; `pulseaudio` not installed.

`dpkg-query -W -f='${Version}'` prints a version and exits `0` for an `rc`
package, which is exactly what `apt remove` leaves — there are 120 `rc`
packages on this machine. The `${db:Status-Abbrev}` field is what distinguishes
them, and this project has been fooled by the shorter form before.

- [ ] **Step 6: Sweep the /etc symlinks dpkg leaves behind**

```bash
echo "=== audio links still under /etc"
find /etc/systemd/user -path '*.wants/*' \
  | grep -E 'pipewire|wireplumber|filter-chain' | sort
find /etc/systemd/user -path '*.wants/*' \
  | grep -cE 'pipewire|wireplumber|filter-chain'

echo "=== dangling links anywhere under /etc/systemd/user"
for f in /etc/systemd/user/*.wants/* /etc/systemd/user/*.upholds/*; do
  [ -e "$f" ] || echo "$f"
done
```

Removing a Debian package that ships a systemd *user* unit leaves a dangling
root-owned `/etc/systemd/user/*.wants` symlink: dpkg's helper creates them and
dpkg does not own them. It has happened with `fumon`, `ydotool` and
`rewrite-launchers`, and eight were already dangling before this task.

Record the count either way. If the six audio links are gone, say so; if they
dangle, add them to the list — they are inert (position 6 pointing at a
`/usr/lib` file that no longer exists, against our live links at position 5),
so this is bookkeeping, not a fix that blocks the task. Do **not** delete them
without asking; they are root-owned and outside this flake's territory.

- [ ] **Step 7: The user reboots**

```bash
sudo reboot
```

The point of this second reboot is that there is now no Debian unit at
position 15 to cover a gap. Anything that was quietly still resolving to
Debian's copy has nowhere left to resolve.

- [ ] **Step 8: Re-run the whole Task 3 gate from cold**

Run Task 3 Steps 6, 7, 8, 9, 10 and 11 again, unchanged, and record the output
the same way. Open Task 3 and read the commands from there — they are
referenced rather than repeated on purpose. The value of this step is that the
two runs are **byte-identical**, and two copies of six command blocks would
eventually drift apart, at which point "the gate passed twice" would stop
being true.

Every expectation is the same, with two differences:

- Task 3 Step 8's last command now expects **`0`** audio links under
  `/etc/systemd/user`, where before it expected six.
- Task 3 Step 11's `bluetooth.service` check is now the only apt-owned piece
  of the audio path left, and it must still be `active`.

Plus the by-hand checks again, all four: speakers, the quickshell OSD, the
Chrome mic rule, and the JBL on both A2DP and HFP.

The repetition is the point. The Task 3 gate ran with Debian's packages still
installed; passing it then did not prove nothing was still reaching for them.

- [ ] **Step 9: Append to the results document and commit**

Append to `docs/2026-08-16-results-suffer-audio-stack.md`:

```markdown
## Phase 3: the apt removal

### The removal set, simulated

<Step 1 output>

### What would have been autoremoved

<Step 2 output>

### The two keepers, marked manual

<Step 3 output, with the reason for each>

### After the removal

<Step 5 output>

### The /etc sweep

<Step 6 output>

### The cold gate, again

<Step 8 output, all six items, plus the four by-hand results>
```

```bash
git add docs/2026-08-16-results-suffer-audio-stack.md
git commit -m "audio: remove the six Debian packages

libcanberra-pulse is in the set for a reason that is not obvious. It
declares Depends: pipewire-pulse | pulseaudio, so removing pipewire-pulse
without it makes apt satisfy the dependency the other way and install
PulseAudio -- two sound servers competing for one socket. With it, the
removal is six packages and installs nothing.

rtkit and pulseaudio-utils are marked manual first. Both appear in the
removal's 'no longer required' list, and both matter: rtkit-daemon is the
system service that grants pipewire's data loop SCHED_FIFO, and
pulseaudio-utils supplies pactl, which Nix does not ship. Neither would
have gone today -- they would have gone to some later apt autoremove,
with the glitching that follows attributed to the version bump.

Then a second reboot and the same gate, with no Debian unit left at
position 15 to cover a gap."
```

---

## Task 5: Close out

**Files:**
- Modify: `docs/2026-08-16-results-suffer-audio-stack.md` — append the endpoint
- Modify: `CLAUDE.md` — two new gotchas

**Interfaces:**
- Consumes: a passing Task 4 gate.

- [ ] **Step 1: Measure the endpoint**

```bash
echo "=== Debian user services remaining"
systemctl --user list-unit-files --state=enabled,static,linked \
  | awk 'NR>1 && NF' | wc -l
for u in $(systemctl --user list-unit-files '*.service' --no-legend | awk '{print $1}'); do
  fp=$(systemctl --user show "$u" -p FragmentPath --value)
  case "$fp" in /usr/lib/systemd/user/*) echo "$u" ;; esac
done | sort

echo "=== the audio versions now in service"
pactl info | grep -E 'Server Name'
sg nix-users -c 'nix eval --raw .#homeConfigurations."isutton@suffer".pkgs.pipewire.version'; echo
sg nix-users -c 'nix eval --raw .#homeConfigurations."isutton@suffer".pkgs.wireplumber.version'; echo

echo "=== bluez5 plugins, both sides"
PW=$(sg nix-users -c 'nix eval --raw .#homeConfigurations."isutton@suffer".pkgs.pipewire.outPath')
ls -1 "$PW/lib/spa-0.2/bluez5/" | wc -l
```

The spec's endpoint claims Debian user services drop from 14 to 10. Count them
from the filesystem and report the real number; if it is not 10, say what the
difference is rather than repeating the spec.

- [ ] **Step 2: Append the endpoint to the results document**

```markdown
## Endpoint

<Step 1 output>

- Audio entirely Nix's: pipewire <version>, wireplumber <version>, both
  sockets, the filter chain, and <n> bluez5 plugins against Debian's 9.
- Six fewer apt packages; two (rtkit, pulseaudio-utils) deliberately kept and
  marked manual.
- Debian user services: <before> to <after>.

## Defects found

<Every place this plan's expectation did not match the machine, with what the
measurement actually said. If there were none, say so explicitly.>
```

- [ ] **Step 3: Add the two new gotchas to `CLAUDE.md`**

Under **Mechanisms that are not what they look like**, add:

```markdown
**`Wants=` and `After=` on a unit that does not exist are silent.** systemd
treats a missing dependency as satisfied by absence: the dependency is dropped,
the ordering with it, and nothing appears in `--state=failed`. Nix's
`pipewire-pulse.service` and `filter-chain.service` both name
`pipewire-session-manager.service`, which exists only because
`wireplumber.service` declares `Alias=` and something writes the alias symlink.
`systemctl enable` writes it; declarative installation does not. Audio would
have started anyway, with the session manager no longer sequenced ahead of the
pulse shim. The check is `systemctl --user show <alias> -p Id` returning the
target unit's name — a unit file *mentioning* the name proves nothing.

**Removing a Debian package orphans things the replacement still needs.**
`apt-get -s remove` prints a "no longer required" list that is easy to skim
past. Removing the six audio packages orphaned `rtkit` — the *system* service
that grants PipeWire's data loop `SCHED_FIFO`, which Nix's pipewire needs just
as much as Debian's did — and `pulseaudio-utils`, which supplies `pactl`.
Neither goes at removal time; both go to some later `apt autoremove`, by which
point the glitching gets blamed on the version bump. Read that list and
`apt-mark manual` what the Nix side still uses.
```

Also add to **Standing facts about this machine**:

```markdown
- **`rtkit` cannot move to Nix,** for the same reason as `bluez`:
  `rtkit-daemon` runs from `/usr/lib/systemd/system/rtkit-daemon.service`, a
  *system* unit, and standalone Home Manager writes only
  `~/.config/systemd/user`. It is marked manual so `autoremove` cannot take it.
  `pulseaudio-utils` is marked manual too, for `pactl`.
```

- [ ] **Step 4: Commit**

```bash
git add docs/2026-08-16-results-suffer-audio-stack.md CLAUDE.md
git commit -m "audio: close out spec 9

Endpoint measured from the filesystem rather than restated from the
spec, and the two gotchas this migration paid for written into
CLAUDE.md: a missing Wants=/After= target is silent, and an apt removal
orphans packages the Nix side still needs -- rtkit above all, which is a
system service and so a permanent apt dependency in the same way bluez
is."
```

---

## Verification summary

Every gate in this plan reads one of three things, in this order of trust:

1. **A running process's own state** — `/proc/<pid>/exe`, the `/usr`
   code-mapping count, `NRestarts` after a cold boot, a thread's scheduling
   priority.
2. **The systemd manager's own resolution** — `systemctl --user show -p Id` on
   the alias, `list-dependencies --after`, `FragmentPath`. Not the unit file's
   text: a unit file naming a dependency says nothing about whether that
   dependency resolved.
3. **One thing a person does** — sound from the speakers, the shell's volume
   OSD, Chrome not walking the mic gain back up, the JBL on a call.

Checks that compared a path, a name or an exit code have eventually lied in
every spec of this project. The deeper pattern is not laziness: in each case a
real command was run and real output was read, and the error was in the
conclusion drawn afterwards, which the measurement did not support.

## Corrections

Measurement overtook parts of this plan after it was written. Left
unrewritten, as the record of what was argued at the time; see
`docs/2026-08-16-results-suffer-audio-stack.md` for the evidence.

- **The alias step (Phase 1: `systemd/user/pipewire-session-manager.service`
  via `xdg.configFile`) does not work.** `xdg.configFile`'s first hop always
  lands in `/nix/store`, and systemd decides on a symlink's immediate target;
  the plan's design would have installed a second, independent wireplumber
  unit under the alias name. The mechanism that measured true is a raw
  `ln -s` from `home.activation`. See Phase 0 in the results document.
- **Step 6's `home.packages` comment ("this line alone changes nothing at
  runtime") is false for `wireplumber`.** Adding it to `home.packages` is
  what puts Nix's Lua scripts ahead of Debian's on `XDG_DATA_DIRS`; without
  it, Nix's `wireplumber` binary ran Debian's older scripts and threw. See
  Phase 0, Attempt 1, and Phase 2, item 7, in the results document.
- **Step 4's premise ("Nix ships a rich `pw-*` toolset and no `pactl`") is
  wrong.** `pkgs.pulseaudio` at the pinned input is `17.0`, the same
  upstream release as Debian's `pulseaudio-utils`, and it ships `pactl`.
  See Phase 3b in the results document.
- **Step 11's Gate 6 checks the wrong process.** `grep -c
  'spa-0.2/bluez5' /proc/$pw/maps` against pipewire's own PID reads `0`
  whether Bluetooth works or not — pipewire never loads the bluez5 plugins,
  wireplumber does, as the device monitor. See Gate 6 in the results
  document's Phase 3 section.
