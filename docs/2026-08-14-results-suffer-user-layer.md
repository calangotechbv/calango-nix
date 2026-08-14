# suffer: the rest of the user layer, from Nix

Date: 2026-08-14
Session: Hyprland (Nix) 0.55.4, `isutton`. Two `home-manager switch` runs, no logout yet.

## What landed

Sixteen links and four non-link install actions, enumerated from `install.sh`'s
`LINK_SRC`/`LINK_DST` arrays rather than from the file tree. After this, apt owns
nothing in the user's home.

| Check | Result |
|---|---|
| `~/.config/{foot,lf}` resolve into the store | yes |
| `~/.config/autostart` entry count | **7** — the user's five, untouched, plus our two |
| pipewire drop-in placed without replacing the directory | yes |
| both `.desktop` entries in `~/.local/share/applications` | yes |
| default browser | `eu.calangotech.CalangoOpen.desktop` |
| units loaded and active | all six |
| failed units | none |
| `command not found` in the journal | none |

The two version jumps were pre-cleared before the switch rather than discovered
at it: foot 1.21 → 1.27 accepts the config (`--check-config` exit 0, with 22
`[colors]` deprecation warnings that have no clean fix — `[colors-dark]` is fatal
on 1.21, which the other host may still run), and lf 34 → 41 loads the lfrc with
no diagnostics.

## The state contract, proven end to end

`~/.local/state/foot/theme-colors.ini` is 361 bytes of real palette, written by
`Theme.qml` and accepted by `foot --check-config`. This is the one thing no build
could have verified: the writer is QML naming a path from `HOME`, the reader is a
`foot.ini` `include=` baked at build time, and nothing cross-checks them. A
mismatch would have been silent — the palette written, foot reading a different
file, the colours simply never changing.

`Paths.footStateDir` deliberately ignores `XDG_STATE_HOME`, for the same reason
`hyprStateDir` does: foot's reader path is fixed at build time and cannot consult
an environment variable.

## Four defects the whole-branch review found, and one the live session found

Nine task-scoped reviews passed clean. The four below were only visible from a
whole-branch view, and the fifth only from a running desktop.

### 1. GTK's dark/light handoff had been writing into a void since spec 2

Nix's `glib` ships no dconf GIO module, so it silently fell back to
`GKeyfileSettingsBackend` and wrote `~/.config/glib-2.0/settings/keyfile` — which
xdg-desktop-portal, libadwaita and every Debian GTK application do not read. The
stores had already diverged in practice: `cursor-theme` read `'Adwaita'` through
Nix and `'default'` through Debian.

This predates spec 4. `home/quickshell.nix` puts the same Nix `glib` on the
theme switcher's PATH, so quickshell's `gsettings set color-scheme` — the
dark/light handoff `gtk/appearance.conf` deliberately delegates to it — went to
the dead backend too.

Fixed with `GIO_EXTRA_MODULES=${pkgs.dconf.lib}/lib/gio/modules` on both the
`apply-gtk-theme` wrapper and `quickshell.service`. Verified after the switch:
dconf now holds `color-scheme='prefer-dark'` and `cursor-theme='Adwaita'`, both
GTK ini files agree, and `apply-gtk-theme --check` reports `ok gtk3`, `ok gtk4`,
`libadwaita dark=True` and exits 0 — where before the switch it exited 1 with
`FAIL … cursor=default`.

**This one was mine to have caught and I recorded the opposite.** During
execution I spot-checked two gsettings keys through both binaries, saw them
agree, and ruled the spec's open item closed. They agreed by coincidence: those
two keys already held identical values in both stores. A correct measurement
carrying an untested causal story.

### 2. Every activation hook ran before the files it acted on existed

`writeBoundary` only marks "safe to write". `linkGeneration` — which creates the
`.desktop` entries — is also `entryAfter [ "writeBoundary" ]` and sorted *last*.
So `xdg-settings set` failed its `desktop_file_to_binary` lookup and left the
stale root-owned `KBrowserSelector` holding http/https, and
`update-desktop-database` rebuilt a `mimeinfo.cache` omitting CalangoOpen. Both
silently; both self-healing on a second switch nobody would know to run.

Fixed by moving `desktopDatabase` to `entryAfter [ "linkGeneration" ]`. The
switch confirmed the new order: `linkGeneration` at line 270, `desktopDatabase`
at 302, `defaultBrowser` at 308 — and the browser default took.

### 3. Home Manager's `activate` replaces PATH rather than inheriting it

`home/gtk.nix` excluded `pkgs.systemd` on the reasoning that Debian's `systemctl`
would be found on the inherited PATH. The activation script exports a PATH of
nine store directories and nix-env's — no `/usr/bin`. So `apply-gtk-theme`'s
`systemctl --user set-environment XCURSOR_THEME=…` never resolved and was
swallowed by its own `|| true`.

`home/quickshell.nix` had already answered the same question the opposite way,
correctly, in the same repository.

### 4. Thirty-plus comments describing a mechanism this repository does not have

Task 1 copied nine trees verbatim; later tasks edited only what substitution
forced; no task was ever allocated to reconcile the carried prose. The sharpest
instance: `data/code.desktop` argued `Exec` must be a bare name because
`uwsm/env` guarantees `~/.local/bin` on PATH, while `uwsm/env` in the same commit
range said its PATH block was deleted *because* the entries carry store paths.

