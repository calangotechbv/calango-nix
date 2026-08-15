# Results: uwsm session scaffolding — suffer

2026-08-15

## What sd-switch said it would do

**Command run** (directly against the `sd-switch` binary, never through the
activation script, never through `home-manager switch`):

```
OLD=$(readlink -f ~/.local/state/nix/profiles/home-manager)
# OLD = /nix/store/x9n1f3h3g5s6lhcdc8fs5n9q1w7506vx-home-manager-generation
NEW=$(sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage')
# NEW = /nix/store/8gfakyl758ximclnappmdg5rbi71jiyh-home-manager-generation
SDSW=/nix/store/dx88dcx0jb6r3zf6n1lcvp2s07iizd94-sd-switch-0.6.3/bin/sd-switch

"$SDSW" --dry-run --verbose \
  --old-units "$OLD/home-files/.config/systemd/user" \
  --new-units "$NEW/home-files/.config/systemd/user"
```

Exit code: `0`.

**Verbatim output:**

```
sd-switch 0.6.3
Options are Options {
    target_manager: User,
    dry_run: true,
    verbose: true,
    timeout: 120s,
    force_systemctl: false,
    old_dir: Some(
        "/nix/store/x9n1f3h3g5s6lhcdc8fs5n9q1w7506vx-home-manager-generation/home-files/.config/systemd/user",
    ),
    new_dir: "/nix/store/8gfakyl758ximclnappmdg5rbi71jiyh-home-manager-generation/home-files/.config/systemd/user",
}
Performing dry-run
Enabling verbose output
Stopping units: app-graphical.slice, background-graphical.slice, fumon.service, wayland-session-bindpid@2963.service, wayland-session-envelope@hyprland\x2dnixgl.desktop.target, wayland-session-xdg-autostart@hyprland\x2dnixgl.desktop.target, wayland-session@hyprland\x2dnixgl.desktop.target, wayland-wm@hyprland\x2dnixgl.desktop.service
Keeping old units: wayland-session-pre@hyprland\x2dnixgl.desktop.target, wayland-wm-env@hyprland\x2dnixgl.desktop.service
Keeping unchanged units: bt-agent.service, hypridle.service, hyprpolkitagent.service, night-light.service, nm-secret-agent.service, quickshell.service, xdg-desktop-portal-hyprland.service
Starting units: app-graphical.slice, background-graphical.slice, fumon.service, wayland-session-bindpid@2963.service, wayland-session-envelope@hyprland\x2dnixgl.desktop.target, wayland-session-xdg-autostart@hyprland\x2dnixgl.desktop.target, wayland-session@hyprland\x2dnixgl.desktop.target, wayland-wm@hyprland\x2dnixgl.desktop.service
```

That block is the plan in full — every line `sd-switch --dry-run` emitted.
The `grep` commands below were run against a scratch copy at
`.superpowers/sdd/2026-08-15-uwsm-session-scaffolding/sd-switch-plan.txt`,
which was git-ignored working state and no longer exists; they are reproduced
for the record, and reproduce identically against the block above.

### Question 1: does `wayland-session-shutdown.target` appear in any *start* action?

**No.** `wayland-session-shutdown.target` does not appear anywhere in the
plan — not in the "Stopping", "Keeping old", "Keeping unchanged", or
"Starting" lists.

Evidence:

```
$ grep -i "wayland-session-shutdown" sd-switch-plan.txt
(no output)
$ grep -iE "graphical-session\.target|graphical-session-pre\.target|xdg-desktop-autostart" sd-switch-plan.txt
(no output)
```

A read-only confirmation of the target's current state:

```
$ systemctl --user is-active wayland-session-shutdown.target
inactive
```

So the specific hazard this task was designed to check for —
`sd-switch` starting `wayland-session-shutdown.target`, which conflicts
with `graphical-session.target` — does not occur in this plan.

### Question 2: does any currently-running session unit appear in a *stop* or *restart* action?

**Yes.** The "Stopping units" and "Starting units" lists are identical sets
of eight units — `sd-switch` prints changed units in both lists (stop, then
start), which reads as a restart. Three of the four units the brief named
by name are in that set:

| Unit named in the brief | In plan? | Where |
|---|---|---|
| `wayland-wm@hyprland\x2dnixgl.desktop.service` | Yes | Stopping **and** Starting (restart) |
| `wayland-session-envelope@hyprland\x2dnixgl.desktop.target` | Yes | Stopping **and** Starting (restart) |
| `wayland-session@hyprland\x2dnixgl.desktop.target` | Yes | Stopping **and** Starting (restart) |
| `wayland-wm-env@hyprland\x2dnixgl.desktop.service` | Present, different treatment | "Keeping old units" — **not** stopped or restarted |

Two more currently-running units not named in the brief's shortlist are also
in the restart set: `wayland-session-xdg-autostart@hyprland\x2dnixgl.desktop.target`
and `wayland-session-bindpid@2963.service`, plus `app-graphical.slice` and
`background-graphical.slice`.

Read-only confirmation that these are in fact the live, running units (not
idle template names):

```
$ systemctl --user is-active \
    'wayland-wm@hyprland\x2dnixgl.desktop.service' \
    'wayland-session@hyprland\x2dnixgl.desktop.target' \
    'wayland-session-envelope@hyprland\x2dnixgl.desktop.target' \
    'wayland-wm-env@hyprland\x2dnixgl.desktop.service' \
    'wayland-session-pre@hyprland\x2dnixgl.desktop.target' \
    fumon.service graphical-session.target wayland-session-shutdown.target
wayland-wm@hyprland\x2dnixgl.desktop.service : active
wayland-session@hyprland\x2dnixgl.desktop.target : active
wayland-session-envelope@hyprland\x2dnixgl.desktop.target : active
wayland-wm-env@hyprland\x2dnixgl.desktop.service : active
wayland-session-pre@hyprland\x2dnixgl.desktop.target : active
fumon.service : active
graphical-session.target : active
wayland-session-shutdown.target : inactive
```

