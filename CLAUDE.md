# calango-nix

A Hyprland desktop on Debian 13 (`suffer`), migrating from apt to Nix +
standalone Home Manager. Fifteen specs are done and written up in
`docs/2026-08-1*-results-suffer-*.md`, with every defect and its owner. Count
that number, never increment it: `ls -1 docs/*results-suffer-*.md | wc -l` is
the authority, and spec 10 landed here saying "Nine" because eight had been
incremented once and spec 9 had never bumped it at all. This
file exists because the same mistakes kept recurring across them; everything
below has been paid for at least once.

## Running commands

Wrap every `nix` and `home-manager` invocation:

```sh
sg nix-users -c 'nix build ...'
```

`/nix/var/nix/daemon-socket/` is `0770 root:nix-users` (the socket inside is
`0666`). A process whose credentials lack the group fails with
`getting status of '/nix/var/nix/daemon-socket/socket': Permission denied`,
which reads as a broken Nix install. A fresh login also picks the group up, but
`sg` is the convention here and is always correct.

`nix flake check` now runs **three** checks (see `flake.nix`):
`no-dangling-home-files`, `no-pulseaudio-daemon` and `gui-desktop-ids`.

Run it after touching a `source =` anywhere under `home/`, `guiPackages` in
`home/gui-apps.nix`, the `applications/` `xdg.dataFile` entries in
`home/apps.nix`, or the `required` list in `flake.nix`. The first of those is
deliberately stated as *syntax* rather than as a list of modules: an earlier
version of this passage named `home/portals.nix` and `home/uwsm.nix`, and
`grep -l 'source =' home/*.nix` returns **ten** modules, so the named pair
silently excused the other eight — `home/audio.nix:195,231` among them. Grep
for the property; do not trust a list of names, including this sentence's.

Further build-time guards ride in `home.packages` rather than in `checks`, so
they run on every generation build — strictly more often than
`nix flake check` is invoked — and none of them appears in that count of three.
Enumerate them the same way, by syntax: `grep -n 'home.packages' home/*.nix`,
then read what each list contains. An earlier version of this passage said
"two", naming only `home/gui-apps.nix`'s `wrappedGuiApps` and
`dbusActivatableGuiApps`; `home/audio.nix:385` also puts `pulseaudioClients`
there, and *that derivation's own body* carries three `exit 1` guards — a
number that needs its own command, because the file around it has nine:

```sh
grep -c 'exit 1' home/audio.nix
# 9   -- the whole file, a different thing
sed -n "/pulseaudioClients = pkgs.runCommand/,/^  '';$/p" home/audio.nix | grep -c 'exit 1'
# 3   -- inside pulseaudioClients, which is what the claim is about
```

A package-producing derivation can be a guard too, which is exactly what a
remembered list of "the guards" misses. `home/default.nix`'s
`nixglSingleSource` is the fourth, added by the nixGL consolidation, and it is
a different shape again: not a package at all, but a `runCommand` that greps
the tree's own source text for a literal wrapper call and fails the build if
one turns up outside `lib/nixgl.nix` — the first guard here that inspects
source text rather than a built package's contents.

`home/syncthing.nix` adds the first guard in this flake that is not a
derivation: two entries in Home Manager's `assertions`, evaluated at build
time. An earlier version of this passage said it *had* to be, which is not
true and was not derived. What cannot work is a `runCommand` in
`home.packages`: those guards inspect a *package*, and a derivation inside the
generation cannot inspect the generation it belongs to. A `checks` entry could
have -- `flake.nix` already reads `${suffer.activationPackage}/home-files` from
outside the generation, in `no-dangling-home-files` and in
`gui-desktop-ids`. `assertions` wins on frequency, not on
possibility: it runs on every generation build, where a check runs only under
`nix flake check`. Enumerate assertions with
`grep -n 'assertions' home/*.nix`, which returns 4 -- one binding and three
prose, so read the lines rather than the count.

---

## Tools that answer a different question than the one asked

**Package versions.** `nixpkgs#<pkg>` reads the flake *registry*
(nixpkgs-unstable), not this flake's pinned input. They differ:

```sh
sg nix-users -c 'nix eval --raw .#homeConfigurations."isutton@suffer".pkgs.xdg-desktop-portal.version'
# 1.20.4  -- the pinned input, what actually gets installed
sg nix-users -c 'nix eval --raw nixpkgs#xdg-desktop-portal.version'
# 1.22.1  -- the registry, irrelevant here
```

Reaching for `nixpkgs#` has produced a wrong version at least three times.

**`grep` here is not GNU grep.** The interactive shell defines `grep` as a
function backed by ugrep, and it silently returns `0` for a pattern containing
`${` even against a file that provably holds it:

```sh
grep -c '${pkgs.nixgl.nixGLIntel}' lib/nixgl.nix            # 0   -- the function
/usr/bin/grep -cF '${pkgs.nixgl.nixGLIntel}' lib/nixgl.nix  # 1   -- the truth
```

Spec 14 published a command whose stated output was `5`; run as written it
printed nothing at all, because every line was filtered as `:0`. The number was
right — one occurrence per module, re-derived — and the instrument beside it was
not. Nothing warns you: a count that should be `1` reads `0`, and `0` is exactly
what "the property holds" looks like for a negative check. Use `/usr/bin/grep`
explicitly, with `-F` for a literal, whenever a count is load-bearing. Inside a
Nix builder the shell is the real one and this does not apply.

**`wrapProgram --prefix PATH : "a:b:c"` writes its entries into the wrapper in
reverse, and the reversal cancels itself.** Each entry gets its own prepend
block, so reading the generated script top to bottom shows the last-declared
entry first. That looks like a reordering and is not: because every block
prepends, the block applied last ends up leftmost. Measured on `home/lf.nix`'s
`lfPath`, declared `file, xdg-utils, glib, coreutils`:

```sh
L=$(sg nix-users -c 'nix eval --raw .#homeConfigurations."isutton@suffer".config.calango.lf')
/usr/bin/grep -n "^PATH='" "$L/bin/lf"
# coreutils, glib, xdg-utils, file   -- the script lines, reversed
env -i /bin/bash -c "PATH=/usr/bin; $(sed -n '/^PATH=/p' "$L/bin/lf"); echo \$PATH"
# file, xdg-utils, glib, coreutils   -- the effective PATH, as declared
```

An earlier version of this entry ran only the first command and concluded that a
name collision would resolve backwards. It would not. The entry belongs in this
section twice over: once for the trap it describes, and once because it was
itself an instance of the trap — a real command, real output, and a conclusion
the measurement did not support, caught by a reviewer who ran the second
command.

**The systemd user unit search path.** `systemd-analyze --user unit-paths`
computes the list from the *caller's* environment and reports 18 entries,
including `~/.nix-profile/share/systemd/user` at 12 — which the manager has
never seen. The authoritative property is the manager's own:

```sh
systemctl --user show -p UnitPath --value | tr ' ' '\n' | nl
# 5   /home/isutton/.config/systemd/user     <- home-manager's territory
# 6   /etc/systemd/user
# 15  /usr/lib/systemd/user                  <- Debian's
```

In one review cycle a reviewer and the controller drew opposite wrong
conclusions from `systemd-analyze`.

**Enumerating units.** `systemctl --user list-units` does not show a `oneshot`
that has finished — this miscounted `xdg-desktop-portal`'s units as three.
Use `dpkg -L <pkg> | grep systemd/user`, `systemctl --user list-unit-files`, or
`list-units --all`.

**"What is in use".** `/proc/<pid>/maps` is unreadable for other users'
processes, and root outnumbers the user roughly 3:1 here (301 vs 115; only 99
of ~430 processes yield readable maps). A `/proc`-only walk covers a quarter of
the system and once nearly swept `bluez`. Any in-use check must union a `/proc`
walk (`maps` + `exe`) with the first field of `ps -eo args` for *every*
process, resolved through `dpkg -S`.

**And that union is blind to interpreted programs — read this together with the
rule above, because the union is the strongest instrument here and this is where
it fails silently.** `exe` and `argv[0]` both name the *interpreter*; the script
is `read()`, never mmapped and never an `exe`, so it appears in neither half.
Measured in spec 12: `system-config-printer` was in the autoremove census *and*
its `/usr/share/system-config-printer/applet.py` was running as pid 3823, and
the union missed it completely —

```sh
grep -c '^/usr/share/system-config-printer/applet\.py$' "$FILES"   # 0  -- missed
grep -c '^/usr/bin/python3$' "$FILES"                              # 1  -- seen
ls -l /proc/3823/fd | grep -c system-config-printer                # 0
```

(Those three print `0`, `1`, `0` and the two zeroes *exit 1*, which is fine typed
into a shell and is the trap described further down if you paste them into
anything with `set -e`.)

and `dpkg -S /usr/bin/python3` resolves to `python3-minimal`, not to the package
whose code was executing. Its sibling `python3-cups` *was* caught, but only
because it is a compiled extension module and therefore mmapped;
`python3-cupshelpers` is pure Python and was missed for the same reason the
applet was. Treating the union's output as the complete live set would have swept
two packages out from under a running process. For anything that might be a
script, ask `dpkg -S` about the full command line, not about `argv[0]`.

