# Spec 7: reducing the apt desktop footprint — suffer

2026-08-15

Spec 6 finished the session scaffolding: uwsm's units come from the flake and
apt's package is gone. What remains on the apt side is a desktop that was
never chosen — a KDE installation nobody launches, 136 tasksel metapackages,
five portal backends for a session that needs two, and the last four backports
packages, which can no longer receive an update of any kind.

This spec removes what is not used. It is a reduction, not a migration. The
one thing it adds is Nix's `xdg-desktop-portal-gtk`, and that is in service of
a removal.

## Scope, in one sentence

Remove the packages nothing on this machine uses, take the last four backports
packages to zero, and leave every remaining apt desktop package either
corp-managed or demonstrably in use.

## The inventory, measured

```
$ apt-mark showmanual | wc -l
519
$ dpkg-query -W -f='${db:Status-Abbrev}\n' | grep -c '^ii'
3256
```

519 manually-installed packages is the number that reframed this work. Broken
down:

| Group | Count | Nature |
|---|---|---|
| `task-*-desktop` metapackages | 136 | Each only `Depends: tasksel` |
| Dictionaries (`aspell-*`, `hunspell*`, `i*`, `w*`) | 82 | Out of scope |
| `firmware-*` and microcode | 32 | Out of scope |
| Base system and libraries | 105 | Out of scope |
| KDE, installed and unused | 82 sweepable | **In scope** |
| Portal backends beyond what the session needs | 3 + sweep | **In scope** |
| Backports survivors | 4 | **In scope** |
| GUI applications | ~25 | Deferred to a later spec |

### The KDE installation

A KDE desktop is installed. It was pulled in by `tasksel`, and it is held in
place by a handful of manually-marked KDE applications — `dolphin`, `konsole`,
`konqueror`, `kfind`, `kruler`, `kdialog`, `keditbookmarks`, `ktaskswitcher`,
`kdeconnect`, `kbrowserselector`. Removing those and running `autoremove`
sweeps **82 packages**.

Two of its daemons are running, which the first pass through this inventory
missed:

```
3094 /usr/bin/kwalletd6 --pam-login 10 11
3422 /usr/bin/kdeconnectd
```

`kwalletd6` is started by PAM, from `/etc/pam.d/greetd`:

```
-auth        optional        pam_kwallet5.so
-session     optional        pam_kwallet5.so auto_start
```

It holds a wallet at `~/.local/share/kwalletd/kdewallet.kwl` (2232 bytes, last
written 2026-08-06). Nothing is asking for it: `org.freedesktop.secrets` on
the session bus resolves to **gnome-keyring** (pid 3049), not kwallet.

`kdeconnectd` autostarts from
`/etc/xdg/autostart/org.kde.kdeconnect.daemon.desktop`.

The user has confirmed both should go and that the wallet holds nothing
wanted.

### The portal situation

Six backends are registered, and the interfaces they claim decide which can be
removed:

| Backend | Package | Provides | Verdict |
|---|---|---|---|
| `hyprland.portal` | Nix | Screenshot, ScreenCast, GlobalShortcuts | keep |
| `gtk.portal` | `xdg-desktop-portal-gtk` | **FileChooser**, AppChooser, Print, Notification, Settings, +6 | **keep — replace with Nix's** |
| `kde.portal` | `xdg-desktop-portal-kde` | 17 interfaces, `UseIn=KDE` | remove |
| `kwallet.portal` | `kwallet6` | Secret | remove |
| `lxqt.portal` | `xdg-desktop-portal-lxqt` | FileChooser, `UseIn=LXQt` | remove |
| `gnome-keyring.portal` | `gnome-keyring` | Secret | keep — manual, and the live provider |

**`hyprland.portal` provides no FileChooser.** File dialogs in Chrome and Code
come from `gtk.portal`. A removal pass aimed at "the KDE portal stuff" that
also swept `xdg-desktop-portal-gtk` would break file pickers in exactly the
applications that must not break.

There is no `Hyprland-portals.conf`. Backend selection today is therefore
*accidental*: `gtk.portal` declares `UseIn=gnome`, which does not match this
session, and it wins only as a fallback. Removing competing backends would
silently change which backend serves which interface.

The only portal config present is `/usr/share/xdg-desktop-portal/lxqt-portals.conf`,
which applies under LXQt and not here.

### Nix's gtk backend is a lateral move

