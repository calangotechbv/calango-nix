# Spec 16: a glue `.deb`, built by Nix

**Date:** 2026-08-18
**Host:** `suffer`
**Status:** design, approved in chat

---

## The problem

This flake has crossed the apt boundary fifteen times and has never been able
to *state* anything about the Debian side. Three consequences, all live:

1. **Knowledge lives in prose and nothing enforces it.** Twenty-two packages
   are `apt-mark manual` for reasons written only in `CLAUDE.md`. The nine
   behind `libpipewire-0.3-modules` are the sharpest case:

   ```sh
   apt-cache rdepends --installed libpipewire-0.3-modules
   # Reverse Depends:      <- empty
   ```

   Nothing but a flag stands between them and `autoremove`. Run
   `apt-mark auto libffado2` and no mechanism notices.

2. **Files outside `$HOME` are owned by nobody.** `CLAUDE.md` records
   `/usr/local/share/wayland-sessions/hyprland-nix.desktop` as hand-created and
   covered by no module. `dpkg -S` agrees: no package owns it. greetd needs it.

3. **Services this flake installs have no firewall vocabulary.**
   `/etc/ufw/applications.d/syncthing` exists on this machine **only** because
   a removed deb left it as an `rc` conffile. Purge `syncthing` and it goes.
   Nix runs the daemon; apt still owns its ufw profile.

## The approach

Build a Debian metapackage from Nix. A `.deb`'s control fields *are* a
declarative manifest, and apt already enforces them.

**Nix builds, apt installs, dpkg enforces.** No sudoers rule, no polkit
action, no privileged step inside a switch. Exactly one privileged act, typed
by a person:

```sh
sg nix-users -c 'nix build .#calangoDeb'
sudo apt install ./result/calango-desktop_0.239_all.deb
```

The version moves with every commit, so the exact number above will not
match what you get; everything else will.

| declaration | control field | enforced by |
|---|---|---|
| keep set | `Depends:` | apt cannot autoremove a dependency of a manual package |
| ban set | `Conflicts:` | apt refuses to install them |
| ufw profiles | conffiles in `/etc/ufw/applications.d/` | dpkg fires ufw's own trigger |
| system files | ordinary package files | dpkg |

`Depends:` is the substantive gain over `apt-mark manual`: a structural reverse
dependency instead of a flag, with the reason travelling in the control file.

### Why not the alternatives

**A report-only drift checker** was the first design. It cannot fix anything,
and `home/apt-hygiene.nix` already occupies that niche.

**An apply script run under `sudo`** was the second. It works, but it
reimplements what dpkg does natively, and it owns no files — so the ufw
profile and the greetd entry stay unowned.

**Automatic convergence** via a NOPASSWD sudoers rule was rejected. `sudo -n`
requires a password here, measured; granting NOPASSWD on `apt-get` puts an
unattended root package operation inside every switch. This project already
declined the analogous shape for `pam_gnome_keyring.so`.

---

## Measurements this design rests on

Every number below was taken on `suffer` on 2026-08-18. Re-take them rather
than trusting this list.

**The mechanism builds and is reproducible.** A probe derivation using
`pkgs.dpkg` 1.23.7:

```sh
nix build --rebuild                          # bit-identical on rebuild
/usr/bin/dpkg-deb --info calango-desktop.deb # Debian's dpkg 1.22.22 parses it
apt-get -s install ./calango-desktop.deb     # resolves clean, unprivileged
```

`fakeroot` is **not** required: `dpkg-deb --root-owner-group` alone gives
`root/root` ownership.

**A note on how that last claim was originally evidenced, because it is the
mistake this spec most wants its reader not to repeat.** An earlier version of
this passage showed `cmp with-fakeroot.deb without-fakeroot.deb # identical`.
Those two files were throwaway derivations built while drafting this spec, they
have never existed in the repository, and the line reproduced into `CLAUDE.md`
before a reviewer ran it and got `No such file or directory`. The conclusion was
correct and the transcript beside it was fiction. The claim is now carried by a
command anyone can run:

```sh
/usr/bin/grep -c fakeroot lib/deb.nix
# 0    -- the builder never invokes it, and the archive is still root/root
```

**ufw already provides the integration point.**

```sh
cat /var/lib/dpkg/info/ufw.triggers
# interest-noawait /etc/ufw/applications.d
sed -n '137,138p' /var/lib/dpkg/info/ufw.postinst
#     triggered)
#         ufw app update all || echo "Processing ufw triggers failed. Ignoring."
```