**A dependency a running-process check can never see, at any moment.** A plugin
directory is not a dependency apt can model, and it is not a mapping any process
holds until the plugin is loaded. `libpipewire-0.3-modules` fills the compiled-in
module directory of Debian's `libpipewire-0.3.so`
(`/usr/lib/x86_64-linux-gnu/pipewire-0.3`, read out of the library with
`strings`, 44 `.so` files in the package). That client library is kept installed
by `libfluidsynth3` and `qemu-system-gui`, both `ii` and both outside the
census — and neither was running, so **no measurement taken at any instant would
have flagged it**. It was found by reading the dependency chain, and it is why
this project's conservatism rule ("anything whose role cannot be explained is
marked manual") is not merely cautious: for this shape of dependency there is no
instrument to be cautious *instead* of.

**Package presence.** `dpkg-query -W -f='${Version}'` prints a version and
exits `0` for `rc` packages (removed, conffiles retained) — which is exactly
what `apt remove` leaves. There are **147** `rc` packages on this machine as of
spec 13 — and that figure moves every time a spec removes something, so count it
rather than quoting this line:

```sh
dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' | awk '$1=="rc"' | wc -l
```

It read 120 for three specs while the true count drifted upward, and spec 10's
own three (`thunar`, `thunar-volman`, `pcmanfm-qt`) are part of the difference.
Note the reading rose only from 128 to 145 across specs 11 and 12 together,
while spec 12 alone removed 128 packages: **`rc` is not a running total of what
has been removed** and cannot be read as one, because a package with no
conffiles leaves no `rc` entry at all. Measured among spec 12's own removals —
`avahi-utils`, `gvfs-fuse` and `python3-cups` are `un`, while `cups-pk-helper`,
`system-config-printer` and `xscreensaver` are `rc`. (No `rc` count was taken
between spec 10 and spec 12, so the 17 cannot be split between them.)

Spec 13 then moved it 145 → 147 by removing exactly two packages,
`signal-desktop` and `bitwarden`, both of which left conffiles. That is a clean
illustration of the paragraph above rather than a counterexample to it: here
the delta happens to equal the number of packages removed, and it is precisely
that coincidence which makes "`rc` is a running total" tempting. It is not one.
Spec 12 removed 128 and moved the reading by part of 17; spec 13 removed 2 and
moved it by 2. The delta is the number of removed packages *that carried
conffiles*, which is a different quantity that sometimes agrees. Use:

**Spec 14 is the clean end of that argument: it removed six and moved the
reading by zero.** `lf`, `ueberzug`, `libxres1`, `python3-attr`,
`python3-docopt` and `python3-xlib` all went, none carried conffiles, and
`dpkg-query` now finds no trace of any of them — not `ii`, not `rc`, not `un`.
The count stood at 147 before and after. If spec 13's agreement made "`rc` is a
running total" tempting, this is the case that settles it.

```sh
dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' <pkg>...
```

Dependency scans over `dpkg-query` include `rc` packages too; filter to `ii`
(`awk '$1=="ii"'`) or the count is inflated.

**Pipelines that report by printing nothing.** `grep … | sed …` exits 0 even
when grep matched nothing, so "the property holds" and "the pipeline broke" are
indistinguishable. Count explicitly (`| wc -l`) and compare the number.

**But that rule inverts in two contexts here, and following it in either fails
with no diagnostic: inside a Nix builder, and inside the Home Manager activation
script.** Both run with `-e` and `pipefail` on. Name both — spec 11 learned it in
the builder and spec 12 met the identical trap in `activate`, which the builder
wording did not cover:

```sh
# inside a runCommand
echo $-              # ehB
set -o | grep pipefail   # pipefail        on

# and the activation script's own first lines, measured:
sed -n '1,3p' "$(sg nix-users -c 'nix build --no-link --print-out-paths \
  .#homeConfigurations."isutton@suffer".activationPackage')/activate"
# #!/nix/store/…-bash-5.3p9/bin/bash
# set -eu
# set -o pipefail
```

So `n="$(grep -rl … | wc -l)"` aborts on *grep's* exit status when grep matches
nothing, rather than yielding `0`, and a bare `n="$(grep -c … )"` aborts the
assignment before any message can print. The guard reads as a counting guard and
behaves as an unconditional failure. Spec 11 wrote it that way *because* of the
rule above and spent a build on it.

Inside a builder, put the grep in a **condition**, which `set -e` exempts:
`if grep -rq … ; then` — which is how `home/foot.nix`'s token guard has always
been written. In an activation hook a condition is often not available, because
the count itself is the message; there, append `|| true` to the assignment and
default the variable.

**But first ask which shell the code actually runs in, because the options are
not inherited across an exec.** `activate` sets `-eu` and `pipefail` for
*itself*. A hook body written inline runs under them; a body handed to a child —
`run ${pkgs.bash}/bin/sh -c '…'`, which is how `home/apt-hygiene.nix` and
`home/apps.nix`'s `mimeappsIds` are both written — does not:

```sh
# from inside such a child, measured
echo $-                          # hBc     <- no `e`
set -o | grep -E 'errexit|pipefail'   # both off
```

`SHELLOPTS` is not exported by `activate`, so nothing carries them in. Spec 12's
`|| true` was documented as load-bearing on the strength of a mutation run
against the body *inlined* — where deleting it does return 1 — while the shipped
child-shell form runs to the end and returns 0. Real command, real output, and a
conclusion about a program the flake does not contain. The clause is worth
keeping anyway, since it is free and correct for the inline shape, but do not
call it what it is not.

Count explicitly in an interactive shell; test by condition in a builder; and in
an activation hook, check `$-` in the shell that will really run the line before
deciding what protects it.

**`pgrep` on a Nix binary.** Nix wraps binaries, so the process name is
`.fumon-wrapped` or `.Hyprland-wrapp` (truncated at 15 chars). `pgrep -x fumon`
matches nothing in both the working and the broken state.

---

## Mechanisms that are not what they look like

**sd-switch restarts a unit when the unit *file* changes, not when the files the
unit reads change.** So a change confined to a config directory a service loads
at startup leaves the unit byte-identical, sd-switch correctly does nothing, and
the service keeps serving the previous generation from a store path that no
longer has a symlink pointing at it. The switch succeeds, the new files are on
disk, and the change has no effect.

This was true of **every** quickshell change this flake ever made until spec 11;
the ones that appeared to work did so because the session happened to be
restarted for another reason. Measured right after a switch whose whole purpose
was to change `AppLaunch.qml`:

```sh
grep -n appPath ~/.config/quickshell/common/AppLaunch.qml   # the new value, present
systemctl --user show quickshell.service -p NRestarts -p ActiveEnterTimestamp
# NRestarts=0
# ActiveEnterTimestamp=Mon 2026-08-17 06:11:42 -03    <- hours before the switch
```

The fix is to make the unit's text depend on the config, by naming its store
path — `home/quickshell.nix`'s `Unit.X-Restart-Triggers = [ "${quickshellConfig}" ]`.
The path changes when the contents change, so the unit changes with it. `X-` keys
are otherwise ignored by systemd, which is why this is the conventional spelling.
Prove it by mutation: a one-line comment in any file of the tree must move the
store path.

**`xdg-desktop-portal.service` still has this defect.** Its unit is a verbatim
store copy (`home/portals.nix:213`) and `hyprland-portals.conf` (`:166`) is read
by the frontend at startup, so editing that config restarts nothing and the
change does not take effect. Unfixed on purpose: the clean shape is a drop-in
carrying `X-Restart-Triggers`, and **whether sd-switch diffs drop-ins as well as
fragments has not been measured here** — verify that before relying on it. The
rest of the tree is clean: `night-light.service` names `quickshellConfig` in its
own `ExecStart`, the audio drop-ins carry their store paths, and `home/foot.nix`
and `home/lf.nix` back no unit.

Note `NRestarts=0` after such a switch is not evidence against a restart —
sd-switch stops and starts the unit, and a fresh start resets that counter.
`ActiveEnterTimestamp` is the property that moves.

**Widening a `PATH` by prefixing changes which copy of the tools you already had
gets used.** Appending adds reach; prefixing also *takes away*. Spec 11 prefixed
a session `PATH` onto quickshell's unit `PATH` to make desktop entries resolve,
and silently moved `systemd-run` and `setsid` — the two binaries the launch
itself depends on, pinned from the Nix closure by `runtimeDeps` on purpose — to
Debian's `/usr/bin`:

```sh
PATH="$APPPATH:$QPATH" command -v systemd-run   # /usr/bin/systemd-run
PATH="$QPATH:$APPPATH" command -v systemd-run   # /nix/store/...-systemd-260.2/bin/...
```

The comment on that line asserted the opposite — that prefixing kept the closure
reachable. Ask which side of the join owns each binary before choosing an order:
if the thing you are adding cannot supply a tool at all (neither is in
`~/.nix-profile/bin`), a prefix can only lose it. Append unless you specifically
intend to override.

**`systemd-run` and `uwsm app` both resolve the executable in their own process,
against their own `PATH`, before any unit exists.** So a service with a curated
`PATH` cannot launch anything outside that closure, and `--setenv=PATH=…` cannot
help — it sets the *unit's* environment, which is decided after the resolution
already failed. Both were measured on this machine from quickshell's real
environment; `uwsm app` is not an escape hatch from this and fails the same way,
though its message is better because it names the entry as well as the missing
binary. The `PATH` has to be widened in the *launching shell*, which is what
`quickshell/common/AppLaunch.qml` does with `appPath` from
`home/quickshell.nix`. Widen it there and not in the unit's own `PATH`: two
`command -v` probes in that shell fail deliberately, and would start finding
Debian's copies.

