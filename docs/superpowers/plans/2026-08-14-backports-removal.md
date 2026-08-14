# Removing trixie-backports Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Nix's hyprlock authenticate on Debian, move the lock screen, the Hyprland portal and Xwayland onto Nix, and remove `trixie-backports`.

**Architecture:** A scoped nixpkgs overlay repoints `pam_unix`'s privileged helper at Debian's setgid `unix_chkpwd`, and hyprlock is told to use a PAM service whose file avoids Debian's `@include` extension. Three apt-provided pieces get Nix replacements, then the packages and the apt source go — in that order, because the removal is the one irreversible step.

**Tech Stack:** Nix flakes, standalone Home Manager (`release-26.05`), nixpkgs `nixos-26.05`, linux-pam, hyprlock, Xwayland, xdg-desktop-portal-hyprland.

**Spec:** `docs/superpowers/specs/2026-08-14-backports-removal-design.md`

## Global Constraints

- **Nix needs `sg nix-users -c '<command>'` in this session.** This shell's process predates the user's addition to the `nix-users` group, so a bare `nix` call fails with `getting status of '/nix/var/nix/daemon-socket/socket': Permission denied`.
- **`git add` new and modified files before building.** Nix's git flake fetcher cannot see untracked files.
- **Build command:** `sg nix-users -c 'nix build --no-link .#homeConfigurations."isutton@suffer".activationPackage'`. Both `isutton@suffer` and `nixtest@suffer` must build until Task 8 removes the latter.
- **Never run `home-manager switch`, never run any `apt` command that changes state, never `systemctl --user start` a new unit.** Tasks 6 through 8 are the user's; an implementer's job ends at a green build and read-only checks.
- **The apt removal is irreversible and has no undo inside Nix.** After it there is no fallback hyprlock. Everything it depends on is verified first.
- **Absolute store paths, never bare command names**, in units, wrappers and `lock_cmd`.
- **Scope every nixpkgs override.** `pam` is a dependency of systemd; replacing it set-wide would rebuild much of the closure. Measured target: **2 derivations**.
- **The nixGL rule, stated because this plan relies on it:** compositor children (foot, lf, Xwayland, anything a keybind spawns) inherit the wrapper's environment and need no wrapping; systemd units (quickshell, hyprpolkitagent, and hyprlock via hypridle) do not inherit and must be wrapped.
- **Host is `suffer`**, carried by `config.calango.host`.

---

### Task 1: The `debianPam` overlay

**Files:**
- Modify: `flake.nix` (add the overlay beside `debianPolkit`, and to the `overlays` list)

**Interfaces:**
- Produces: a `pkgs.hyprlock` whose `pam_unix.so` calls `/usr/sbin/unix_chkpwd`. Task 2 consumes it as plain `pkgs.hyprlock`; no new option is exported.

Read `flake.nix`'s existing `debianPolkit` overlay first. This one is the same
shape for the same class of bug — a Nix library resolving a `/run/wrappers`
path that exists only on NixOS — and should read as its sibling.

- [ ] **Step 1: Add the overlay**

In `flake.nix`, after the `debianPolkit` binding:

```nix
      # nixpkgs patches pam_unix's privileged helper to /run/wrappers/bin,
      # NixOS's setuid-wrapper directory, because the store copy cannot carry
      # the setgid bit -- see the comment at pkgs/by-name/li/linux-pam/package.nix.
      # That directory exists on no Debian machine, so pam_unix could never
      # verify a password here: strace shows
      #   execve("/run/wrappers/bin/unix_chkpwd", ...) = -1 ENOENT
      # against Debian's /usr/sbin/unix_chkpwd, which is -rwxr-sr-x root shadow
      # and is the right target. With this patch the same trace reads
      #   execve("/usr/sbin/unix_chkpwd", ...) = 0
      #
      # Third instance of the same failure as debianPolkit above and nixGL
      # before it. Scoped to hyprlock for the same reason: pam is a dependency
      # of systemd, and replacing it set-wide rebuilds most of the closure.
      # Measured -- scoped, this is 2 derivations, and `systemd` keeps its
      # stock store path.
      #
      # --replace-fail matches nixpkgs' own substituted output, so an upstream
      # change to that line fails the build rather than silently restoring the
      # NixOS path.
      debianPam = final: prev:
        let
          patched = prev.pam.overrideAttrs (old: {
            postPatch = (old.postPatch or "") + ''
              substituteInPlace modules/module-meson.build \
                --replace-fail "'/run/wrappers/bin/unix_chkpwd'" "'/usr/sbin/unix_chkpwd'"
            '';
          });
        in
        {
          hyprlock = prev.hyprlock.override { pam = patched; };
        };
```

Then add it to the overlay list:

```nix
        overlays = [ nixgl.overlays.default debianPolkit debianPam ];
```

- [ ] **Step 2: Confirm the scoping — this is the step that matters**

