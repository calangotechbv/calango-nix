# calango-nix spec 5: removing trixie-backports

Makes Nix's hyprlock authenticate on Debian, moves the last three things apt
still provides to the session — the lock screen, the Hyprland portal and
Xwayland — onto Nix, and removes `trixie-backports`: the source, and every
package of it that can go. Finishes the migration the first four specs began.

Along the way it fixes a defect nobody was looking for: X11 clients have been
running on software rendering since spec 1.

## What the spike established

Recorded here because it is the reason this spec is writable at all. Spec 3
banked the PAM problem as characterised-but-unsolved; the characterisation was
incomplete. There are **two** independent root causes, and it found neither.

### 1. `pam_unix` calls a helper that does not exist on Debian

`nixpkgs/pkgs/by-name/li/linux-pam/package.nix:56` patches the helper path with
a comment that names the reason:

```nix
# patching unix_chkpwd is required as the nix store entry does not have the necessary bits
substituteInPlace modules/module-meson.build \
  --replace-fail "sbindir / 'unix_chkpwd'" "'/run/wrappers/bin/unix_chkpwd'"
```

`/run/wrappers` is NixOS's setuid-wrapper directory. It exists on no Debian
machine. Proven by `strace`, stock against patched, same wrong password:

```
stock:   execve("/run/wrappers/bin/unix_chkpwd", …) = -1 ENOENT
patched: execve("/usr/sbin/unix_chkpwd",        …) = 0
```

So authentication could never have succeeded, for any password. Debian's
`/usr/sbin/unix_chkpwd` is `-rwxr-sr-x root shadow` and is the correct target.

This is the **third** instance of this project's oldest failure — a Nix library
resolving a path that exists only on NixOS. `/run/opengl-driver/lib` produced
nixGL in spec 1; `/run/wrappers/bin/polkit-agent-helper-1` produced `flake.nix`'s
`debianPolkit` overlay in the same spec. This one has the same shape and takes
the same shape of fix.

### 2. `@include` is a Debian extension that Nix's libpam does not have

Upstream's parser (`libpam/pam_handlers.c:185`) handles `include` only as a
*token in the type field* — `auth include login`. A line beginning `@include` is
not upstream syntax. Debian patches it in, because `pam-auth-update` builds its
whole `common-*` scheme on it.

Confirmed three ways: absent from the upstream source; present in Debian's
`libpam.so.0` strings and absent from Nix's; and empirically — Nix's libpam
opened `/etc/pam.d/other`, a file consisting of nothing but four `@include`
lines, and attempted **zero** of them. The whole trace contains no mention of
`common-auth`.

This is what made spec 3's attempt inconclusive. `/etc/pam.d/hyprlock` is
`auth include login`, and `/etc/pam.d/login` reaches `pam_unix` only through
`@include common-auth`. Even with the helper fixed, `pam_unix` never loads.

**It does not need patching.** hyprlock exposes `auth:pam:module`, so naming a
service whose file uses a direct `pam_unix.so` line avoids the extension
entirely. `common-auth` is exactly such a file, and `hyprlock` calls only
`pam_start` and `pam_authenticate` (`src/auth/Pam.cpp:119-127`) — no
`pam_acct_mgmt`, no `pam_setcred` — so a service carrying only `auth` lines is
complete for it.

### What the spike did not prove

Every test used a deliberately wrong password, because the spike had no
credential to test with. The helper exec'ing with `= 0` is the strongest
available evidence short of the real thing, but *"a correct password is
accepted"* remains unverified and is this spec's first verification step.

## The inventory, measured

`apt-get -s remove --autoremove` over the six real packages proposes **26
removals**. Simulated, not assumed — and it surfaced three dependencies that
neither the package list nor the earlier specs would have revealed.

**Removed, and already replaced by Nix:** `hyprland`, `hypridle`,
`hyprpolkitagent`, `hyprland-guiutils` (Nix's hyprland ships
`hyprland-share-picker`), plus the hypr-specific libraries
(`libaquamarine9/10`, `libhyprcursor0`, `libhyprgraphics4`, `libhyprlang2`,
`libhyprtoolkit5`, `libhyprutils10/12`, `libhyprwire3`, `libudis86-0`,
`qml6-module-org-hyprland-style`) and their orphaned dependencies
(`libiniparser4`, `libmuparser2v5`, `libsdbus-c++2`, `libseat1`,
`libxcb-errors0`, `wayland-protocols`).

**Removed, and unused:** `hyprpaper` — the session draws wallpaper with
`swaybg`.