**A guard that greps a file for a string can be satisfied by that file's own
comments.** Spec 11's first `appPath` guard checked that `AppLaunch.qml`
contained `/usr/bin`; one of the comments in that very file explains that the
unit's `PATH` has no `/usr/bin`, so the guard matched its own prose and could
never fail. Deleting `/usr/bin` from the list built green. Read the *value* — the
property line, the assignment, the substituted field — and compare whole
elements, not substrings: `/usr/bin` is a substring of nothing else in that list,
but `/bin` is a substring of four of its six entries.

**A relative `ExecStart` does not use the manager's `PATH`.** systemd resolves
it against a search path fixed when systemd was compiled:

```sh
systemd-path search-binaries-default
# /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
```

No `/nix/store` path can ever appear there. `ExecStart=fumon` ran Debian's
binary under Nix's unit file for two whole phases. But
`ExecCondition=/bin/sh -c "command -v X"` *does* use `$PATH`, because `/bin/sh`
is absolute and the shell does the lookup — `~/.nix-profile/bin` is at position
18 against `/usr/bin` at 22 in the session PATH. Every `Exec*=` in a unit this
flake ships must be an absolute path; `home/uwsm.nix` asserts that at build
time by directive *syntax* (`^Exec[A-Za-z]*=`), not by a hand-written list of
directive names.

**A Nix package alone places nothing where it will be found.** Two gaps:

- The session bus's `XDG_DATA_DIRS` has no `~/.nix-profile/share` — check with
  `tr '\0' '\n' < /proc/$(systemctl --user show dbus.service -p MainPID --value)/environ | grep XDG_DATA_DIRS`.
  D-Bus activation files must go into `XDG_DATA_HOME` via `xdg.dataFile`.
- `~/.nix-profile/share/systemd/user` is not on the manager's UnitPath at all.
  Units must go into `~/.config/systemd/user` via `xdg.configFile`.

`dbus-broker` caches its service directory at *its own* startup, before uwsm
sets the session environment, and never rescans on a switch: a fresh login (or
`busctl --user ReloadConfig`) is required.

**D-Bus prefers `SystemdService=` over `Exec=`.** That is a unit *name*, so the
unit search path decides which binary runs — not the `Exec=` line sitting right
above it. Adding the Nix package while Debian's unit is at position 15 changes
nothing.

**`xdg-desktop-portal` case-folds `$XDG_CURRENT_DESKTOP`.** With
`XDG_CURRENT_DESKTOP=Hyprland` the config file is `hyprland-portals.conf`,
lower-case (`man 5 portals.conf`; the binary calls `g_ascii_strdown`). To prove
a config is actually read rather than merely present, run the binary verbosely
on a throwaway bus:

```sh
dbus-run-session -- env XDG_CURRENT_DESKTOP=Hyprland \
  /nix/store/…-xdg-desktop-portal-1.20.4/libexec/xdg-desktop-portal -v
# every interface should resolve "(config)"
```

**Removing a Debian package that ships a systemd *user* unit leaves a dangling
root-owned `/etc/systemd/user/*.wants` symlink.** dpkg's helper creates them;
dpkg does not own them. Seen with `fumon`, `ydotool`, `rewrite-launchers` and
the audio removal. The census taken across specs has moved 8 → 14 → 0: the
audio spec's own removal took the dangling total to 14 (its six audio links
plus the eight inherited), and a subsequent sweep cleared all fourteen — the
count right now is zero, all of them unowned per `dpkg -S`. It will rise again
the next time a package shipping a user unit is removed. Spec 12 removed 128
packages and did not move it: six of them shipped a user unit and all six were
`static` or `disabled`, so nothing enabled existed to dangle. Sweep with:

```sh
find /etc/systemd/user -xtype l          # dangling symlinks only; 0 right now
```

Use `find`, and treat the loop below as the narrower thing it is rather than an
equivalent:

```sh
# NOT equivalent -- only *.wants/ and *.upholds/, and only one level
for f in /etc/systemd/user/*.wants/* /etc/systemd/user/*.upholds/*; do
  [ -L "$f" ] && [ ! -e "$f" ] && echo "$f"
done
```

`deb-systemd-helper` also creates `.requires/`, and `/etc/systemd/user` holds
top-level symlinks the loop never looks at — `dbus.service` and
`dbus-org.bluez.obex.service` are there right now. Measured on a scratch tree
holding four dangling links, one each under `.wants/`, `.upholds/`, `.requires/`
and at top level: the loop found **2**, `find` found **4**. It misses exactly the
two it never looks at.

**The obvious form of that loop — `[ -e "$f" ] || echo "$f"` — reports a false
positive on this machine right now**, so it is written above with a `-L` test
instead. A glob needs at least one entry to expand; with none, the shell leaves
the *literal pattern* in `$f`, `[ -e ]` rejects it, and the loop prints
`/etc/systemd/user/*.upholds/*` — a line that reads exactly like a finding.
`/etc/systemd/user/sockets.target.upholds/` is the only `.upholds` directory and
it is empty, which is why. Requiring `-L` fixes it: the literal pattern is not a
symlink, so it is silently skipped, and a real dangling link still prints. Both
forms above were proven able to fail, against a throwaway tree containing one
deliberately dangling link.

The same emptiness produces the *opposite* symptom on the other glob, and which
one you get depends on whether any sibling of that glob expands. `*.wants/*` has
non-empty members (six `.wants` directories, every entry resolving), so the empty
`/etc/systemd/user/pipewire.service.wants/` vanishes silently rather than being
reported. Cosmetic, since an empty directory dangles nothing, but don't read
either loop's silence as "no residue of any kind" — only as "no dangling
*symlinks*".

**Removing a package does not kill its running process.** Absence is only
measurable after the session ends — check after the reboot, not before.

**Nor does it make the unit disappear from `systemctl --user show`.** The
manager caches its unit table until a reload, so a unit whose fragment has just
been deleted still reports `LoadState=loaded` and `UnitFileState=enabled`, with
a `FragmentPath` pointing at a file that is no longer there. Measured right
after `apt remove foot`:

```sh
systemctl --user show foot-server.service -p LoadState -p FragmentPath -p UnitFileState
# LoadState=loaded
# FragmentPath=/usr/lib/systemd/user/foot-server.service   <- does not exist
# UnitFileState=enabled
```

`list-unit-files` had already dropped it, so the two disagree. Checking a
unit's *absence* with `show`, without a `daemon-reload` or a fresh login, is a
false positive waiting to happen.

**A `.source` pointing at a nonexistent path builds fine.** Home Manager's file
builder uses a bare `ln -s` with no existence test, so you get a dangling
symlink and a clean switch. `nix flake check`'s `no-dangling-home-files` exists
for this.

**fontconfig builds a process's font map at startup.** A running application
cannot see newly installed fonts and keeps deleted ones mmapped — it looks fine
until it is next launched. Restart applications before removing font packages.

**A systemd alias symlink must point at a sibling inside a unit directory.**
systemd decides from the link's *immediate* target, not the fully chased one.
A link into `/nix/store` loads as a second, independent unit with its own
`FragmentPath`; a relative link to the sibling gives one unit under two
names. `xdg.configFile` always emits `~/.config/… -> /nix/store/<home-manager-files>/…`,
so it can never express an alias — and neither can `mkOutOfStoreSymlink`,
which routes hop 1 through the same store. Home Manager's
`modules/systemd.nix` has no `Install.Alias` handling and sd-switch never
calls `enable`. The only mechanism is a raw `ln -s` from `home.activation`.
The failure is silent: `Wants=` and `After=` naming a unit that does not
exist are dropped along with their ordering, and `--state=failed` stays empty.
And the link is unmanaged by Home Manager's own file manifest —
`no-dangling-home-files` walks `home-files` and never sees it, so removing
`home/audio.nix` from the flake's module list leaves
`~/.config/systemd/user/pipewire-session-manager.service` dangling forever
unless someone deletes it by hand — the same species as the root-owned
`/etc/systemd/user/*.wants` residue below, now reproduced in the user's own
tree by this flake.

**`systemctl --user show-environment` is not what a boot-path unit
inherited.** It reports the manager's environment *as it is now*, after uwsm
has set the session environment. Units pulled in by `default.target` or
`sockets.target` start before that — measured here, three seconds before
`graphical-session.target` — so their `XDG_DATA_DIRS` has no
`~/.nix-profile/share`. The authoritative source is the unit's own
`/proc/<MainPID>/environ`. Same trap as `systemd-analyze --user unit-paths`
above, in a new place.

**wireplumber resolves its scripts and config through `XDG_DATA_DIRS`;
pipewire does not.** pipewire uses a compiled-in datadir and
`PIPEWIRE_CONFIG_DIR`. So a Nix wireplumber will happily execute Debian's Lua
scripts, and the resulting API-mismatch tracebacks read as an upstream bug in
the new version. `home/audio.nix` pins it with a `wireplumber.service.d`
drop-in setting `WIREPLUMBER_DATA_DIR`. Do not assume the two halves of a
subsystem find their data the same way.

**PipeWire's bluez5 SPA plugins are loaded by wireplumber, not pipewire.**
Checking `/proc/<pipewire-pid>/maps` for them returns 0 whether Bluetooth
works or not — a check that cannot fail. The session manager's maps are where
they appear.

