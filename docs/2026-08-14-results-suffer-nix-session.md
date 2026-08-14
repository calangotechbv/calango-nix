# suffer: a Nix Hyprland on Debian 13

Date: 2026-08-14
Hardware: AMD Phoenix3 [1002:1900], Mesa 25.0.7 from Debian trixie.
Account: `nixtest`, on tty2.

## Does it need nixGL?

Yes. Unambiguously.

| Rung | Command | Result |
|---|---|---|
| 1 | `~/.nix-profile/bin/Hyprland` | **fails** — `CBackend::create() failed!` |
| 2 | `~/.nix-profile/bin/hyprland-nixgl` | draws |
| 3 | `uwsm start -e -D Hyprland hyprland-nixgl.desktop` | draws, `graphical-session.target` active |

The spec's section 5 asked whether `nixGL` was needed at all. It is. The
upstream wiki's claim that a Nix Hyprland "won't be able to find graphics
drivers" holds on this hardware, and the failure is not subtle.

## What the logs said

Rung 1, in full:

```
MESA-LOADER: failed to open dri: /run/opengl-driver/lib/gbm/dri_gbm.so: cannot open shared object file: No such file or directory (search paths /run/opengl-driver/lib/gbm, suffix _gbm)
terminate called after throwing an instance of 'std::runtime_error'
  what():  CBackend::create() failed!
Hyprland has crashed :(
```

`/run/opengl-driver/lib` is where NixOS puts the GL stack. It exists on no
Debian machine, so Nix's Mesa finds no DRI driver and the backend never comes
up. Run twice, the log was byte-identical apart from the crash-report
filename — a deterministic failure, not a race.

Rung 2 draws, with one caveat worth carrying forward:

```
xwayland glamor: failed to setup GBM backend, falling back to sw accel
```

The compositor gets hardware GL through `nixGLIntel`; XWayland does not, and
X11 clients in this session are software-rendered. Wayland-native clients are
unaffected, so this does not threaten quickshell in spec 2.

## The first run of this ladder was invalid

Worth recording, because the failure looked exactly like success.

Nothing puts `~/.nix-profile/bin` on `PATH`. Debian's `nix-bin` ships no
`/etc/profile.d/nix.sh`, and Home Manager's `hm-session-vars.sh` sets only
`LOCALE_ARCHIVE_2_27`. So the first pass at rung 1 ran a bare `Hyprland`,
which resolved to `/usr/bin/Hyprland` — apt's 0.55.2 from backports — and
drew perfectly, which would have been recorded as "nixGL is unnecessary".

The tell was rung 2: `hyprland-nixgl: command not found`, for a binary that
`ls ~/.nix-profile/bin/` had just listed. Same cause. Rung 3 had it too:
`uwsm` resolved to apt's `/usr/bin/uwsm`.

Every rung was re-run with absolute paths.

## Task 8's call had to change

The plan's rung 3 was `uwsm start -e -D Hyprland hyprland.desktop`, and Task 8
builds its session entry on that call. It cannot work. `uwsm` resolves a
compositor through a desktop entry, and hyprland's own `hyprland.desktop` is

```
Exec=/nix/store/…-hyprland-0.55.4/bin/start-hyprland
```

— unwrapped, so it launches exactly the build rung 1 proved crashes.

`home/session.nix` now adds `hyprland-nixgl.desktop` to the profile, with
`Exec` pointing at the wrapper, beside the stock entry rather than over it.
Rung 3 and Task 8 both name that entry.

Task 8's `Exec` also sets `XDG_DATA_DIRS` explicitly. The plan assumed
`sh -lc` would supply it via the login shell; nothing does, and without it
`uwsm` finds apt's `/usr/share/wayland-sessions` first and the "Hyprland
(Nix)" entry would have silently started Debian's compositor.

## Checking which compositor is running

`pgrep -x Hyprland` never matches. `bin/Hyprland` is a nixpkgs wrapper script
that execs `.Hyprland-wrapped` with `exec -a "$0"`, so `comm` is
`.Hyprland-wrapp` (truncated at 15) while the cmdline still reads
`…/bin/Hyprland`. Neither `-x Hyprland` nor `-f Hyprland-wrapped` finds it.

What works:

```sh
pgrep -x .Hyprland-wrapp
~/.nix-profile/bin/hyprctl version | head -3
```

## The repository copy

`/home/isutton` is 0700, so `nixtest` cannot clone from it. A bare clone at
`/var/tmp/calango-nix.git`, `chmod -R a+rX`, is `nixtest`'s `origin`.
Refreshed from `isutton` with `git push share base-and-session`.

`~/.config/nix/nix.conf` is per-user and had to be written again for
`nixtest`; the first command on tty2 otherwise fails with `experimental Nix
feature 'nix-command' is disabled`.
