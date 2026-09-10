# Spec 23: Debian GL applications must not inherit the session's nixGL environment

**Branch:** `nixgl-strip-for-debian-apps`
**Written:** 2026-09-10
**Status:** design approved in chat; not implemented
**Follows:** the nixGL consolidation in `lib/nixgl.nix`, and spec 11's
`AppLaunch.qml`, which is the launch path this spec changes.

---

## The problem

1Password could not open a window on suffer. Pressing SUPER+D, choosing it and
waiting produced nothing at all -- no window, no error the user could see, and a
tray icon that behaved as though the application were healthy.

The cause is the one `CLAUDE.md` already records, in a place nobody had looked
for it. The compositor is wrapped by nixGL, so every session child inherits five
variables:

    __EGL_VENDOR_LIBRARY_FILENAMES  GBM_BACKENDS_PATH
    LD_LIBRARY_PATH  LIBGL_DRIVERS_PATH  LIBVA_DRIVERS_PATH

`__EGL_VENDOR_LIBRARY_FILENAMES` tells libglvnd to use *only* Nix's mesa vendor
JSON, and `LD_LIBRARY_PATH` puts Nix's mesa first. A Debian-linked process then
loads a Nix `libEGL`, its GPU process dies during initialisation, and Electron
creates no window. The application stays alive, serves its tray icon and its
SSH agent, and looks fine.

That is why this took a whole session to find: **every instrument that reads a
running process said the application was healthy.** The GPU process even mapped
`libgallium` six times, which reads as hardware acceleration and was recorded as
such mid-session before being withdrawn -- a mapped library is not an
initialised EGL display.

---

## Decisions

1. **An explicit table, holding only entries proven to break.** Not a derived
   predicate. `CLAUDE.md` records that `wrapExemptions` shipped as a derived
   rule and was deleted after review, because a predicate exempts every future
   package that satisfies it by accident and nobody is asked a question at that
   moment. A name in a table is typed by a person who then writes the sentence
   beside it.
2. **The strip list is derived from nixGL, not written here.** See
   "The list is derivable" below.
3. **`~/.config/autostart` stays untouched.** This reverses an earlier decision
   in the same conversation, on evidence gathered afterwards. See "The autostart
   path is already clean" and "Why not own the autostart entry".
4. **No `dpkg-divert`.** See "Why not divert the binary".
5. **1Password only.** Chrome and Slack are Debian-linked too and both measure
   healthy; adding them would change two working applications to fix one.

---

## What was measured

### The five variables are the cause, and stripping them is the fix

Same binary, same session, two invocations. With the session's environment:

```
[ERROR:ui/gl/gl_display.cc:673] Initialization of all (2) EGL display types failed.
[ERROR:ui/ozone/common/gl_ozone_egl.cc:26] GLDisplayEGL::Initialize failed.
[ERROR:viz_main_impl.cc:190] Exiting GPU process due to errors during initialization
libva error: /nix/store/…-mesa-26.1.5/lib/dri/radeonsi_drv_video.so has no function __vaDriverInit_1_0
```

no window, and the process then shut down cleanly logging
`Could not get key from unlocked account!`. With the five unset:

```sh
env -u LD_LIBRARY_PATH -u LIBGL_DRIVERS_PATH -u GBM_BACKENDS_PATH \
    -u LIBVA_DRIVERS_PATH -u __EGL_VENDOR_LIBRARY_FILENAMES \
    /opt/1Password/1password
# WINDOW APPEARED at ~1600ms: class=1password ws=special:magic size=[1024, 800]
# EGL errors: 0
```

### The launcher passes all five

`quickshell/common/AppLaunch.qml:134` launches with
`setsid systemd-run --user --scope --quiet "$@"`, and nothing in the shell tree
sets `environment` or `clearEnvironment` -- `grep -rn 'clearEnvironment\|environment:'`
over `quickshell/**.qml` returns nothing. `--scope` execs into the application,
so the application gets quickshell's environment, and quickshell is itself
nixGL-wrapped:

```sh
# quickshell.service's own environment
tr '\0' '\n' < /proc/$QS_PID/environ | grep -cE '^(LIBGL_DRIVERS_PATH|GBM_BACKENDS_PATH|LIBVA_DRIVERS_PATH|__EGL_VENDOR_LIBRARY_FILENAMES|LD_LIBRARY_PATH)='
# 5

# and a process launched through the launcher's own command shape
setsid systemd-run --user --scope --quiet ./probe.sh
# probe reports 5
```

The second command is the one that matters. It was run because the first only
shows what quickshell holds, not what it passes on, and `systemd-run --scope`
was worth measuring rather than reasoning about.

### The autostart path is already clean

XDG autostart entries become units from `systemd-xdg-autostart-generator`, and
the systemd user manager carries none of the five:

```sh
systemctl --user show-environment | grep -cE '^(LIBGL_DRIVERS_PATH|…)='
# 0
# every autostart-launched process measured: 0/5
```

So the login-time instance works. It is not a theory -- the journal shows it
running:

