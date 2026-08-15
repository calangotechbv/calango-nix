# calango-nix spec 6: the session scaffolding

Spec 5 left one structural thing unmigrated and said so plainly: the systemd
user units that start and hold this session belong to apt's `uwsm`. This spec
moves them to Nix's and removes the apt package.

It is the last item on the board that changes what the system *is* rather than
tidying it. Everything after this — `ydotool`, the xkbcommon pins,
`/run/opengl-driver` — is housekeeping or someone else's dependency graph.

## Corrections to the record

Three claims in spec 5's results document and one code comment are wrong or
stale. They are corrected here rather than left to be rediscovered, because two
of them are the reason this spec looked bigger than it is.

**"The session's scaffolding is Debian's."** Half true, and the half that is
false is the important half. The launch chain measured on 2026-08-15:

```
greetd/tuigreet
  └─ /usr/local/share/wayland-sessions/hyprland-nix.desktop   root-owned, hand-installed
       └─ $HOME/.nix-profile/bin/uwsm start -e -D Hyprland …  Nix's uwsm CLI
            └─ systemctl --user start wayland-session-envelope@…
                 └─ /usr/lib/systemd/user/wayland-wm@.service apt's unit templates
                      └─ start-hyprland → Hyprland            Nix's compositor
```

Nix's uwsm *binary* already drives the session. What is Debian's is the set of
unit templates it drives. The split runs down the middle of one tool, and it
works today only because both sides are upstream 0.26.4. That coincidence is
the actual risk, and it expires at the next `nix flake update`.

**"Nix's equivalent templates are not on any path systemd searches."** False.
`systemctl --user show -p UnitPath` puts `~/.config/systemd/user` at position 5
and `/usr/lib/systemd/user` at position 15. Home Manager already writes to
position 5 — ten units live there now. There is no path problem; there is only
the fact that nothing has put uwsm's templates there yet.

**"`wayland-session-bindpid@.service` hardcodes `/usr/bin/uwsm`."** True of
Debian's copy, which is the one running. Not true of Nix's, which is fully
store-pathed. The sentence read as a property of the unit; it is a property of
the packaging.

**`home/session.nix:73`** says "apt's Hyprland, hyprctl and hyprlock are all
still installed under `/usr/bin`, and an appended path would let them win."
Stale since spec 5: `/usr/bin/Hyprland`, `/usr/bin/hyprctl` and
`/usr/bin/hyprlock` do not exist, and `/usr/share/wayland-sessions` does not
exist as a directory. The *conclusion* — prepend, do not append — is still
right for other reasons, so the code does not change; the comment's premise
does.

## The inventory, measured

Fourteen unit templates ship in `${pkgs.uwsm}/share/systemd/user`. Diffed
file-by-file against `/usr/lib/systemd/user`:

| Unit | Debian vs Nix |
|---|---|
| `app-graphical.slice` | identical |
| `background-graphical.slice` | identical |
| `fumon.service` | identical |
| `session-graphical.slice` | identical |
| `wayland-session-bindpid@.service` | differs, 2 lines |
| `wayland-session-envelope@.target` | identical |
| `wayland-session-pre@.target` | identical |
| `wayland-session-shutdown.target` | identical |
| `wayland-session-waitenv.service` | differs, 2 lines |
| `wayland-session-xdg-autostart@.target` | identical |
| `wayland-session@.target` | identical |
| `wayland-wm-app-daemon.service` | differs, 2 lines |
| `wayland-wm-env@.service` | differs, 4 lines |
| `wayland-wm@.service` | differs, 2 lines |

Nine identical, five differing. **Every differing line is the same
substitution** — `/usr/bin/uwsm` becomes the Nix store path — plus
`bindpid@`'s `waitpid`, which Nix resolves to util-linux's store path instead
of a bare name. There is no structural or semantic divergence anywhere in the
set. That is what makes this spec small.

None of the nine identical files contains a `/usr` path at all, so nine of the
fourteen are safe by inspection.

### What else the apt package owns

`dpkg -L uwsm`, excluding docs, man pages and the units:

- Binaries Nix also ships: `uwsm`, `uwsm-app`, `fumon`, `uuctl`,
  `uwsm-terminal`, `uwsm-terminal-scope`, `uwsm-terminal-service`
- Binaries Nix does **not** ship: `ttyautolock`, `wait-tray`
- `/usr/libexec/uwsm/{prepare-env,signal-handler}.sh` — Nix ships both; the
  live session is already running Nix's `signal-handler.sh` (PID 2963)