And their current `FragmentPath` shows why `sd-switch` sees them as
changed: every one of them is presently loaded from
`/usr/lib/systemd/user/` (Debian's apt-installed `uwsm` package unit
files), not from `~/.config/systemd/user` (home-manager's territory,
where Task 1's `home/uwsm.nix` lands its copies). Once the new generation
is active, the same instance names would resolve from
`~/.config/systemd/user/*.service`/`*.target` instead, which is a real
content/path change from `sd-switch`'s point of view, hence "restart"
rather than "leave alone":

```
$ systemctl --user show -p FragmentPath,Id \
    'wayland-wm@hyprland\x2dnixgl.desktop.service' \
    'wayland-session@hyprland\x2dnixgl.desktop.target' \
    'wayland-session-envelope@hyprland\x2dnixgl.desktop.target' \
    'wayland-wm-env@hyprland\x2dnixgl.desktop.service'
Id=wayland-wm@hyprland\x2dnixgl.desktop.service
FragmentPath=/usr/lib/systemd/user/wayland-wm@.service

Id=wayland-session@hyprland\x2dnixgl.desktop.target
FragmentPath=/usr/lib/systemd/user/wayland-session@.target

Id=wayland-session-envelope@hyprland\x2dnixgl.desktop.target
FragmentPath=/usr/lib/systemd/user/wayland-session-envelope@.target

Id=wayland-wm-env@hyprland\x2dnixgl.desktop.service
FragmentPath=/usr/lib/systemd/user/wayland-wm-env@.service
```

So: `sd-switch` does not touch `wayland-session-shutdown.target`, but it
does plan to stop-then-start the compositor service itself
(`wayland-wm@hyprland\x2dnixgl.desktop.service`) and the session target
chain around it (`wayland-session@…`, `wayland-session-envelope@…`,
`wayland-session-xdg-autostart@…`, plus the two graphical slices and
`wayland-session-bindpid@2963.service`). Restarting the compositor unit
directly is itself capable of ending the running session, independent of
whether `wayland-session-shutdown.target` is ever started.

### Question 3: what does it intend for `fumon.service`?

**Restart** (stop, then start) — it is in both the "Stopping units" and
"Starting units" lists, and `systemctl --user is-active fumon.service`
confirms it is currently active (loaded today from
`/usr/lib/systemd/user/fumon.service`, the apt package; the new generation
would load it from home-manager's `~/.config/systemd/user/fumon.service`,
newly added by Task 1 and newly listed in
`graphical-session.target.wants/`).

## Phase 1: the switch, run from a TTY

The user logged out of Hyprland, logged in on tty1, ran
`sg nix-users -c 'home-manager switch --flake .#isutton@suffer'` there, and
logged back in through greetd. The switch was never run from inside a
graphical session.

That sequencing was not a precaution that turned out to be unnecessary. The
dry run recorded above lists
`wayland-wm@hyprland\x2dnixgl.desktop.service` -- the compositor unit itself --
in both the stop set and the start set. Run from inside the session, this
switch would have stopped the compositor mid-activation.

### What the units resolve to now

Measured from the restored graphical session:

```
fumon.service                                      ~/.config/systemd/user/fumon.service
wayland-session-bindpid@293521.service             ~/.config/systemd/user/wayland-session-bindpid@.service
wayland-session-waitenv.service                    ~/.config/systemd/user/wayland-session-waitenv.service
wayland-wm-env@hyprland\x2dnixgl.desktop.service   ~/.config/systemd/user/wayland-wm-env@.service
wayland-wm@hyprland\x2dnixgl.desktop.service       ~/.config/systemd/user/wayland-wm@.service
app-graphical.slice                                ~/.config/systemd/user/app-graphical.slice
background-graphical.slice                         ~/.config/systemd/user/background-graphical.slice
wayland-session-envelope@…desktop.target           ~/.config/systemd/user/wayland-session-envelope@.target
wayland-session-pre@…desktop.target                ~/.config/systemd/user/wayland-session-pre@.target
wayland-session-shutdown.target                    ~/.config/systemd/user/wayland-session-shutdown.target
wayland-session-xdg-autostart@…desktop.target      ~/.config/systemd/user/wayland-session-xdg-autostart@.target
wayland-session@…desktop.target                    ~/.config/systemd/user/wayland-session@.target

graphical-session-pre.target                       /usr/lib/systemd/user/graphical-session-pre.target
graphical-session.target                           /usr/lib/systemd/user/graphical-session.target
```

Twelve units moved. The two that did not are `systemd`'s own, not uwsm's --
`dpkg -S` attributes both to the `systemd` package -- and they are expected to
stay where they are for good. A check demanding they move would be a wrong
check.

### Debian's uwsm has stopped executing

Before this switch the session ran
`/usr/bin/python3 /usr/bin/uwsm aux waitpid <pid>` -- apt's uwsm, executing
inside a session otherwise built from Nix. That process is gone:

```
$ pgrep -af "/usr/bin/uwsm"
  (no matches)

$ pgrep -af waitpid
293550 /nix/store/…-util-linux-2.42.2-bin/bin/waitpid -e 293521
```

This is a second, unlooked-for improvement. Debian's
`wayland-session-bindpid@.service` tests for a bare `waitpid` on PATH and falls
back to `uwsm aux waitpid`, a Python reimplementation, when it does not find
one. On this machine it never found one, so every session since spec 1 has
carried that shim. Nix's unit names util-linux's `waitpid` by absolute store
path, so the real binary is used and the Python process is not spawned at all.

### Session health

`fumon`, `quickshell`, `hypridle` and `hyprpolkitagent` all active; no failed
units; the compositor running from
`/nix/store/…-hyprland-0.55.4/bin/Hyprland`.

`xdg-desktop-portal-hyprland.service` is **inactive, and that is correct**.
The unit was checked rather than assumed, because spec 5 shipped a portal
regression that only a reboot caught. Three facts settle it: the unit has
`WantedBy=` empty and has never appeared in
`graphical-session.target.wants/`, so nothing is supposed to start it eagerly;
`busctl --user list --activatable` reports
`org.freedesktop.impl.portal.desktop.hyprland` as `(activatable)`; and
`~/.local/share/dbus-1/services/org.freedesktop.impl.portal.desktop.hyprland.service`
is present, naming the Nix binary and
`SystemdService=xdg-desktop-portal-hyprland.service`. It is D-Bus activated by
design -- spec 5's arrangement -- and starts when a client first asks for it.

### fumon's enablement link merged cleanly

The spec recorded an open question: `home.file` writing into
`graphical-session.target.wants/`, a directory Home Manager's own systemd
module also generates, might collide. It does not. The live directory now
holds seven entries -- Home Manager's six plus `fumon.service` from
`home/uwsm.nix` -- and `fumon.service` is active, loaded from
`~/.config/systemd/user/fumon.service`.

## Phase 2: the gate

Rebooted at 2026-08-15 11:13 and logged in through greetd as normal. This is
the gate that authorises the irreversible step, so it is stated as a rule and
not as a count: **every live session unit must resolve under
`~/.config/systemd/user`, with exactly two permitted exceptions.**

```
fumon.service                                      ~/.config/systemd/user/fumon.service
wayland-session-bindpid@3081.service               ~/.config/systemd/user/wayland-session-bindpid@.service
wayland-session-waitenv.service                    ~/.config/systemd/user/wayland-session-waitenv.service
wayland-wm-env@hyprland\x2dnixgl.desktop.service   ~/.config/systemd/user/wayland-wm-env@.service
wayland-wm@hyprland\x2dnixgl.desktop.service       ~/.config/systemd/user/wayland-wm@.service
app-graphical.slice                                ~/.config/systemd/user/app-graphical.slice
background-graphical.slice                         ~/.config/systemd/user/background-graphical.slice
wayland-session-envelope@…desktop.target           ~/.config/systemd/user/wayland-session-envelope@.target
wayland-session-pre@…desktop.target                ~/.config/systemd/user/wayland-session-pre@.target
wayland-session-shutdown.target                    ~/.config/systemd/user/wayland-session-shutdown.target
wayland-session-xdg-autostart@…desktop.target      ~/.config/systemd/user/wayland-session-xdg-autostart@.target
wayland-session@…desktop.target                    ~/.config/systemd/user/wayland-session@.target

graphical-session-pre.target                       /usr/lib/systemd/user/graphical-session-pre.target
graphical-session.target                           /usr/lib/systemd/user/graphical-session.target
```

The two exceptions are the permitted ones and no others. `dpkg -S` attributes
both to the `systemd` package rather than to `uwsm`, so removing `uwsm` cannot
touch them. This was checked before the plan was written precisely because a
missing `graphical-session.target` would take down every service in this
configuration that is `WantedBy` it.

`session-graphical.slice` does not appear because it is not loaded on this
boot. The gate is written as a rule rather than as a fixed number for exactly
this reason: instance names carry a fresh PID each boot
(`wayland-session-bindpid@3081` here, `@293521` before the reboot) and slices
load on demand, so a count would fail for reasons that have nothing to do with
the migration.

### Health

```
fumon.service                        active
quickshell.service                   active
xdg-desktop-portal-hyprland.service  active
hypridle.service                     active
hyprpolkitagent.service              active

failed units: none
compositor:   /nix/store/…-hyprland-0.55.4/bin/Hyprland
```

The portal is **active on this boot**, where it was inactive immediately after
the Phase 1 switch. Both states were correct, and the pair of observations is
better evidence than either alone: the unit is D-Bus activated, so it is
inactive until a client asks and active once one has. Seeing it come up on its
own confirms the activation path spec 5 built is intact, which is the thing
that regressed in spec 5 and was caught only by a reboot.

### Debian's uwsm, across a boot

```
$ pgrep -af "/usr/bin/uwsm"
  (no matches)

$ pgrep -af waitpid
3170 /nix/store/…-util-linux-2.42.2-bin/bin/waitpid -e 3081
```

The handover survives a reboot: nothing matching `/usr/bin/uwsm` executes, and
the Python `waitpid` shim is still replaced by util-linux's binary.

**Gate verdict: passed.** Phase 3 is authorised.

> **Correction, written after Phase 4.** The two sentences that stood here
> originally — "nothing from apt's `uwsm` executes" and "the package is now
> inert on disk, which is what makes the next step safe to take" — were false
> when written, and they are the sentences that carried the gate to the
> irreversible step.
>
> `pgrep -af "/usr/bin/uwsm"` matches one path. Apt's `uwsm` package also
> installs `/usr/bin/fumon`, and that binary *was* executing at this moment,
> as `fumon.service`'s main process. The check searched for the name it
> expected the leftovers to have. A fourth defective check, in other words,
> and the most consequential of them: it is the one the removal was authorised
> on. See "Every defect, and who owns it" below.

## Phase 3: the irreversible step

### The restore path, built first

```
$ sudo dpkg-repack uwsm
dpkg-deb: building package 'uwsm' in './uwsm_0.26.4+ds-2~bpo13+1_amd64.deb'.

-rw-r--r-- 1 root root 90188 Aug 15 11:16 /root/pkg-archive/uwsm_0.26.4+ds-2~bpo13+1_amd64.deb
```

The file landed in `/root/pkg-archive`, not `~isutton/pkg-archive`, because the
commands ran in a root shell. That is where it is, and the path is written down
here rather than corrected, because a restore path nobody can find is not one.

This mattered: `apt` cannot re-download this package. The backports source went
in spec 5 and no `.deb` was cached, so `/var/lib/dpkg/status` -- the installed
files themselves -- was the only remaining source. Repacking converted those
files back into something installable while they still existed.

### The removal

`apt-get -s remove uwsm` proposed `uwsm` and nothing else, matching the
measured empty `apt-cache rdepends --installed uwsm`. The real removal took
only that package.

```
$ ls /usr/lib/systemd/user/wayland-wm@.service
ls: cannot access '…': No such file or directory

$ dpkg -l uwsm | tail -1
rc  uwsm  0.26.4+ds-2~bpo13+1  amd64  Wayland session manager for standalone compositors
```

`rc` -- removed, config files retained. Apt's unit templates are gone.

### The root-owned enablement link: dangling, and harmless

```
$ ls -l /etc/systemd/user/graphical-session.target.wants/fumon.service
… -> /usr/lib/systemd/user/fumon.service
```

The link survived the removal and now points at a file that no longer exists.
This is one of the two outcomes the spec anticipated, and it is the harmless
one. `systemd` resolves a unit by *name* through the `UnitPath`, and
`~/.config/systemd/user` sits at position 5 against `/etc/systemd/user` at
position 6, so the flake's copy wins:

```
$ systemctl --user cat fumon.service | head -1
# /home/isutton/.config/systemd/user/fumon.service

$ systemctl --user is-active fumon.service
active
```

`fumon` stayed active across the removal. Had the flake not taken ownership of
its `.wants` link in Task 1, this dangling symlink would have been the only
thing enabling it.

### A landmine the plan did not anticipate

`apt` now reports four packages as automatically installed and no longer
required:

```
fuzzel  inotify-tools  libinotifytools0  libnotify-bin
```

They were pulled in as `uwsm` dependencies and became orphans when it went.
**`apt autoremove` must not be run without deciding about `libnotify-bin`
first**, because:

```
$ dpkg -S "$(command -v notify-send)"
libnotify-bin: /usr/bin/notify-send
```

`fumon.service` carries
`ExecCondition=/bin/sh -c "command -v notify-send > /dev/null"`. Remove
`libnotify-bin` and that condition fails, so `fumon` stops starting -- silently
and by design, because a failed `ExecCondition` is not a failed unit. Nothing
would appear in `systemctl --user list-units --state=failed`. The unit would
simply never run again, and the next person to look would find a healthy
system with a service quietly absent.

This is the same shape as the defect that has recurred through this project:
a dependency that is real but invisible to the check being run. It is recorded
here rather than fixed, because fixing it is a scope decision -- either the
flake takes ownership of `notify-send`, or `libnotify-bin` is marked manual --
and neither belongs in a spec about session scaffolding.

> **Resolved after the branch, before it was left.** The flake took ownership.
> `libnotify` is now in `home.packages`, so `notify-send` comes from
> `~/.nix-profile/bin`, which precedes `/usr/bin` on the session `PATH`. All
> four orphans were then removed outright. See "The orphans, resolved" below.

`fuzzel` is referenced nowhere in this flake, `hyprland.lua`, or the quickshell
tree. `inotify-tools` and `libinotifytools0` likewise. They are genuinely
orphaned; only `libnotify-bin` is load-bearing.

### Session state immediately after removal

No failed units. `quickshell`, `hypridle`, `hyprpolkitagent`,
`xdg-desktop-portal-hyprland` and `fumon` all active, with the session still
running from before the removal.

## Phase 4: what the second reboot found

The reboot at 17:35 came up with a failed unit.

```
$ systemctl --user list-units --state=failed
● fumon.service  loaded failed failed  User unit failure monitor

$ journalctl --user -u fumon.service -b
fumon.service: Unable to locate executable 'fumon': No such file or directory
fumon.service: Failed at step EXEC spawning fumon: No such file or directory
fumon.service: Main process exited, code=exited, status=203/EXEC
... (five restarts) ...
fumon.service: Start request repeated too quickly.
```

Not the `libnotify-bin` landmine recorded above: `/usr/bin/notify-send` was
present and the `ExecCondition` exited 0. The failure is `ExecStart`.

### systemd does not use the manager's PATH

`fumon.service` is the one unit in uwsm's set whose `ExecStart` is a bare
name. The comment written into `home/uwsm.nix` in Task 1 claimed that bare
name resolves against the user manager's `PATH`, and that since uwsm's store
`bin` is on that `PATH`, the name would reach Nix's copy. Both halves of the
premise were true. The conclusion was wrong, because the premise is not the
rule systemd applies.

systemd resolves a relative `ExecStart` against a search path fixed **when
systemd was compiled**. The manager's `PATH` does not enter into it. On this
machine:

```
$ systemd-path search-binaries-default
/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
```

No `/nix/store` path can appear in a compile-time constant, so no amount of
environment arrangement could have made the bare name work here.

The bug is invisible on NixOS, whose systemd is patched to search the system
profile. It was invisible on this machine too, for as long as apt's uwsm
supplied `/usr/bin/fumon`.

### What that means about the Phase 2 gate

For the whole of Phase 1 and Phase 2, `fumon.service` was **Nix's unit file
running Debian's binary.**

The Phase 2 gate did not catch it. It could not: it compared
`FragmentPath` for every session unit and confirmed each one resolved under
`~/.config/systemd/user`. Every unit did. The gate measured where the unit
*files* came from and never asked where their *executables* resolved to, so a
unit half-migrated read as fully migrated.

That is the defect this project keeps producing — cataloguing by one
syntactic form and missing the rest — appearing this time in the verification
layer rather than in the thing being verified. Phase 3 was authorised by a
gate with a hole in it. The removal happened to be safe anyway, but it was not
*shown* to be safe.

### The fix

Enumerating all fourteen units first, rather than patching the one that
failed:

```
$ grep -nE '^Exec[A-Za-z]*=' \
    /nix/store/mafjfhm7pyzjk2ry1sp9xxz4lf07q7n3-uwsm-0.26.4/share/systemd/user/*
wayland-session-waitenv.service:15:ExecStart=/nix/store/...-uwsm-0.26.4/bin/uwsm aux waitenv
wayland-wm-app-daemon.service:11:ExecStart=/nix/store/...-uwsm-0.26.4/bin/uwsm aux app-daemon
wayland-session-bindpid@.service:13:ExecStart=/bin/sh -c "... /nix/store/...-util-linux-2.42.2-bin/bin/waitpid ..."
fumon.service:9:ExecCondition=/bin/sh -c "command -v notify-send > /dev/null"
fumon.service:10:ExecStart=fumon
wayland-wm-env@.service:21:ExecStart=/nix/store/...-uwsm-0.26.4/bin/uwsm aux prepare-env -- "%I"
wayland-wm-env@.service:22:ExecStopPost=/nix/store/...-uwsm-0.26.4/bin/uwsm aux cleanup-env
wayland-wm@.service:22:ExecStart=/nix/store/...-uwsm-0.26.4/bin/uwsm aux exec -- %I
```

Eight `Exec*` directives across six of the fourteen units. Seven carry a fully
substituted store path; `fumon.service`'s `ExecStart` is the only relative one
— a single miss in nixpkgs' substitution, invisible on the platform nixpkgs
targets.

**That command is not the one this section originally showed.** The first
version listed the directive names by hand — `ExecStart|ExecStop|ExecCondition|ExecStartPre|ExecStartPost|ExecReload`
— and so returned seven lines rather than eight, missing
`wayland-wm-env@.service`'s `ExecStopPost=`. The missed line happens to be
absolute, so the conclusion held. But the enumeration was being offered as
proof that the patch was minimal rather than lucky, and it was itself an
incomplete enumeration produced by cataloguing one syntactic form by hand —
inside the section diagnosing exactly that. Found by the final branch review,
not by me. `^Exec[A-Za-z]*=` is the pattern that cannot miss one.

`home/uwsm.nix` patches the relative directive inside the `uwsmUnits`
derivation:

```nix
test -x ${pkgs.uwsm}/bin/fumon
substituteInPlace "$out/fumon.service" \
  --replace-fail 'ExecStart=fumon' 'ExecStart=${pkgs.uwsm}/bin/fumon'
```

`--replace-fail` rather than `--replace`, so that upstream substituting the
path itself becomes a build error here instead of a stale patch that silently
does nothing.

That is still an exact check on one byte string, and exact checks are what
this whole document is about. It says nothing about a *different* relative
`Exec` appearing in some other unit on the next nixpkgs bump — which is the
same failure, in a file whose name the unit-set check would have approved. So
the derivation also asserts the property itself, over every unit at once:

```sh
relative="$(
  grep -hE '^Exec[A-Za-z]*=' "$out"/* \
    | sed -E 's/^Exec[A-Za-z]*=//; s/^[@:+!-]+//' \
    | awk 'NF && $1 !~ /^\// { print }'
)" || true
[ -n "$relative" ] && { ...; exit 1; }
```

`^Exec[A-Za-z]*=` there for the same reason as above: a hand-written list of
directive names is the bug. Both guards were verified by mutation — the
unit-set check by adding a name that does not exist, the relative-Exec check
by pointing the substitution at a bare name and confirming the build fails
with the message above.

### The gate, re-run on a clean boot

Boot at 17:46, after the fix.

```
$ systemctl --user list-units --state=failed
0 loaded units listed.

$ systemctl --user show fumon.service -p MainPID -p NRestarts -p ExecStart
MainPID=3465
NRestarts=0
ExecStart={ path=/nix/store/...-uwsm-0.26.4/bin/fumon ; ... }

$ tr '\0' ' ' < /proc/3465/cmdline
/nix/store/...-bash-interactive-5.3p9/bin/sh /nix/store/...-uwsm-0.26.4/bin/.fumon-wrapped

$ grep -c '/usr/' /proc/3465/maps
0
```

`NRestarts=0` matters: it started on the first attempt at boot, which a warm
`systemctl start` after the switch could not have demonstrated. Zero `/usr/`
mappings in the running process is the executable-provenance check the Phase 2
gate should have made.

The full provenance table, in the same form Phases 1 and 2 used:

```
fumon.service                                    /home/isutton/.config/systemd/user/fumon.service
wayland-session-bindpid@3095.service             /home/isutton/.config/systemd/user/wayland-session-bindpid@.service
wayland-session-waitenv.service                  /home/isutton/.config/systemd/user/wayland-session-waitenv.service
wayland-wm-env@hyprland\x2dnixgl.desktop.service /home/isutton/.config/systemd/user/wayland-wm-env@.service
wayland-wm@hyprland\x2dnixgl.desktop.service     /home/isutton/.config/systemd/user/wayland-wm@.service
app-graphical.slice                              /home/isutton/.config/systemd/user/app-graphical.slice
background-graphical.slice                       /home/isutton/.config/systemd/user/background-graphical.slice
graphical-session-pre.target                     /usr/lib/systemd/user/graphical-session-pre.target
graphical-session.target                         /usr/lib/systemd/user/graphical-session.target
wayland-session-envelope@…desktop.target         /home/isutton/.config/systemd/user/wayland-session-envelope@.target
wayland-session-pre@…desktop.target              /home/isutton/.config/systemd/user/wayland-session-pre@.target
wayland-session-shutdown.target                  /home/isutton/.config/systemd/user/wayland-session-shutdown.target
wayland-session-xdg-autostart@…desktop.target    /home/isutton/.config/systemd/user/wayland-session-xdg-autostart@.target
wayland-session@…desktop.target                  /home/isutton/.config/systemd/user/wayland-session@.target
```

Twelve under `~/.config/systemd/user`. `graphical-session.target` and
`graphical-session-pre.target` remain `/usr/lib/systemd/user`, which is
correct — they belong to systemd, not to uwsm. Neither `/usr/bin/uwsm` nor
`/usr/bin/fumon` exists. All five services active:

```
fumon.service                            active
quickshell.service                       active
xdg-desktop-portal-hyprland.service      active
hypridle.service                         active
hyprpolkitagent.service                  active
```

The package states, using the corrected status check rather than the
version check discussed below:

```
$ dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' …
ii  libcpptrace1        1.0.4-2~bpo13+1
ii  libxkbcommon0       1.13.1-1~bpo13+1
ii  libxkbcommon-x11-0  1.13.1-1~bpo13+1
ii  quickshell          0.3.0-1~bpo13+1
ii  ydotool             1.0.4-2~bpo13+1
rc  uwsm                0.26.4+ds-2~bpo13+1

$ dpkg -L uwsm
Package 'uwsm' does not contain any files (!)
```

Five installed, one removed with nothing left behind — not even conffiles,
which is cleaner than `rc` normally implies.

Finally, the flake still evaluates and builds:

```
$ sg nix-users -c 'nix eval .#homeConfigurations --apply builtins.attrNames'
[ "isutton@suffer" ]
$ sg nix-users -c 'nix build --no-link --print-out-paths \
    .#homeConfigurations."isutton@suffer".activationPackage'
/nix/store/pdpxm3sqd3fhcwqf7skbln255mp4wb90-home-manager-generation
```

That store path is the generation the session is running, so the tree, the
build and the live system all agree.

### Two more checks that could not have failed

Running Phase 4 as written turned up two further checks that do not test what
they claim.

```
$ dpkg-query -W -f='${Version}' uwsm
0.26.4+ds-2~bpo13+1
$ echo $?
0
```

The plan's survivor count used `dpkg-query -W -f='${Version}'` and treated a
non-zero exit as `GONE`. For a package in `rc` state — removed, conffiles
retained, which is exactly what `apt remove` leaves — `dpkg-query` prints the
version and exits 0. The check would have counted `uwsm` among the survivors
and reported six. Asking for the status field instead:

```
$ dpkg-query -W -f='${db:Status-Abbrev}' uwsm
rc
```

Five installed, one `rc`, and `dpkg -L uwsm` lists no file that still exists
on disk.

The second: `pgrep -x fumon`, the plan's bare-name resolution check, matches
nothing at all. Nix wraps the binary, so the process is `.fumon-wrapped`. The
check printed an empty result during the failure and would have printed the
same empty result on success. It was incapable of distinguishing the two
states it existed to distinguish.

Three checks in this spec's own verification — the Phase 2 gate, the survivor
count, and the bare-name resolution — were unable to detect the condition they
were written to detect. All three failed the same way: they measured a proxy
that was easier to reach than the property, and the proxy held while the
property did not.

## Did it work?

| Question | Before | After |
|---|---|---|
| What supplies the session's unit templates? | `/usr/lib/systemd/user` (apt's uwsm), position 15 | `~/.config/systemd/user` (the flake), position 5 |
| What does `wayland-wm@` execute? | `/usr/bin/uwsm` (Debian) | `/nix/store/…-uwsm-0.26.4/bin/uwsm` |
| What does `wayland-session-bindpid@` execute? | Debian's Python shim, `uwsm aux waitpid` | `/nix/store/…-util-linux-2.42.2-bin/bin/waitpid -e` |
| What does `fumon.service` execute? | `/usr/bin/fumon` (Debian) — while its unit file was already Nix's | `/nix/store/…-uwsm-0.26.4/bin/fumon` |
| `uwsm` package state | `ii 0.26.4+ds-2~bpo13+1` | `rc` — removed, and `dpkg -L` reports no file left on disk |
| backports packages installed | 6 | 5 |
| Two copies of uwsm able to drift apart? | yes — Debian's units calling Debian's binary, Nix's binary on `PATH` | no — one copy, pinned by the flake |