So the package needs **no `postinst`**. Dropping a file into that directory
makes dpkg fire ufw's own trigger.

**dpkg still owns an `rc` package's conffiles.**

```sh
dpkg -S /etc/ufw/applications.d/syncthing
# syncthing: /etc/ufw/applications.d/syncthing     <- syncthing is rc
```

Shipping that exact path would need a conffile handover between packages.
This spec sidesteps it with distinct names.

**The version scheme sorts correctly.**

```sh
dpkg --compare-versions 0.0+dirty20260818153504 lt 0.239   # true
dpkg --compare-versions 0.239 lt 0.240                     # true
```

**Every `Depends:` name resolves**, checked with `apt-cache policy` — all 22
have a candidate version.

**No ban-set member is `ii`**, so `Conflicts:` installs cleanly today. All 19
read `rc`, `un` or absent.

**One latent conflict exists and is wanted, and `Conflicts:` only protects it
on one of the two paths a user can hit it from.** `flatpak` is `ii` and
**Recommends** (not Depends) `xdg-desktop-portal (>= 1.6)`, which is `rc`.
Measured both ways with `apt-get -s install`: naming `xdg-desktop-portal`
explicitly alongside `calango-desktop` fails loudly (`E: unmet dependencies`).
Installing something that merely *recommends* it — `libglib2.0-tests`, say —
does not: apt silently drops `xdg-desktop-portal` from the install set, with
no warning and no error, and Debian's portal frontend simply stays absent
rather than being restored. `Conflicts:` still does its job either way — the
frontend never gets installed — but only the explicit path is loud.

**The greetd session file names no store path.**

```sh
/usr/bin/grep -c '/nix/store' /usr/local/share/wayland-sessions/hyprland-nix.desktop
# 0     -- it reaches Nix through $HOME/.nix-profile
```

That is what makes it safe for a root-owned package to own.

**syncthing's real listening sockets**, which fix the profile's contents:

```
tcp  *:22000            udp  *:22000            <- sync protocol, incl. QUIC
udp  0.0.0.0:21027      udp  [::]:21027         <- discovery
tcp  127.0.0.1:8384                             <- GUI, loopback only
```

---

## Architecture

Three layers, mirroring `lib/nixgl.nix` and its module.

### `lib/deb.nix` — the builder

A pure function of `{ pkgs }`, exposing one attribute:

```nix
{ pkgs }:
{
  build = { manifest, manifestFile, version }: pkgs.runCommand "calango-desktop-${version}" …;
}
```

It knows `dpkg-deb` and nothing about this machine. It assembles the payload
tree, writes `DEBIAN/control` and `DEBIAN/conffiles`, copies `manifestFile` to
`/usr/share/calango-desktop/manifest.json`, normalises mtimes, and builds:

```sh
mkdir -p pkg/DEBIAN pkg/usr/share/calango-desktop
cp ${manifestFile} pkg/usr/share/calango-desktop/manifest.json
# control, conffiles, ufw profiles and payload files written here
find pkg -exec touch -h -d @0 {} +
mkdir -p "$out"
dpkg-deb --root-owner-group -Zxz --build pkg "$out/calango-desktop_${version}_all.deb"
```

**`$out` is a directory, not the file.** apt needs a path ending in `.deb`
with a package-shaped name, so `nix build .#calangoDeb` must yield
`./result/calango-desktop_0.239_all.deb`. A bare-file output would give
`./result`, which `apt install` rejects.

Pinning every mtime before the build is what makes it reproducible. The value
is `SOURCE_DATE_EPOCH`, which Nix's stdenv sets to `315532800` (1980-01-01
UTC), with `@0` as the fallback.

An earlier version of this passage said `dpkg-deb` "clamps to its 1980 floor".
**It does not clamp at all** — that is a ZIP/FAT timestamp behaviour, and the
1980 in the probe's output came from `SOURCE_DATE_EPOCH` alone. The claim was
written from a real command whose output was 1980 and an invented mechanism to
explain it; it was caught by a reviewer who extracted `data.tar.xz` and read a
tar member's `mtime` with Python, getting `0` for a build that used a plain
`@0`. Note also that `dpkg-deb --contents` renders in local time, so the same
archive reads `1980-01-01` under `TZ=UTC` and `1979-12-31 21:00` here.

### `home/deb.nix` — the module

Declares the options, assembles the manifest, exposes
`config.calango.debPackage`, carries the assertions, and installs the drift
hook.