**Removed, and this spec must replace:** `hyprlock`,
`xdg-desktop-portal-hyprland` and `xwayland`. The first two are backports
packages currently serving the session. `xwayland` is not — it is `2:24.1.6-1`
from trixie/main and `--autoremove` takes it only because apt cannot see that
the Nix compositor spawns it — but it is replaced rather than held, because
Debian's is currently giving X11 clients software rendering. Decision 4.

**Removed, and correct to remove:** `calango-desktop-deps`, the old
repository's dependency metapackage. Nothing in calango-nix references it.

### The load-bearing file the removal exposes

`dpkg -S` puts **both** `/usr/share/wayland-sessions/hyprland.desktop` and
`/usr/share/wayland-sessions/hyprland-uwsm.desktop` in apt's `hyprland`
package, so the removal in section 4 deletes them. greetd's greeter is
launched as:

```
tuigreet --sessions /usr/share/wayland-sessions:/usr/local/share/wayland-sessions ...
```

— those two directories and nothing else. So after the removal the **only**
session entry on the machine is:

```
/usr/local/share/wayland-sessions/hyprland-nix.desktop
```

It is root-owned, **not apt-managed** (`dpkg -S` finds no owner), and was
created by hand during spec 1. Its `Exec` runs
`$HOME/.nix-profile/bin/uwsm start -e -D Hyprland hyprland-nixgl.desktop`.

This makes it load-bearing in a way nothing has written down: if that file
were ever missing, or its `Exec` broken, the reboot in the verification
section would reach a greeter with **no session to launch** — on a machine
whose only fallback lock screen has just been removed. It is not covered by
any Nix module (`home/session.nix` builds `hyprland-nixgl.desktop` into
`~/.nix-profile/share/wayland-sessions`, which greetd does not read), so a
Home Manager rollback would not restore it either. Its existence is checked
before the removal, not after.

**NOT removed, and this is the important part. There are six survivors, not
three.** Measured by subtracting the simulation's 26 removals from
`apt list --installed | grep backports`:

```
libcpptrace1  libxkbcommon0  libxkbcommon-x11-0  quickshell  uwsm  ydotool
```

They survive for two different reasons, and the difference matters:

- `libxkbcommon0`, `libxkbcommon-x11-0` and `libcpptrace1` are
  reverse-dependencies of `google-chrome-stable`, `deskflow` and `code`, so
  `--autoremove` cannot take them.
- `quickshell`, `uwsm` and `ydotool` are marked **manual**, so `--autoremove`
  leaves them regardless of whether anything needs them. `quickshell` and
  `uwsm` are shadowed by Nix copies on `~/.nix-profile/bin`, so apt's are
  inert. **`ydotool` is not** — there is no Nix `ydotool` in this
  configuration; `home/default.nix` defers it to spec 3 as `dev` tier and
  nothing at runtime invokes it. It stays as an apt package with no Nix
  counterpart, and it is the one survivor that is neither frozen-for-a-
  dependant nor shadowed. Removing it is out of scope here; recorded so a
  later spec does not rediscover it.

Removing the *source* does not downgrade anything — packages stay at the
version already installed. So "nothing from backports remains on the machine"
is not achievable without downgrading shared libraries that three unrelated
applications link against. This spec does not attempt it; see Non-goals.

**A live dependency on Debian's `uwsm`, which five specs have not surfaced.**
The running session contains:

```
/usr/bin/python3 /usr/bin/uwsm aux waitpid 65275
```

That is **Debian's** uwsm, executing right now, even though the session was
launched through `$HOME/.nix-profile/bin/uwsm` (see
`/usr/local/share/wayland-sessions/hyprland-nix.desktop`) and PID 65275 it is
waiting on is Nix's `libexec/uwsm/signal-handler.sh`. Traced to its cause:

| unit | `FragmentPath` |
|---|---|
| `wayland-session-bindpid@65275.service` | `/usr/lib/systemd/user/wayland-session-bindpid@.service` |
| `wayland-wm@hyprland-nixgl.desktop.service` | `/usr/lib/systemd/user/wayland-wm@.service` |
| `wayland-wm-env@hyprland-nixgl.desktop.service` | `/usr/lib/systemd/user/wayland-wm-env@.service` |
| `wayland-session@hyprland-nixgl.desktop.target` | `/usr/lib/systemd/user/wayland-session@.target` |
| `wayland-session-envelope@hyprland-nixgl.desktop.target` | `/usr/lib/systemd/user/wayland-session-envelope@.target` |

