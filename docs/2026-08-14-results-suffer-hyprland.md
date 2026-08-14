# suffer: the Hyprland configuration from Nix

Date: 2026-08-14
Session: Hyprland (Nix) 0.55.4, `isutton`.

## Did the Lua config load?

| Check | Command | Result |
|---|---|---|
| config manager | journal | `[cfg] Config is lua, loading lua mgr` |
| a value only `hyprland.lua` sets | `hyprctl getoption general:border_size` | `2`, set |
| bind count vs spec 1's three | `hyprctl binds \| grep -c` | **94** |
| config errors | `hyprctl configerrors` | none |
| no stale `.conf` | `ls ~/.config/hypr/hyprland.conf` | removed by Home Manager |

The spec's open question about `.lua` versus `.conf` is answered twice over.
Hyprland's own generated stub says "This config is a STUB! This should never
be generated. Use the default lua config from …", and the previous session's
journal reads `[cfg] Lua config not found, using legacy config at
…/hyprland.conf`. It looks for the Lua config first and falls back.

`--config` accepts a `.lua` path. This was verified *before* the risky logout,
by pointing the binary at the real config with a bogus `WAYLAND_DISPLAY` so it
would parse and then fail at the backend rather than touch DRM. It printed
`Config is lua, loading lua mgr` and then `CBackend::create() failed!` — the
expected no-display outcome. A logout was never needed to answer it.

## The runtime gate

Zero `command not found` in the journal after a session's real use: terminal,
screenshots, workspace switching, clipboard, panels. The sixteen packages
derived from the tree are the right sixteen.

That derivation is the one part of this port that went right first time, and
it is worth recording why. The spec refused to ship a closure table, because
the previous spec shipped one and it was missing six packages. The
implementation derived its own list, over-inclusively, and classified 84
candidates by hand. During that work it found `lf` and `sh` **only by reading
the file** — the extractor misses bare function-parameter words with no
shell-operator prefix. That is a fifth static-extraction failure mode, on top
of the four found while writing the spec.

## The state contract

| Check | Result |
|---|---|
| `monitors.lua` written on first panel use | yes, and valid Lua |
| compositor reads it back | no Lua errors |
| `workspace-layouts.lua` written by the layout switcher | yes, and valid Lua |
| compositor reads `workspace-layouts.lua` back | untested |
| `~/.config/hypr` holds only `hypridle.conf` | yes, after removing two stale duplicates |

`monitors.lua` arrived as `hl.monitor({ output = "eDP-1", … })`, which works
identically under `dofile` and `require`: `hl` is a global by the time the
config loads either way. `workspace-layouts.lua` arrived too, as
`hl.workspace_rule({ workspace = "1", layout = "scrolling" })`, and parses the
same way. The write side of the state contract is now proven for both files;
only the compositor's read-back of `workspace-layouts.lua` remains untested.

## Four defects, and only one was spec 3's own

### 1. Every `qs ipc call` bind was dead — from spec 2, not spec 3

The user reported the session menu, the layout switcher and the brightness
keys not working. One root cause for all three, and for twelve more nobody
had tried:

```
$ qs list
Could not find "default" config directory or shell.qml in any valid config path.
```

quickshell is launched with `-p <store path>`, so there is no "default"
config, and `qs ipc call` — which defaults to it — misses every time. All
nineteen IPC targets were unreachable.

**This had been broken since spec 2 merged.** Nothing exercised those calls
until spec 3 wired up the binds that use them. Spec 2's verification passed
because it tested that the bar drew and that panels opened by click; it never
tested IPC. What is not exercised is not verified.

Fixed by exporting `QS_CONFIG_PATH` in the compositor wrapper — quickshell
documents it as the environment fallback for `--path`, so all fifteen call
sites work with no change to `hyprland.lua`.

It also vindicates excluding `brightnessctl` from the closure: brightness
genuinely goes through quickshell IPC, not `brightnessctl`. The static
derivation was right and the plumbing was missing.

### 2. The compositor was launched without `start-hyprland`

```
WARNING: Hyprland is being launched without start-hyprland. This is highly advised against.
```

Under apt the chain was uwsm → `hyprland.desktop` → `start-hyprland` →
Hyprland. Spec 1's wrapper dropped the inner launcher and spec 3 carried the
omission forward. This does not contradict spec 1's decision to use uwsm:
that rejected `start-hyprland` as an alternative *session manager*, but it is
a watchdog around the compositor binary and composes with uwsm — apt's own
entry used both.

`start-hyprland` also turns out to have built-in nixGL handling
(`--force-nixgl` / `--no-nixgl`). The wrapper now runs it with `--no-nixgl`
inside the existing `nixGLIntel` wrapping, keeping the GL path three specs
have verified. Letting `start-hyprland` do nixGL itself would let the flake
drop its `nixgl` input entirely; that is the tidier end state and is
deliberately not taken here.