| | Debian | nixpkgs |
|---|---|---|
| `xdg-desktop-portal-gtk` | `1.15.3-1` | `1.15.3` |
| Interfaces declared | 11 | the same 11 plus `Wallpaper` |
| `xdg-desktop-portal` (frontend) | `1.20.3+ds-1` | `1.22.1` |

Same upstream version, strict superset of interfaces. The discovery mechanism
is already proven on this machine: `XDG_DATA_DIRS` places
`/home/isutton/.nix-profile/share` first, ahead of `/usr/share`, and Debian's
portal frontend is at this moment activating Nix's hyprland backend through a
D-Bus service file in `~/.nix-profile/share/dbus-1/services`. Nix's gtk backend
would be found by the identical route and would shadow Debian's.

### The backports survivors

```
ii  libcpptrace1        1.0.4-2~bpo13+1
ii  libxkbcommon0       1.13.1-1~bpo13+1
ii  libxkbcommon-x11-0  1.13.1-1~bpo13+1
ii  quickshell          0.3.0-1~bpo13+1
```

The backports suite is not in `sources.list` or `sources.list.d` — spec 5
removed it. These four will never receive another update, security or
otherwise. That is the forcing function; the package count is not.

`quickshell` is redundant: Nix's is what runs the session (pid 3449, a store
path, and the process answering `org.freedesktop.Notifications`). Apt's
`/usr/bin/qs` and `/usr/bin/quickshell` are shadowed. Removing it orphans
`libcpptrace1`, `libdwarf1` and `libjemalloc2`.

The xkbcommon pair is not pinned by anything. **42 installed packages** depend
on `libxkbcommon0` or `libxkbcommon-x11-0`, and the strongest version
constraint any of them expresses is `>= 1.0.0` (`kitty`, `kdeconnect`,
`fuzzel`, `foot`, `deskflow`); `kwin-x11` asks only `>= 0.7.0~`. Trixie's own
`1.7.0-2` satisfies every one of them.

Crucially, the compositor does not use Debian's copy:

```
$ grep -oE '/[^ ]*libxkbcommon[^ ]*' /proc/3301/maps
/nix/store/g1q0iamxnrgzgb5hgxhxy7x9pf92b9cb-libxkbcommon-1.13.1/lib/libxkbcommon.so.0.13.1
```

So the downgrade cannot affect the session's keyboard handling. It reaches
only apt applications — Chrome, Code, Bitwarden, foot, deskflow, syncthingtray
and the other users of Debian's copy.

## Decisions

**Corp applications stay on apt, permanently.** `google-chrome-stable`,
`code`, `1password`, `1password-cli`, `endpoint-verification`. They are
managed outside this project and this spec does not touch them. Several are
also the awkward cases in nixpkgs (unfree, Electron, corp-signed), so the
boundary is convenient as well as correct.

**KDE goes entirely**, including the two running daemons.

**`xdg-desktop-portal-gtk` moves to Nix rather than being kept on apt.** Same
version, superset of interfaces, proven discovery mechanism, and the swap is
reversible by deleting one line until the apt package is removed.

**Backend selection becomes explicit.** A `Hyprland-portals.conf` is written
before any backend is removed, so the removal is a no-op rather than a
reshuffle.

**`/etc/pam.d/greetd` is not edited.** The `pam_kwallet5.so` lines carry a
leading `-`, which instructs PAM to skip silently when the module is absent.
Once `libpam-kwallet5` is swept the lines are inert. The file is a dpkg
conffile owned by `greetd`; editing it would create a conffile diff on every
future upgrade, which is a worse outcome than two dead lines.

**The wallet file is left in place.** Package removal does not touch user
data, and neither does this spec.

## Non-goals

- **The portal frontend.** `1.20.3` → `1.22.1` is a real version change, it
  owns systemd units rather than a D-Bus service file alone, and it sits in
  the path of every portal call including the corp applications'. Its own
  spec.
- **Migrating the remaining GUI applications** — `firefox-esr`,
  `signal-desktop`, `bitwarden`, `kitty`, `emacs-lucid`, `thunar`,
  `pcmanfm-qt`, `virt-manager`, `displaycal`, `isoimagewriter`, `seahorse`,
  `flatseal`, `syncthingtray`, `deskflow`, `bat`, `chafa`, `yt-dlp`. Its own
  spec, and honestly scoped only once this one has deleted 230 packages.