`dpkg -S` puts every one of those in apt's `uwsm` package. **The entire uwsm
session scaffolding is Debian's, not Nix's.** Nix's `uwsm-0.26.4` does ship
the same templates in `share/systemd/user/`, and
`~/.nix-profile/share/systemd/user` does exist — but it is **not** on
`systemctl --user show -p UnitPath`, so systemd never looks there. Nix's uwsm
asks for a unit by name and Debian's template is what answers.

Most of those templates then re-resolve to Nix at runtime, because they name
`uwsm` by bare word and `~/.nix-profile/bin` is first on the session PATH —
`wayland-wm@.service`'s live `ExecStart` is the `/nix/store/...-uwsm-0.26.4`
binary. `wayland-session-bindpid@.service` is the exception: its `ExecStart`
hardcodes `/usr/bin/uwsm` inside a `sh -c` fallback, which is the process
above. And that unit carries `OnSuccess=wayland-session-shutdown.target`, so
it is not incidental — it is what binds the session's lifetime to the
compositor.

Nothing in this spec removes apt's `uwsm`: it is marked manual, so
`--autoremove` leaves it, and the session is therefore safe. That is luck
rather than design. The recorded assumption that "the Nix copy shadows apt's,
therefore apt's is inert" is **false for `uwsm`**, and any future spec that
proposes removing it must first move these templates onto a directory systemd
actually searches. Recorded here so that spec starts from the measurement.

## Decisions

1. **Fix the helper with a scoped overlay, not a module-path patch.** A
   `debianPam` overlay rewriting `/run/wrappers/bin/unix_chkpwd` to
   `/usr/sbin/unix_chkpwd`, placed beside `debianPolkit` in `flake.nix` and
   scoped to hyprlock's closure. Measured cost: **2 derivations**. Scoping is
   not optional — `pam` is a dependency of systemd, and replacing it set-wide
   would rebuild a large part of the closure. `debianPolkit` cost 4 derivations
   scoped against 41 unscoped; the same discipline applies.

2. **Avoid `@include` rather than patch libpam.** Set hyprlock's
   `auth:pam:module` to `common-auth`. Patching Debian's `@include` extension
   into nixpkgs' linux-pam would be a larger, more fragile change carried
   forever, to gain a level of indirection this configuration does not need.

3. **The PAM service name goes in a store-side hyprlock config, not in
   `Theme.qml`.** A Nix-generated `hyprlock.conf` carries the static settings —
   `auth:pam:module` among them — and `source`s the theme switcher's generated
   file for the palette. `lock_cmd` points `--config` at the store file. This
   mirrors `foot.ini` exactly: static config in the store, runtime-written
   values in state, the store file including the state file. The alternative,
   adding an `auth` block to what `applyHyprlockTheme` emits, would put
   authentication config in a theme generator and would not take effect until
   the next theme switch.

4. **Xwayland comes from nixpkgs, and this fixes a live defect.** Debian's
   Xwayland is currently giving every X11 client **software rendering**.
   Measured, with identical client environments and only the server binary
   differing:

   | display | Xwayland | `glxinfo -B` |
   |---|---|---|
   | `:99` | `pkgs.xwayland` | **Accelerated: yes** -- AMD Radeon 780M, radeonsi, phoenix, ACO |
   | `:0` | Debian's, live | **Accelerated: no** -- llvmpipe (LLVM 21.1.8) |

   The cause is nixGL. Debian's Xwayland is a child of the wrapped compositor,
   so it inherits `LIBGL_DRIVERS_PATH` and `GBM_BACKENDS_PATH` pointing into
   Nix's `mesa-26.1.5`, while linking Debian's
   `/lib/x86_64-linux-gnu/libgbm.so.1`. Glamor needs a matching GBM/DRI pair, it
   gets a mismatched one, and it falls back to llvmpipe. The wrapper that makes
   Nix binaries work has been silently breaking this Debian one since spec 1.

   `pkgs.xwayland` joins `compositorPath` in `home/session.nix`, which is
   prepended, so it wins over `/usr/bin/Xwayland`. It needs **no** nixGL wrapper:
   it is a compositor child and inherits the environment already -- exactly what
   the `:99` test demonstrated, since that server was started with nothing but
   the compositor's inherited variables.

   Debian's is then allowed to go with `--autoremove` rather than being held.
   Keeping both would leave two servers where PATH order decides the winner, and
   ambiguity of precisely that kind has cost this project four defects already.

   Two earlier drafts of this decision were wrong, both in the same way. The
   first claimed Nix's Xwayland would not match the hardware -- false; nixGL
   never used Debian's Mesa, and Nix's `mesa-26.1.5` already drives this machine.
   The second conceded that and concluded the choice was free, so Debian's won on
   cost -- also false. Neither draft ran `glxinfo`. The lesson is the one this
   project keeps relearning: a claim about behaviour is worth nothing until it is
   measured, and "it should work the same either way" is a claim about behaviour.