```bash
git add flake.nix
sg nix-users -c 'nix build --no-link --dry-run .#homeConfigurations."isutton@suffer".activationPackage' 2>&1 | tail -20
```

Expected: a small build list. If `systemd`, `dbus`, `util-linux` or a comparable
low-level package appears, the overlay is not scoped — stop and fix it rather
than starting a large rebuild.

- [ ] **Step 3: Prove the patch reached the binary**

`homeConfigurations."isutton@suffer".pkgs` exposes the overlaid package set, so
the patched hyprlock can be reached directly. Write the probe to a file — the
quoting does not survive `sg nix-users -c` inline:

```bash
cat > /tmp/pamprobe.nix <<'EOF'
let
  f = builtins.getFlake (toString /home/isutton/Projects/calango-nix);
in f.outputs.homeConfigurations."isutton@suffer".pkgs.hyprlock
EOF
HL=$(sg nix-users -c 'nix build --no-link --print-out-paths --impure --file /tmp/pamprobe.nix' 2>&1 | tail -1)
echo "hyprlock: $HL"
for p in $(sg nix-users -c "nix path-info --recursive $HL" 2>/dev/null | grep linux-pam); do
  echo "== $p"
  strings "$p/lib/security/pam_unix.so" 2>/dev/null | grep chkpwd | head -2
done
```

Expected: exactly one linux-pam path in hyprlock's closure, whose `pam_unix.so`
contains `/usr/sbin/unix_chkpwd` and **not** `/run/wrappers/bin/unix_chkpwd`.

Both strings appearing would mean the substitution ran on a copy that is not the
one being linked. Only the `/run/wrappers` string appearing means the overlay is
not being applied — check that `debianPam` actually reached the `overlays` list
in step 1.

- [ ] **Step 4: Confirm systemd was not rebuilt**

```bash
cat > /tmp/pamscope.nix <<'EOF'
let
  f = builtins.getFlake (toString /home/isutton/Projects/calango-nix);
  stock = f.inputs.nixpkgs.legacyPackages.x86_64-linux;
  ours  = f.outputs.homeConfigurations."isutton@suffer".pkgs;
in "stock systemd: ${stock.systemd}\nours  systemd: ${ours.systemd}\n"
EOF
sg nix-users -c 'nix eval --raw --impure --file /tmp/pamscope.nix'
```

Expected: the two paths are identical. A difference means the overlay leaked
past hyprlock.

- [ ] **Step 5: Build and commit**

```bash
sg nix-users -c 'nix build --no-link .#homeConfigurations."isutton@suffer".activationPackage'
sg nix-users -c 'nix build --no-link .#homeConfigurations."nixtest@suffer".activationPackage'
git commit -m "flake: point pam_unix at Debian's setgid unix_chkpwd, scoped to hyprlock"
```

---

### Task 2: hyprlock from Nix