The manifest becomes a store path once, and both consumers read that same path:

```nix
manifestFile = pkgs.writeText "calango-deb-manifest.json" (builtins.toJSON manifest);
```

`builtins.toJSON` is deterministic here because Nix attribute sets are stored
sorted, so the same declaration always serialises to the same bytes. The
builder embeds this file in the package; the drift hook compares against it.

### Contributing modules

The point of the option namespace: a reason lives beside the thing that needs
it.

| module | contributes |
|---|---|
| `home/audio.nix` | `rtkit` and the nine `libpipewire-0.3-modules` packages |
| `home/syncthing.nix` | its ufw profile; `syncthing` and `syncthingtray` bans |
| `home/session.nix` | the greetd session file |
| `home/deb.nix` | entries with no natural owner: `bluez`, the keyring set, the corp set, the remaining bans |

### `flake.nix`

Bind `self` in the outputs signature, compute the version, pass it in through
the module list beside `calango.host`, and expose the package:

```nix
outputs = { self, nixpkgs, home-manager, nixgl, ... }:
…
calango.deb.version =
  if self ? revCount
  then "0.${toString self.revCount}"
  else "0.0+dirty${self.lastModifiedDate}";
…
packages.${system}.calangoDeb = suffer.config.calango.debPackage;
```

---

## The declaration

```nix
options.calango.deb = {
  version     = mkOption { type = types.str; };
  keep        = mkOption { type = types.attrsOf types.str;   default = {}; };
  ban         = mkOption { type = types.attrsOf types.str;   default = {}; };
  ufwProfiles = mkOption { type = types.attrsOf types.lines; default = {}; };
  files       = mkOption { type = types.attrsOf types.lines; default = {}; };
};
options.calango.debPackage = mkOption { type = types.package; readOnly = true; };
```

`attrsOf` merges across modules by key. Two modules claiming the same package
with different reasons is a module-system error, which is the right outcome:
it forces someone to decide.

`files` and `ufwProfiles` hold **content**, never a path. A path would put a
`/nix/store` reference in the manifest, which is both non-reproducible and the
hazard `CLAUDE.md` rejects for root-owned files.

### keep — 22 packages

Verified `ii` and `manual` on 2026-08-18. Reasons abridged here; the
implementation carries the full sentence from `CLAUDE.md`.

| package | reason |
|---|---|
| `bluez` | `bluetoothd` is a system unit; standalone HM writes only user units |
| `rtkit` | `rtkit-daemon` is a system unit; grants pipewire `SCHED_RR` |
| `gnome-keyring` | serves `org.freedesktop.secrets`; nixpkgs ships no units |
| `libpam-gnome-keyring` | `/etc/pam.d/greetd` auto-unlock; replacing it risks login |
| `ufw` | this package ships ufw profiles and relies on its dpkg trigger |
| `cups` | printing; the applet went in spec 12, the daemon did not |
| `google-chrome-stable`, `code`, `1password`, `1password-cli`, `endpoint-verification` | the corp set, permanently apt |
| `flatseal` | absent from nixpkgs |
| `fresh-editor` | nixpkgs has 0.3.6 against Debian's 0.4.7 |
| `libpipewire-0.3-modules` | fills Debian `libpipewire-0.3.so`'s compiled-in module dir |
| `libffado2`, `libroc0.4` | hard `Depends` of the above |
| `libconfig++11`, `libglibmm-2.4-1t64`, `libxml++2.6-2v5`, `libsigc++-2.0-0v5`, `libopenfec1`, `libspeexdsp1` | their chain, 1+2+3+2+1 |

### ban — 19 packages

Everything Nix now owns that apt could put back. All confirmed not `ii`.

`syncthing`, `syncthingtray`, `lf`, `signal-desktop`, `bitwarden`,
`gammastep`, `gammastep-indicator`, `foot`, `fumon`, `hypridle`,
`hyprpolkitagent`, `pipewire`, `wireplumber`, `xdg-desktop-portal`,
`xdg-desktop-portal-hyprland`, `hyprland`, `quickshell`, `pulseaudio`,
`pulseaudio-utils`.

The criterion excludes packages this project merely *removed*. `ueberzug` went
with `lf` because nothing wanted it, and `system-config-printer` was removed
after asking the user — `CLAUDE.md` says re-adding it is
`sudo apt install system-config-printer`, "not a re-argument". Banning either
would convert a reversible decision into a permanent one. `thunar`,
`pcmanfm-qt`, `xscreensaver`, `ydotool` and `deskflow` are excluded for the
same reason.