5. **`xdg-desktop-portal-hyprland` gets a Home Manager user unit.** Nix's binary
   is already in the profile and its `.portal` file already shadows Debian's
   (`~/.nix-profile/share` is first in `XDG_DATA_DIRS`), but the unit actually
   running is `/usr/lib/systemd/user/xdg-desktop-portal-hyprland.service`, whose
   `ExecStart` is the absolute `/usr/libexec/` path. A user unit of the same
   name shadows the system one.

6. **`nixtest` is retired last, and only after the lock screen is proven.** It
   is the safe place to test authentication from a spare VT. Deleting it before
   the final verification would remove the safety net at the exact moment it is
   most needed.

7. **The backports source lines are removed from `sources.list`, not commented
   out.** A commented line is a configuration that looks disabled and is one
   edit from being live. Git history is the record.

## Non-goals

- **Downgrading `libxkbcommon0`, `libxkbcommon-x11-0` or `libcpptrace1`** to
  their trixie versions. Three applications outside this project link them, the
  installed versions keep working with the source removed, and a downgrade to
  satisfy a bookkeeping definition of "no backports packages" would risk real
  breakage for no functional gain. They stay, frozen, and this spec's results
  document names them.
- **Removing apt's `quickshell`, `uwsm` or `ydotool`**, the other three
  backports survivors. All three are marked manual, so `--autoremove` leaves
  them and this spec does not have to argue about them. `quickshell` is inert
  (Nix's wins on PATH). `uwsm` is **not** inert — it supplies every
  `wayland-session*` systemd user template the live session runs on, per the
  inventory above, so removing it needs its own spec. `ydotool` has no Nix
  counterpart at all and nothing in this configuration invokes it;
  `home/default.nix` defers it as `dev` tier. Six survivors, not three, and
  the results document should name all six.
- **Patching `@include` support into nixpkgs' linux-pam.** Decision 2.
- **Removing apt's `xdg-desktop-portal` or `xdg-desktop-portal-gtk`.** Both come
  from trixie, not backports, and the GTK portal is what serves file choosers.
- **`code`, `google-chrome-stable`, `deskflow`.** Not from backports.
- **Fingerprint authentication.** hyprlock supports it; this machine has no
  reader and the spike did not look at it.
- **Making Debian's hyprlock work as a fallback.** Once this spec lands there is
  no apt hyprlock to fall back to. The rollback is the previous Home Manager
  generation plus `apt install`, and the results document records that.

## Design

### 1. The PAM overlay

`flake.nix` gains `debianPam`, beside `debianPolkit`, in the same style and for
the same reason. It overrides `pam` and applies it to `hyprlock` only:

```nix
debianPam = final: prev:
  let patched = prev.pam.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          substituteInPlace modules/module-meson.build \
            --replace-fail "'/run/wrappers/bin/unix_chkpwd'" "'/usr/sbin/unix_chkpwd'"
        '';
      });
  in { hyprlock = prev.hyprlock.override { pam = patched; }; };
```

`--replace-fail` against nixpkgs' own substituted output means an upstream
change to that line breaks the build loudly rather than silently restoring the
NixOS path — the same guarantee `debianPolkit` relies on.

**This exact overlay was evaluated before the spec was written**, so decision 1
rests on measurement rather than on the analogy to `debianPolkit`:

| | store path |
|---|---|
| `hyprlock`, scoped overlay | `fac9jqck…-hyprlock-0.9.5` |
| `hyprlock`, the spike's proven build | `fac9jqck…-hyprlock-0.9.5` — **identical** |
| `hyprlock`, stock | `0rbd1zkz…-hyprlock-0.9.5` |
| `systemd`, scoped overlay | `krsvx5x3…-systemd-260.2` |
| `systemd`, stock | `krsvx5x3…-systemd-260.2` — **identical, not rebuilt** |

So the override yields the same binary whose helper `strace` showed exec'ing
`/usr/sbin/unix_chkpwd`, and the rest of the package set is untouched.
`hyprlock` takes `pam` as a function argument
(`pkgs/by-name/hy/hyprlock/package.nix:13`), so no `overrideAttrs` on hyprlock
itself is needed — unlike `debianPolkit`, which needed one for `polkit-qt-1`.

### 2. hyprlock's configuration and the lock chain

A Nix-generated `hyprlock.conf` in the store carrying the static settings:

```
auth {
    pam {
        module = common-auth
    }
}

source = <hyprState>/hyprlock.conf
```

`lock_cmd` in `home/hyprland.nix` returns to Nix's hyprlock, wrapped in nixGL —
spec 3 established that a Nix GUI cannot create a GL context here without it,
and hyprlock was the fourth binary to prove it:

```
lock_cmd = "${pkgs.procps}/bin/pidof hyprlock || ${hyprlock-nixgl}/bin/hyprlock --config ${hyprlockConfig}"
```

`hyprlock` returns to `home.packages`, which spec 3 removed deliberately: a
broken Nix build must not be reachable by bare name. That reason expires here.

Two things need verifying rather than assuming. First, that hyprlang's `source`
directive works in hyprlock and tolerates a missing target — the state file
exists today, but a fresh machine would not have one until the first theme
switch. Second, that `source` composes with `--config` as expected. If either
fails, decision 3's fallback is to emit the `auth` block from
`applyHyprlockTheme` and accept that it lands on the next theme change.

### 3. Xwayland and the portal

`pkgs.xwayland` joins `compositorPath` in `home/session.nix`, with a comment
recording the llvmpipe measurement — the reason is not obvious from the code and
a future reader would otherwise see a package that duplicates one apt already
provides. `compositorPath` is prepended, so Nix's wins over `/usr/bin/Xwayland`
from the moment of the next login, before apt's is removed. It needs no nixGL
wrapper: the compositor spawns it as a child, so it inherits the environment.

This is the one part of the port that can be verified *before* any apt change and
*without* a logout, by starting it on a spare display with the compositor's
inherited environment and running `glxinfo -B` against it — which is how the
defect was found.

`xdg-desktop-portal-hyprland` gets a `systemd.user.services` entry shadowing
`/usr/lib/systemd/user/`'s. Its `.portal` file is already discoverable, so no
`XDG_DATA_DIRS` work is needed.

**It does need the nixGL wrapper, and this was settled by linkage, not by
analogy.** `libexec/xdg-desktop-portal-hyprland` is a makeWrapper shim whose
only job is to prepend the package's own `bin` to `PATH` (that is how the
portal finds `hyprland-share-picker`); the real binary is
`libexec/.xdg-desktop-portal-hyprland-wrapped`, and plain `ldd` on *that* shows