- `/usr/share/uwsm/plugins/*.sh` including `hyprland.sh` — Nix ships its own
- `/usr/lib/systemd/user-preset/80-{fumon,ttyautolock}.preset`

Neither `ttyautolock` nor `wait-tray` is referenced anywhere in this flake, in
`hyprland.lua`, or in the quickshell tree. `ttyautolock.service` reports
`not-found` and is inactive. Losing both is accepted, and recorded here so that
"we did not notice" is not available as an explanation later.

`apt-cache rdepends --installed uwsm` is **empty**. Nothing on the system
depends on the package.

### Two units that are not uwsm's

`graphical-session.target` and `graphical-session-pre.target` appear in
`/usr/lib/systemd/user` but not in Nix's uwsm. `dpkg -S` attributes both to
**`systemd`**, not to `uwsm`. Removing uwsm does not touch them. This was
checked precisely because a missing `graphical-session.target` would take down
every service in this configuration that is `WantedBy` it.

### `fumon.service`, the one unit with an `[Install]`

`fumon.service` is active and enabled. Two properties matter:

1. Its `ExecStart` is the **bare name** `fumon`, resolved against the user
   manager's `PATH`. That PATH already contains uwsm's store `bin`, so `fumon`
   resolves to Nix's copy today and will continue to after the apt package is
   gone. Bare-name resolution in a unit is the failure class this project has
   hit repeatedly, so it was measured rather than assumed.
2. Its enablement is a **root-owned symlink** at
   `/etc/systemd/user/graphical-session.target.wants/fumon.service` pointing at
   `/usr/lib/systemd/user/fumon.service`, created by the preset at install
   time. It is a third file outside both `$HOME` and this flake, and `apt
   remove` will either delete it or leave it dangling.

`ExecCondition` requires `notify-send`, which is `/usr/bin/notify-send` from
Debian's `libnotify-bin` — not owned by `uwsm`, so unaffected.

### The removal is one-way

The backports source was removed in spec 5, and there is no cached `.deb`:

```
$ apt-get install --reinstall --print-uris -y uwsm
Reinstallation of uwsm is not possible, it cannot be downloaded.

$ apt-cache policy uwsm
  Installed: 0.26.4+ds-2~bpo13+1
  Candidate: 0.26.4+ds-2~bpo13+1
 *** 0.26.4+ds-2~bpo13+1 100
        100 /var/lib/dpkg/status
```

The only remaining source for this package is the dpkg status file — that is,
the installed files themselves. Once removed, it cannot be reinstalled from any
repository. This single fact drives the whole recovery design below.

## Decisions

**Shadow first, then remove.** Home Manager installs Nix's units at position 5,
which wins over apt's position 15 immediately and reversibly. The apt package
comes out only after a reboot has proven the Nix units actually run the
session. The two steps are separated by a verification gate, not by a comment
saying they should be.

**All fourteen, not just the five that differ.** Overriding only the divergent
units would leave nine resolving to apt's copies, which vanish with the
package. The unit set is migrated whole or not at all.

**Symlinks to the store, not transcription into Home Manager's systemd
module.** Expressing these as `systemd.user.services.*` would mean
re-describing fourteen upstream units in Nix, which drifts from upstream and
loses exact semantics for no benefit. They are installed as `home.file`
symlinks pointing into a checked copy of uwsm's own directory.

**`sd-switch` does see these units, and that is the main risk in this spec.**
An earlier draft of this design claimed `home.file` entries sit outside
`sd-switch`'s set, so activation would leave them inert until the next login.
That is false, and reading the generated activation script is what disproved
it. `sd-switch` is invoked on directories, not on Home Manager's list of
module-declared units:

```
sd-switch --old-units $oldGenPath/home-files/.config/systemd/user \
          --new-units $newGenPath/home-files/.config/systemd/user
```

`home.file.".config/systemd/user/…"` lands in exactly that tree. All fourteen
units will therefore appear to `sd-switch` as newly added, and it will act on
them.

The specific danger has a name. `wayland-session-shutdown.target` declares:

```
Conflicts=graphical-session-pre.target graphical-session.target xdg-desktop-autostart.target
StopWhenUnneeded=yes
```

If `sd-switch` starts that target when it appears, systemd stops
`graphical-session.target` to satisfy the conflict — taking quickshell, the
portal, `hypridle` and `hyprpolkitagent` with it, and very likely ending the
session from inside a `home-manager switch`. This is not a hypothetical class
of failure; it is one unit with one directive.

Two measures address it, and both are required:

