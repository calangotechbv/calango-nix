# suffer: removing trixie-backports

Date: 2026-08-14 to 2026-08-15.
Session: Hyprland (Nix) 0.55.4. Verified on two accounts — `nixtest`, tty2,
for the lock/unlock test with a spare-VT escape; `isutton` for the switch,
the apt removal and the reboot.

## Did it work?

| Question | Before | After |
|---|---|---|
| Does Nix's hyprlock authenticate? | no — spec 3 banked it unsolved | **yes** — correct password accepted, twice: `pamtester` against the patched pam, then the real lock screen with a recovery VT open |
| What renders X11 clients? | llvmpipe (software) | AMD Radeon 780M, radeonsi, phoenix, ACO |
| What runs the portal? | `/usr/libexec/xdg-desktop-portal-hyprland` (Debian) | Nix's, nixGL-wrapped, D-Bus activatable |
| What runs Xwayland? | `/usr/bin/Xwayland` | `/nix/store/…-xwayland-24.1.13/bin/Xwayland` |
| backports packages installed | 25 | 6, frozen |
| backports source in `sources.list` | present | removed |

Every row but one is a straightforward win. The last is not: six packages
remain, unpatched, forever, and the session's own scaffolding is still not
Nix's. Both are discussed below rather than left implicit.

## The headline: the PAM blocker is solved

Spec 3 banked authentication as characterised-but-unsolved, and the
characterisation was incomplete — it had found one of two independent
causes.

**Cause one.** `nixpkgs/pkgs/by-name/li/linux-pam/package.nix:56` patches
`pam_unix`'s helper path to `/run/wrappers/bin/unix_chkpwd`, which is a
NixOS-only setuid-wrapper directory that exists on no Debian machine. `strace`
against stock and patched pam, same wrong password, showed it plainly:

```
stock:   execve("/run/wrappers/bin/unix_chkpwd", …) = -1 ENOENT
patched: execve("/usr/sbin/unix_chkpwd",        …) = 0
```

Authentication could never have succeeded, for any password, before this was
fixed. This is the third time this project has hit a Nix library resolving a
path that exists only on NixOS — `/run/opengl-driver/lib` produced nixGL in
spec 1, `/run/wrappers/bin/polkit-agent-helper-1` produced the `debianPolkit`
overlay in the same spec, and now `/run/wrappers/bin/unix_chkpwd` produces
`debianPam`, scoped to hyprlock's closure at a measured cost of 2
derivations.

**Cause two, and the one spec 3 never saw.** Even with the helper fixed,
authentication still would not have worked, because `@include` is a Debian
extension to PAM's config syntax that Nix's libpam does not implement.
`/etc/pam.d/hyprlock` says `auth include login`, and `login` reaches
`pam_unix` only through `@include common-auth`. Confirmed three ways:
`@include` is absent from upstream's parser (`libpam/pam_handlers.c:185`),
absent from Nix's `libpam.so.0` strings and present in Debian's, and
empirically — Nix's libpam opened `/etc/pam.d/other`, a file of nothing but
four `@include` lines, and attempted zero of them. This is exactly what made
spec 3's own attempt inconclusive: its patched pam exec'd the right helper but
`pam_unix.so` never appeared in the trace, and there was no way at the time to
tell whether the patch was incomplete or the test harness was lying.

The fix takes no patch: hyprlock exposes `auth:pam:module`, so pointing it at
`common-auth` — which uses `pam_unix.so` directly, no `@include` — avoids the
extension rather than implementing it.

The spike itself wrote down what it had not proven: *"a correct password is
accepted" remains unverified and is this spec's first verification step.*
That question is closed. `pamtester common-auth <user> authenticate`, built
from this flake, accepted the real password against the same patched pam
store path hyprlock loads. And then the stronger proof: with the switch run
and hypridle back up, the user locked the session with SUPER+M and unlocked
it with their real password, from a session with the `nixtest` escape VT
still open. hyprlock is spawned by a systemd unit, not run standalone, and
this project has repeatedly found things that work in one process context and
not another — so the end-to-end test is the one that counts, and it passed.

## A fix nobody was looking for

X11 clients have been rendering in software since spec 1. `nix-session.md`
recorded the symptom in passing — `xwayland glamor: failed to setup GBM
backend, falling back to sw accel` — and moved on, because spec 1 only had
the compositor in view. It sat there for three more specs.