```
libgbm.so.1 => /nix/store/…-mesa-libgbm-26.0.3/lib/libgbm.so.1
```

a direct, non-`dlopen` dependency — so the "`ldd` is a false negative for Qt's
`dlopen`'d plugins" caveat does not apply. Meanwhile
`systemctl --user show-environment` contains none of `GBM_BACKENDS_PATH`,
`LIBGL_DRIVERS_PATH`, `__EGL_VENDOR_LIBRARY_FILENAMES` or `LD_LIBRARY_PATH`,
so Nix's libgbm would fall back to its compiled-in `/run/opengl-driver/lib/gbm`
— the same NixOS-only path nixGL exists for, and one Debian does not have.

`ExecStart` is therefore a nixGL wrapper around the shim, in the shape
`quickshell.service` and `hyprpolkitagent` already use. Wrapping *outside* the
shim keeps the shim's `PATH` work intact and hands the share-picker the GL
environment too, since it is a child of this unit. This is not a "try it and
see" — the switch replaces the live Debian portal with this one, so there is no
later moment of controlled choice.

### 4. The apt removal

Three root actions, in this order, each run by the user:

1. `sudo apt remove --autoremove hyprland hypridle hyprlock hyprpolkitagent hyprpaper hyprland-guiutils`
2. remove the two `trixie-backports` lines from `/etc/apt/sources.list`
3. `sudo apt update`

The order matters: removing the source first would leave apt unable to resolve
the packages it is about to remove.

A `--dry-run` of step 1 immediately beforehand must still show the **26**
packages this spec measured, `xwayland` among them. A different set means
something has drifted since the inventory was taken — stop and re-measure rather
than proceeding.

**This is the irreversible step and the one with no undo inside Nix.** It must
come *after* the lock screen, Xwayland and the portal are all verified working
from Nix, not before. A `--dry-run` of step 1 immediately beforehand, compared
against the 26 packages this spec measured, is the check that nothing has drifted.