**Files:**
- Modify: `home/hyprland.nix` (add the config derivation, the nixGL wrapper, the activation hook; change `lock_cmd`)
- Modify: `home/default.nix` (remove the comment explaining hyprlock's absence)

**Interfaces:**
- Consumes: Task 1's patched `pkgs.hyprlock`.
- Produces: `hyprlock` on `~/.nix-profile/bin`, wrapped in nixGL. Nothing later consumes it programmatically; Task 5 tests it by hand.

`home/hyprland.nix` already binds `hyprState` at the top of its `let`. Reuse it —
do not re-derive the path.

- [ ] **Step 1: Add the config derivation and the wrapper**

In `home/hyprland.nix`'s `let` block, after `hyprConfig`:

```nix
  # hyprlock's static configuration. The palette is deliberately not here: the
  # quickshell theme switcher rewrites it on every theme change, so it lives in
  # state and is pulled in by the `source` below. Same split as foot -- store
  # config, state palette, store file naming the state file.
  #
  # auth:pam:module is the whole reason this file exists. hyprlock's default
  # service is "hyprlock", whose /etc/pam.d/hyprlock is `auth include login`,
  # and /etc/pam.d/login reaches pam_unix only through `@include common-auth`.
  # @include is a Debian extension that Nix's libpam does not implement --
  # measured: given /etc/pam.d/other, four @include lines and nothing else,
  # Nix's libpam attempted zero of them. Naming common-auth directly reaches
  # pam_unix through a plain `auth` line, which upstream libpam does parse.
  # Safe because hyprlock calls only pam_start and pam_authenticate
  # (src/auth/Pam.cpp:119-127) -- no pam_acct_mgmt -- so an auth-only service
  # is complete for it.
  hyprlockConfig = pkgs.writeText "hyprlock.conf" ''
    auth {
        pam {
            module = common-auth
        }
    }

    source = ${hyprState}/hyprlock.conf
  '';

  # hypridle is a systemd unit, so what it spawns inherits nothing from the
  # compositor's nixGL wrapper. Spec 3 found this the hard way: unwrapped, Nix's
  # hyprlock draws nothing and dies with
  #   CRIT: Hyprlock threw: EGL_EXT_platform_base not supported
  # Named `hyprlock` so lock_cmd's `pidof hyprlock` guard still matches.
  hyprlock-nixgl = pkgs.writeShellScriptBin "hyprlock" ''
    exec ${pkgs.nixgl.nixGLIntel}/bin/nixGLIntel ${pkgs.hyprlock}/bin/hyprlock "$@"
  '';
```

- [ ] **Step 2: Point `lock_cmd` at it**

Replace the `lock_cmd` line in `services.hypridle.settings.general`, and replace
the long TEMPORARY REVERT comment above it with:

```nix
        # Nix's hyprlock, wrapped, with the store-side config that names the PAM
        # service. The revert to /usr/bin/hyprlock that stood here since spec 3
        # is gone: flake.nix's debianPam overlay makes Nix's pam_unix call
        # Debian's setgid unix_chkpwd, so authentication works.
        #
        # The `pidof hyprlock` guard stays -- it stops a second instance when
        # the lock is already up, and matches by process name, which the wrapper
        # preserves.
        lock_cmd = "${pkgs.procps}/bin/pidof hyprlock || ${hyprlock-nixgl}/bin/hyprlock --config ${hyprlockConfig}";
```

- [ ] **Step 3: Put hyprlock on PATH and seed the state file**

In the `config` block of `home/hyprland.nix`:

```nix
  config.home.packages = [ hyprlock-nixgl ];

  # hyprlock's `source` treats a missing target as an error, so this file must
  # exist before the first lock. The theme switcher creates it on its first
  # theme apply, which is not soon enough on a fresh machine.
  #
  # Deliberately NOT suffixed with `|| true`, matching home/foot.nix's
  # equivalent hook and for the same reason: if this cannot run, the screen
  # will not lock, and a switch that fails loudly leaves the previous
  # generation working.
  config.home.activation.hyprlockConf =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if [ ! -e ${lib.escapeShellArg "${hyprState}/hyprlock.conf"} ]; then
        run mkdir -p ${lib.escapeShellArg hyprState}
        run touch ${lib.escapeShellArg "${hyprState}/hyprlock.conf"}
      fi
    '';
```

- [ ] **Step 4: Remove the stale explanation in `home/default.nix`**

`home/default.nix`'s `home.packages` carries a commented-out `hyprlock` with a
paragraph explaining why a broken Nix build must not be reachable by name. That
reason has expired. Delete the comment and the commented-out entry; do not add
`hyprlock` there, since Task 2 step 3 adds the wrapped one from
`home/hyprland.nix`.

- [ ] **Step 5: Build and check the generated hypridle config**

```bash
git add home/hyprland.nix home/default.nix
sg nix-users -c 'nix build --no-link .#homeConfigurations."isutton@suffer".activationPackage'
OUT=$(sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage')
grep lock_cmd "$OUT/home-files/.config/hypr/hypridle.conf"
```

Expected: `lock_cmd` names a `/nix/store/...` hyprlock and a `/nix/store/...`
config, with no `/usr/bin/hyprlock` anywhere.

- [ ] **Step 6: Check the store config's contents**

```bash
CFG=$(grep -o '\-\-config [^ ]*' "$OUT/home-files/.config/hypr/hypridle.conf" | awk '{print $2}')
cat "$CFG"
```

Expected: an `auth { pam { module = common-auth } }` block and a `source =`
naming `/home/isutton/.local/state/hypr/hyprlock.conf`.

- [ ] **Step 7: Verify hyprlock parses it, without locking the screen**

```bash
HL=$(grep -o '/nix/store/[^ ]*/bin/hyprlock' "$OUT/home-files/.config/hypr/hypridle.conf" | tail -1)
echo "binary: $HL"
WAYLAND_DISPLAY=definitely-not-a-display "$HL" --config "$CFG" 2>&1 | head -5
```

Expected: it reads the config and then fails to reach a display. A config error
would name the offending line instead.

**Do not run it with a valid `WAYLAND_DISPLAY`** — that locks the screen, and
until Task 5 proves authentication works, unlocking is not guaranteed.

**If `source =` turns out not to work**, the spec's stated fallback is to emit
the `auth` block from `applyHyprlockTheme` in
`quickshell/theme-switcher/Theme.qml` instead, accepting that it only lands on
the next theme change. Do not reach for it speculatively: `source` is a
registered handler in hyprlock's own `ConfigManager.cpp:353`, so it is expected
to work. Its one sharp edge is already handled — a missing target is an *error*,
not a silent skip (`ConfigManager.cpp:562`), which is what step 3's activation
hook exists for.

- [ ] **Step 8: Confirm the wrapper resolves the PATCHED pam**

Task 1 step 3 proved a patched hyprlock exists. This proves the one `lock_cmd`
actually names is that build and not the stock one — a different question, and
the one that matters at lock time.

```bash
for p in $(sg nix-users -c "nix path-info --recursive $HL" 2>/dev/null | grep linux-pam); do
  echo "== $p"
  strings "$p/lib/security/pam_unix.so" 2>/dev/null | grep chkpwd | head -2
done
```

Expected: `/usr/sbin/unix_chkpwd`, and no `/run/wrappers/bin/unix_chkpwd`. If
the stock path appears here while Task 1 step 3 was clean, `lock_cmd` is
pointing at an unpatched hyprlock — check that `hyprlock-nixgl` wraps
`pkgs.hyprlock` and not something re-imported from a different package set.

- [ ] **Step 9: Commit**

```bash
git commit -m "hypr: lock with Nix's hyprlock, authenticating through common-auth"
```

---

### Task 3: Xwayland from Nix

**Files:**
- Modify: `home/session.nix` (`compositorPath`)

**Interfaces:**
- Consumes: nothing.
- Produces: `Xwayland` on the compositor's PATH, ahead of `/usr/bin/Xwayland`.

- [ ] **Step 1: Add it to `compositorPath`**

In `home/session.nix`'s `compositorPath` list, keeping the list's alphabetical
order:

```nix
    xwayland      # Xwayland, spawned by the compositor for every X11 client
```

Above the list, add:

```nix
  # xwayland is in this list to FIX something, not merely to replace apt's.
  # Debian's Xwayland is a child of this nixGL-wrapped compositor, so it
  # inherits LIBGL_DRIVERS_PATH and GBM_BACKENDS_PATH pointing into Nix's mesa
  # while linking Debian's libgbm. Glamor needs a matching GBM/DRI pair, gets a
  # mismatched one, and silently falls back to software rendering. Measured with
  # identical clients, only the server differing:
  #     Nix's Xwayland      Accelerated: yes  AMD Radeon 780M (radeonsi)
  #     Debian's Xwayland   Accelerated: no   llvmpipe
  # Every X11 client has been on the CPU since spec 1. Nix's needs no nixGL
  # wrapper of its own -- it inherits the compositor's environment, which is
  # exactly what makes it work.
```

- [ ] **Step 2: Build and confirm it is on the path, ahead of Debian's**

```bash
git add home/session.nix
sg nix-users -c 'nix build --no-link .#homeConfigurations."isutton@suffer".activationPackage'
W=$(readlink -f ~/.nix-profile/bin/hyprland-nixgl)
sed -n 's/^export PATH=//p' "$W" | tr ':' '\n' | grep -n xwayland
```

Expected: a store path containing `xwayland`, and it appears before any
`/usr/bin`. (`~/.nix-profile/bin/hyprland-nixgl` is the *currently activated*
wrapper; after a build but before a switch it still shows the old list. If it
does not list xwayland, resolve the new one from the build output instead:
`$OUT/home-path/bin/hyprland-nixgl`.)

- [ ] **Step 3: Prove the acceleration claim before relying on it**

This runs a second Xwayland on a spare display. It does not touch `:0`.

```bash
XW=$(sg nix-users -c 'nix build --no-link --print-out-paths --impure --expr "
  let f = builtins.getFlake (toString /home/isutton/Projects/calango-nix);
  in f.inputs.nixpkgs.legacyPackages.x86_64-linux.xwayland"' 2>&1 | tail -1)
G=$(sg nix-users -c 'nix build --no-link --print-out-paths --impure --expr "
  let f = builtins.getFlake (toString /home/isutton/Projects/calango-nix);
  in f.inputs.nixpkgs.legacyPackages.x86_64-linux.mesa-demos"' 2>&1 | tail -1)
HP=$(pgrep -f 'bin/Hyprland' | head -1)
tr '\0' '\n' < /proc/$HP/environ | grep -E '^(LIBGL_DRIVERS_PATH|GBM_BACKENDS_PATH|LD_LIBRARY_PATH|__EGL_VENDOR_LIBRARY_FILENAMES|XDG_RUNTIME_DIR|HOME)=' > /tmp/gl.env
WD=$(systemctl --user show-environment | sed -n 's/^WAYLAND_DISPLAY=//p')
nohup env -i $(cat /tmp/gl.env | tr '\n' ' ') WAYLAND_DISPLAY="$WD" "$XW/bin/Xwayland" :99 -rootless >/dev/null 2>&1 &
sleep 3
for d in 99 0; do
  printf ':%s  ' "$d"
  DISPLAY=":$d" "$G/bin/glxinfo" -B 2>&1 | grep -E 'Accelerated|renderer string' | tr '\n' ' '
  echo
done
```

Expected: `:99` reports `Accelerated: yes` with the radeonsi renderer; `:0`
reports `Accelerated: no` with llvmpipe. That difference is the defect this task
fixes, and seeing it is what justifies the change.

- [ ] **Step 4: Stop the test server**

```bash
XP=$(pgrep -x Xwayland | while read p; do grep -qa ':99' /proc/$p/cmdline 2>/dev/null && echo $p; done | head -1)
[ -n "$XP" ] && kill "$XP"
pgrep -x Xwayland | while read p; do tr '\0' ' ' < /proc/$p/cmdline | cut -c1-30; echo; done
```

Expected: only `Xwayland :0` remains. **Do not use `pkill -f 'Xwayland :99'`** —
`-f` matches your own command line and kills the shell running it.

- [ ] **Step 5: Commit**

```bash
git commit -m "session: Xwayland from Nix, which fixes X11 clients running on llvmpipe"
```

---

### Task 4: The Hyprland portal from Nix

**Files:**
- Modify: `home/services.nix` (add the unit)

**Interfaces:**
- Consumes: nothing.
- Produces: `xdg-desktop-portal-hyprland.service` as a user unit, shadowing `/usr/lib/systemd/user/`'s.

Nix's binary and its `.portal` file are already installed —
`~/.nix-profile/libexec/xdg-desktop-portal-hyprland` exists, and
`~/.nix-profile/share` is first in the session's `XDG_DATA_DIRS`, so Nix's
`hyprland.portal` already shadows Debian's. Only the unit is Debian's.

- [ ] **Step 1: Add the unit**

In `home/services.nix`'s `config` block, modelled on Debian's unit (`Type=dbus`
with a `BusName` — the portal is D-Bus activated and the type must match):

```nix
  # Debian's /usr/lib/systemd/user/xdg-desktop-portal-hyprland.service names
  # /usr/libexec/xdg-desktop-portal-hyprland absolutely, so removing apt's
  # package takes the running implementation with it. A user unit of the same
  # name shadows the system one.
  #
  # Nix's .portal file already wins on its own: ~/.nix-profile/share is first in
  # the session's XDG_DATA_DIRS, so no XDG work is needed here.
  #
  # Type=dbus and BusName are copied from Debian's unit deliberately. The portal
  # frontend activates this over D-Bus, and Type=simple would let systemd report
  # it started before it owns the name.
  config.systemd.user.services.xdg-desktop-portal-hyprland = {
    Unit = {
      Description = "Portal service (Hyprland implementation)";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
      ConditionEnvironment = "WAYLAND_DISPLAY";
    };
    Service = {
      Type = "dbus";
      BusName = "org.freedesktop.impl.portal.desktop.hyprland";
      ExecStart = "${pkgs.xdg-desktop-portal-hyprland}/libexec/xdg-desktop-portal-hyprland";
      Restart = "on-failure";
      Slice = "session.slice";
    };
  };
```

Note there is **no** `Install.WantedBy`: Debian's unit has no `[Install]` section
either, because the portal is started on demand by D-Bus activation rather than
pulled in by a target.

- [ ] **Step 2: Build and compare against Debian's unit**

```bash
git add home/services.nix
sg nix-users -c 'nix build --no-link .#homeConfigurations."isutton@suffer".activationPackage'
OUT=$(sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage')
diff <(grep -vE '^\s*#|^\s*$' /usr/lib/systemd/user/xdg-desktop-portal-hyprland.service) \
     <(grep -vE '^\s*#|^\s*$' "$OUT/home-files/.config/systemd/user/xdg-desktop-portal-hyprland.service")
```

Expected: the only difference is the `ExecStart` path, `/usr/libexec/...`
against `/nix/store/...`. Any other difference is a transcription error — the
whole point is to change the binary and nothing else.

- [ ] **Step 3: Confirm the binary exists and is executable**

```bash
E=$(sed -n 's/^ExecStart=//p' "$OUT/home-files/.config/systemd/user/xdg-desktop-portal-hyprland.service")
test -x "$E" && echo "ok $E" || echo "MISSING $E"
```

- [ ] **Step 4: Gather the nixGL evidence — but do NOT add the wrapper**

Spec 1 established that a systemd unit runs exactly what `ExecStart` names, so a
Qt/GL binary aborts on first draw unless wrapped. Whether this one draws needs
evidence rather than a guess.

**`ldd` on the main binary does not answer this.** Qt loads its platform and GL
plugins with `dlopen`, so they never appear in `ldd` output. Measured: `ldd` finds
zero GL libraries in `quickshell` too, and quickshell demonstrably needs the
wrapper — it reaches "active (running)" and then aborts with `status=6/ABRT` the
moment the bar tries to map. Any check built on `ldd` here is a false negative.

Compare closures instead, and look at what the portal spawns:

```bash
P=$(sed -n 's/^ExecStart=//p' "$OUT/home-files/.config/systemd/user/xdg-desktop-portal-hyprland.service")
PKG=$(echo "$P" | sed 's|/libexec/.*||')
for pat in qtbase qtwayland mesa libglvnd; do
  printf '%-12s portal=%s quickshell=%s\n' "$pat" \
    "$(sg nix-users -c "nix path-info --recursive $PKG" 2>/dev/null | grep -c $pat)" \
    "$(sg nix-users -c 'nix path-info --recursive /nix/store/ij0frm7iyv9m71y99gvz79sy22qvg7x5-quickshell-0.3.0' 2>/dev/null | grep -c $pat)"
done
ls "$PKG/bin"
```

Recorded when the plan was written, so you have something to compare against: the
two closures are identical in shape — `qtbase 2, qtwayland 1, mesa 1, libglvnd 1`
— and the portal package ships `bin/hyprland-share-picker`, a Qt GUI it launches
for the screen-share dialog. A child of a systemd unit inherits that unit's
environment, so an unwrapped portal would hand the picker no GL setup either.

The evidence therefore points at needing the wrapper. **Do not add it anyway.**
Every one of the four wrappers in this project was established by a crash or a
runtime failure, never by analogy, and "the closure looks similar" is analogy.
Task 5 starts the unit and exercises screen sharing, which settles it with the
only evidence that counts. Report your findings so Task 5 knows what to expect.

- [ ] **Step 5: Commit**

```bash
git commit -m "services: the Hyprland portal from Nix, shadowing Debian's unit"
```

---

### Task 5: Verify everything before the irreversible step

**Files:**
- Create: `docs/2026-08-14-results-suffer-backports-removal.md` (started here, finished in Task 9)

**Interfaces:**
- Consumes: Tasks 1-4.

This task changes the running session and hands two checks to the user. **An
agent must not run `home-manager switch`, must not lock the screen, and must not
run any apt command.**

- [ ] **Step 1: Record the before state**

```bash
{
  echo "== BEFORE =="; date
  echo "-- backports packages"; apt list --installed 2>/dev/null | grep -c backports
  echo "-- X11 acceleration"; DISPLAY=:0 glxinfo -B 2>/dev/null | grep -E 'Accelerated|renderer string'
  echo "-- Xwayland binary"; readlink -f /proc/$(pgrep -x Xwayland | head -1)/exe
  echo "-- portal binary"; readlink -f /proc/$(pgrep -f 'xdg-desktop-portal-hyprland' | head -1)/exe
  echo "-- lock_cmd"; grep lock_cmd ~/.config/hypr/hypridle.conf
} | tee /tmp/backports-before.txt
```

- [ ] **Step 2: Hand the switch to the user**

Report, and stop:

> Ready to switch. Please run:
>
> ```
> home-manager switch --flake ~/Projects/calango-nix#isutton@suffer
> ```
>
> Expect `sd-switch` to restart `quickshell` and start the new portal unit. The
> lock screen is not exercised by the switch.

- [ ] **Step 3: The authentication test — the gate for everything else**

This is the evidence the spike could not gather, and nothing downstream should
proceed without it. Ask the user to run, entering their **real** password:

```bash
sg nix-users -c 'nix run nixpkgs#pamtester -- common-auth "$USER" authenticate'
```

Expected: `pamtester: successfully authenticated`. That binary links nixpkgs'
stock pam, so it proves the *service file* is usable but not the patched helper.
For the patched one, ask them to run:

```bash
HL=$(grep -o '/nix/store/[^ ]*/bin/hyprlock' ~/.config/hypr/hypridle.conf | head -1)
ldd "$HL" 2>/dev/null | grep libpam
```

and record which linux-pam store path hyprlock resolves — it must be the patched
one from Task 1 step 3, not nixpkgs' stock.

- [ ] **Step 4: The lock test, from a spare VT as `nixtest`**

Spec 3 caused a lockout by testing this on the live session. Ask the user to:

1. switch to a free VT (Ctrl+Alt+F3) and log in as `nixtest`
2. from there, run `loginctl lock-session <isutton's session id>` — or simply
   wait for hypridle's 300-second timeout
3. switch back to the graphical VT and try to unlock with the real password

Expected: the lock screen appears and **unlocks**. If it does not, the user can
return to the `nixtest` VT and `pkill hyprlock` without killing the graphical
session — which is the whole reason for this arrangement.

If unlocking fails, stop the plan here and report. Tasks 6 onward remove the
fallback.

- [ ] **Step 5: Xwayland and the portal, live**

```bash
readlink -f /proc/$(pgrep -x Xwayland | head -1)/exe
DISPLAY=:0 glxinfo -B 2>/dev/null | grep -E 'Accelerated|renderer string'
readlink -f /proc/$(pgrep -f 'xdg-desktop-portal-hyprland' | head -1)/exe
systemctl --user status xdg-desktop-portal-hyprland --no-pager | head -5
```

Expected: Xwayland is now a `/nix/store/...` path, `Accelerated: yes` with the
radeonsi renderer, and the portal is the Nix binary. Note that Xwayland only
changes at a fresh login — the running one was started by the old compositor —
so if it is still `/usr/bin/Xwayland`, that is expected until Task 7's reboot,
and should be recorded rather than treated as a failure.

- [ ] **Step 6: Exercise the portal end to end, including the part that draws**

Two different paths, and the second is the one Task 4 could not settle:

```bash
xdg-open https://example.invalid/
```

Expected: the browser picker appears. That goes through the portal, so it tests
the unit rather than its status line.

Then ask the user to start a screen share — any application that offers one, or
a browser's "share your screen". Expected: Hyprland's share-picker window
appears and a source can be chosen.

**This is the check that decides the nixGL question.** The picker is a Qt GUI the
portal spawns, so it inherits the unit's environment. If it fails to draw — or
the portal logs `status=6/ABRT` in `journalctl --user -u
xdg-desktop-portal-hyprland` — the unit needs its `ExecStart` wrapped in
`nixGLIntel`, exactly as `quickshell.service` and `hyprpolkitagent` are. That is
a one-line change to `home/services.nix`; make it, rebuild, and re-test before
continuing to Task 6.

If screen sharing is not something the user needs, record that it was untested
rather than recording it as passing.

- [ ] **Step 7: Start the results document**

Create `docs/2026-08-14-results-suffer-backports-removal.md` with the before
state, each check above and its result, following the shape of
`docs/2026-08-14-results-suffer-user-layer.md`. Leave the post-removal and
post-reboot sections empty.

- [ ] **Step 8: Commit**

```bash
git add docs/2026-08-14-results-suffer-backports-removal.md
git commit -m "results: Nix's lock screen, Xwayland and portal, before the apt removal"
```

---

### Task 6: Remove the packages and the apt source

**Files:**
- Modify: `docs/2026-08-14-results-suffer-backports-removal.md`

**Interfaces:**
- Consumes: Task 5's verification, in full.

**Every command here is the user's to run.** This is the irreversible step. Do
not proceed if any check in Task 5 failed.

- [ ] **Step 1: Re-measure before removing**

Ask the user to run:

```bash
sudo apt-get -s remove --autoremove hyprland hypridle hyprlock hyprpolkitagent hyprpaper hyprland-guiutils 2>&1 | grep -c '^Remv'
```

Expected: **26**. A different number means the machine has drifted since the
inventory was taken — stop and re-measure rather than proceeding. The list
should include `xwayland`, `xdg-desktop-portal-hyprland` and
`calango-desktop-deps`, all of which Tasks 2-4 have now replaced or retired.

- [ ] **Step 2: Remove the packages**

```bash
sudo apt remove --autoremove hyprland hypridle hyprlock hyprpolkitagent hyprpaper hyprland-guiutils
```

- [ ] **Step 3: Remove the source**

Delete these two lines from `/etc/apt/sources.list` — delete, not comment out; a
commented line is a configuration that looks disabled and is one edit from live,
and git history is the record:

```
deb http://deb.debian.org/debian trixie-backports main non-free-firmware
deb-src http://deb.debian.org/debian trixie-backports main non-free-firmware
```

Then:

```bash
sudo apt update
```

- [ ] **Step 4: Confirm what is left**

```bash
apt list --installed 2>/dev/null | grep backports
```

Expected: exactly three — `libxkbcommon0`, `libxkbcommon-x11-0` and
`libcpptrace1`. These stay because `google-chrome-stable`, `deskflow` and `code`
link them; removing the source freezes them at their installed versions rather
than downgrading anything. Any fourth entry needs explaining before continuing.

- [ ] **Step 5: Confirm the session survived**

```bash
hyprctl version | head -2
which Xwayland hyprlock
systemctl --user --failed --no-pager
journalctl --user --since "5 minutes ago" 2>/dev/null | grep -ic 'command not found'
```

Expected: hyprctl is the Nix build, `Xwayland` and `hyprlock` resolve into
`/nix/store` or `~/.nix-profile`, no failed units, zero `command not found`.

- [ ] **Step 6: Lock and unlock once more**

The fallback is gone now, so this is the moment Task 5's test pays for itself.
Ask the user to lock the session and unlock it. If it fails, the recovery is
`apt install hyprlock` — which needs the backports source back, so record that
in the results document as the rollback.

- [ ] **Step 7: Record and commit**

Fill in the post-removal section of the results document.

```bash
git add docs/2026-08-14-results-suffer-backports-removal.md
git commit -m "results: trixie-backports removed, three shared libraries frozen"
```

---

### Task 7: Verify after a reboot

**Files:**
- Modify: `docs/2026-08-14-results-suffer-backports-removal.md`

Each of the last four specs found something only a cold boot revealed. This one
has more reason than most: Xwayland changes only at a fresh login, and greetd's
own enablement was repaired by hand during spec 4.

- [ ] **Step 1: Ask the user to reboot**

- [ ] **Step 2: Check the boot chain and the session**

```bash
systemctl is-enabled greetd; systemctl is-active greetd
readlink -f /proc/$(pgrep -x Xwayland | head -1)/exe
DISPLAY=:0 glxinfo -B 2>/dev/null | grep -E 'Accelerated|renderer string'
systemctl --user is-active quickshell hypridle hyprpolkitagent bt-agent night-light nm-secret-agent xdg-desktop-portal-hyprland
systemctl --user --failed --no-pager
```

Expected: greetd enabled and active, Xwayland is the Nix build, **`Accelerated:
yes`**, every unit active, none failed.

- [ ] **Step 3: Lock and unlock from a cold session**

Ask the user to lock and unlock once. This is the last unverified path: a lock
screen that works mid-session but not after a reboot would be a PAM environment
difference, and it is better found now than at 2am.

- [ ] **Step 4: Record and commit**

```bash
git add docs/2026-08-14-results-suffer-backports-removal.md
git commit -m "results: verified after a reboot"
```

---

### Task 8: Retire `nixtest`

**Files:**
- Modify: `flake.nix` (remove the `nixtest@suffer` configuration)
- Modify: `docs/2026-08-14-results-suffer-backports-removal.md`

**Interfaces:**
- Consumes: Task 7's verification. The account is the safety net for exactly the
  test in Task 7 step 3, so it goes only after that passes.

- [ ] **Step 1: Remove the configuration**

In `flake.nix`, delete:

```nix
        "nixtest@suffer" = mkHome "nixtest" "suffer";
```

`mkHome` stays — `isutton@suffer` still uses it.

- [ ] **Step 2: Build what remains**

```bash
git add flake.nix
sg nix-users -c 'nix build --no-link .#homeConfigurations."isutton@suffer".activationPackage'
sg nix-users -c 'nix eval .#homeConfigurations --apply builtins.attrNames'
```

Expected: the build succeeds and the attribute list is `[ "isutton@suffer" ]`.

- [ ] **Step 3: Delete the account**

The user runs:

```bash
sudo userdel -r nixtest
```

This removes the home directory, and with it `nixtest`'s Home Manager
generations and Nix profile. The store paths they referenced become
garbage-collectable; collecting them is not part of this plan.

- [ ] **Step 4: Confirm**

```bash
id nixtest 2>&1 | head -1
ls -d /home/nixtest 2>&1 | head -1
getent group nix-users
```

Expected: no such user, no home directory, and `nix-users` now lists only
`isutton`.

- [ ] **Step 5: Commit**

```bash
git commit -m "flake: retire the nixtest account, its purpose served"
```

---

### Task 9: Finish the results document

**Files:**
- Modify: `docs/2026-08-14-results-suffer-backports-removal.md`

- [ ] **Step 1: Complete it**

Cover, honestly: what was verified and how; the before/after acceleration
numbers, because that is a user-visible improvement nobody asked for; every
defect found and whether it belonged to this spec or an earlier one; the three
frozen backports libraries and the fact that they will receive no further
security updates; and what the next spec inherits.

Say explicitly whether the two PAM root causes behaved as the spike predicted,
and whether the correct-password test passed first time — the spike's own
"what it did not prove" section names that as the open question, and this is
where it gets closed.

If the recurring incomplete-enumeration defect appeared again, record where. Four
results documents have now named it; this one should say whether the `apt-get -s`
simulation — the first time this project enumerated by *asking the tool* rather
than by reading a list — made any difference.

- [ ] **Step 2: Commit**

```bash
git add docs/2026-08-14-results-suffer-backports-removal.md
git commit -m "results: the backports removal, complete"
```

---

## Notes for the executor

**Tasks 1-4 are agent work; Tasks 5-9 are not.** Everything from Task 5 changes
the user's live session, and Task 6 is irreversible. An agent's job on those
tasks is to prepare commands, read results and write them down — not to run
`home-manager switch`, `apt`, `userdel`, or anything that locks the screen.

**The ordering is the plan's spine, not a preference.** Task 6 removes the only
fallback lock screen on the machine. Task 5's authentication test is what makes
that safe, and Task 5 step 4 runs it from a VT where failure costs nothing.
Reordering these turns a recoverable failure into a lockout — which has already
happened once in this project, for exactly this reason.

**Two things in this plan are fixes rather than ports**, and their verification
should be treated as load-bearing rather than ceremonial: Task 3 fixes X11
clients running on llvmpipe, and Task 1 fixes authentication that has never
worked. Both have a measured "before" to beat, and both are stated in the spec
with the measurement that found them.

**Do not add a nixGL wrapper to the portal speculatively.** Task 4 step 4
gathers the evidence and Task 5 settles it. Four binaries in this project have
needed the wrapper and each was established by a crash or a linkage check, never
by analogy.