Six rows are wins. The fourth is the interesting one, and it was not a win
until the last reboot of the spec: for the whole of Phase 1 and Phase 2 that
row read *Nix's unit file, Debian's binary*, and nothing in the plan was
capable of noticing.

## Every defect, and who owns it

### The spec asserted `home.file` units sit outside sd-switch's set. False.

**Owner: the spec's first draft. Caught before implementation.**

The draft argued that because the units are installed through `home.file`
rather than `systemd.user.services`, Home Manager's `sd-switch` integration
would not see them, so activation could not disturb a running session.

Reading the generated activation script disproved it:

```
sd-switch --old-units $oldGenPath/home-files/.config/systemd/user \
          --new-units $newGenPath/home-files/.config/systemd/user
```

`sd-switch` runs against **directories**, not against Home Manager's list of
module-declared units — and `home-files/.config/systemd/user` is precisely
where `home.file` entries land. All fourteen would be seen as newly added.

Cost if it had shipped: a `home-manager switch` run from inside the desktop
session, restarting the compositor unit out from under it. The correction
added Phase 0 (read the dry run) and Phase 1 (switch from a TTY), which is
what made the rest of the spec safe.

### The same spec named the wrong mechanism for the hazard it correctly predicted.

**Owner: the spec. Caught by Task 2's dry run.**