```
07:36:29  app-1password@autostart.service starts, "SSH Agent has started."
07:53:29  Main process exited, code=killed, status=5/TRAP
```

It served the SSH agent for seventeen minutes and then died of an unrelated
SIGTRAP. **That crash is what exposed the bug.** With the autostart instance
gone, SUPER+D was no longer signalling a healthy instance; it was creating the
first one, in the launcher's 5/5 environment, where it could never draw.

### Which is why the shim is a safety net, not the normal path

1Password is single-instance. With a healthy instance running, a second
invocation exits and asks the first to show a window:

```
1. autostart unit running (--silent)  -> active, no window
2. second invocation                  -> "1Password is already running, closing."
3.                                    -> window appeared after ~800ms
```

Confirmed interactively by the user: clicking the tray icon reveals the window.

| Situation | Today | With the shim |
|---|---|---|
| autostart instance alive | window appears | unchanged |
| autostart instance dead or absent | launcher becomes first instance at 5/5, **no window** | first instance is clean, **window appears** |

The second row is the whole value of this spec, and today proved it is not
hypothetical.

### The list is derivable

`lib/nixgl.nix` -- the one file that decides which GL wrapper this machine uses
-- does **not** name these variables; nixGLIntel exports them at runtime. A
hand-written list in `home/apps.nix` would be a second declaration with nothing
checking it. It does not have to be:

```sh
grep -oE '^export [A-Z_]+' ${nixgl.bin} | cut -d' ' -f2 | sort -u
# __EGL_VENDOR_LIBRARY_FILENAMES
# GBM_BACKENDS_PATH
# LD_LIBRARY_PATH
# LIBGL_DRIVERS_PATH
# LIBVA_DRIVERS_PATH
```

nixGLIntel is a bash script, so the names are readable at build time. If nixGL
ever exports a sixth, the shim strips it with no edit here.

### Chrome and Slack are unaffected

Both are Debian-linked and both are healthy, per `CLAUDE.md`'s own instrument
(`libgallium` is the hardware signal, `swiftshader` the software one), walking
the process tree rather than the top-level pid:

```
chrome  --type=gpu-process   libgallium=6  swiftshader=0
Slack   --type=gpu-process   libgallium=6  swiftshader=0
```

Their main processes also measure 0/5, so something in their own startup
sanitises the environment. That is luck rather than design, and it is not
relied on: it is the reason they are absent from the table, not a claim that
they are immune.

---

## The design

One table in `home/apps.nix`, in the style of `wrapExemptions`:

```nix
glStripped = {
  "1password" = {
    binary    = "/opt/1Password/1password";
    desktopId = "1password.desktop";
    reason = ''
      Debian-linked Electron. With the session's nixGL variables set its GPU
      process dies during initialisation -- "Initialization of all (2) EGL
      display types failed" -- and Electron then creates no window at all,
      while the tray icon and the SSH agent keep working. Measured 2026-09-10:
      no window with them, a window in 1.6 s without.
    '';
  };
};
```

Each entry generates two things, covering the two paths measured broken:

| Generated | Lands at | Covers |
|---|---|---|
| a shim package, `bin/1password` | `~/.nix-profile/bin`, ahead of `/usr/bin` via `uwsm/env` | a typed launch |
| `data/1password.desktop`, `Exec=@shim@ %U` | `~/.local/share/applications` | the quickshell launcher |

The shim is the same shape as `bin/code`, which exists for the same class of
reason -- a `.desktop` covers only launcher launches, and a name typed in a
terminal goes straight to `/usr/bin`:

```sh
exec env -u __EGL_VENDOR_LIBRARY_FILENAMES -u GBM_BACKENDS_PATH \
        -u LD_LIBRARY_PATH -u LIBGL_DRIVERS_PATH -u LIBVA_DRIVERS_PATH \
        /opt/1Password/1password "$@"
```

with the `-u` list generated from the derivation above, not typed.

`data/1password.desktop` is a copy of the vendor's ten lines with only `Exec`
changed. It must keep `MimeType=x-scheme-handler/onepassword;x-scheme-handler/onepassword8;`
or the `onepassword:` scheme stops resolving -- the trap `CLAUDE.md` records for
Signal, where nixpkgs' `.desktop` id differed from Debian's and two handlers
died silently.

### Guards

**A build-time vacuity anchor.** If the derivation's `grep` yields zero names,
the build fails. Without it, a change in nixGL's script shape produces a shim
that strips nothing, launches 1Password exactly as today, and passes every
check -- the failure mode this repository keeps paying for, where "the property
holds" and "the instrument broke" are the same reading.

**Two activation warnings**, because no Nix builder may read `/opt`:

1. `/opt/1Password/1password` does not exist -- the shim would exec nothing.
2. The vendor `.desktop` has drifted from our copy on any field but `Exec` --
   an upgrade adding a `MimeType` or an `Action` would otherwise be shadowed
   silently.

Both are **non-fatal**, for the reason `home/apps.nix` already gives about
`mimeappsIds`: a fatal version aborts every switch on a machine where the corp
package is simply not installed.

