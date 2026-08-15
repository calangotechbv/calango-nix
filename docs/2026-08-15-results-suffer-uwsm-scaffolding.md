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