**Deleting a Debian `.wants` link does not disable the unit for long.** `gcr4`'s
and `openssh-client`'s postinst run `deb-systemd-helper --user unmask` and then
re-enable when `was-enabled` returns true — and it defaults to true, because a
bare `rm` never updates that helper's statefile under
`/var/lib/systemd/deb-systemd-helper-enabled/`. So the next upgrade of the
package silently restores the link. `deb-systemd-helper` only ever touches
`/etc`, so the durable answer is a **mask** in `~/.config/systemd/user`
(UnitPath position 5), which is also owned by the flake instead of by root.

**A symlink's meaning depends on which question systemd is asking, and the
answers differ.** Masking asks "does this unit path resolve to `/dev/null`",
which is a full chase, so a store-mediated link masks fine. Aliasing compares
the link's name against its **immediate** target's basename, so a store-mediated
link is not an alias at all (see `home/audio.nix`). Both were measured on this
machine. Do not carry a result from one to the other.

**And probe every layer the change passes through, not just the interesting
one.** The mask shape above was probed against systemd by hand and passed —
then the build failed, because `xdg.configFile`'s `source` is a `types.path`
and Nix refuses to import `/dev/null` in pure evaluation mode
(`access to absolute path '/dev' is forbidden`). The runtime question was
answered and the build question was assumed. The fix is a one-line
`runCommand` whose output *is* a symlink to `/dev/null`, which is pure because
`ln -s` never resolves its target.

**An apt removal orphans packages the Nix side still needs.**
`apt-get -s remove` prints a "no longer required" list that is easy to skim
past. Removing the audio set orphaned `rtkit` and, at that same moment,
`pulseaudio-utils` — both were marked manual to survive the removal. Neither
goes at removal time; an unmarked orphan goes to some later `apt autoremove`,
by which point the breakage gets blamed on something else entirely. Read
that list and `apt-mark manual` what is still in use, **as of that
moment** — that qualifier matters, because the two kept different fates.
`rtkit` stayed manual permanently: `rtkit-daemon` is a system service Nix can
never own (see Standing facts below). `pulseaudio-utils` did not — once
`pactl` and its siblings came from Nix (`home/audio.nix`'s
`pulseaudioClients`, in Phase 3b), it was removed on purpose. The sequence is
the instructive part: "rescued from autoremove" is not "kept forever", and
the standing fact further down that `pulseaudio-utils` is gone is that same
package at a later phase, not a contradiction of this one.

**Then this rule was written down here and not applied for four more specs, and
the backlog reached 137.** That is the single most expensive thing in this file,
because the cost is not the two packages the rule was written about — it is that
`apt-get -s autoremove` came to propose removing 137 packages at once, none of
them orphaned by anything current, so that whoever finally ran it would see the
breakage attributed to whatever they had changed most recently. Spec 12 defused
it: 9 marked manual, **128 removed in one deliberate operation**, census now
`0`. Do not let it regrow. `home/apt-hygiene.nix` warns at every switch when the
count is above zero, but a warning is a smoke alarm, not a habit — the habit is
reading the "no longer required" list *at the moment of each removal*, which is
the only thing that prevents this.

**A hit from an in-use check is not a keep.** Spec 12's union check flagged six
of the 137, and four of them did not survive inspection — which means a bare hit
would have kept six packages for four wrong reasons. Classify every hit by *why*
the file is held. The shapes measured here:

- **A stale process of an already-removed package.** `libmng1` and
  `qt6-image-formats-plugins` were held by pid 3790, whose `/proc/3790/exe` read
  `/usr/bin/deskflow (deleted)` — `deskflow` had been removed in spec 10 and was
  gone from dpkg's database entirely. The hit measures history, not need. The
  `(deleted)` marker on `exe` is the cheap tell; note it is absent when the
  holder is an *interpreter* that survived (see the union rule above).
- **A font held by fontconfig mmap.** `xscreensaver`'s only held file was
  `/usr/share/fonts/xscreensaver/gallant12x22.ttf`, mmapped by Nix's `foot` —
  a Nix binary keeping a Debian package looking alive. Restart the holders, then
  it goes.
- **A live consumer that is itself orphaned.** `gir1.2-notify-0.7` and
  `python3-cups` were genuinely held by a genuinely running process — pid 3823,
  the printer applet — but `system-config-printer`, which *is* that process, was
  in the census too. A consumer inside the census keeps nothing alive on its own;
  the question collapses into "is the consumer wanted?", which is a user
  question, not a measurement. Both went.

So a hit only becomes a keep when the consumer is live, wanted, and **outside**
the census. Note the fourth shape — a keep with no explanation at all — did not
occur in spec 12's six hits, but it remains the conservative default if it does.

**nixpkgs relocates GSettings schemas, and then wraps the binary to find
them.** Schemas live at `share/gsettings-schemas/<name>/glib-2.0/schemas`, a
path GLib never searches — but `wrapGAppsHook` produces a `bin/<name>` wrapper
that prefixes `XDG_DATA_DIRS` with every schema directory the application
needs, so a Nix GTK application works on Debian with no help from this flake.
The thing to check is that the wrapper *exists*: a package that missed the hook
aborts at startup with `Settings schema … is not installed`, which reads as a
broken package rather than a missing environment. Detect it by the
`.<name>-wrapped` sibling in `bin/`, not by grepping the binary —
`makeWrapper` emits a shell script and `makeBinaryWrapper` an ELF, and a check
that understands only one passes vacuously on the other.
`home/gui-apps.nix`'s `wrappedGuiApps` is the guard for this property, and it is
the only one — spec 10 first wrote that `gui-desktop-ids` was "the other half"
of it, which is false: that check asserts `.desktop` ids and contains no schema
or wrapper logic at all. The three checks spec 10 added cover three unrelated
properties, and conflating any two of them is how a guard comes to look
load-bearing for something it never touches:

| check | property | where |
|---|---|---|
| `wrappedGuiApps` | every non-exempt GUI package has a wrapped binary | `home.packages` |
| `dbusActivatableGuiApps` | every package shipping a D-Bus service file has an `xdg.dataFile` mirror | `home.packages` |
| `gui-desktop-ids` | the `.desktop` ids this flake must ship are present | `checks` |

**`wrappedGuiApps`' exemption is an explicit table, and the derived form was
tried and disproved.** Spec 10 shipped a derived rule — "ships no schemas of its
own, therefore nothing to wrap", spelled `[ ! -d "$pkg/share/gsettings-schemas" ]`
— and it was deleted after review, because a GTK application that had merely
*missed* `wrapGAppsHook` takes that exempt path and aborts at startup anyway,
which is the exact failure the guard exists to turn into a build error. Spec 13
replaced it with `wrapExemptions` in `home/gui-apps.nix`: an attrset of pname →
reason, keyed by `lib.getName` so an entry survives a version bump and only a
version bump. Two entries today, `signal-desktop` and `bitwarden-desktop`, both
Electron with genuinely nothing to wrap.

A name in a table has to be typed by a person who then has to write the
sentence beside it. A predicate exempts every future package that happens to
satisfy it, including the one that satisfies it by accident, and nobody is
asked a question at that moment. Do not derive it again.

**An exemption that stops being true fails the build; it does not accumulate.**
Three branches, all three proven by mutation with the mutation confirmed by a
count before the build ran:

| branch | fires when | message |
|---|---|---|
| missing | a non-exempt member has no `.*-wrapped` | `<name> has no wrapped binary in bin/.` |
| **stale** | an *exempt* member has gained one upstream | `<name> is on wrapExemptions but ships N wrapped binary(ies).` |
| **vacuity** | every member is exempt | `every guiPackages member is on wrapExemptions.` |

The stale branch is what separates this from an allowlist: an allowlist only
grows, and an entry that has stopped being true goes on excusing a package that
has started needing the check, silently, because nothing re-reads it. The
vacuity anchor is the same one `gui-desktop-ids` and `no-pulseaudio-daemon`
carry — without it the guard prints an `ok` line per member while requiring
nothing of any of them.

**And gammastep is the counterexample to that reasoning, not an instance of a
package that would have broken — `home/gui-apps.nix`'s own comment overstates
this and has not been corrected in the file.** What is measured:

```sh
SH=$(sg nix-users -c 'nix eval --raw .#homeConfigurations."isutton@suffer".pkgs.seahorse')
find "$SH" -name '*.gschema.xml' | wc -l                                  # 3
strings "$SH/bin/.seahorse-wrapped" | grep -oE 'org\.gnome\.[a-z.]*' | sort -u
# org.gnome.crypto.pgp, org.gnome.keyring., org.gnome.seahorse{,.manager,.window}

GA=$(sg nix-users -c 'nix eval --raw .#homeConfigurations."isutton@suffer".pkgs.gammastep')
find "$GA" -path '*gsettings-schemas*' | wc -l                            # 0
strings "$GA/bin/.gammastep-wrapped" | grep -oE 'org\.[a-z]+\.[a-zA-Z.]*' | sort -u
# org.freedesktop.DBus.Error.AccessDenied, org.freedesktop.DBus.Properties.Set,
# org.freedesktop.GeoClue   -- D-Bus names, not GSettings schema ids
```

seahorse's wrapper is load-bearing: three schemas of its own and a binary that
names them. gammastep's main binary reaches for no schema at all, so the two
directories its wrapper prefixes (`gtk+3` and `gsettings-desktop-schemas`) look
**incidental** — `wrapGAppsHook` adds what the closure offers whether the
binary wants it or not. "Ships no schemas of its own" genuinely does not imply
"needs no wrapper", and that is the whole disproof; gammastep is not evidence
that any package on this machine *would* have broken.