Having identified the risk, the spec attributed it to
`wayland-session-shutdown.target` and its `Conflicts=graphical-session.target`.
The actual dry-run plan does not mention that target at all. The real
mechanism is an ordinary stop-then-start of
`wayland-wm@hyprland\x2dnixgl.desktop.service`.

Right risk class, wrong mechanism. Worth recording because the mitigation the
flawed reasoning produced — sequence the first switch from a TTY — was
correct for the real mechanism too. The plan was saved by a precaution
derived from a wrong premise, which is luck, not method.

### `home/uwsm.nix` documented a rule systemd does not have.

**Owner: Task 1. Caught by Task 6, after the irreversible step.**

Covered in full under Phase 4 above. The comment asserted that a bare
`ExecStart` resolves against the service manager's `PATH`. It does not; it
resolves against a path fixed when systemd was compiled. The premise was
checked and true, the conclusion was false, and the two were connected by a
rule that was never verified.

This is the only defect in the spec that reached a reboot, and it reached one
because it was written into a comment as though it were a measurement.

### Five of this spec's own checks could not detect what they tested for.

**Owner: the plan. Two caught in Task 6, three only by the final review.**

| Check | Claimed to establish | What it actually did |
|---|---|---|
| The Phase 2 gate | the session runs on Nix | compared `FragmentPath` only — passed a unit whose binary was Debian's |
| `pgrep -af "/usr/bin/uwsm"` | nothing from apt's uwsm executes | matches one path; apt's uwsm also ships `/usr/bin/fumon`, which *was* running |
| `dpkg-query -W -f='${Version}'` | `uwsm` is gone | prints a version and exits 0 for `rc` packages; would have reported six survivors |
| `pgrep -x fumon` | fumon resolves into the store | matches nothing ever — Nix wraps it as `.fumon-wrapped`; empty output in both states |
| the hand-listed `Exec*` grep | every Exec directive was enumerated | omitted `ExecStopPost=`; returned seven of eight lines |