- **The dictionary and firmware sets.** Unrelated to the desktop.
- **`/run/opengl-driver` and the twelve `nixGLIntel` references.** Still
  parked. `mesa-26.1.5` carries no `/run/opengl-driver` reference, so the
  claim that the symlink retires all five wrappers remains unestablished.
- **Deleting `~/.local/share/kwalletd/kdewallet.kwl`.**
- **Editing `/etc/pam.d/greetd`.**

## Design

Five phases, ordered by reversibility. The split is not stylistic — it was
measured.

| Phase | What | Packages | Reversible |
|---|---|---|---|
| 1 | `tasksel`, `tasksel-data`, 136 `task-*` metapackages | 138 | yes — all downloadable from trixie |
| 2 | KDE applications and their sweep | 82 | yes — all downloadable from trixie |
| 3a | Add Nix's `xdg-desktop-portal-gtk`; write `Hyprland-portals.conf` | 0 removed | yes — delete one line |
| 3b | Remove Debian's gtk, kde and lxqt backends | 3 + sweep | yes — all downloadable from trixie |
| 4 | apt's `quickshell`, `libcpptrace1` (+ `libdwarf1`, `libjemalloc2`) | 4 | **no** — repack first |
| 5 | xkbcommon downgraded to trixie `1.7.0-2` | 2 | **no** — repack first |

Phases 1 through 3 need no `dpkg-repack` and no reboot gate: the worst case is
a single `apt install`. Only phases 4 and 5 carry the one-way ceremony spec 6
established, and only six packages are involved.

### Phase 1 — the tasksel metapackages

`apt-get -s remove` on the 136 `task-*` names plus `tasksel` removes 138
packages and nothing else. Each metapackage's entire dependency set is
`tasksel`, so this group is weightless — it is clutter, and it is the reason
KDE arrived. Removing it prevents recurrence.

### Phase 2 — the KDE installation

Remove `dolphin`, `konsole`, `konqueror`, `kfind`, `kruler`, `kdialog`,
`keditbookmarks`, `ktaskswitcher`, `kdeconnect`, `kbrowserselector`, then
`autoremove`. 82 packages.

The sweep was checked against the things that must survive, and touches none
of them: `google-chrome-stable`, `code`, `1password`, `1password-cli`,
`endpoint-verification`, `signal-desktop`, `firefox-esr`, `quickshell`,
`greetd`, `tuigreet`, `foot`, `kitty`, `deskflow`. The only Qt package it
takes is `libqt6sensors6`.

It does contain three PAM-related packages, all verified safe:

- `libpam-kwallet5`, `libpam-kwallet-common` — being removed deliberately.
- `libpam-fprintd` — no `fprintd` line in any `/etc/pam.d/` file, no reader
  present, `fprintd.service` inactive, no enrolled prints. It is in the sweep
  only because `libkscreenlocker6` depends on it.

Nothing in the sweep touches `greetd`, `systemd`, `dbus`, or `polkit`.

### Phase 3a — Nix's gtk backend, shadowing

Add `xdg-desktop-portal-gtk` to `home.packages`. Its `.portal` file and D-Bus
service file land under `~/.nix-profile/share`, which precedes `/usr/share` in
both `XDG_DATA_DIRS` and the session bus's service search path, so Nix's
backend wins the `org.freedesktop.impl.portal.desktop.gtk` name.

Nix's package installs exactly the two filenames that do the shadowing —
`share/xdg-desktop-portal/portals/gtk.portal` and
`share/dbus-1/services/org.freedesktop.impl.portal.desktop.gtk.service` —
so no renaming or extra wiring is needed.

Write `~/.config/xdg-desktop-portal/Hyprland-portals.conf` declaring the
choice rather than inheriting a fallback. The filename is not arbitrary: the
frontend reads `$XDG_CURRENT_DESKTOP-portals.conf`, and this session reports
`XDG_CURRENT_DESKTOP=Hyprland`. Debian's frontend supports the format — it
ships `portals.conf.5`.

```ini
[preferred]
default=gtk
org.freedesktop.impl.portal.Screenshot=hyprland
org.freedesktop.impl.portal.ScreenCast=hyprland
org.freedesktop.impl.portal.GlobalShortcuts=hyprland
org.freedesktop.impl.portal.Secret=gnome-keyring
```

No apt package changes in this phase. Reverting is deleting one line from
`home.packages`.

### Phase 3b — remove the displaced backends

