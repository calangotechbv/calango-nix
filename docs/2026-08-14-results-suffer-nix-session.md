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

## The four proofs

| Check | Command | Result |
|---|---|---|
| Qt6 draws | `pkexec true` | **failed** — see below |
| graphical-session.target | `systemctl --user is-active graphical-session.target` | `active` |
| a unit runs | `systemctl --user is-active hypridle.service` | `active` |
| portal reachable | `busctl --user list \| grep portal` | `org.freedesktop.impl.portal.desktop.hyprland`, running |
| fonts resolve | `fc-match "Adwaita Sans"` | `AdwaitaSans-Regular.ttf`, and `AdwaitaMonoNerdFont-Regular.ttf` |

`systemctl --user show-environment` carried `WAYLAND_DISPLAY=wayland-1` and an
`XDG_DATA_DIRS` beginning `/home/nixtest/.nix-profile/share`, so `uwsm` did
export a usable environment into the unit scope. That is what spec 2's four
units depend on.

### The Qt6 proof, and a third NixOS path

`hyprpolkitagent.service` is `active (running)` and its QML engine loads. It
still cannot authenticate:

```
Cannot spawn helper: Failed to execute child process
“/run/wrappers/bin/polkit-agent-helper-1” (No such file or directory)
```

`/run/wrappers/bin` is where NixOS puts setuid wrappers, exactly as
`/run/opengl-driver/lib` is where it puts the GL stack. The agent aborts
before drawing anything, which is why no dialog appeared and `pkexec` fell
back to its terminal prompt.

The path is compiled into `libpolkit-agent-1`, so no wrapper can fix it.
`pkgs/by-name/po/polkit/package.nix` binds `setuid` in a `let` block rather
than as a function argument, so `.override` cannot reach it either. `flake.nix`
now carries a `debianPolkit` overlay that re-substitutes the path to Debian's
`/usr/lib/polkit-1/polkit-agent-helper-1` (mode 4755 root) with
`--replace-fail`, so an upstream change breaks the build instead of quietly
restoring the NixOS path.

The overlay is scoped to `hyprpolkitagent`, and that detail is the whole cost
of the fix. Replacing `polkit` for the entire package set queues **41
derivations**: pipewire depends on polkit, and ffmpeg, qtmultimedia,
**qtwebengine**, gtk4, xwayland and hyprland itself all sit downstream of
that. Overriding only the agent's own inputs queues **4**, with 1.44 MiB
fetched. Everything else keeps its binary-cache hit.

Two entries are required, not one. `polkit-qt-1` is what carries
`libpolkit-agent-1.so.0` in its `NEEDED` list, so it needs the patched polkit
through `kdePackages.overrideScope`; `hyprpolkitagent` also references
polkit's store path directly. Verified after building: the agent's closure
holds exactly one polkit, the patched one, and `polkit-qt-1`'s RPATH points
at it.

Rejected alternative: a `/run/wrappers/bin` symlink kept alive by
`/etc/tmpfiles.d`. It needs no rebuild and fixes every Nix polkit client at
once, but it would have been a second root-owned file, and spec 1 section 8
makes "one file outside `$HOME`" a property worth keeping.

Debian's `polkitd` is 126 against nixpkgs' 127. Both fixes pair nixpkgs'
`libpolkit-agent-1` with Debian's helper binary, so the skew is the same
either way.

### A note on `pkexec` as the Qt6 proof

`/usr/share/polkit-1/rules.d/50-default.rules` returns `unix-group:sudo` as
the admin identity, and `sudo` holds only `isutton`. `pkexec true` is an
`auth_admin` action, so on the test account it correctly asks for `isutton`'s
password, not `nixtest`'s. That is polkit working, not a fault — but it makes
the proof weaker here than it will be on the real account.

## The repository copy

`/home/isutton` is 0700, so `nixtest` cannot clone from it. A bare clone at
`/var/tmp/calango-nix.git`, `chmod -R a+rX`, is `nixtest`'s `origin`.
Refreshed from `isutton` with `git push share base-and-session`.

`~/.config/nix/nix.conf` is per-user and had to be written again for
`nixtest`; the first command on tty2 otherwise fails with `experimental Nix
feature 'nix-command' is disabled`.