The first two are the serious ones, and they are the same mistake twice:
both were run as the gate on Phase 3, and Phase 3 is not reversible through
apt. The removal was safe. That it was safe was not established at the time it
was taken — the gate could not see the condition that failed two reboots
later, and the sentence declaring apt's uwsm inert was false as written.

The fifth is the one with a lesson about this document rather than about the
system: it was the enumeration offered as evidence that the fix was minimal,
and it was incomplete in exactly the way the surrounding paragraphs describe.
It was caught by a reviewer, after the branch had already been declared
finished.

### A landmine the plan did not anticipate

Recorded in full under Phase 3 above: removing `uwsm` orphaned
`libnotify-bin`, which provides `notify-send`, which is `fumon.service`'s
`ExecCondition`. `apt autoremove` would stop `fumon` starting without
producing a failed unit.

Fixed after the branch was otherwise finished — see "The orphans, resolved"
below. Worth noting how it was found: not by any check in this plan, but by
reading the list of packages `apt` reported as newly orphaned and asking what
each one did. The plan had no step for that, and the four names would
otherwise have scrolled past as noise.

## The recurring defect, counted

Spec 5's results document named this project's signature defect: cataloguing
by one syntactic form and missing the rest. Spec 6 produced five more
instances, and the shape has shifted.