The package that would break is a GTK application with no schemas of its own
that reads a **dependency's**. The nearest thing here is `gammastep-indicator`,
and whether it qualifies is **unmeasured**: `.gammastep-indicator-wrapped` is a
16-line launcher stub with no toolkit token in it, but the module it imports is
a real GTK 3 application —

```sh
M="$GA/lib/python3.13/site-packages/gammastep_indicator"
grep -ohE 'Gtk|Gio|GLib|GSettings|AppIndicator|AyatanaAppIndicator' "$M"/*.py | sort | uniq -c
# 2 AppIndicator / 2 AyatanaAppIndicator / 24 GLib / 28 Gtk
```

— with no `Gio` or `Settings` reference anywhere in it, against six GTK 3
schemas in the closure (`org.gtk.Settings.{ColorChooser,Debug,EmojiChooser,FileChooser}`,
`org.gtk.Demo`, `org.gtk.exampleapp`) that a status-icon application plausibly
never opens. Plausibly is not measured. Either way the table is unaffected:
gammastep is wrapped, so it takes the checked path and never the exempt one.
Do not read the `.nix` comment as saying gammastep was a casualty.

**A `.desktop` file's winning entry and its winning binary are chosen by two
different search paths.** `XDG_DATA_DIRS` decides which `.desktop` a launcher
reads; a bare-name `Exec=` is then resolved through `PATH`. While both a Debian
and a Nix package are installed, those can disagree — Nix's `.desktop` running
Debian's binary, or the reverse. Same shape as spec 6's `fumon`. Removing the
apt package is part of making it deterministic, not cleanup afterwards.

**`.desktop` ids are not stable across the Debian/Nix boundary.** nixpkgs'
`signal-desktop` ships `signal.desktop` where Debian's ships
`signal-desktop.desktop`, and `~/.config/mimeapps.list` named the Debian id for
`x-scheme-handler/sgnl` and `x-scheme-handler/signalcaptcha`. Migrating Signal
without checking kills both handlers silently. Some ids *are* identical —
`firefox-esr.desktop`, `bitwarden.desktop`,
`org.gnome.seahorse.Application.desktop` — which is worse than none being
identical, because it invites the assumption.

**Spec 13 made this concrete, and it is no longer a hypothetical.** Signal
moved; both handlers were rewritten to `signal.desktop` by
`home/apps.nix`'s `signalMimeappsId` activation hook — narrow, idempotent,
non-fatal, and ordered `entryBetween [ "mimeappsIds" ] [ "writeBoundary" ]` so
the fixer runs before the reporter. `bitwarden` migrated in the same spec with
its id unchanged, which is the identical-id trap sitting right beside the
non-identical one; do not generalise from either. Live state:

```sh
xdg-mime query default x-scheme-handler/sgnl           # signal.desktop
xdg-mime query default x-scheme-handler/signalcaptcha  # signal.desktop
xdg-mime query default x-scheme-handler/bitwarden      # bitwarden.desktop
```

And `gui-desktop-ids` now covers ids handlers actually reference, which is the
property it declared in spec 10 and could not reach until spec 11 widened it to
both trees. `required` holds **6** ids; **3** of them are named in
`~/.config/mimeapps.list`, across **8** handler lines:

```sh
for id in org.gnome.seahorse.Application.desktop gammastep.desktop \
          gammastep-indicator.desktop eu.calangotech.CalangoOpen.desktop \
          signal.desktop bitwarden.desktop; do
  printf '%-45s %s\n' "$id" "$(grep -cF "$id" ~/.config/mimeapps.list || true)"
done
# eu.calangotech.CalangoOpen.desktop  5 ; signal.desktop  2 ; bitwarden.desktop  1
# the other three read 0 -- launcher ids with no association
```

Count that list from `flake.nix` rather than quoting these numbers; they move
whenever `required` or `mimeapps.list` does.

**A Nix comment and a shell comment are not the same thing, and the difference
is which side of the string boundary it is on.** A `#` comment in a Nix
expression — inside a `lib.makeBinPath` list, say — does not reach the
derivation and cannot change its hash. A `#` comment inside a `''…''` string
that becomes `buildCommand` **is** part of the derivation, so editing it moves
the output path. Both claims were made on the same branch, the second one
asserting byte-identical derivations across generations; it was disproved by
diffing them, where `inputDrvs`, `inputSrcs`, `args`, `builder` and `system`
were identical and `buildCommand` differed by exactly one comment line. If you
want to know whether a comment mattered, diff the derivation rather than
reasoning about the comment.

**A Home Manager module's `cfg.<option>` is the resolved value, not a record
that someone set it.** `services.syncthing` creates `syncthing-init` -- a
oneshot that PATCHes the running configuration over syncthing's REST API --
whenever `settings` is non-empty, `guiCredentials` is set, or

    hasCustomGuiAddress = cfg.guiAddress != defaultGuiAddress

is true. Spec 15 first claimed that writing `guiAddress = "127.0.0.1:8384"`
explicitly -- the module's own default -- would trip that and turn the writer
on. It does not: the comparison reads the merged value, so an explicit
assignment equal to the default is indistinguishable from no assignment and is
a genuine no-op. The claim conflated "the option was set" with "the value
differs from the default", reached a spec, a plan and a guard's own error
message, and was caught by an implementer who read the module source instead of
the paragraph describing it.

What is true is smaller and still worth guarding: three unrelated-looking
options each switch on a writer that rewrites a config this flake does not own.
`home/syncthing.nix` asserts on the *effect* -- that `syncthing-init` does not
exist -- which catches every case where setting one of them would do something,
and by construction cannot catch a redundant write. If you need to know whether
an option was written at all rather than what it resolved to, the module system
answers that with `options.<path>.isDefined`, not with a value comparison.

**`tray.target` exists here, is Home Manager's, and was inactive for its whole
life until spec 15.** It is `~/.config/systemd/user/tray.target`, "Home Manager
System Tray", `Requires=graphical-session-pre.target` -- and it carries no
`[Install]` section, so nothing pulled it in. Any Home Manager tray service is
`Requires=tray.target`, and an earlier version of this entry said that meant
such a service was unable to start at all. That is wrong:
`Requires=` is an activation dependency, so the consumer pulls the target in
itself -- measured, `tray.target` has no `ExecStart`, `RefuseManualStart=no`,
and its own `Requires=graphical-session-pre.target` is satisfied. The target was
inactive because nothing had ever asked for it, not because anything prevented
it. `home/quickshell.nix` declares `Wants = [ "tray.target" ]` so the target is
active because the tray's *provider* runs, not only when a consumer asks --
quickshell owns `org.kde.StatusNotifierWatcher` and
`org.kde.StatusNotifierHost-*` on the session bus. Check with
`busctl --user list | /usr/bin/grep StatusNotifier` before assuming some other
component is the host.

---

## Standing facts about this machine

- **`bluez` cannot move to Nix.** `bluetoothd` runs from
  `/usr/lib/systemd/system/bluetooth.service` — a *system* unit — and
  standalone Home Manager writes only `~/.config/systemd/user`. Permanent apt
  dependency, by architecture. It is marked manual so `autoremove` cannot take
  it. Do not re-open this.
- **`gnome-keyring` stays on apt, deliberately — and this one was decided after
  a survey, not by default.** It serves `org.freedesktop.secrets` and
  `org.gnome.keyring` on the session bus and backs
  `org.freedesktop.impl.portal.Secret`, which `hyprland-portals.conf` names. It
  is a genuine candidate on paper, and three measurements say leave it:
  - **nixpkgs' package ships no systemd units and no D-Bus activation files.**
    `find <store> -path '*systemd*'` returns 0, where Debian ships two units
    and three activation files. Every migration in this project copied units
    verbatim; here all five artifacts would have to be hand-authored, which is
    the drift the copy-verbatim rule exists to avoid.
  - **`pam_gnome_keyring.so` is in `/etc/pam.d/greetd`** (`auth optional`, and
    `session optional … auto_start`), from Debian's `libpam-gnome-keyring`.
    That is the auto-unlock path. nixpkgs does ship the module at
    `lib/security/pam_gnome_keyring.so`, but using it means a root-owned
    system file referencing a `/nix/store` path — and if that path is ever
    garbage-collected or the package dropped, **login breaks**. Every other
    failure mode this project has accepted is recoverable from a running
    desktop. This one is not.
  - 48 → 50 is two majors, on `~/.local/share/keyrings/login.keyring`, a live
    file.

  Note the daemon is currently owned by the *systemd user unit*, not by PAM's
  `auto_start` — `/proc/<pid>/cgroup` puts it in
  `app.slice/gnome-keyring-daemon.service`. PAM's `auth` hook is what passes
  the login password through to unlock the keyring, and that is the part with
  no user-space replacement. Do not re-open this without answering the PAM
  question first.