Note `pipewire` the daemon is banned while `libpipewire-0.3-modules` is kept.
They are different packages serving different consumers, and this pairing is
the clearest illustration of why the manifest carries reasons.

### ufwProfiles — one file, `calango`

```
[calango-syncthing]
title=Syncthing (calango-nix)
description=Syncthing sync protocol and local discovery
ports=22000|21027/udp
```

Named `calango` rather than `syncthing` because dpkg still owns
`/etc/ufw/applications.d/syncthing` while the package is `rc`, and the
profile is named `calango-syncthing` so it cannot collide in ufw's profile
namespace with the one that file defines.

**No GUI profile, deliberately.** 8384 listens on `127.0.0.1` only. Shipping a
profile for it would invite opening a port that must stay shut.

### files — one entry

`usr/share/wayland-sessions/hyprland-nix.desktop`, verbatim from the existing
hand-made file.

**`/usr/share`, not `/usr/local/share`.** Debian policy forbids packages
writing to `/usr/local`, and `/etc/greetd/config.toml` passes
`--sessions /usr/share/wayland-sessions:/usr/local/share/wayland-sessions`, so
greetd searches both — `/usr/share/wayland-sessions` does not currently exist.
The old copy is **not** deleted by this package. Removing it is a separate,
later, user step, taken only after a login has been confirmed against the new
one. Until then tuigreet shows two identical entries, which is cosmetic and
visible; the alternative is a login path that depends on an untested file.

---

## Drift detection

The package ships `/usr/share/calango-desktop/manifest.json` — the declaration
it was built from, and nothing else. **The version is not in the manifest**, so
an ordinary commit bumps the version without registering as drift.

**The comparison lives in a script, not inline in the hook.** This is a
testability requirement, not a style choice. The activation script runs only
under `DRY_RUN=1` for anyone but the user, and `DRY_RUN=1` makes `run` echo its
argument instead of executing it — so a hook body written inline can never be
executed by an implementer or a reviewer, and a guard nobody can run is a guard
nobody can prove able to fail. `lib/deb.nix` therefore exports:

```nix
driftCheck = pkgs.writeShellScript "calango-deb-drift" ''
  installed="''${1:-/usr/share/calango-desktop/manifest.json}"
  …
'';
```

`home/deb.nix`'s activation hook is then one line, `run ${driftCheck} || true`,
and an agent tests every branch by invoking the script directly against a
temporary file. Note the same child-shell fact `home/apt-hygiene.nix` records:
a body handed to a child inherits neither `errexit` nor `pipefail`, so the
`|| true` is defensive rather than load-bearing.

The script distinguishes **three** outcomes:

| state | test | message |
|---|---|---|
| not installed | file absent | `calango-desktop is not installed.` |
| stale | `cmp -s` differs | `calango-desktop is out of date.` + build/install commands |
| current | `cmp -s` matches | silent |

It also reports any ban-set member that is `ii`, because that is the condition
which blocks installation.

**The absence case is called out separately on purpose.** A missing file makes
`cmp` fail, and a hook that only tested "did `cmp` succeed" would report a
never-installed package identically to a stale one. `CLAUDE.md` catalogues
this: a check for a file's absence proves nothing unless you know every name
and every state the file could have. Spec 15 shipped exactly that mistake.

Non-fatal, for the reason `home/apt-hygiene.nix` records at length: this is
apt's state, not this flake's, and a switch must never abort over it.

---

## Guards

Every one must be proven able to fail by mutation, with the mutation confirmed
by a count before the build runs, and applied to a **tracked** file — a flake
build of a dirty tree does not see untracked additions.

| # | guard | property | where |
|---|---|---|---|
| 1 | non-empty keep | the vacuity anchor: an empty manifest must not pass | `assertions` |
| 2 | keep ∩ ban = ∅ | a package cannot be both required and forbidden | `assertions` |
| 3 | every reason non-empty | the `wrapExemptions` idiom: a name must carry a sentence | `assertions` |
| 4 | no `/nix/store` in the payload | a root-owned file must never name the store | `runCommand` in `home.packages` |

Guards 1–3 are `assertions` because they read merged option values, which is
what `home/syncthing.nix` established. Guard 4 must inspect built content, so
it takes the `nixglSingleSource` shape.