1. `home/uwsm.nix` guards against it directly — the hardcoded unit list is
   cross-checked against the real directory at build time, so a stale list is
   a build error. That guard worked; the unit *set* never drifted.
2. But the guard checked the set of unit **names** and nothing about their
   **contents**. `ExecStart=fumon` sat inside a file the check had already
   approved.
3. The gate that authorised the irreversible removal searched for
   `/usr/bin/uwsm` — one name from a package that installs several — and
   declared the package inert while `/usr/bin/fumon` was running.
4. Two verification commands (`dpkg-query` on version, `pgrep -x fumon`) were
   incapable of returning a distinguishing answer at all.
5. The `Exec*` enumeration written to prove the fix was minimal listed the
   directive names by hand and missed `ExecStopPost=`.

The pattern across all five: **a check that measures a proxy because the proxy
is easier to reach than the property.** File names instead of file contents.
Unit paths instead of executable paths. One binary's name instead of a
package's file list. Exit codes instead of package states. A hand-written list
of directive names instead of the directive syntax. Each proxy held while the
property it stood for did not.

The last three were found by reviewers rather than by running the plan, two of
them after the work had been called finished. That is the honest summary of
this spec's method: the checks it wrote were weaker than the checks it wrote
*about*, and the gap was closed by someone reading them adversarially rather
than by the checks themselves failing.