The cause: Debian's Xwayland is a child of the nixGL-wrapped compositor, so it
inherits `LIBGL_DRIVERS_PATH` and `GBM_BACKENDS_PATH` pointing into Nix's
`mesa-26.1.5`, while it links Debian's own
`/lib/x86_64-linux-gnu/libgbm.so.1`. Glamor needs a matching GBM/DRI pair,
gets a mismatched one, and falls back to llvmpipe. The wrapper that makes Nix
binaries work on this machine has been silently breaking a Debian one since
the first spec.

Measured, with identical inherited environment and only the server binary
differing:

| Xwayland | `glxinfo -B` |
|---|---|
| Debian's, live at `:0` | Accelerated: no — llvmpipe (LLVM 21.1.8) |
| `pkgs.xwayland` at `:99` | Accelerated: yes — AMD Radeon 780M, radeonsi, phoenix, ACO |

And confirmed again after the real switch and a reboot, on the live display
rather than a spare one: **Accelerated: no, llvmpipe → Accelerated: yes, AMD
Radeon 780M (radeonsi, phoenix, ACO)**. `pkgs.xwayland` needs no nixGL wrapper
of its own — it is a compositor child and inherits the environment already,
which is exactly what the `:99` test demonstrated before any apt change was
made.

Getting to that measurement took two wrong drafts of the same decision,
worth recording because both failed the same way. The first draft claimed
Nix's Xwayland would not match the hardware — false; nixGL never touched
Debian's Mesa, and Nix's `mesa-26.1.5` already drives this machine. The
second draft conceded that and concluded the choice was free, so Debian's
Xwayland won on the grounds of not duplicating a package apt already
provides — also false, and also never ran `glxinfo`. Only the third draft
measured anything. "It should work the same either way" is a claim about
behaviour, and this project has now paid for that specific claim more than
once.

## Every defect, and who owns it

Four agent-run tasks (the flake overlay, hyprlock's config, Xwayland, the
portal unit) landed with zero fix rounds — every task review came back clean
on the first pass. The defects below were not in that work. They were in the
plan that dispatched it, in the controller's own conduct while it ran, and in
one place that only a cold reboot could show.

**The controller clobbered an implementer's commit with `git add -A`.**
While Task 1's implementer was mid-flight with `flake.nix` staged, the
controller fixed an unrelated plan defect and committed it with `git add -A`
— which sweeps up whatever is staged, and swallowed the implementer's overlay
into a commit whose message described only the plan edit. The implementer
found nothing left to commit, correctly refused to rewrite history it did not
own, and reported back with a diagnosis of "another concurrent session." That
session was the controller. Nothing was lost — the tree content was
byte-identical either way, and it was untangled with a soft reset into two
clean commits (`1847602` for the plan edit, `6b3d3c7` for the overlay) before
the review that would otherwise have been handed a conflated diff. The rule
adopted for the rest of the branch: the controller commits with explicit
paths only, never `-A` or `.`, while any implementer is live. Self-inflicted,
recorded plainly rather than folded into "process notes."

**A verification step built on `ldd` would have returned a false negative.**
The plan's Task 4 told the implementer to decide whether the portal needs a
nixGL wrapper by grepping `ldd` output for GL and Qt symbols. Measured before
dispatch: that returns 0 for quickshell, a binary that demonstrably needs the
wrapper — it reaches "active (running)" and aborts with `status=6/ABRT` on
first draw, because Qt `dlopen`s its platform and GL plugins and they never
appear in `ldd`. This is the same caveat spec 2 already established for
quickshell itself; the plan came close to relearning it the hard way a second
time inside the same project. It was replaced before dispatch with a closure
comparison (portal and quickshell carry an identical qtbase/qtwayland/mesa/
libglvnd shape) and, for the one binary where `ldd`'s dlopen blind spot does
not apply, a direct read of the portal's real binary — `ldd` on
`.xdg-desktop-portal-hyprland-wrapped` shows a plain, non-dlopen `libgbm.so.1`
from Nix's mesa, with none of the driver environment variables present in the
unit's environment to redirect it. Wrapped on that evidence, and it was both
necessary and sufficient: the switch replaced the live portal with the
wrapped one at zero restarts.

**Three drafts of the Xwayland decision, the first two wrong.** Covered
above — worth repeating here as a defect in its own right, because the
recurring shape (a claim asserted instead of measured) is what this section
exists to track.

