# Spec 12: defuse the apt orphan backlog — suffer

2026-08-17. Branch `apt-orphan-backlog`.

## The problem

`apt-get -s autoremove` removes **137 packages** on this machine today. None of
them was orphaned by anything this spec proposes to do. They are the accumulated
residue of every earlier spec's removals — thunar, pcmanfm-qt, kitty, emacs,
deskflow, and the lxqt and xscreensaver families — none of which read the "no
longer required" list at the moment of removal and acted on it.

`CLAUDE.md` already records this failure twice, in its own words:

> An apt removal orphans packages the Nix side still needs. […] Neither goes at
> removal time; an unmarked orphan goes to some later `apt autoremove`, by which
> point the breakage gets blamed on something else entirely.

`rtkit` and `pulseaudio-utils` were both rescued by hand after that lesson. The
rule was written down and then not applied for four more specs, which is why the
number is 137 rather than a handful.

The risk is not that the packages are installed. It is that a single
`apt autoremove` — run casually, or suggested by apt after any unrelated
operation — sweeps all 137 at once, and the resulting breakage looks like
whatever was changed most recently rather than like this.

## Why "in use" is not the test

The obvious approach is to run the union in-use check `CLAUDE.md` mandates —
`/proc` `maps` and `exe` for every process, unioned with the first field of
`ps -eo args`, resolved through `dpkg -S` — and mark whatever it flags as manual.

That approach was tried during this design and **it is wrong**. It flagged six
packages, and four of them do not survive inspection:

| orphan | held by | verdict |
|---|---|---|
| `libmng1`, `qt6-image-formats-plugins` | pid 3790 `/usr/bin/deskflow` | **Dead.** `deskflow` was removed in spec 10. This is a stale process of a deleted package, and `CLAUDE.md` records that removing a package does not kill its process. The hit measures history, not need. |
| `xscreensaver` | pid 28847 `foot` | **Dead.** The held file is a *font*, `/usr/share/fonts/xscreensaver/gallant12x22.ttf`, mmapped by fontconfig. `CLAUDE.md` records that a running process keeps deleted fonts mmapped. Restart terminals first, then it goes. |
| `gir1.2-notify-0.7`, `python3-cups` | pid 3823 `system-config-printer/applet.py` | **Decision needed.** A live feature — the printer applet. Note `system-config-printer` is itself in the orphan list. |
| `gvfs-fuse` | pid 4116 `gvfsd-fuse` | **Decision needed.** A live service backing `/run/user/1000/gvfs`. Thunar and pcmanfm-qt are gone and `lf` is the file manager now, so its consumer may also be gone. |

Three distinct false-positive shapes in a sample of six. So the design's central
rule is: **a hit is not a keep.** Every hit must be classified by *why* the file
is held, and only a live, wanted consumer justifies keeping the package.

## Goal

`apt-get -s autoremove` removes nothing, and every one of the 137 is either

- deliberately removed, or
- deliberately marked manual, with the reason recorded.

No package is left in the "orphaned and unexamined" state that created this
problem.

## Scope

The 137, profiled by name to show where the work is. The bins are applied in the
order listed and are mutually exclusive, so they sum to the census — a first
attempt at this table used overlapping patterns and summed to 150, which is the
same defect as every other number in this project that did not close:

```
library      lib*                 76    mostly Qt5/Qt6, xfce and lxqt libraries
                                        of packages already gone
everything else                   30    where the decisions live
translation  *-l10n                9
lxqt session lxqt*                 8
data         *-data, *-common      7
typelib      gir1.2-*              4
             python3-*             3
                                 ---
                                  137
```

The 30 that are not obviously a library or data file of something already gone:

```
avahi-utils cups-pk-helper emacs-el exo-utils ffmpegthumbnailer galternatives
gnome-accessibility-themes gnome-themes-extra gtk2-engines-pixbuf gvfs-fuse
install-info kitty-doc kitty-shell-integration kitty-terminfo lximage-qt m17n-db
pnp.ids qlipper qps qt5-gtk-platformtheme qt6-image-formats-plugins qtwayland5
system-config-printer system-config-printer-udev tumbler xaw3dg xfconf
xscreensaver xscreensaver-gl xsettingsd
```

**Out of scope:** migrating anything to Nix. This spec only resolves the state of
packages apt already considers unnecessary. `signal-desktop` and `bitwarden` were
the next migration candidates and are deliberately deferred, because adding two
removals to an armed backlog is the wrong order.