The code now asserts the property instead of a proxy: every `Exec*` value in
every unit must be an absolute path, matched by directive *syntax* rather than
by a list of names. That is the one guard here that could have caught the
defect that reached a reboot.

## The orphans, resolved

Removing `uwsm` left four orphaned Debian packages. All four are now gone, and
the one that mattered is owned by the flake instead.

| Package | Was it needed? | Outcome |
|---|---|---|
| `libnotify-bin` | **yes** — `notify-send`, `fumon.service`'s `ExecCondition` *and* its runtime notification command | replaced by `pkgs.libnotify` in `home.packages`; removed |
| `inotify-tools` | no — nothing on this system invokes `inotifywait`/`inotifywatch` | replaced by `pkgs.inotify-tools` anyway, as an interactive tool; removed |
| `libinotifytools0` | no — library for the above | removed |
| `fuzzel` | no — unreferenced in the flake, `hyprland.lua`, the quickshell tree and `~/.config`; no config directory; not running | removed, not replaced |

A fifth package went with them, not orphaned by the removal but found by the
same sweep:

| Package | Was it needed? | Outcome |
|---|---|---|
| `ydotool` | no — no reference in the flake, `hyprland.lua`, the quickshell tree, `~/.config`, or any keybind | removed, not replaced |

`ydotool` had been deferred since spec 1 as "dev tier, belongs to spec 3", and
the deferral was never revisited. Meanwhile apt's `ydotool.service` kept a
`ydotoold` daemon running as the user with `/dev/uinput` open and
`Restart=always` — the capability to synthesise arbitrary keyboard and mouse
input into the session, with nothing consuming it. It held the only open
handle on that device, and its package owned the only udev rule referencing
it:

```
KERNEL=="uinput", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput"
```

So the removal took the whole uinput surface with it. `nixpkgs#ydotool` is
1.0.4, the same version Debian shipped, if a consumer ever appears — but that
rule would have to be recreated by hand in `/etc/udev/rules.d/`, since a
standalone Home Manager cannot install udev rules. Verified after removal: no
binaries, no daemon, no unit, no rule, zero package files on disk.

Like `uwsm`, it left a dangling root-owned enablement symlink at
`/etc/systemd/user/default.target.wants/ydotool.service`, which kept the unit
visible to `systemctl --user` as `loaded inactive dead` until it was deleted.
Second occurrence of that pattern in one spec: **removing a Debian package
that ships a systemd *user* unit leaves its `/etc` enablement link behind.**
Worth expecting rather than rediscovering.

`libnotify4` — the shared library, a different package from `libnotify-bin` —
stays, with ten installed dependents. It was eleven before `fuzzel` went.

### Why the ExecCondition was safe to move to Nix, when ExecStart was not

The two look like the same problem and are not:

```
ExecStart=fumon                                          <- broke
ExecCondition=/bin/sh -c "command -v notify-send ..."    <- fine
```

`ExecStart` was a bare name resolved by systemd itself, against the
compile-time search path that contains no `/nix/store`. The `ExecCondition`
runs an **absolute** `/bin/sh`, and `command -v` inside that shell searches
the service's real `$PATH` — where `~/.nix-profile/bin` sits at position 18
against `/usr/bin` at 22. Putting `notify-send` in the profile is therefore
sufficient, and no unit patching was needed.

### Verified after the removal

```
$ command -v notify-send inotifywait
/home/isutton/.nix-profile/bin/notify-send
/home/isutton/.nix-profile/bin/inotifywait

$ systemctl --user show fumon.service -p ActiveState -p NRestarts -p MainPID
ActiveState=active
NRestarts=0
MainPID=3465

$ systemd-run --user --pipe --wait /bin/sh -c 'command -v notify-send'
/home/isutton/.nix-profile/bin/notify-send        # the ExecCondition, in the service environment

$ apt-get -s autoremove
0 upgraded, 0 newly installed, 0 to remove and 138 not upgraded.
```