Swept under one rule: nothing in a forked file may name `install.sh`, `make gtk`
or `~/.local/bin` as a live mechanism.

### 5. The shims were unreachable — found only by checking a live session

`~/.nix-profile/bin` is on no PATH on this machine. Not the login shell's, not
the compositor's, not the systemd user manager's. There is no
`/etc/profile.d/nix.sh` here and nothing sources `hm-session-vars.sh`. Measured
in the running session:

```
foot, lf, qs      -> the Nix builds      (via compositorPath)
code              -> /usr/bin/code       no --use-angle=vulkan
calango-open      -> not found
apply-gtk-theme   -> not found
```

A regression against calango-desktop, where `install.sh` put the same three
shims in `~/.local/bin` — which *is* on PATH, at position 2, via Debian's
`~/.profile`. `code` typed in a terminal used to get the ANGLE-flagged shim.

Spec decisions 5 and 6 both assumed the profile's bin directory was on PATH.
Task 7's deletion of `uwsm/env`'s PATH block was not wrong — nothing needed
`~/.local/bin` any more — but the replacement was never made. The job moved; it
did not disappear.

Fixed by restoring `uwsm/env`'s PATH block against `~/.nix-profile/bin`. Takes
effect at the next login.

## What went right, and it is worth naming

**Nine tasks, zero fix rounds.** No task review found a Critical or Important
issue. Every closure, path, unit and state contract was re-derived by a second
agent and none was wrong.

**Implementers overrode the controller four times, and were right four times:**
`bsdtar` from `libarchive` rather than `tar` from `gnutar` (the controller's
match was on the MIME type `application/x-tar`); five packages missing from the
GTK closure including `cmp` from `diffutils`; `coreutils` unnecessary for
`calango-open` because `printf` is a bash builtin under its shebang; and
`pkgs.glib.out` rather than `pkgs.glib`, whose `bin` output has no
`lib/girepository-1.0` at all.

That last one is the pattern in miniature. The controller ran a real probe,
got a real pass, and then wrote down *why* it passed without testing the
mechanism — the imports had succeeded because glib ≥2.80 resolves its own
typelibs internally, not because the path named was correct.

## The recurring defect, counted honestly

This project's signature failure is enumerating something by matching one
syntactic form of it. It appeared **eight times** in this spec. Four were the
controller's, all from the same extractor matching text that was not a command
invocation:

| Where | Matched | Was actually |
|---|---|---|
| night-light's closure | `systemctl`, `touch` | words inside comments |
| Task 4's edit sites | "the call site" | three call sites |
| lf's closure | `tar` | the MIME type `application/x-tar` |
| lf's closure | `file` ×18 | the shell variable `$file` |

And the inverse, once: a tightened verification regex reported no `rm` in
`apply-gtk-theme`, when `rm` is genuinely there at `:296` inside
`trap 'rm -rf "$tmpdir"' EXIT`. A loose pattern invents commands; a tight one
hides them. Both are answered only by reading the file.

**What changed this spec is where the defect landed.** In earlier specs it
reached the shipped closure — spec 2's table was missing six packages. Here it
never did: every one was caught, because cross-checks were handed to
implementers labelled *compare against, do not copy*, and because the plan
required deriving rather than transcribing. What it reached instead was the
prose. Three deferred Minors were all inaccurate comments attached to correct
code, and in `home/gtk.nix` the comments were the only record of two design
decisions — both of which were false, and are defects 1 and 3 above.

Prose was not the layer where nothing was at stake. It was the layer where this
branch's unverified assumptions were parked, because nobody re-derives a
sentence.

## Still open

- **Two comment defects, parked and known.** `lf/lfrc:1-2` says lf is launched as
  `kitty --class lf -e lf`; `hyprland.lua:107` sets `foot --app-id lf lf`.
  `lf/colors:14` references `kitty/theme-colors.conf`, a file this branch
  deleted. Comment-only, no behavioural effect.
- **foot's 22 deprecation warnings per start.** `[colors]` is deprecated in 1.27
  and `[colors-dark]` is fatal in 1.21. No spelling is clean on both, and the
  other host may still be on 1.21.
- **An upstream evaluation warning** — `'system' has been renamed to
  'stdenv.hostPlatform.system'` — comes from `nixgl/flake.nix:36`, not this
  repository.
- **Everything requiring a logout.** See below.

## Not yet verified — needs one logout

Four things only a fresh `graphical-session.target` can show, and they are the
whole of Task 11:

- `ibus-daemon` should stop. It is still running (7 processes) because the
  `Hidden=true` stub and `uwsm/env`'s `unset GTK_IM_MODULE QT_IM_MODULE` only
  take effect at session start. Both variables are still exported today.
- The `~/.nix-profile/bin` PATH fix takes effect at the same moment.
- The three new units should start themselves from
  `graphical-session.target.wants` rather than from `sd-switch`.
- The pipewire quirk applies only to a fresh `pipewire-pulse`.

## What the next spec inherits

Removing `trixie-backports` is **still blocked** on Nix's hyprlock failing PAM
authentication against Debian's `/etc/shadow`, unchanged from
`docs/2026-08-14-results-suffer-hyprland.md`. **Keep the `nixtest` account** —
testing a lock screen from a spare VT is how that gets solved without another
lockout.

This spec makes `bluez-tools`, `gammastep` and `lf` removable from apt.
`code` stays (Microsoft's repository, not backports) and `hyprlock` stays until
PAM is solved.