## Method

Every step enumerates by syntax. No step consults a list saved by an earlier
step, because a saved list is what this whole problem is made of.

**Phase 1 — census.** Re-derive the set:

```sh
apt-get -s autoremove | awk '/^Remv /{print $2}' | sort -u
```

Record the count and the full list. If it is not 137, say so and use the number
measured, not this document's.

**Phase 2 — the union in-use check**, over that set:

```sh
# every process's exe and every mapped path, plus every argv[0]
for p in /proc/[0-9]*; do
  readlink "$p/exe"
  awk '{print $NF}' "$p/maps" | grep '^/'
done
ps -eo args= | awk '{print $1}' | grep '^/'
```

resolved through `dpkg -S` and intersected with the census. `/proc/<pid>/maps` is
unreadable for other users' processes and root outnumbers the user roughly 3:1
here, so the `ps` half is not optional — a `/proc`-only walk covers about a
quarter of the system.

**Phase 3 — classify every hit by why.** For each, name the holding process and
decide which shape it is:

- a stale process of an already-removed package → **dead**
- a font or other data file held by fontconfig mmap → **dead**, but restart the
  holding applications before removal
- a live consumer that is itself in the census → **dead**, unless the consumer is
  wanted, in which case both are keeps
- a live, wanted consumer → **keep**

A hit with no explanation is a **keep**, on the conservative rule below.

**Phase 4 — the decision list.** Bring to the user only the packages whose fate
turns on whether a feature is wanted. From this design's sample that is expected
to be the printer applet (`system-config-printer`, `system-config-printer-udev`,
`cups-pk-helper`, `python3-cups`, `gir1.2-notify-0.7`), `gvfs-fuse`, and
`xscreensaver` with its `-gl` and `-data` companions. Do not decide these alone.

**Phase 5 — mark, then remove.** The user runs both. Mark the keepers first, so
that the removal cannot take them:

```sh
sudo apt-mark manual <keepers>
apt-get -s autoremove          # read this plan in full before the next line
sudo apt autoremove
```

The simulated plan is recorded in the results document *before* the real removal
runs, so the two can be compared afterwards.

**Phase 6 — endpoint.** `apt-get -s autoremove` must report nothing to remove.
Verify the desktop after a reboot rather than before: `CLAUDE.md` records that
absence is only measurable once the session ends.

**Phase 7 — the guard.** Add a non-fatal activation warning when the
autoremovable count is above zero:

```
N package(s) are autoremovable; read `apt-get -s autoremove` before it runs for you
```

Non-fatal, for the same reason `mimeappsIds` is: this is apt's state, not the
flake's, and it must never abort a switch. A flake check cannot see apt at all —
the Nix sandbox has no `/var/lib/dpkg` — so activation is the only layer that can
observe this, exactly as spec 10's two-layer `.desktop` check concluded.

The guard must be proven able to fire before it is trusted.

## Conservatism, stated as a rule

Keeping an unnecessary package costs disk. Removing a load-bearing one costs the
desktop, possibly the ability to log in. Those are not symmetric, so:

- Anything whose role cannot be explained is marked manual, not removed.
- Anything removed must have a recorded reason.
- The removal is one deliberate operation with its plan read first, never an
  `autoremove` run to see what happens.

## Risks

- **A load-bearing package is removed anyway.** Mitigated by the union check, the
  why-classification, and conservatism. Recovery is `sudo apt install <pkg>`,
  which is cheap — the packages remain in apt's cache and in the archive.
- **A font package is removed while an application has it mmapped.** The
  application keeps working until relaunched and then silently loses glyphs.
  Mitigated by restarting terminals and GUI applications before the removal, per
  `CLAUDE.md`.
- **The census moves between measurement and removal**, because marking a package
  manual changes what is orphaned. Mitigated by re-deriving the census after the
  marking step and before the removal, and by reading the simulated plan.

## What this spec does not claim

- That all 137 are safe to remove. That is the audit's output, not its premise.
- That the six current hits are the complete set of live consumers. The check
  sees this moment; a package used only by an application that is not running now
  will not appear. This is the known limit of the instrument, and it is why the
  30-package "everything else" group gets read by hand rather than trusted to the
  automated check.
- That reaching zero prevents recurrence. Phase 7's warning makes regrowth
  visible; only reading the orphan list at each future removal prevents it.