Guard 4's needle must be built by concatenation — `"/nix" + "/store"` — or the
guard's own source contains it and fails for ever. `lib/nixgl.nix` records the
same trap in the opposite direction.

---

## Acceptance

Build-time, runnable by an agent:

1. `nix build .#calangoDeb` succeeds.
2. `nix build --rebuild .#calangoDeb` passes — bit-reproducible.
3. `/usr/bin/dpkg-deb --info` and `--contents` parse it under Debian's dpkg.
4. `/usr/bin/dpkg-deb --field` shows the expected `Depends`, `Conflicts`.
5. `apt-get -s install ./result/*.deb` — resolves, `0 to remove`.
6. Each of the four guards fails under its mutation.
7. `calango-deb-drift` returns each of its three outcomes on demand:
   **current** against the manifest the flake just built, **stale** against a
   copy with one reason edited, and **not installed** against a path that does
   not exist. All three are reachable without root and without activation,
   which is why the comparison is a script.
8. `nix flake check` passes; the three existing checks still run.

Privileged, and therefore the **user's** steps only:

9. `sudo apt install ./result/calango-desktop_*.deb`.
10. **The central claim, and how to prove it.** That `Depends:` protects the
    keep set has been reasoned, not measured:

    ```sh
    sudo apt-mark auto libffado2
    apt-get -s autoremove | grep libffado2      # expect: proposed for removal
    sudo apt install ./result/calango-desktop_*.deb
    apt-get -s autoremove | grep libffado2      # expect: no longer proposed
    sudo apt-mark manual libffado2              # restore
    ```

    `apt-get -s` is a simulation, so nothing is removed at any point, and the
    final line restores the mark.
11. `ufw app info calango-syncthing` lists the profile after installation,
    which proves the dpkg trigger fired.
12. A login against `/usr/share/wayland-sessions/hyprland-nix.desktop`, before
    the `/usr/local` copy is removed.

---

## Known limitations, accepted

- ~~**The declaration is not yet authoritative.**~~ **Resolved 2026-08-18,
  after this spec was written.** All 22 keep-set members were *also*
  `apt-mark manual`, so deleting an entry from `keep` did not make the package
  removable — the mark still held it. They are now all `auto`, held solely by
  `calango-desktop`'s `Depends`, so the manifest is the single source of truth.

  The flip was licensed by isolating the claim first rather than by flipping
  everything and hoping: only `libpipewire-0.3-modules` was flipped, because
  the metapackage is its sole installed holder, and `apt-get -s autoremove`
  stayed at 0. Nothing else could have accounted for that. The accepted cost is
  the one this entry already named — removing the metapackage now exposes all
  22, `bluez` and `google-chrome-stable` among them.
- **ufw rules are declared nowhere.** The package ships the vocabulary;
  `sudo ufw allow calango-syncthing` remains a one-time human act. This is not
  laziness: `/etc/ufw/user.rules` is `0640 root:root`, `nft` and `iptables`
  both refuse an unprivileged read, and a guard that cannot observe its
  property is the failure mode this project has hit three times.
- **A dirty build cannot be installed over a clean one.** `0.0+dirty…` sorts
  below `0.<revCount>`, so apt treats it as a downgrade and refuses. That is
  intended — an installed artifact should trace to a commit — and `dpkg -i`
  remains the escape hatch for deliberate testing.
- **System-unit masking is out of scope.** A deb *could* ship
  `/etc/systemd/system/*.service → /dev/null`, giving this flake a capability
  standalone Home Manager has never had. It is a genuinely new power over
  system state and deserves its own spec.
- **Sweeping dangling `/etc/systemd/user/*.wants` symlinks is out of scope**
  for the same reason. The count is `0` right now.

---

## Constraints on implementation

- Every `nix` and `home-manager` invocation is wrapped `sg nix-users -c '…'`.
- **No agent runs a privileged command.** No `apt`, `apt-get`, `dpkg`,
  `apt-mark`, `ufw`, `flatpak` mutation; no `systemctl start/stop/restart/
  enable/disable/daemon-reload`; no `home-manager switch`; no `reboot`; no
  activation script without `DRY_RUN=1`. Items 9–12 above are the user's.
- `grep` in the interactive shell is ugrep-backed and silently returns `0` for
  a pattern containing `${`. Use `/usr/bin/grep`, with `-F` for a literal,
  whenever a count is load-bearing.
- Never read a package version from `nixpkgs#<pkg>`; it reads the registry,
  not this flake's pinned input.
- No path containing `.superpowers/` may appear in any committed file.