1. **A dry run before any real switch.** The activation script honours
   `DRY_RUN`, and `sd-switch` implements `--dry-run` as "print, but do not
   perform, the switch actions". Building the generation and running its
   `activate` under `DRY_RUN=1` prints `sd-switch`'s exact plan at zero risk.
   Whether it intends to start `wayland-session-shutdown.target` becomes a
   fact to read rather than a property to reason about.
2. **The first real switch runs from a TTY, with the graphical session logged
   out.** Then even a plan that starts the shutdown target has no session to
   tear down. This costs one logout and removes the failure mode entirely
   rather than betting on the dry run having been read correctly.

`home.file` remains the right mechanism — the alternative, transcription into
`systemd.user.*`, hands the same units to the same `sd-switch` while also
duplicating upstream. The mechanism was never the protection; the sequencing
is.

**A build-time assertion on the exact unit set.** The unit list is written out
by name, and the derivation that provides the files fails to build if
uwsm's directory ever contains a different set. This project's signature defect
is incomplete enumeration — cataloguing by one syntactic form and missing the
rest — and a hardcoded list with no cross-check is precisely that defect in a
new place. The assertion converts an upstream change from a silently missing
unit into a build error.

The comparison uses `LC_ALL=C` collation. Under the machine's locale, `ls`
returns `wayland-session@.target` before `wayland-session-waitenv.service`;
under C collation it does not, because `-` (0x2D) sorts before `@` (0x40). A
list written from unsorted `ls` output would fail the check on a correct tree.

**The flake owns `fumon.service`'s enablement.** Rather than depend on a
root-owned symlink that the removal is about to invalidate, the
`graphical-session.target.wants/fumon.service` link is installed by Home
Manager alongside the unit.

**`dpkg-repack` before removal.** Since apt cannot re-download the package, a
reconstructed `.deb` is the only artifact that can restore apt's units. It is
produced and parked *before* `apt remove` runs, not after.

## Non-goals

- **`ydotool`, the xkbcommon pins, `libcpptrace1`, `quickshell`.** The other
  five backports survivors are out of scope. `ydotool` has no consumer and its
  daemon is running twice, which is worth its own small change, but bundling it
  here would mix an irreversible session change with unrelated tidying.
- **`/run/opengl-driver` and the nixGL wrappers.** Out of scope, and demoted:
  a probe on 2026-08-15 showed `mesa-26.1.5` carries no `/run/opengl-driver`
  reference at all, so the claim that the symlink retires all five wrappers is
  not established. See the amended bullet in spec 5's results document.
- **Replacing greetd, tuigreet, or the root-owned session entry.**
  `/usr/local/share/wayland-sessions/hyprland-nix.desktop` already invokes
  `$HOME/.nix-profile/bin/uwsm` — Nix's — and needs no change.
- **Removing `/etc/pam.d/hyprlock`.** Still dead code, still not worth a root
  action.
- **Putting uwsm's units on `SYSTEMD_UNIT_PATH`.** Considered and rejected:
  `~/.config/systemd/user` already wins, so extending the search path would add
  a fragile mechanism to solve a problem that does not exist.

## Design

### `home/uwsm.nix`, a new file