Each guard is proven able to fail by mutation before it is trusted, the vacuity
anchor included -- it is the one most likely to be written so that it cannot
fire.

---

## What this does not do, and why

### Why not own the autostart entry

It was decided to own it, and then reversed on measurement. Two findings:

**1Password rewrites that file on every start**, not only when its "Start at
login" setting is toggled:

```
before restart : 2026-09-10 08:17:53
after restart  : 2026-09-10 09:05:28    <- the restart
```

It is Electron's `setLoginItemSettings`, which writes
`~/.config/autostart/<app>.desktop` at startup. `dpkg -L 1password` ships no
autostart file and the file is mode 600, so it is pure runtime state. Home
Manager would place a read-only store symlink there; 1Password would fail to
write it or replace it; the next switch would clobber. That is a loop, not
determinism.

**And it writes the real binary regardless of how it was started.** An instance
launched *through* a stripped environment still wrote:

```
Exec=/opt/1Password/1password --silent
```

because Electron writes `process.execPath`, which is the binary the shim execs
into. A shim can never propagate into that file.

Set against a path that is already clean at 0/5 and demonstrably working, there
is nothing to buy.

### Why an alternate autostart directory does not help

Measured by running the real generator three times in a sandbox:

```
~/.config/nix-autostart/probe.desktop              -> 0 units   (nothing scans it)
<dir on XDG_CONFIG_DIRS>/autostart/probe.desktop   -> 1 unit    (scanned)
same filename in XDG_CONFIG_HOME and XDG_CONFIG_DIRS -> HOME wins
```

The subdirectory name `autostart` is fixed by the spec; only the parent varies.
A parent added to `XDG_CONFIG_DIRS` is *lower* precedence than
`$XDG_CONFIG_HOME/autostart`, so the vendor entry keeps winning. Giving ours a
different filename instead races two instances of a single-instance
application.

### Why not divert the binary

`dpkg-divert --rename` on `/opt/1Password/1password` would cover every launch
path at once and is immune to Electron rewriting anything. It was rejected on
two grounds.

**The machinery does not exist.** Measured on the built artifact -- this is the
whole control archive of `calango-desktop`:

```sh
dpkg-deb --ctrl-tarfile result/*.deb | tar -t
# ./
# ./conffiles
# ./control
```

`lib/deb.nix` supports `control` and `conffiles` and nothing else, and
`calango.deb` exposes five options, none of which is a script. A divert needs
maintainer-script support in `lib/deb.nix`, a new option to declare it, the
divert logic itself (idempotent on re-install, undone on removal, safe when the
`1password` package is absent), and a guard for each. `CLAUDE.md` records that
this package has stayed script-free deliberately.

**And the machinery is the smaller objection.** A divert puts the SSH agent
inside this flake's failure domain. `~/.ssh/config` sets
`IdentityAgent ~/.1password/agent.sock` for `github.com`, so a half-applied
divert -- diverted binary, missing or broken shim -- is a login with no
1Password, therefore no agent, therefore no `git push`, recoverable only from a
terminal. Against that, the divert's only measured benefit is covering a path
that already works.

If a future launch path is found that the shim misses, the divert should be its
own spec, so the maintainer-script machinery is designed and guarded on its own
terms rather than as a rider on this fix.

---

## Verification plan

1. `nix flake check` -- count the checks with
   `grep -c '^checking derivation checks\.'` rather than quoting a number.
2. Build the shim; confirm it names every derived variable and that no
   `@token@` survives (`home/apps.nix`'s `desktopEntries` already runs that
   guard over the generated entries).
3. **Mutation, the vacuity anchor.** Break the `grep` pattern; confirm the build
   fails rather than shipping a shim that strips nothing.
4. **Mutation, the activation warnings.** Point `binary` at a missing path;
   confirm the switch warns and does not abort.
5. **Live, and this is the real test.** Kill every 1Password process so no
   instance holds the single-instance lock, press SUPER+D, and confirm:
   - a window appears
   - the new process reads 0/5 nixGL variables
   - its GPU process maps `libgallium` and not `swiftshader`
   - its log holds no `EGL display types failed`
6. **No regressions.**
   - `xdg-mime query default x-scheme-handler/onepassword` still reads
     `1password.desktop` (it does today)
   - `command -v 1password` moves from `/usr/bin/1password` to the shim
   - `signal-desktop` still draws -- the control for a Nix application that
     *needs* the variables the shim removes, which `CLAUDE.md` measured failing
     with the same EGL error when they are stripped

Step 5 must start from no running instance. Starting it with a healthy instance
alive tests the path that already works and proves nothing.

---

## Known limitations

- **The table holds one entry.** Any other Debian-linked GL application that
  starts failing needs a person to add a row and write its reason. That is the
  design, not an oversight.
- **The vendor `.desktop` is duplicated.** The activation warning reports drift;
  it cannot repair it.
- **The autostart instance can still die** the way it did at 07:53:29 with
  `status=5/TRAP`. This spec does not investigate that crash; it makes the
  recovery path work, so a dead instance is no longer a desktop you cannot open
  a password manager on.