`MainPID` is unchanged from the boot at 17:46 and `NRestarts` is still 0, so
`fumon` never restarted through any of this — the swap happened underneath a
running process that had already passed its condition.

The check that matters is the last one, and it is deliberately not a proxy. A
passing `ExecCondition` proves only that `notify-send` is *findable*. A real
notification was sent through the session bus and rendered: the daemon
answering `org.freedesktop.Notifications` identifies itself as `quickshell
1.2`. Findable, and working.

## What is still true

### Four backports packages remain, and none of them is pinned by anything

```
$ dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' …
ii  libcpptrace1        1.0.4-2~bpo13+1
ii  libxkbcommon0       1.13.1-1~bpo13+1
ii  libxkbcommon-x11-0  1.13.1-1~bpo13+1
ii  quickshell          0.3.0-1~bpo13+1
rc  uwsm                0.26.4+ds-2~bpo13+1
rc  ydotool             1.0.4-2~bpo13+1
```

Six at the start of this spec, four at the end: `uwsm` went in Phase 3 and
`ydotool` went after it, both now `rc` with no files on disk.

The backports suite is not in `sources.list` or `sources.list.d` — spec 5
removed it. `apt-cache policy` shows what that means for each survivor:
`libcpptrace1` and `quickshell` have **no downloadable source at all**,
existing only in `/var/lib/dpkg/status` at priority 100. They are frozen in
the same sense `uwsm` was: removable, but restorable only from a
`dpkg-repack` taken beforehand.

**Correction to the record.** Spec 5's results document said the xkbcommon
pins were held by three packages; this plan's Task 7 brief said four, naming
`google-chrome-stable`, `deskflow`, `kwin-x11` and `code`. Both are wrong,
and wrong in kind rather than in count:

```
$ # installed (ii) packages depending on libxkbcommon0 or -x11-0
42
$ # the highest version constraint any of them expresses
1.0.0    kitty, kdeconnect, fuzzel, foot, deskflow
0.7.0~   kwin-x11
```

Forty-two installed packages depend on these libraries, and the strongest
constraint among them is `>= 1.0.0`. Trixie's own `libxkbcommon0` is
`1.7.0-2`, which satisfies every one of them. **Nothing requires the
backport.** The earlier documents counted packages that depend on the
*package* and described them as holding the *backport version* — a third
instance of the proxy problem, in the record rather than in a script.

What this means practically is left for a later spec: these two are the only
survivors that could be returned to trixie's own version rather than frozen,
and whether that is worth a downgrade is a question this spec did not ask.

### Debian's Hyprland stack is fully gone

```
$ dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' hyprlock hyprland
dpkg-query: no packages found matching hyprland
rc  hyprlock
```

`hyprland` is not present in any state; `hyprlock` is `rc`. This confirms the
correction made to `home/session.nix:73` in Task 1 — the comment there had
justified prepending to `PATH` on the premise that apt's Hyprland, `hyprctl`
and `hyprlock` were all still installed under `/usr/bin`, and that premise had
expired. Note that `hyprlock` being `rc` is why it still appears in raw
`dpkg-query` dependency scans; filtering to `ii` is required to get an honest
answer, which is how the 42-package count above was produced.

### One file outside `$HOME`

```
$ ls -l /usr/local/share/wayland-sessions/
-rw-r--r-- 1 root root 288 Aug 14 03:25 hyprland-nix.desktop
```

Still the only thing this project installs outside the home directory, and
still necessary — greetd reads session desktop files from system paths.

## What the next spec inherits

**`ydotool` is resolved — removed, not inherited.** It was one commit, as
predicted. Recorded in "The orphans, resolved" above alongside the other four
removals; the short version is that three specs had carried it forward as
"dev tier, belongs to spec 3" while nothing was ever built that used it. No
reference in the flake, `hyprland.lua`, the quickshell tree or `~/.config`,
and no keybind. What it did have was `ydotool.service` keeping a `ydotoold`
daemon alive with `/dev/uinput` open — synthetic keyboard and mouse input for
no consumer — restarted forever by `Restart=always`.

Two corrections to the record it produced on the way out: `ydotoold` was
running as **one** process (`3048`), not the two this plan's brief carried;
and the deferral itself was wrong. "Belongs to spec 3" was written in spec 1
and never re-examined, so a running daemon with an input-injection capability
survived three specs on the strength of a comment nobody re-read. Deferral
notes expire the same way premises do.

**The rollback rule is permanently inverted.** Before this spec, a previous
Home Manager generation was always a safe recovery path. It is not any more.
Apt's uwsm units are gone and only the current generation supplies
replacements, so rolling back produces a system with no session scaffolding
at all. Recovery is now: fix forward with `home-manager switch` from tty1, or
`sudo dpkg -i /root/pkg-archive/uwsm_0.26.4+ds-2~bpo13+1_amd64.deb`. Note the
repack lives in **root's** home, not `~isutton`.

**`ttyautolock` and `wait-tray` are not on the system** — neither is on
`PATH` after the removal. This document does not assert they came from
`uwsm`: verifying that requires reading the repacked `.deb`, which needs root,
and it was not done. If either turns out to be wanted, note that Nix's
`pkgs.uwsm` ships neither — its `bin/` is `fumon`, `uuctl`, `uwsm`,
`uwsm-app`, `uwsm-terminal`, `uwsm-terminal-scope`, `uwsm-terminal-service`.

**`/run/opengl-driver` is still open and still demoted.** `mesa-26.1.5`
carries no `/run/opengl-driver` reference, so only libglvnd's EGL vendor
lookup is covered by the symlink. The claim that it retires all five nixGL
wrappers is not established. See the amended bullet in spec 5's results
document.

**The verification lesson is the one worth carrying.** Every check this spec
wrote that compared a path or an exit code passed while the thing it stood
for was false. Checks that read a running process — `/proc/PID/cmdline`,
`/proc/PID/maps`, `NRestarts` — did not. A gate that authorises an
irreversible step should measure the running system, not the files that are
supposed to describe it.