```nix
{ config, lib, pkgs, ... }:

let
  # Every unit template uwsm 0.26.4 ships, in LC_ALL=C order. Written out by
  # name rather than read from the store directory with builtins.readDir: that
  # would be import-from-derivation, and it would trade a loud build failure
  # for a silent change in what gets installed. The uwsmUnits derivation below
  # cross-checks this list against the real directory, so a hardcoded list that
  # goes stale is a build error rather than a unit that quietly stops existing.
  #
  # C collation is not incidental. Under the machine's locale `ls` returns
  # wayland-session@.target before wayland-session-waitenv.service; under C it
  # does not, because '-' (0x2D) sorts before '@' (0x40).
  unitNames = [
    "app-graphical.slice"
    "background-graphical.slice"
    "fumon.service"
    "session-graphical.slice"
    "wayland-session-bindpid@.service"
    "wayland-session-envelope@.target"
    "wayland-session-pre@.target"
    "wayland-session-shutdown.target"
    "wayland-session-waitenv.service"
    "wayland-session-xdg-autostart@.target"
    "wayland-session@.target"
    "wayland-wm-app-daemon.service"
    "wayland-wm-env@.service"
    "wayland-wm@.service"
  ];

  # A copy of uwsm's unit directory that refuses to build if the set of units
  # has changed. The files are copied rather than symlinked so that the check
  # sits in the path of the files themselves -- nothing can consume the units
  # without having passed it. Copying preserves the absolute /nix/store paths
  # inside each unit, which is the whole point of using Nix's copies.
  uwsmUnits = pkgs.runCommand "uwsm-session-units" { } ''
    expected="${lib.concatStringsSep " " unitNames}"
    actual="$(cd ${pkgs.uwsm}/share/systemd/user && LC_ALL=C ls -1 | LC_ALL=C sort | tr '\n' ' ')"
    actual="''${actual% }"
    if [ "$expected" != "$actual" ]; then
      echo "uwsm's unit set has changed." >&2
      echo "  expected: $expected" >&2
      echo "  actual:   $actual" >&2
      echo "Update unitNames in home/uwsm.nix, then re-check that every" >&2
      echo "added or removed unit is accounted for in the session." >&2
      exit 1
    fi
    mkdir -p "$out"
    cp ${pkgs.uwsm}/share/systemd/user/* "$out/"
  '';

  unitLinks = lib.listToAttrs (map
    (n: lib.nameValuePair ".config/systemd/user/${n}" {
      source = "${uwsmUnits}/${n}";
    })
    unitNames);
in
{
  # The fourteen templates, at ~/.config/systemd/user -- position 5 on the user
  # manager's UnitPath, against /usr/lib/systemd/user at position 15. That
  # ordering is what makes these win; nothing has to be removed for them to
  # take effect.
  #
  # home.file rather than systemd.user.*, to avoid re-describing fourteen
  # upstream units in Nix and drifting from them.
  #
  # This does NOT keep them away from sd-switch. sd-switch is invoked on
  # $generation/home-files/.config/systemd/user, which is precisely where
  # home.file entries land, so it sees all fourteen as newly added and acts on
  # them. That matters because wayland-session-shutdown.target carries
  # Conflicts=graphical-session.target: if sd-switch starts it, systemd tears
  # the session down to satisfy the conflict.
  #
  # The protection is sequencing, not the mechanism -- the first switch is run
  # from a TTY with the graphical session logged out, after a DRY_RUN=1
  # activation has been read. See the spec's Phase 0 and Phase 1.
  home.file = unitLinks // {
    # fumon.service's enablement, owned here rather than inherited.
    #
    # It is currently enabled by a root-owned symlink at
    # /etc/systemd/user/graphical-session.target.wants/fumon.service, written
    # by apt's 80-fumon.preset and pointing into /usr/lib/systemd/user. Removing
    # the package either deletes that link or leaves it dangling, and neither
    # outcome should decide whether fumon runs. This link makes the flake the
    # owner.
    #
    # fumon.service's ExecStart is the bare name `fumon`, resolved against the
    # user manager's PATH. uwsm's store bin is already on it, so the bare name
    # reaches Nix's copy both before and after the apt package goes.
    ".config/systemd/user/graphical-session.target.wants/fumon.service".source =
      "${uwsmUnits}/fumon.service";
  };
}
```

`home/default.nix` imports it. No other file changes: `pkgs.uwsm` is already in
the profile, `home/session.nix`'s `compositorPath` already carries `uwsm`, and
the root-owned session entry already calls Nix's binary.

### Phase 0 — read `sd-switch`'s plan, change nothing

Build the generation and run its activation script with `DRY_RUN=1` and
`VERBOSE=1`, from the ordinary graphical session. Nothing is modified:
`sd-switch` receives `--dry-run` and prints its intended actions.

```
nix build --no-link --print-out-paths \
  .#homeConfigurations."isutton@suffer".activationPackage
DRY_RUN=1 VERBOSE=1 <result>/activate
```

Read the printed plan and record, for each of the fourteen units, what
`sd-switch` intends. The question that decides whether Phase 1 is safe in a
live session is whether `wayland-session-shutdown.target` is among the units it
would start. This phase is pure information; it is a gate on understanding, not
on state.

### Phase 1 — shadow, from a TTY with no graphical session

Regardless of what Phase 0 printed, the first real switch runs with the
graphical session logged out. Reading a dry run correctly and having no session
to lose are different kinds of assurance, and this step is cheap enough to take
both.

1. Log out of Hyprland entirely, back to greetd.
2. Switch to tty1 (`Ctrl+Alt+F1`) and log in there.
3. Run `home-manager switch`.
4. Read the activation output. `sd-switch`'s real actions are expected to match
   the Phase 0 plan; any divergence is recorded before going further.
5. Confirm the files landed and resolve correctly:

```
systemctl --user cat wayland-wm@.service | head -1
```

must name a path under `~/.config/systemd/user`, not `/usr/lib/systemd/user`.

This phase is reversible in the ordinary way: the previous generation still has
apt's units underneath it, because the package is still installed.

### Phase 2 — prove it across a reboot