- **`syncthing` and `syncthingtray` are Nix's, and they join `hypridle` and
  `hyprpolkitagent` as services this flake runs from an upstream Home Manager
  module rather than a copied unit.** An earlier draft of this entry called
  syncthing the *first* such migration. It is at least the third —
  `home/default.nix:231` declares `services.hyprpolkitagent` and
  `home/hyprland.nix:135` declares `services.hypridle`, and both packages are
  `rc` in dpkg, so both were real apt migrations. The claim was written without
  enumerating `home/*.nix`, which is the rule this file opens with, and it is
  recorded here because that is twice on one branch.

  What IS new with syncthing is narrower and is the part worth carrying: it is
  the first module adopted here that mutates state this flake does not own,
  in place and at runtime. `services.syncthing`
  creates `syncthing-init` -- a oneshot that PATCHes the live `config.xml` over
  syncthing's REST API -- whenever `settings`, `guiCredentials` or a non-default
  `guiAddress` is set. That is why those options are deliberately omitted in
  `home/syncthing.nix` rather than pinned, and why this flake gained its first
  `assertions`. The module's unit also adds four hardening directives Debian's
  lacks -- `LockPersonality`, `PrivateUsers`, `RestrictNamespaces` and
  `SystemCallFilter=@system-service` -- on top of the three they share; the
  results document records whether any had to be reverted.

  **The 1.x database is renamed, not deleted, and the name is the trap.**
  Migrating to 2.x leaves `~/.local/state/syncthing/index-v0.14.0.db-migrated`
  — 163 MB, intact — beside the new `index-v2`. A check written as
  `ls -d …/index-v0.14.0.db` therefore fails, and reads as "the rollback is
  gone". Spec 15's close-out shipped exactly that check and the wrong
  conclusion was one `ls` away from being recorded. A check for a file's
  *absence* proves nothing unless you know every name the file could have.
  Syncthing also writes its own `config.xml.v37` beside the upgraded config, so
  both halves of the rollback exist whether or not anyone arranged them.

  **2.1.2 neither honours nor rejects a folder with an empty id.** One such
  entry survives in `config.xml` with `paused=false` and `fsWatcherEnabled=true`;
  syncthing loads only the two real folders, logs no complaint, and the GUI
  cannot show it because the GUI lists loaded folders. Left in place, inert.

  One coverage gap, accepted on purpose: `syncthingtray` is installed by the
  module's own `home.packages`, so it is outside `guiPackages` and
  `wrappedGuiApps` does not check it. It is wrapped today --
  `.syncthingtray-wrapped` and `.syncthingctl-wrapped` both exist -- so nothing
  is broken; what is given up is a build failure if a future nixpkgs bump drops
  the wrapper.
- **`gcr4` cannot be removed either — it takes `gnome-keyring` with it.**
  `apt-get -s remove gcr4` removes `gcr`, `gcr4`, `gnome-keyring`, `seahorse`,
  `pinentry-gnome3` and `golang-docker-credential-helpers`; `gnome-keyring`
  declares `Depends: gcr (>= 3.4)`. So `gcr-ssh-agent` can be **masked but
  never uninstalled**, and a one-level `apt-cache rdepends` does not show this
  — it reports only `gcr`, which looks discardable. Simulate the removal.
- **The ssh agent is `gcr-ssh-agent`; openssh's `ssh-agent.service` and
  `.socket` are masked in `home/services.nix`.** Debian enables both, and both
  set `SSH_AUTH_SOCK` from `ExecStartPost` with no ordering between them, so
  which agent a shell talked to was decided by whichever activated last
  (measured: identical `ActiveEnterTimestamp`). `SSH_AUTH_SOCK` is now
  `/run/user/1000/gcr/ssh`. `gcr-ssh-agent` is a wrapper and runs openssh's own
  agent underneath on a private socket, so nothing is lost by the choice; it
  was kept because `gcr4` is a permanent resident anyway. Home Manager's
  `services.ssh-agent` is **not** a drop-in — it exports the variable only from
  shell initialisation, where Debian's socket sets it in the manager's
  environment, so adopting it would leave every GUI application that was not
  launched from a shell without it.
- **Open question, not a conclusion: can `gcr-ssh-agent` persist a key across
  logins?** The reason to prefer it would be keyring-backed passphrases. What
  was measured: `ssh-add` against its socket writes nothing to
  `~/.local/share/keyrings/login.keyring`, and the key does not survive even a
  restart of the agent — because `ssh-add` decrypts the key locally and sends
  the *decrypted key* over the agent protocol, so the agent never sees a
  passphrase to store. What was not measured: the binary links `libsecret` and
  carries `secret_password_storev`/`lookupv`, so a storage path exists that
  this probe did not reach. The likely trigger is on-demand loading of a key
  from `~/.ssh/`, which needs a test against real key material. Until someone
  runs that, treat keyring persistence as unproven.
- **The corp set stays on apt permanently:** `google-chrome-stable`, `code`,
  `1password`, `1password-cli`, `endpoint-verification`, and flatpak Slack
  (`com.slack.Slack`). Note `1password` is load-bearing beyond its own window:
  `~/.ssh/config` sets `IdentityAgent ~/.1password/agent.sock` for `github.com`,
  and that agent holds the SSH keys — which is why Debian's `ssh-agent` and
  `gcr-ssh-agent` serve nothing here.