### 3. hypridle locked with apt's hyprlock — and the fix opened two more

The defect the spec set out to fix, captured before touching anything:
`hypridle.service` has `Environment=` empty, and `command -v hyprlock` in a
user unit resolved to `/usr/bin/hyprlock`, Debian's build from
`trixie-backports`. Absolute store paths fixed it, and the journal then read
`Locking with /nix/store/…-hyprlock-0.9.5/bin/hyprlock`.

Fixing the binary exposed two things underneath it, in sequence:

```
CRIT: Config path error: Could not find config in HOME, XDG_CONFIG_HOME, XDG_CONFIG_DIRS or /etc/hypr.
CRIT: Hyprlock threw: EGL_EXT_platform_base not supported
```

The first is mine: this spec moved `hyprlock.conf` into the state directory
because the theme switcher writes it, and never asked who *reads* it.
hyprlock searches only the XDG config locations. The second is spec 1's
lesson applying to a fourth binary — a Nix GUI application cannot create a GL
context here without the wrapper — and it had only ever worked because apt's
hyprlock ran against Debian's Mesa.

**And then the lock screen locked the user out.** With config and GL both
fixed, hyprlock drew and refused every password, then crashed. The user had
to kill the session to get back in.

### 4. Nix's PAM cannot authenticate on Debian

```
Nix's unix_chkpwd:     -r-xr-xr-x  root root
Debian's unix_chkpwd:  -rwxr-sr-x  root shadow
```

Nix's libpam resolves modules against its own store path, so `pam_unix.so` is
Nix's, which verifies passwords through a helper that has no `shadow` group
bit and therefore cannot read `/etc/shadow`. On NixOS `/run/wrappers` supplies
the privileged copy. On Debian nothing does.

This is the **fourth** instance of this project's signature failure:
`/run/opengl-driver/lib`, `/run/wrappers/bin`, and now PAM's module directory.
Each is a Nix library resolving a path that exists only on NixOS.

**Current state: `lock_cmd` is reverted to `/usr/bin/hyprlock`,** with
`hyprlock.conf` restored to `~/.config/hypr` alongside the state copy. The
lock works. This blocks spec 6: removing `trixie-backports` deletes Debian's
hyprlock and leaves no working lock screen.

#### What was learned attempting the fix, so spec 6 need not rediscover it

- `-Dsecuredir=/lib/x86_64-linux-gnu/security` does **not** build. `securedir`
  governs the install location as well as the search path, and meson dies with
  `PermissionError: '/lib'`.
- Patching `libpam/meson.build`'s
  `'-DDEFAULT_MODULE_PATH="@0@/"'.format(securedir)` to a literal Debian path
  **does** build, and the compiled-in search path becomes
  `/lib/x86_64-linux-gnu/security/`.
- **It demonstrably works at runtime.** `strace` of a `pamtester` built
  against that pam shows Debian's `pam_faildelay.so`, `pam_nologin.so` and
  `pam_group.so` opening from Debian's directory.
- Nix's pam ships no `etc/pam.d`, so it does read Debian's `/etc/pam.d`.
- Unresolved: authentication still fails, and `pam_unix.so` never appears in
  the trace — `@include common-auth` in `/etc/pam.d/login` appears not to be
  followed. It could not be established whether the patch is incomplete or
  whether `pamtester` is an unfaithful proxy: it invokes PAM with a different
  `PAM_TTY` and no graphical session, and apt's hyprlock authenticates fine
  against the identical stack. Two `strace` runs disagreed, so the harness is
  itself suspect.

Spec 6 should test with real hyprlock on the `nixtest` account from a spare
VT, where a lockout costs nothing. That is the reason not to delete that
account yet.

## What this cost

Three logouts and one killed session. Two of the three were avoidable: the
`QS_CONFIG_PATH` and `start-hyprland` fixes each needed a fresh compositor,
and both were defects that a first login would have surfaced whenever it
happened. The killed session was not avoidable by better planning — it was
caused by fixing a defect, which exposed a second, which exposed a third.

The pattern worth naming: **each fix in the lock chain revealed the next
layer, and each layer had been hidden by the one above it.** hypridle called a
bare name, so it got Debian's binary, which had Debian's config and Debian's
Mesa and Debian's PAM. Correcting the binary correctly exposed all three
dependencies at once. Nothing was wrong with the fix; the apparent working
state had been resting on three accidents.

## Surprises

The recurring defect was named in the spec, in a section written about it,
and then committed again in the same document. Spec 2 catalogued quickshell's
writers and forgot its readers, which broke `bar.conf`. Spec 3 inherited that
and fixed it — and its own state table, listing `hyprlock.conf` as a file the
theme switcher writes, forgot to ask who reads it. Writing the lesson down
did not prevent repeating it two sections later.

What did work was refusing to write a table: the closure was derived rather
than transcribed, and it is the only enumeration in this spec that was right
first time.