Reboot, log in through greetd as normal, then require that **every live
session unit except systemd's own two** resolves under
`~/.config/systemd/user`. The rule is stated that way rather than as a count:
the instance names vary (`wayland-session-bindpid@<pid>.service` carries a
different PID each boot) and `session-graphical.slice` may or may not be
loaded, so a fixed number would be a check that fails for the wrong reason.

```
systemctl --user list-units --all --plain --no-legend \
  | awk '{print $1}' | grep -E 'wayland|fumon|graphical' \
  | while read -r u; do
      printf '%-58s %s\n' "$u" \
        "$(systemctl --user show -p FragmentPath --value "$u")"
    done
```

`graphical-session.target` and `graphical-session-pre.target` are expected to
stay under `/usr/lib/systemd/user` — they are systemd's, not uwsm's. Every
other line must be under `~/.config`. "Most of them" is not a pass.

Also required: compositor, `quickshell`, the portal, `hypridle`,
`hyprpolkitagent` and `fumon.service` all active, and no failed user units.

### Phase 3 — remove the package, one-way

Preserve a restore path first, because after this step none can be created:

```
sudo apt install dpkg-repack
sudo dpkg-repack uwsm            # writes uwsm_0.26.4+ds-2~bpo13+1_*.deb
```

Park the `.deb` somewhere durable and outside the repo — it is a binary
artifact, not source. Then:

```
sudo apt remove uwsm
```

Then inspect what became of the root-owned enablement symlink:

```
ls -l /etc/systemd/user/graphical-session.target.wants/fumon.service
```

Deleted and dangling are both acceptable — the flake now owns its own link at
position 5 — but which one happened gets recorded rather than assumed.

### Phase 4 — verify after a second reboot

The Phase 2 check again, plus:

- `dpkg -l uwsm` reports the package gone
- `/usr/lib/systemd/user/wayland-wm@.service` no longer exists
- five backports survivors remain, not six
- no failed user units

### Recovery, and how it differs from every previous spec

Every spec so far has had the same rollback story: activate the previous Home
Manager generation. **After Phase 3 that story is no longer true.** A previous
generation carries no uwsm units in `~/.config/systemd/user`, and apt's copies
will be gone, so rolling back produces a system with *no* session scaffolding
at all — a worse state than the failure it was meant to undo.

Recovery after Phase 3, in order:

1. **tty1.** `getty@tty1.service` is active and enabled, and greetd is on VT7,
   so a text console is always reachable. `home-manager` runs from a plain TTY.
2. **Fix forward.** Edit the flake from tty1 and `home-manager switch`. This is
   the expected path: the failure mode being guarded against is a wrong unit
   file, and a wrong unit file is editable.
3. **Restore apt's package** with `sudo dpkg -i` on the repacked `.deb`, if the
   Nix units turn out to be unusable rather than merely wrong.

Phases 1 and 2 remain conventionally reversible; only Phase 3 changes the
rules, and it runs only after Phase 2 has passed.

## Open items

- **The `graphical-session.target.wants` entry shares a directory Home
  Manager's systemd module also generates.** HM writes its own wants links
  there (`bt-agent`, `hypridle`, `quickshell` and three more) from
  `systemd.user.services.*.Install`. Adding a `home.file` entry with a distinct
  filename into the same generated tree is expected to merge cleanly, but it
  puts two mechanisms in one directory and the plan verifies it rather than
  assuming it. If they collide, the fallback is to enable `fumon.service`
  through an activation-time `systemctl --user enable` instead.
- **`ydotool` is the next small thing.** No consumer anywhere in the flake, and
  `ydotoold` is currently running as **two** processes (PIDs 2899 and 99089),
  which is its own minor defect. Removing the apt package is probably a single
  commit rather than a spec.
- **`ttyautolock` and `wait-tray` disappear with this removal.** Neither is
  referenced and `ttyautolock.service` is already `not-found`. If either turns
  out to be wanted later, it has no Nix counterpart in `pkgs.uwsm` and would
  need packaging.
- **The version coincidence ends here, deliberately.** Debian's uwsm and Nix's
  are both 0.26.4 today, which is why the current hybrid works. After this spec
  there is only one uwsm, so `nix flake update` can move it freely — that is
  the durable benefit, more than the one package removed.
- **`/usr/local/share/wayland-sessions/hyprland-nix.desktop` remains the only
  file this project installs outside `$HOME`**, unchanged by this spec, and
  still hand-installed per `system/README.md`.
- **`home/session.nix:73`'s comment premise is stale** (apt's Hyprland is gone).
  The conclusion it supports is still correct, so this spec corrects the comment
  and leaves the code alone.