### 5. Retiring `nixtest`

Only after section 4 is verified. `sudo userdel -r nixtest`, and
`"nixtest@suffer"` comes out of `flake.nix`'s `homeConfigurations`. Its Home
Manager generations and Nix profile go with the home directory; the store paths
they reference become garbage-collectable but are not collected here.

### 6. Verification

The order is the point: each step must pass before the irreversible one.

**Before touching apt**, with apt's hyprlock still installed as a fallback:

- `pamtester common-auth <user> authenticate` with the **correct** password,
  against the patched pam, exits 0. This is the spike's missing evidence and
  the gate for everything else.
- Nix's hyprlock locks and **unlocks** — run from a spare VT as `nixtest`, so a
  failure costs a VT switch rather than a killed session. Spec 3's lockout
  happened because this test was run on the live session.
- `Xwayland` on the compositor's PATH resolves to the Nix build, and
  `glxinfo -B` against the live display reports **Accelerated: yes** with the
  radeonsi renderer rather than llvmpipe. This is a fix, not just a swap, so it
  has a before value to beat.
- The Nix portal unit is active and a portal-mediated action works — opening a
  link through the browser picker exercises it end to end.

**After the apt removal:**

- `hyprctl version` is the Nix build; nothing under `/usr/bin` shadows it.
- The lock screen still unlocks — the fallback is gone now, so this is the
  moment the earlier test pays for itself.
- X11 clients, screen sharing and the browser picker all still work.
- `apt list --installed | grep backports` lists exactly the **six** survivors
  named in the inventory — `libcpptrace1`, `libxkbcommon0`,
  `libxkbcommon-x11-0`, `quickshell`, `uwsm`, `ydotool` — and nothing else.
- `/usr/local/share/wayland-sessions/hyprland-nix.desktop` still exists. It is
  now the only session entry greetd can see, and the reboot below depends on
  it. This is checked *before* the removal too, since afterwards there is
  nothing to restore it from.
- Zero failed units and no `command not found` in the journal after real use.

**After a reboot**, because the last four specs each found something only a cold
boot showed: greetd reaches the session, all units self-start, the lock screen
works from a fresh login.

## Open items

- **`hyprpaper` is being removed as unused.** Verified only by knowing the
  session uses `swaybg`. If something references it, the removal surfaces it.
- **All six surviving backports packages** receive no further updates once the
  source is gone — the three frozen libraries and `quickshell`, `uwsm`,
  `ydotool` alike. Worth a note in the results document so a future security
  update is not a surprise.
- **`ydotool` is a survivor with no Nix counterpart and no known consumer.** It
  is out of scope here. Either give it a Nix build or remove it; leaving an
  unowned backports package is the state this project has been trying to leave.
- ~~**`xdg-desktop-portal-hyprland` and nixGL** is unresolved until tested.~~
  **Resolved before the switch**, by a linkage check rather than by running it:
  the real binary links `libgbm.so.1` directly and the user manager's
  environment carries none of the driver variables. See section 3. It is
  wrapped. Screen sharing still wants exercising, but as a functional check,
  not as the thing that decides the wrapper.
- **`/etc/pam.d/hyprlock` remains on the machine**, now unused, since hyprlock
  is told to use `common-auth` instead. Harmless, and removing a root-owned file
  to tidy up is not worth a root action.

- **nixGL may be removable entirely, and that deserves its own spec.** Working
  out decision 4 surfaced it. nixGL exists because Nix's Mesa has
  `/run/opengl-driver/lib` compiled in as its driver search path and that
  directory exists only on NixOS. The project's answer so far has been a
  per-consumer wrapper, one per binary that does not inherit the environment —
  four so far (`hyprland-nixgl`, `quickshell-nixgl`, `hyprpolkitagent-nixgl`,
  and hyprlock's, added by this spec).

  Creating `/run/opengl-driver` as a symlink to Nix's Mesa would satisfy the
  compiled-in path directly and make every wrapper unnecessary, including for
  systemd units, which are precisely the cases the inheritance trick does not
  cover. It would also let the flake drop its `nixgl` input — which spec 3
  already noted as "the tidier end state" when it found `start-hyprland`'s
  `--force-nixgl`, and deliberately did not take.

  Explicitly **not** in this spec's scope: it is GL plumbing, not backports
  removal, it introduces a new root-owned path on a machine where this project
  has worked hard to keep root's surface small, and it wants its own
  verification. Recorded here so the next spec starts from the observation
  rather than rediscovering it.