**The plan told the user the opposite of what the switch would do.** The
whole-branch review ran `sd-switch --dry-run` and found it would restart
`hypridle.service`, whose new `lock_cmd` arms a 300-second idle timer the
moment it restarts — before the authentication gate had been exercised and
before the spare-VT escape was in place. The plan's own text said, in so many
words, "the lock screen is not exercised by the switch." It also claimed
quickshell would restart; the dry run showed quickshell byte-identical
between generations and not restarting at all. This is spec 3's lockout,
re-armed by the very plan written to prevent a repeat of it. Caught before
the user ran anything, in a fix wave the whole-branch review dispatched
alongside the other findings below; hypridle was left stopped after the real
switch until the lock/unlock test passed, per the corrected plan.

**The survivor count was wrong: three assumed, six measured.** The plan's
Non-goals section originally reasoned about "the other three backports
survivors" — the packages marked manual (`quickshell`, `uwsm`, `ydotool`) —
and missed that three more packages (`libcpptrace1`, `libxkbcommon0`,
`libxkbcommon-x11-0`) survive for an unrelated reason: they are
reverse-dependencies of `google-chrome-stable`, `deskflow` and `code`, which
`--autoremove` cannot touch regardless of manual-marking. Caught by the
whole-branch review, before the irreversible apt step, by subtracting the
dry run's 26 proposed removals from the full `apt list --installed | grep
backports` — not by trusting either list alone. Had it shipped, it would have
fired a false drift alarm at the last checkpoint of the one task with no
undo. More on this below.

**Load-bearing session files existed only because of a hand-repair spec 4
made, and the spec never named it.** `dpkg -S` puts both
`/usr/share/wayland-sessions/hyprland.desktop` and `hyprland-uwsm.desktop`
in apt's `hyprland` package, so this removal deletes them. greetd's greeter
reads only two directories, and the login path survives this removal solely
because of `/usr/local/share/wayland-sessions/hyprland-nix.desktop` —
root-owned, not apt-managed, hand-created back in spec 1, covered by no Nix
module and therefore unrestorable by a Home Manager rollback. The
whole-branch review found this and made it a precondition checked before the
irreversible step rather than after, since afterwards there would be nothing
left to check it against.

## The one the reboot caught

Removing apt's `xdg-desktop-portal-hyprland` package took
`/usr/share/dbus-1/services/org.freedesktop.impl.portal.desktop.hyprland.service`
with it. Nix's portal is correct and already in the profile — its `.portal`
file was already shadowing Debian's, and Task 4's review confirmed exactly
that before the switch. But the file the reboot's `Ping` call needed is a
different one, read by a different daemon: `dbus-broker` scans
`XDG_DATA_DIRS` from its own startup environment, set long before uwsm sets
the session's, so `~/.nix-profile/share/dbus-1/services` — correct, present,
and irrelevant — was never searched. The unit sat inactive and
`GDBus.Error:org.freedesktop.DBus.Error.ServiceUnknown: The name is not
activatable` is what a portal-mediated action got instead.

Task 4 checked that the `.portal` file was discoverable and stopped there.
Two files, two consumers, one checked. This is spec 4's `mimeinfo.cache`
lesson arriving again in the same shape: a directory being in
`XDG_DATA_DIRS` for the *session* is not enough when the consumer is a daemon
that read its own environment earlier and never rescans it on a switch.

Fixed by hand first to confirm the mechanism — copying the file to
`~/.local/share/dbus-1/services/` and calling `busctl --user
ReloadConfig` made the `Ping` return, the unit go active, and the Nix wrapped
binary start — then landed properly in `home/services.nix` (commit
`46a7e97`) as an `xdg.dataFile` entry into the same directory, mirroring how
spec 4 placed `.desktop` entries into `~/.local/share/applications` for the
identical reason. The manual reload was needed only because dbus-broker
caches its service directory at startup; a fresh login rescans and needs
none of it.

## The recurring defect, counted

Every prior results document in this series counts instances of the same
failure: enumerating something by reading one syntactic form of it, or
trusting a partial list as though it were the whole one. Spec 2 named three
instances and called it "the recurring root cause." Spec 4 counted eight and
called it the project's signature failure.

This spec has three instances of the same shape, and for the first time two
of the three were caught before they shipped rather than after:

- The survivor count (three assumed, six measured) — caught in the
  whole-branch review, before the irreversible apt step.
- The `ldd`-based nixGL check for the portal — caught before dispatch,
  because the exact same blind spot had already been named once, for
  quickshell, in spec 2.
- The portal's D-Bus service file — not caught. It shipped, and a reboot
  found it, in precisely the shape spec 4's `mimeinfo.cache` defect took:
  two files serving the same feature, read by two different consumers on two
  different schedules, one of them checked and the other assumed covered by
  the first.

This spec is also the first time the project enumerated a removal by asking
the tool rather than reading a list: `apt-get -s remove --autoremove` over
the six named packages, rather than trusting a hand-built table, is what
produced the trustworthy 26-package removal figure and, combined with a
separate `apt list --installed | grep backports`, the correct six-survivor
figure. That combination is real progress — it is why the wrong "three"
never reached the irreversible step. But `apt-get -s` on its own would not
have been enough: it enumerates what `--autoremove` *proposes to remove*, not
what remains installed afterwards. The three-survivor undercount came from
reasoning about the proposal (only manual packages seemed exempt) rather than
measuring the remainder directly. Asking the tool is better than reading a
list; it is not the same as asking the tool the actual question. The
project's overall record on this failure is unchanged in kind and only
narrowly better in outcome — two catches instead of zero, one miss instead
of none.

## What is still true after all five specs

The backports source is gone from `sources.list`. Twenty-five backports
packages have become six, and the packages this spec set out to move —
the lock screen, the portal, Xwayland — are Nix's.

What did not change: the session's own scaffolding is still Debian's. The
systemd user templates that actually run this session —
`wayland-wm@.service`, `wayland-wm-env@.service`, `wayland-session@.target`,
`wayland-session-envelope@.target`, `wayland-session-bindpid@.service` — all
resolve, per `dpkg -S`, to apt's `uwsm` package under
`/usr/lib/systemd/user/`, not to Nix's copy of the same templates sitting
unused in `~/.nix-profile/share/systemd/user` because that directory is
never on systemd's `UnitPath`. The live session runs `/usr/bin/python3
/usr/bin/uwsm aux waitpid …` — Debian's `uwsm`, executing right now — even
though the session is launched through `~/.nix-profile/bin/uwsm`. It survives
this removal only because it is marked manual, so `--autoremove` was never
going to touch it; that is luck, not a design this spec put in place. Six
backports packages remain, frozen at their currently-installed versions and
receiving no further updates from any source, for as long as they stay: the
three held back by `google-chrome-stable`, `deskflow` and `code`
(`libxkbcommon0`, `libxkbcommon-x11-0`, `libcpptrace1`), and the three marked
manual (`quickshell` and `uwsm`, both shadowed by Nix on PATH and therefore
inert as packages; `ydotool`, which is not shadowed, has no Nix build in this
configuration, and is not invoked by anything at runtime).

Five specs in, "the migration is complete" would be an overstatement. The
lock screen, the compositor, the portal, Xwayland and the rest of the user
layer are Nix's. The thing that starts and holds the session together is
still apt's.

## What the next spec inherits

- **Debian's `uwsm` is load-bearing, not incidental**, and removing it needs
  its own spec: the session-lifetime unit
  (`wayland-session-bindpid@.service`, the one carrying
  `OnSuccess=wayland-session-shutdown.target`) hardcodes `/usr/bin/uwsm`
  rather than resolving it by bare name, and Nix's equivalent templates are
  not on any path systemd searches. That spec starts from this measurement,
  not from rediscovering it.
- **`ydotool` has no Nix counterpart and no known consumer.** Give it one or
  remove the apt package; leaving an unowned backports survivor is the state
  this whole project has been working to leave.
- **`/run/opengl-driver` as a symlink to Nix's Mesa** would retire all five
  nixGL wrappers this project has accumulated (`hyprland-nixgl`,
  `quickshell-nixgl`, `hyprpolkitagent-nixgl`, and hyprlock's and the
  portal's from this spec), let the flake drop its `nixgl` input entirely,
  and remove the exact environment mismatch that caused the llvmpipe bug this
  spec fixed by accident. Explicitly out of scope here — it is GL plumbing,
  not backports removal, and it introduces a new root-owned path on a machine
  where this project has otherwise kept root's surface small — but it is the
  cleanest next target on the board.
- **`/etc/pam.d/hyprlock` is dead code, left in place.** hyprlock now reads
  `common-auth`; the old file is harmless and removing a root-owned file to
  tidy up was judged not worth a root action.
- **The rollback story changed with this spec.** Before it, the fallback for
  a broken Nix lock screen was `apt install hyprlock`. After it, there is no
  apt hyprlock to fall back to — the rollback is the previous Home Manager
  generation, full stop.