- **A previous Home Manager generation is not a recovery path.** It lacks the
  uwsm session units, both portal backends, the portal frontend, the portal
  config and the font baseline. Recovery is fix-forward:
  `home-manager switch` from tty1, or
  `sudo dpkg -i /root/pkg-archive/uwsm_*.deb` (note: **root's** home).
- **One file outside `$HOME`:** `/usr/local/share/wayland-sessions/hyprland-nix.desktop`,
  root-owned, hand-created, covered by no Nix module. greetd needs it and
  nothing else supplies it.
- **A Nix binary that actually uses GL needs nixGL's *environment*. Needing your
  own *wrapper* is a separate question, and the answer turns on whether you are a
  systemd unit.** This file has now been wrong on this in both directions; the
  measurements below are what each claim rests on.

  Five things carry their own wrapper — the compositor, quickshell, hyprlock,
  hyprpolkitagent and the hyprland portal, all through `lib/nixgl.nix` as of
  the nixGL consolidation. The old enumeration, `grep -rn 'bin/nixGLIntel'
  home/*.nix`, now returns 0 — every site spells `nixgl.wrap`, `nixgl.wrapBin`
  or `nixgl.bin` instead, and none of them names `nixGLIntel` by hand. The
  obvious replacement is not clean either:

  ```sh
  /usr/bin/grep -rn 'nixgl\.\(wrap\|wrapBin\|bin\)' home/*.nix   # 7, not 5
  /usr/bin/grep -c 'pkgs.nixgl.nixGLIntel' lib/nixgl.nix          # 2, not 1
  ```

  Both over-count for the same reason spec 11's `AppLaunch.qml` guard once
  matched its own prose: `nixglSingleSource`'s failure message, in
  `home/default.nix`, spells out `nixgl.wrap`, `nixgl.wrapBin` and `nixgl.bin`
  by name so a person reading a broken build knows what to write instead — two
  lines that answer to the enumeration pattern without being a call site. And
  `lib/nixgl.nix`'s own header comment names `pkgs.nixgl.nixGLIntel` in prose,
  above the one line that actually defines it. Both have a clean syntax needle,
  and neither needs a list of names:

  ```sh
  /usr/bin/grep -rn 'nixgl\.\(wrap\|wrapBin\|bin\)' home/*.nix | /usr/bin/grep -v 'echo '
  # 5 -- the call sites; the exclusion drops the guard's own help text
  /usr/bin/grep -rnF '${pkgs.nixgl.nixGLIntel}' home lib
  # 1 -- the one definition, in lib/nixgl.nix
  ```

  **Session children inherit the five variables. Units do not.** Measured:

  ```sh
  systemctl --user show-environment | grep -cE '^(LIBGL_DRIVERS_PATH|GBM_BACKENDS_PATH|LIBVA_DRIVERS_PATH|__EGL_VENDOR_LIBRARY_FILENAMES|LD_LIBRARY_PATH)='
  # 0        <- the user manager carries none of them
  # a plain shell in the session: 5 of 5
  # quickshell.service        5 of 5   from its OWN wrap
  # hyprpolkitagent.service   5 of 5   from its OWN wrap
  # night-light.service       0 of 5
  # xdg-desktop-portal.service 0 of 5   unwrapped unit -- see below
  # xdg-desktop-portal-hyprland.service 5 of 5   from its OWN wrap
  ```

  There are **two** portal units and only one is wrapped.
  `xdg-desktop-portal-hyprland.service` -- the backend, the one this file's list
  means -- has `ExecStart` = `…-xdg-desktop-portal-hyprland-nixgl` and 5 of 5.
  `xdg-desktop-portal.service`, the frontend, has `ExecStart` = the bare
  `…-xdg-desktop-portal-1.20.4/libexec/xdg-desktop-portal` and 0 of 5, which is
  the ordinary case for an unwrapped unit and not an anomaly. An earlier version
  of this entry measured the frontend, did not notice it was the wrong unit, and
  recorded its expected zero as an open question.

  That is *why* the units are wrapped: a unit cannot inherit from the compositor,
  because the manager's environment never carried these. `home/default.nix:8-16`
  records hyprpolkitagent crashing for exactly this reason.

  **Not every Nix GUI binary needs them.** `foot` is Nix's, draws through wayland
  shm rather than GL, and `home/default.nix:53-55` keeps it as the control for
  precisely this: if foot opens and a GL client does not, the fault is the GL
  wrapper. And the only application measured under a stripped environment is
  `signal-desktop`; `bitwarden`, `seahorse` and `gammastep` were never stripped,
  so their dependence is inferred, not shown.

  An earlier version of this entry said four applications "draw without it" and
  concluded the parenthetical list was the whole rule. Signal draws without its
  own wrapper by inheriting the session's; strip the variables and Nix's mesa
  falls back to `/run/opengl-driver/lib`, which does not exist here:

  ```sh
  env -u LIBGL_DRIVERS_PATH -u GBM_BACKENDS_PATH -u LIBVA_DRIVERS_PATH \
      -u __EGL_VENDOR_LIBRARY_FILENAMES -u LD_LIBRARY_PATH signal-desktop
  # MESA-LOADER: failed to open dri: /run/opengl-driver/lib/gbm/dri_gbm.so
  # ANGLE Display::initialize error 12289: Failed to get system egl display
  # Initialization of all (2) EGL display types failed.
  # Exiting GPU process due to errors during initialization
  ```

  **So do not "clean up" the session inheritance.** It looks like a leak and it is
  load-bearing for every Nix GL application launched as a session child — which is
  every one the Applications panel starts. A spec to scrub it was one command from
  being written.

  **gammastep-indicator's wrapper is load-bearing, and GI_TYPELIB_PATH is what
  carries it.** Spec 13 left this open and the note that carried it forward
  described `.gammastep-indicator-wrapped` as a 16-line stub with no toolkit
  token. That is the python launcher; the wrapper is its 118-line sibling
  `bin/gammastep-indicator`. Adding its variables back to the bare stub one at
  a time — adding, not stripping, because a shell with none of them set
  returns the same failure whatever you strip — gives GI_TYPELIB_PATH alone as
  sufficient and XDG_DATA_DIRS as irrelevant. The indicator reads no GSettings
  schema from any source. So "ships no schemas" is not just an unsafe
  exemption predicate, it is not the right question at all.

  `ldd` still cannot answer the per-application question: it `dlopen`s its
  platform and GL plugins, so `ldd` is clean for a binary that aborts on first
  draw. The instrument is one person and one window.
- **That same inheritance breaks flatpak, and the fix belongs at the flatpak
  boundary.** The sandbox has no `/nix/store`, so the inherited paths resolve to
  nothing inside it and mesa loads no driver at all — Debian's flatpak Slack falls
  back to software rendering and loses VA-API too. Reproduced inside the sandbox:

  ```sh
  flatpak run --command=sh com.slack.Slack -c 'echo $GBM_BACKENDS_PATH'
  # /nix/store/…-mesa-26.1.5/lib/gbm:…      <- valid on the host, absent in here
  ```

  The file exists; the namespace does not contain it. Flatpak ships its own
  matched GL stack (`org.freedesktop.Platform.GL.default`), which is the
  accelerated path — our variables override it with dead paths. Unset them per
  application with `flatpak override --user --unset-env=…`, never by scrubbing the
  session. Do not mount `/nix/store` into the sandbox either: a host mesa against
  the runtime's own glibc is worse than the fallback.

  **This flake does not own those overrides, deliberately.**
  `~/.local/share/flatpak/overrides/` held seven files on 2026-08-17, and not
  one of them is Home Manager's: six 61-byte browser overrides from
  2026-08-06, for applications not installed as flatpaks and owned by nobody,
  plus a 255-byte `com.slack.Slack` written by hand that day. A managed file
  among them *would* reproduce the `pipewire-session-manager.service` alias
  shape — invisible to `no-dangling-home-files`, and dangling for ever when its
  module leaves — which is the reason not to add one. Run the override by hand
  for every flatpak application, and record it here.
- Recurring shape: a Nix library resolving a NixOS-only path
  (`/run/opengl-driver/lib`, `/run/wrappers/bin/polkit-agent-helper-1`,
  `/run/wrappers/bin/unix_chkpwd`). Fixed with scoped overlays in `flake.nix`,
  always with `--replace-fail` so an upstream change breaks the build.
- 218 MB of fonts under `~/.local/share/fonts` are owned by neither apt nor
  Nix; `~/.local/share/fonts/calango-desktop/` shadows the flake's
  `adwaita-fonts`.
- **`rtkit` cannot move to Nix,** for the same architectural reason as
  `bluez`: `rtkit-daemon` runs from
  `/usr/lib/systemd/system/rtkit-daemon.service`, a *system* unit, and
  standalone Home Manager writes only `~/.config/systemd/user`. It grants
  pipewire's `data-loop.0` thread `SCHED_RR` priority 20 — measured under
  Nix's pipewire. Marked manual so `autoremove` cannot take it. Do not
  re-open this.
- `pulseaudio-utils` is gone; `pactl` comes from Nix through
  `home/audio.nix`'s `pulseaudioClients`, which withholds the daemon
  deliberately. Never add `pkgs.pulseaudio` to `home.packages` —
  `flake.nix`'s `no-pulseaudio-daemon` check exists to stop exactly that.
- **The Applications panel resolves launched apps against `appPath`, which is a
  second and deliberately different list from `runtimeDeps`.** `runtimeDeps`
  answers "what does the shell run?"; `appPath` answers "what can the shell's
  users run?". One list served both until spec 11, and 57 of 59 bare-name desktop
  entries could not launch as a result — silently, because the diagnostic went to
  `/dev/null`. Do not merge them, and do not add `/usr/bin` to `runtimeDeps`:
  `ddcutil` and `swww` are probed with `command -v` there and are meant to fail.
  The launcher's own failures now print `AppLaunch: cannot resolve …`; a launched
  application's own output does not, on purpose, because
  `systemd-run --scope` execs into the app and that stderr would otherwise be
  quickshell's for the app's whole lifetime.
- **There is deliberately no foot server.** `pkgs.foot` ships
  `foot-server.service` and `foot-server.socket`, but they land in
  `~/.nix-profile/share/systemd/user`, which is not on the manager's UnitPath
  at all — so their presence in the store is not an oversight to be corrected.
  Debian's `foot` was removed because its unit *was* enabled, by two root-owned
  links, and had been running a 1.21.0 server for months while every terminal
  on screen was Nix's 1.27.0: a mixed-provenance shadow of the same shape as
  spec 6's `fumon`. Nothing used it — zero references to `footclient` anywhere
  in this repo, and `SUPER+Q` runs `foot` standalone. Server mode buys startup
  latency and, measured here, roughly 13 MB of private RSS per window beyond
  the first against a 15.7 MB baseline — a wash at two windows. It would also
  put every window in one process that parses the config once, which is a
  hazard for the quickshell theme switcher (see `home/foot.nix`, which records
  that a theme change already fails to reach an *open* window). Adopt it only
  after testing that interaction.
- **`seahorse` is Nix's; `gnome-keyring` and `gcr4` are Debian's, and that is
  correct rather than half-finished.** The coupling is D-Bus — `libsecret`
  talking to `org.freedesktop.secrets`, a stable cross-version API — not shared
  libraries. Nix's seahorse links Nix's own gcr inside its own process. This is
  the first client in this project to cross the boundary while its daemon did
  not, and it is the template for the remaining GUI applications.
- **`gammastep` is entirely Nix's.** It was a two-provenance split until spec
  10: `pkgs.gammastep` reached the night-light unit through
  `home/services.nix`'s `nightLightPath` but never through `home.packages`, so
  the unit ran 2.0.11 while a shell got Debian's 2.0.9. `nightLightPath` still
  names it explicitly on purpose — a unit that resolves its own binaries does
  not depend on `PATH` order. Specs 10 and 11 record a gamma-control failure on
  2026-08-17 (`Zero outputs support gamma adjustment`, every client refused);
  it was compositor state, not this package or this flake, and the reboot at
  15:27 that day cleared it — a full mid-session stop and restart of
  `night-light.service` afterwards logged zero such warnings — so read those
  documents as a resolved incident rather than an open one.
- **`lf` is entirely Nix's, as of spec 14 — and the way it nearly went wrong
  generalises to every future migration.** apt's `lf` was `ii`, manual, with
  zero reverse dependencies, shadowed on `PATH` by Nix's r41: the same
  two-provenance split spec 10 found with gammastep. What made it more than one
  `apt remove` is that `home/lf.nix` wrapped it with `writeShellScriptBin`,
  **which produces a package holding exactly one file**. So `bin/lf` reached the
  profile and lf-41's whole `share/` tree — bash, fish and zsh completions,
  `lf.1.gz`, `lf.desktop` — did not, and apt's package was quietly the only
  source of lf completions on this machine. `find ~/.nix-profile/share -iname
  '*lf*'` returned nothing.

  `writeShellScriptBin` is the obvious way to add a `PATH` to a binary and it
  silently discards everything else the package ships. Use `symlinkJoin` over
  the real package plus `wrapProgram`, which is what `home/lf.nix` does now.
  Check any other wrapper in this tree the same way before trusting it: build
  the thing `home.packages` actually receives and list its `share/`.

  Two smaller traps met while verifying it. The bash completion installs as
  `completions/lf.bash`, not `completions/lf`, so looking for the un-suffixed
  name reads as a missing file. And files present is not completion working —
  test the loader:

  ```sh
  bash -lic '. /usr/share/bash-completion/bash_completion; _comp_load lf; complete -p lf'
  # complete -o filenames -F _lf lf
  ```

  Removing apt's `lf` took five packages with it — `ueberzug` and its
  `libxres1`, `python3-attr`, `python3-docopt`, `python3-xlib`. Nothing here
  wanted them: `lf/preview` calls `chafa`, `kitty` and `sixel`. Note `ueberzug`
  is a Python program, so the union instrument was required to establish its
  absence; a `/proc` walk alone cannot see an interpreted program.
- **`signal-desktop` and `bitwarden` are Nix's, as of spec 13.** Both apt
  packages are `rc` — removed, conffiles retained — and both binaries resolve
  to `~/.nix-profile/bin`. Three things to carry:
  - **The nixpkgs attribute is `bitwarden-desktop`.** Plain `pkgs.bitwarden`
    throws `'bitwarden' has been renamed to/replaced by 'bitwarden-desktop'`
    — a `throw` from the alias machinery, so it fails at eval with a message
    naming the fix rather than silently installing nothing. The *binary* is
    still `bitwarden` and the `.desktop` id is still `bitwarden.desktop`; only
    the attribute differs. `lib.getName` returns `bitwarden-desktop`, which is
    what `wrapExemptions` is keyed by.
  - **Both are exempt from `wrappedGuiApps`, on purpose.** Electron, not GTK:
    one binary each, zero `.*-wrapped` siblings, zero `share/gsettings-schemas`
    directories. They are the first and only entries in `wrapExemptions`.
    Neither ships `share/dbus-1/services`, so `dbusActivatableGuiApps` owes
    them nothing and says so itself with `ok (no activation files)`.
  - **The GL verdict is narrower than it sounds. Neither *requires nixGL to
    draw a window* — that is what the user measured, both windows opened bare
    and unwrapped in the live session. Whether either is GPU-accelerated is
    unmeasured**, because Electron falls back to SwiftShader silently and the
    window looks identical either way. The check needs one of them running:
    `grep -cE 'swiftshader|libEGL_mesa|iris_dri' /proc/<pid>/maps` over every
    pid in the tree (the GL stack is in a child process, so the top-level pid
    gives a misleading zero) — `swiftshader` means software, `iris_dri` means
    the Intel GPU path. Do not answer a future "it feels sluggish" with "GL was
    established"; it was not.

  One more thing that is not about these two packages specifically: **running a
  newer build of an application once can migrate a config directory the older
  build then cannot read.** `~/.config/Signal` is 116 MB of message history in
  an encrypted database, and both live directories were written during the
  bare-binary GL test. Backups were taken first. Whether a schema migration
  actually happened was deliberately left unestablished — finding out means
  starting the old build against the migrated config, which teaches nothing the
  backup does not cover and risks damage if it has not migrated. Treat every
  future GUI migration's *first launch* as the one-way step, not the apt
  removal.
- **`flatseal` and `fresh-editor` stay on apt.** `flatseal` is absent from
  nixpkgs and is really a flatpak; nixpkgs' `fresh-editor` is 0.3.6 against
  Debian's 0.4.7, so moving it would be a downgrade.
- **`~/.config/mimeapps.list` has at least two dead associations, and they are
  not this flake's.** `eu.calangotech.KBrowserSelector.desktop` — the stale
  root-owned entry `home/apps.nix`'s `defaultBrowser` hook displaced in
  `[Default Applications]`, still named by both `[Added Associations]` lines,
  and present nowhere on disk — and `slack.desktop`, where the only Slack entry
  on the search path is flatpak's `com.slack.Slack.desktop`, a different id.
  "At least two" rather than exactly two: the count was measured in one shell's
  `XDG_DATA_DIRS`, not the activation script's, and a narrower search path can
  only report more missing ids. This is why `home/apps.nix`'s `mimeappsIds`
  hook is **non-fatal by requirement rather than by convenience** — a fatal
  version would now abort every switch on this machine over associations this
  flake does not own and never will.
- **Nine packages are permanently `apt-mark manual`, and all nine for one
  reason:** `libpipewire-0.3-modules`, its two hard `Depends` `libffado2` and
  `libroc0.4`, and their chain `libconfig++11`, `libglibmm-2.4-1t64`,
  `libxml++2.6-2v5`, `libsigc++-2.0-0v5`, `libopenfec1`, `libspeexdsp1` —
  1 + 2 + 3 + 2 + 1, verified by reading each package's `Depends`. 12166 KiB
  in total, from `${Installed-Size}`. They fill the compiled-in module directory
  of **Debian's** `libpipewire-0.3.so`, which `libfluidsynth3` and
  `qemu-system-gui` keep installed from outside the orphan set; a
  Debian-linked PipeWire client (a
  qemu VM's audio device, in practice) loads its protocol and client-node
  modules from there. Nix's pipewire is unaffected either way — it has its own
  closure. Every automated check clears these nine, because nothing that needs
  them was running, which is exactly why they are marked rather than trusted to
  a measurement. Do not re-litigate this against an in-use check; it cannot see
  the dependency.
- **The printer applet and GUI are gone by deliberate choice, and printing is
  not.** `system-config-printer`, `system-config-printer-udev`, `python3-cups`,
  `python3-cupshelpers`, `python3-smbc`, `cups-pk-helper`, `avahi-utils` and the
  `gir1.2-*`/`libhandy` set behind them were removed in spec 12, after the user
  was asked. The tray applet had been autostarting at every login through
  `/etc/xdg/autostart/print-applet.desktop`. What stays: `cups` and
  `cups-daemon` are `ii` and were never in the orphan set, `cupsd` and
  `cups-browsed` run as system services, and `avahi-daemon` is a separate
  non-orphaned package still running. So printing itself is unaffected — what
  was given up is the job-notification applet, the add-a-printer GUI and its
  network discovery. Re-adding it is `sudo apt install system-config-printer`,
  not a re-argument.
- **`gvfs-fuse` is gone, `gvfs` stays.** The FUSE bridge exposed GIO mounts as
  real paths under `/run/user/1000/gvfs` for programs that do not speak GIO. Its
  consumers here were `thunar` and `pcmanfm-qt`, both removed in spec 10; `lf`
  is the file manager now. At the moment of the decision the bridge was mounted
  and **empty**. Nothing requires it — `gvfs` neither `Depends` on nor
  `Recommends` it — so `gvfs` itself is untouched and `ii`. If MTP phones or SMB
  shares ever need to appear as real paths, this is the package to reinstall.
- **xscreensaver is gone; `hyprlock` and `hypridle` are the lock and idle
  path.** `xscreensaver`, `xscreensaver-data`, `xscreensaver-gl` and the
  `libglu1-mesa` / `libjpeg-turbo-progs` / `libturbojpeg0` behind them went in
  spec 12. There was no `~/.xscreensaver`, no running process, the shipped user
  unit was `disabled`, and this repository had zero references to it. It
  survived the in-use check only because its font `gallant12x22.ttf` was mmapped
  by Nix's `foot` — which is the fontconfig false positive above, and the reason
  terminals were restarted before the removal.

---

## The method that actually worked

Checks that read a **running process's own state** told the truth every time:

```
/proc/<pid>/exe        /proc/<pid>/cmdline      grep -c '/usr/' /proc/<pid>/maps
busctl --user status   systemctl --user show -p MainPID -p NRestarts
```

Checks that compared a **path, a name or an exit code** eventually lied. A unit
resolving to `~/.config/systemd/user` says nothing about which binary it
executes. `NRestarts=0` after a cold boot is worth more than `is-active` after
a warm start.

**Prove a check can fail before trusting it.** Three checks in spec 6 passed
while the property they stood for was false, and two guards in `home/uwsm.nix`
were only trusted after being verified by mutation.

**And prove it against the property it claims to cover, not just against
itself.** Spec 10's `gui-desktop-ids` was proven able to fail by mutation and
still did not do what it said: it declared coverage of the ids
`mimeapps.list` names *and* this flake provides, while reading only
`home-path/share/applications` — and the single id satisfying both halves is an
`xdg.dataFile` entry landing in `home-files/.local/share/applications`. It
passed because every id it actually listed was one no handler references, so its
stated purpose was unreachable by its own mechanism. Same species as spec 6's
three checks, and caught by a reviewer rather than by production. Read a
check's declared scope against the paths it really searches.

**And check what could satisfy it besides the property.** Spec 11 made this the
third of the shape and the cheapest to have avoided: its `appPath` guard grepped
`AppLaunch.qml` for `/usr/bin`, and that file's own comments contain the string,
so the guard read its own prose. It was written, built green, and would have
shipped as a check that could not fail — except that the rule above forced a
mutation, and the mutation passed. Before trusting a guard, ask what else in the
haystack answers to the needle.

The three instances now have one shape between them. Spec 6's checks looked at
the wrong thing, spec 10's looked in the wrong place, and spec 11's found the
right string in the wrong role. All three passed. All three were caught by
mutation or by a reviewer, never by the check itself — which is the argument for
mutating every guard rather than only the ones that look risky.

The deeper pattern is not laziness. In every one of these cases a real command
was run and real output was read; the error was in the *conclusion drawn
afterwards*, which the measurement did not support. Enumerate by syntax, never
by a remembered list of names — including inside a document that says so.

**Spec 10 reproduced this inside a controller ruling**, which is worse than in a
comment: a ruling is what the rest of a task is built on. The ruling held that a
mid-session restart of the night-light client was the first the machine had ever
logged, generalised from a 40-line journal window containing only the four
preceding boots; the full journal shows warning-free mid-session toggles on
08-13, 08-14 and twice on 08-15. It was withdrawn, but not before reaching a
committed document. And the union-instrument rule above — that a process-absence
claim must union `ps -eo args` over *full* command lines with a `/proc` walk —
was violated on that same branch despite already being written here: an exe-only
walk backed the decisive step, and a reviewer found a process it had missed. A
rule being documented is not a rule being followed; check the instrument against
this file when the claim is load-bearing.