Remove `xdg-desktop-portal-kde`, `kwallet6`, `xdg-desktop-portal-lxqt`, and
Debian's `xdg-desktop-portal-gtk`. Gated on 3a's verification.

### Phase 4 — apt's quickshell

`dpkg-repack quickshell libcpptrace1` first: neither has a download source.
Then remove. Nix's quickshell already serves the session, so this phase has no
shadow step — the shadow has been in place since spec 4.

### Phase 5 — the xkbcommon downgrade

`dpkg-repack libxkbcommon0 libxkbcommon-x11-0` first — trixie's `1.7.0-2` is
downloadable but the backports `1.13.1` is not, so this is the only route back
up. Then:

```
apt-get install libxkbcommon0=1.7.0-2 libxkbcommon-x11-0=1.7.0-2
```

Simulated: two packages downgraded, nothing removed, no cascade.

## Verification

Spec 6's headline finding was that five of its own checks measured a proxy
that held while the property did not. Designing *this* spec reproduced the
defect twice more, both times by writing a list of names by hand:

- Counting KDE packages with `^(kde|kwin|plasma|kf6|libkf|kio)`, which misses
  `dolphin`, `konsole`, `konqueror`.
- Looking for running KDE with `pgrep 'kwin|plasma|kded|ksmserver'`, which
  reported "none of it is running" while `kwalletd6` and `kdeconnectd` were
  running.

Both errors were in the *design* phase and were caught before anything was
executed, but neither was caught by a check — they were caught by looking
again. So the verification rules are:

1. **Read the whole `Remv` list before executing each phase.** Categorised,
   not spot-checked. `libpam-fprintd` surfaced only because the sweep was
   grepped for `pam`; a different blind spot hides a different package. Every
   entry matching PAM, login, D-Bus, systemd, polkit or portal is justified
   individually, in writing.
2. **Enumerate by syntax, never by a remembered list of names.** Packages by
   `Section:` and dpkg state. Running processes by walking `/proc`, not by
   `pgrep` with names someone thought of.
3. **Gates interact with the real thing.** Not "the binary exists", not "the
   unit is active".

### Per-phase gates

| After | Gate |
|---|---|
| 1 | Session unaffected; `apt-get -s autoremove` reports 0; the removal list contained only `task-*`, `tasksel`, `tasksel-data` |
| 2 | Chrome, Code and 1Password each **launch and render**; no failed user units; `greetd` still starts a session across a reboot |
| 3a | A real file dialog opens in Chrome, **and** the process serving it is a store path; screenshot and screencast still work through the hyprland backend; the file chooser's fonts and icons render correctly |
| 3b | Same three checks again, after removal |
| 4 | Nix's quickshell is the process answering `org.freedesktop.Notifications`; the bar, panels and notifications all still work |
| 5 | Typing works **in an apt application** — Chrome and Code specifically — including a non-ASCII key and a compose sequence if configured; the compositor is immune and proves nothing |

Phase 3a names a cosmetic check deliberately. Nix's gtk backend draws its
dialog with Nix's GTK, so the file chooser's theme, fonts and icons come from
`home/gtk.nix` rather than Debian's configuration. A check that the process
exists would pass while the dialog rendered unstyled.

## Recovery

- **Phases 1–3:** `apt install <package>`. Everything removed is available
  from trixie at the version that was removed.
- **Phases 4–5:** `dpkg -i` from the archives taken beforehand, stored in
  `/root/pkg-archive/` beside `uwsm`'s and `ydotool`'s.
- **A Home Manager rollback is not a recovery path.** The rule spec 6
  established still holds and is extended by phase 3a: the portal config and
  the gtk backend live in the generation, so rolling back removes them.
- If the session does not start, `Ctrl+Alt+F1` reaches tty1, whose getty is
  active and enabled.

## Endpoint

- ~230 fewer apt packages.
- **Zero** backports packages; every installed package from a suite that still
  receives updates.
- Both portal backends supplied by Nix, with backend selection declared rather
  than inherited from a fallback.
- Every remaining apt desktop package either corp-managed or in demonstrable
  use.

## Open items this spec does not close

- **The portal frontend** is still Debian's `1.20.3` driving Nix backends.
  Next spec.
- **~25 GUI applications** remain on apt with no Nix counterpart. The spec
  after that, with the corp five carved out permanently.
- **`/run/opengl-driver`** remains parked and unestablished.
- **The dictionary set** — 82 packages — has never been examined. It is not a
  desktop concern, but it is 82 manual packages nobody has justified.
