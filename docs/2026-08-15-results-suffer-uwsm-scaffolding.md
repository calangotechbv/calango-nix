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

Full output is also saved at
`.superpowers/sdd/2026-08-15-uwsm-session-scaffolding/sd-switch-plan.txt`.

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

The handover survives a reboot: nothing from apt's `uwsm` executes, and the
Python `waitpid` shim is still replaced by util-linux's binary. The package is
now inert on disk, which is what makes the next step safe to take.

**Gate verdict: passed.** Phase 3 is authorised.

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
systemd was compiled** — on Debian, `/usr/local/bin:/usr/bin:/bin` and the
`sbin` variants. The manager's `PATH` does not enter into it. No `/nix/store`
path can appear in a compile-time constant, so no amount of environment
arrangement could have made the bare name work here.

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
$ grep -nE '^(ExecStart|ExecStop|ExecCondition|ExecStartPre|ExecStartPost)=' \
    /nix/store/mafjfhm7pyzjk2ry1sp9xxz4lf07q7n3-uwsm-0.26.4/share/systemd/user/*
wayland-session-waitenv.service:15:ExecStart=/nix/store/...-uwsm-0.26.4/bin/uwsm aux waitenv
wayland-wm-app-daemon.service:11:ExecStart=/nix/store/...-uwsm-0.26.4/bin/uwsm aux app-daemon
wayland-session-bindpid@.service:13:ExecStart=/bin/sh -c "... /nix/store/...-util-linux-2.42.2-bin/bin/waitpid ..."
fumon.service:9:ExecCondition=/bin/sh -c "command -v notify-send > /dev/null"
fumon.service:10:ExecStart=fumon
wayland-wm-env@.service:21:ExecStart=/nix/store/...-uwsm-0.26.4/bin/uwsm aux prepare-env -- "%I"
wayland-wm@.service:22:ExecStart=/nix/store/...-uwsm-0.26.4/bin/uwsm aux exec -- %I
```

Thirteen of fourteen carry a fully substituted store path. `fumon.service` is
the only relative `Exec` line in the set — a single miss in nixpkgs'
substitution, invisible on the platform nixpkgs targets.

`home/uwsm.nix` now patches it inside the `uwsmUnits` derivation:

```nix
substituteInPlace "$out/fumon.service" \
  --replace-fail 'ExecStart=fumon' 'ExecStart=${pkgs.uwsm}/bin/fumon'
```

`--replace-fail` rather than `--replace`, so that upstream substituting the
path itself becomes a build error here instead of a stale patch that silently
does nothing. Same contract as the unit-set check beside it: the build is
required to tell us when its input moves. The guard was verified by mutating
the pattern to one that does not occur — the build fails, as intended.

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

Twelve units resolve under `~/.config/systemd/user`.
`graphical-session.target` and `graphical-session-pre.target` remain
`/usr/lib/systemd/user`, which is correct — they belong to systemd, not to
uwsm. Neither `/usr/bin/uwsm` nor `/usr/bin/fumon` exists. All five services
active.

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
