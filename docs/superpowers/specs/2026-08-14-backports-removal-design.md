# calango-nix spec 5: removing trixie-backports

Makes Nix's hyprlock authenticate on Debian, moves the last two things apt still
provides to the session — the lock screen and the Hyprland portal — onto Nix,
and removes `trixie-backports`: the source, and every package of it that can go.
Finishes the migration the first four specs began.

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

**Removed, and this spec must replace:** `hyprlock` and
`xdg-desktop-portal-hyprland` — both from backports, both currently serving the
session. See Design.

**Removed, and must be PROTECTED rather than replaced:** `xwayland`. It is
`2:24.1.6-1` from trixie/main, not a backports package at all; `--autoremove`
takes it only because apt cannot see that the Nix compositor spawns it. One
`apt-mark manual` keeps it. Decision 4.

**Removed, and correct to remove:** `calango-desktop-deps`, the old
repository's dependency metapackage. Nothing in calango-nix references it.

**NOT removed, and this is the important part.** `libxkbcommon0`,
`libxkbcommon-x11-0` and `libcpptrace1` came from backports but are
reverse-dependencies of `google-chrome-stable`, `deskflow` and `code`. apt
leaves them installed, and removing the *source* does not downgrade anything —
packages stay at the version already installed. So "nothing from backports
remains on the machine" is not achievable without downgrading shared libraries
that three unrelated applications link against. This spec does not attempt it;
see Non-goals.

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

4. **Xwayland stays Debian's, and is protected from `--autoremove` rather than
   replaced.** It appears in the removal list, but `apt policy` shows
   `2:24.1.6-1` from **trixie/main at priority 500** — it is not a backports
   package. It is swept up only because `--autoremove` sees it orphaned once
   apt's hyprland goes; the Nix Hyprland that spawns it is invisible to apt.
   `sudo apt-mark manual xwayland` before the removal is the whole fix.

   **Nix's `xwayland` would also work**, and an earlier draft of this decision
   said otherwise on a false premise. It claimed Debian's Xwayland uses "the
   system Mesa that matches the system GPU drivers" and Nix's would not.
   Measured, that is wrong twice over. nixGL does not use Debian's Mesa at all:
   it exports `LIBGL_DRIVERS_PATH`, `GBM_BACKENDS_PATH` and `LD_LIBRARY_PATH`
   pointing at Nix's `mesa-26.1.5`, which is what drives this machine's AMD
   Phoenix3 today. And those variables are inherited, so Debian's Xwayland —
   a child of the compositor — has already loaded
   `…mesa-26.1.5/lib/dri/libdril_dri.so`. The Nix DRI driver is in use either
   way; only the `libgbm.so.1` it links differs.

   That inheritance is also why Nix's Xwayland would need no wrapper. The
   distinction that actually governs nixGL in this project is **compositor
   child versus systemd unit**: children (foot, lf, Xwayland, anything a keybind
   spawns) inherit the wrapper's environment; units (quickshell,
   hyprpolkitagent, and hyprlock via hypridle) do not, which is why exactly
   those needed wrapping.

   So the choice is genuinely free, and Debian's wins on cost alone: `xwayland`
   is not a backports package, removing it was never a goal, and keeping it is
   one `apt-mark` against a package swap plus a `compositorPath` entry. Nothing
   about hardware or drivers argues either way.

   Getting this wrong breaks every X11 client: Chrome, VS Code, deskflow, and
   `apply-gtk-theme`'s `xrdb` step.

   The other trixie-sourced packages in the removal list — `libseat1`,
   `libiniparser4`, `libmuparser2v5`, `libsdbus-c++2`, `libxcb-errors0` — are
   genuinely orphaned. They were dependencies of apt's hypr packages, Nix's
   builds carry their own, and nothing in the session invokes them by name.
   They go.

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

Xwayland needs no Nix work at all — decision 4. The only action is
`sudo apt-mark manual xwayland` in section 4, *before* the removal, so
`--autoremove` leaves Debian's in place. Nothing changes in `compositorPath`:
the compositor spawns `Xwayland` by bare name and finds `/usr/bin/Xwayland`
through the inherited PATH, exactly as it does today.

`xdg-desktop-portal-hyprland` gets a `systemd.user.services` entry with the
Nix binary's absolute path, shadowing `/usr/lib/systemd/user/`'s. It needs the
same treatment `hyprpolkitagent` got in spec 1 if it draws: check whether it
needs the nixGL wrapper before assuming it does not. Its `.portal` file is
already discoverable, so no `XDG_DATA_DIRS` work is needed.

### 4. The apt removal

Three root actions, in this order, each run by the user:

1. `sudo apt-mark manual xwayland` — decision 4, and it must come first, or
   step 2 removes it
2. `sudo apt remove --autoremove hyprland hypridle hyprlock hyprpolkitagent hyprpaper hyprland-guiutils`
3. remove the two `trixie-backports` lines from `/etc/apt/sources.list`
4. `sudo apt update`

The order matters twice over: `apt-mark` must precede the removal or Xwayland
goes with it, and removing the source before the packages would leave apt unable
to resolve what it is about to remove.

A `--dry-run` of step 2 after step 1 must show **25** removals, not 26, with
`xwayland` absent from the list. If it still names `xwayland`, stop — the
`apt-mark` did not take.

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
- `apt-mark showmanual | grep -x xwayland` returns it, and the step-2 dry run
  shows 25 removals without `xwayland`.
- The Nix portal unit is active and a portal-mediated action works — opening a
  link through the browser picker exercises it end to end.

**After the apt removal:**

- `hyprctl version` is the Nix build; nothing under `/usr/bin` shadows it.
- The lock screen still unlocks — the fallback is gone now, so this is the
  moment the earlier test pays for itself.
- X11 clients, screen sharing and the browser picker all still work.
- `apt list --installed | grep backports` lists only the three shared libraries
  named in the inventory.
- Zero failed units and no `command not found` in the journal after real use.

**After a reboot**, because the last four specs each found something only a cold
boot showed: greetd reaches the session, all units self-start, the lock screen
works from a fresh login.

## Open items

- **`hyprpaper` is being removed as unused.** Verified only by knowing the
  session uses `swaybg`. If something references it, the removal surfaces it.
- **The three frozen backports libraries** receive no further updates. Worth a
  note in the results document so a future security update is not a surprise.
- **`xdg-desktop-portal-hyprland` and nixGL** is unresolved until tested. Spec 1
  found that a systemd unit runs exactly what `ExecStart` names, so an unwrapped
  Qt/GL binary aborts on first draw. The portal may not draw at all.
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
