# Spec 18: from a bare Debian 13 install to a calango-nix desktop

**Branch:** `bare-debian-bootstrap`
**Written:** 2026-08-19
**Status:** design approved in chat; not implemented

---

## The problem

Seventeen specs have moved this machine from apt to Nix. Not one of them can be
run in reverse on a new machine. Every module assumes a live session, a
`nix-users` group, a running Nix daemon, and a `$HOME` full of state that no
package and no flake owns.

The bootstrap knowledge exists in three places and agrees with none of them:

- `README.md` gives four commands for Nix and a paragraph on the group.
- `system/README.md` gives the session entry and a test account.
- **`/etc/greetd/config.toml` is `calango-desktop`'s reference copy, comments
  included.** It names `../install.sh` in its own header.

The last of those is an architectural defect, not an inconvenience. `README.md`
says `calango-desktop` "stays as a reference and is not an input to this
build". So the file that decides whether this machine can log in is defined by
a repository that is explicitly not an input. A bootstrap cannot exist until
that content moves here.

## Decisions

Five decisions were taken in the design conversation. Each one narrows the
spec, and each is recorded with what it excludes.

| # | Decision | Excludes |
|---|---|---|
| 1 | The target is a **second machine**; suffer keeps running | Live state migration: fonts, syncthing, Signal, the keyring, `~/.ssh` |
| 2 | The bootstrap **supplies the repositories**; a human installs the corp packages | Fetching seven third-party packages, and any corporate enrolment |
| 3 | Proof is a **drift check on suffer plus one qemu run** | A container harness, and a first run against real hardware |
| 4 | The root-owned half is **declared in the flake and applied by hand** | A second `.deb`, and a script that runs as root |
| 5 | The method is **generic over hostnames, with a build-time guard** | Targeting `epiphany` alone |

---

## What made this hard, measured

Three findings shaped the design. Each was measured, and each contradicts
something a reader would reasonably assume.

### The metapackage runs backwards as an installer

`calango-desktop` declares 22 packages in `Depends:`. Five of them come from
third-party repositories, and **two are reachable from no repository at all**:

```sh
apt-cache policy fresh-editor slack-desktop
#  fresh-editor:  Candidate: 0.4.7-1     100 /var/lib/dpkg/status
#  slack-desktop: Candidate: 4.51.180    100 /var/lib/dpkg/status
```

One entry in the version table, and that entry is dpkg's own status file. The
installed copy is the only copy apt knows about. apt resolves `Depends` before
it unpacks anything, so no amount of repository configuration satisfies those
two. They must be installed from files first.

This inverts the package's purpose. It was built to *declare* a keep set on a
machine that already holds it. Using it to *install* that set runs it
backwards.

### Four repositories, not five

The seven corp packages come from four repositories and two files:

```sh
1password              https://downloads.1password.com/linux/debian/amd64
1password-cli          https://downloads.1password.com/linux/debian/amd64
code                   https://packages.microsoft.com/repos/code
google-chrome-stable   https://dl.google.com/linux/chrome-stable/deb
endpoint-verification  https://packages.cloud.google.com/apt
# distinct: 4
```

**The design conversation said five twice before this was counted.**
`1password` and `1password-cli` share a repository. The number is recorded here
as derived, and the deriving command is above, because this file's own opening
rule is to count rather than to quote.

### The apt source files are scaffolding, not state

All seven source files in `/etc/apt/sources.list.d/` are **unowned by dpkg**,
and three of them say in their own text that their package rewrites them.
Chrome's copy is recreated by `/etc/cron.daily/google-chrome`; 1Password's by
its `postinst`.

So the flake must not declare them as permanent files. They exist so that one
`apt install` can succeed. Afterwards each vendor package owns its own copy,
and the flake's copy becomes a duplicate source apt warns about.

Consequence: the scaffolding files are named `calango-bootstrap-<vendor>.sources`,
the runbook says to delete them once the vendor packages are installed, and the
drift check never watches them. Comparing them forever would assert something
false.

---

## The dependency graph

The bootstrap is a graph, not a list. Six constraints order it.

| # | Constraint | Why |
|---|---|---|
| 1 | Nix before everything | apt supplies `nix-bin`; `nix-daemon` is a root service |
| 2 | The `nix-users` group needs a new login | `/nix/var/nix/daemon-socket/` is `0770 root:nix-users` |
| 3 | The repositories before the corp packages | Five of seven come from third-party repositories |
| 4 | The corp packages before `calango-desktop` | apt resolves `Depends` before unpacking; two come from no repository |
| 5 | `calango-desktop` before the first login | It ships the greetd session entry |
| 6 | The first `activate` before the first login | The session entry runs `$HOME/.nix-profile/bin/uwsm` |

Five stages follow.

- **Stage A, root.** Install the base packages. Add the user to three groups.
- **Stage B, user.** Enable flakes. Clone the flake. Write the host's files.
  Build both artifacts.
- **Stage C, root.** Install the repositories, the corp packages, then
  `calango-desktop`. Install the greetd configuration.
- **Stage D, user.** Run the pinned activation package. Log out. Select
  "Hyprland (Nix)".
- **Stage E.** Take the acceptance measurements.

### A gate at each boundary

Prose ordering alone puts constraint 4 in the reader's memory, where it does
not belong. `RUNBOOK.md` therefore prints **one gate command for each stage
boundary**, with its expected output. A wrong answer stops the reader at the
boundary rather than three stages later.

### Use the pinned activation package for the first switch

`programs.home-manager.enable = true` gives the `home-manager` command only
after a generation exists. `nix run home-manager` reads the flake **registry**,
which tracks unstable rather than this flake's `release-26.05` input. That is
the same trap as `nixpkgs#<pkg>`, in a new place. The first switch is:

```sh
p=$(sg nix-users -c 'nix build --no-link --print-out-paths \
  .#homeConfigurations."<user>@<host>".activationPackage')
"$p/activate"
```

---

## Piece 1: `home/bootstrap.nix`, the declarations

A new module with a `calango.bootstrap.*` namespace. It declares five things
and nothing else.

| Option | Type | Holds |
|---|---|---|
| `greetdConfig` | `str` | The whole `/etc/greetd/config.toml` |
| `aptSources` | `attrsOf str` | One deb822 stanza per repository, key inline |
| `packages.base` | `attrsOf str` | Stage A's apt packages, each with a reason |
| `packages.corp` | `attrsOf str` | The seven corp packages, each naming its source |
| `groups` | `listOf str` | `nix-users`, `video`, `input` |

### The keys go inline, so no keyring file is created

`man 5 sources.list` documents an inline `Signed-By:` holding an armored key
block, with continuation lines indented by one space and blank lines written as
` .`. apt here is 3.0.3, and the manual page on this machine is the authority
for the syntax; no version floor is claimed, because none was measured.

This buys three things. No binary blob enters the repository. Nothing unowned
lands in `/etc/apt/keyrings`. An expired key fails at `apt update` with a
message naming its repository, rather than at a package install.

**The four keys are exported from suffer's own keyrings, not fetched from a
vendor URL.** suffer is a machine on which all four repositories demonstrably
verify, so its keyrings are known-good, and the export needs no network:

```sh
gpg --no-default-keyring --keyring /usr/share/keyrings/google-chrome.gpg \
    --armor --export          # 8497 bytes of armored text
```

Each stanza records the fingerprint beside the key, so a reviewer can tell that
the block was not edited and a future rotation is visible as a change rather
than as a silent replacement. Measured 2026-08-19:

| repository | keyring on suffer | fingerprint |
|---|---|---|
| Google Chrome | `/usr/share/keyrings/google-chrome.gpg` | `EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796` |
| Microsoft (code) | `/usr/share/keyrings/microsoft.gpg` | `BC528686B50D79E339D3721CEB3E94ADBE1229CF` |
| 1Password | `/usr/share/keyrings/1password-archive-keyring.gpg` | `3FEF9748469ADBE15DA7CA80AC2D62742012EA22` |
| Google Cloud | `/etc/apt/keyrings/endpoint-verification.gpg` | `35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3` |

Note the fourth is the only one under `/etc/apt/keyrings` rather than
`/usr/share/keyrings`, and the only live source still in the one-line format
(`endpoint-verification.list`). All four become deb822 stanzas here.

### `packages.base` and the keep set answer different questions

This distinction is the reason `packages.base` exists as its own option rather
than reusing `calango.deb.keep`.

- **`calango.deb.keep` answers: what must not be removed, once here.**
- **`packages.base` answers: what must be installed, to get here.**

A package can be in one and not the other, and `polkitd` is exactly that case.
It owns `/usr/lib/polkit-1/polkit-agent-helper-1`, which `flake.nix`'s
`debianPolkit` overlay patches Nix's polkit to call, so the Nix polkit agent
cannot authenticate without it. It needs no `keep` entry, because it is held by
`network-manager`, `udisks2`, `upower` and `systemd`:

```sh
apt-mark showmanual polkitd            # (nothing -- it is auto)
apt-cache rdepends --installed polkitd # udisks2, upower, systemd, network-manager, ...
```

On a bare install, with no desktop task selected, none of those holders is
present either, so `polkitd` must be named. Same shape as `runtimeDeps` against
`appPath` in `home/quickshell.nix`: two lists, two questions, and merging them
loses one.

### `packages.base`, stated as a hypothesis

**This list is reasoned, not measured, and the spec says so because the qemu
run is what falsifies it.** It is derived from a machine holding 349 manual
packages, where everything needed is present for reasons that cannot be
separated after the fact.

| package | why |
|---|---|
| `nix-bin` | The Nix client and the daemon binary |
| `nix-setup-systemd` | Installs and enables `nix-daemon.service` |
| `git` | To clone the flake; priority `optional`, so absent on a bare install |
| `greetd` | The login manager, and it ships `/etc/pam.d/greetd` with the four keyring lines |
| `tuigreet` | The greeter that `greetdConfig` names |
| `dbus-user-session` | Owns `/usr/lib/systemd/user/dbus.socket`, the per-login session bus |
| `dbus-broker` | The bus implementation serving here, measured |
| `polkitd` | Owns the setuid helper the polkit overlay patches to |
| `network-manager` | `home/services.nix` runs `nm-secret-agent` against it |
| `ca-certificates` | The four repositories are https; priority `standard`, so probably already present |

Two packages are deliberately absent from that list and named here so a reader
does not add them:

- **`libpam-modules-bin`** owns `/usr/sbin/unix_chkpwd`, which the hyprlock
  overlay patches to. Its priority is `required`, so it is always present.
- **The Debian-side keeps** — `bluez`, `cups`, `gnome-keyring`,
  `libpam-gnome-keyring`, `ufw`, `rtkit` and the nine-package pipewire-module
  chain — arrive as `calango-desktop`'s own `Depends` in stage C. Naming them
  in stage A would install them twice over and hide the fact that the
  metapackage is what holds them.

The user bus claim is measured rather than assumed:

```sh
systemctl --user show dbus.service -p FragmentPath --value
# /usr/lib/systemd/user/dbus-broker.service
dpkg -S /usr/lib/systemd/user/dbus.socket
# dbus-user-session: /usr/lib/systemd/user/dbus.socket
```

---

## Piece 2: the rendered directory and the generated runbook

The module renders one store directory, `config.calango.bootstrapDir`, holding:

```
etc/greetd/config.toml
etc/apt/sources.list.d/calango-bootstrap-<vendor>.sources    (four)
RUNBOOK.md
```

`flake.nix` exposes it as `packages.x86_64-linux.calangoBootstrap`, beside
`calangoDeb`.

**`RUNBOOK.md` is generated from the same option values it describes.** The
package lists, the group names, the repository names and the install commands
are rendered from `calango.bootstrap.*`, not typed twice. Prose and content
cannot disagree, which is the failure mode this project has paid for most
often.

The runbook holds, per stage: the commands to run, the gate command for the
boundary that follows, and its expected output.

---

## Piece 3: the greetd handover

`greetdConfig` takes over the content of `/etc/greetd/config.toml` from
`calango-desktop`. The live file is 56 lines. Its comments reference Fedora,
`../install.sh --check`, and a two-machine comparison that this repository
does not perform.

**Decision: declare it with the comments rewritten for this repository, and
require the functional lines to be byte-identical.** The alternative — declare
it verbatim so the drift check passes at once — puts prose in the flake that
references a script the flake does not contain, which goes stale by
construction.

Two lines are functional. Everything else is comment:

```
command = "tuigreet --sessions /usr/share/wayland-sessions:/usr/local/share/wayland-sessions --remember --remember-user-session --time --asterisks"
user = "_greetd"
```

Both are transcribed verbatim from the live file. The acceptance step proves it
with a targeted diff rather than a whole-file one:

```sh
diff <(/usr/bin/grep -E '^(command|user) =' /etc/greetd/config.toml) \
     <(/usr/bin/grep -E '^(command|user) =' "$B/etc/greetd/config.toml")
# no output
```

`--sessions` keeps both directories. suffer needs the second for the legacy
`calango-desktop` entry, and a new machine needs only the first. Naming a
directory that does not exist is harmless: the file's own comment records that
tuigreet hits `ENOENT` on the missing one and goes on to draw its interface.

**The handover is ordered declare, report, install, confirm.** The drift check
reports the difference; a human runs the install command; the login is
confirmed before anything else happens. This is spec 16's ship → login → delete
ordering, which exists because this file is the one artefact that can leave a
machine unable to reach its desktop. Recovery is tty1, which the greetd
configuration keeps free on purpose by leaving the greeter on VT7.

---

## Piece 4: the drift check

A non-fatal Home Manager activation hook in `home/bootstrap.nix`.

### Two subjects were removed for being vacuous

**This is the most important paragraph in the piece.** `home-manager switch`
builds and then activates. The build needed the Nix daemon, and needed flakes
enabled, or no generation would exist to activate. So a hook testing
`systemctl is-active nix-daemon.service`, or grepping `~/.config/nix/nix.conf`
for `flakes`, reports a property its own existence guaranteed. Both were
designed, then cut.

A third subject is removed for being owned elsewhere: `home/apt-hygiene.nix`
already warns on the autoremove census at every switch.

### Three subjects remain, and each can genuinely fail

| Subject | Instrument | Fails when |
|---|---|---|
| `/etc/greetd/config.toml` | `cmp` against the store copy | The live file is edited, or the declaration moves |
| Group memberships | `id -nG`, matched as whole words | A `usermod` was missed, or a group was dropped |
| The package's own files | `dpkg -V calango-desktop` | The session entry or `/etc/default/slack` is edited |

The third covers two files for the price of one, because dpkg already
checksums both.

### Four properties, each from this project's own record

- **It runs as a child shell.** `activate` sets `-eu` and `pipefail` for
  itself, and a body handed to `${pkgs.bash}/bin/sh -c` inherits neither. That
  is what makes `cmp` returning 1 safe. `home/apt-hygiene.nix` and
  `home/apps.nix` are both written this way. Check `$-` in the shell that will
  really run the line before deciding what protects it.
- **It is non-fatal by requirement, not by convenience.** A fatal version
  aborts every switch on a machine whose `/etc` has drifted, and drift is a
  report. `home/apps.nix`'s `mimeappsIds` is non-fatal for the same reason.
- **It separates absent from different.** On a bare machine
  `/etc/greetd/config.toml` does not exist. A single `cmp` reports both cases
  identically, and they need different commands. Same trap as a `find -L … ||
  true` that swallows `ENOENT` as readily as no-match.
- **Group names are matched as whole words.** `grep -cx`, not a substring
  search. `nix-users` is a substring of nothing here, but the rule that caught
  `/bin` inside four of six `PATH` entries applies whether or not today's data
  happens to be safe.

### The vacuity anchor

Two assertions: `groups != [ ]` and `greetdConfig != ""`. Without them the hook
prints an `ok` line per subject while requiring nothing of any of them.

### Proven by mutation, in three runs

Each mutation is confirmed by measurement **before** the switch, because spec
16 spent two rounds on mutations that turned the build red without ever
reaching the guard.

| mutation | expected report |
|---|---|
| One byte changed in `greetdConfig` | The file differs, with the install command |
| The live file moved aside | The file is absent, with the install command |
| A group the user does not hold added to `groups` | That group is named |

---

## Piece 5: the per-host guard, and a comment that contradicts itself

`hypr/hyprland.lua` makes two opposite claims about an unknown hostname, seven
lines apart. One comment says an unknown host "is now an evaluation error,
which is the earlier and louder failure". The next says "that is a working
desktop on an unknown machine, not a broken one".

The code is the second. `pcall(dofile, …)` falls back to `hostCfg = {}`, and
there is no evaluation error anywhere: `home/hyprland.nix:16` substitutes the
name into a path string and nothing tests that the file exists.

```sh
/usr/bin/grep -n 'hosts' home/hyprland.nix
# 110:  description = "Which hosts/<name>.lua this configuration bakes in.";
# -- the only match; no existence test
```

**The consequence for a new machine is not cosmetic.** With no
`hosts/<name>.lua`, `primary` is nil, so every workspace rule in the file
becomes a no-op — the 1-5 and 6-10 split, the VSCode monocle workspace, and
the persistent YouTube workspace. The desktop starts and looks correct.

Two changes:

- **A build-time guard** asserting that every host in `homeConfigurations` has
  a `hypr/hosts/<name>.lua`. A missing file becomes a build failure.
  `foot/hosts/<name>.ini` and `gtk/hosts/<name>.conf` stay optional, and that
  is measured rather than assumed: both modules carry an explicit `else`
  branch. `home/foot.nix:35` writes a comment line naming the absent file, and
  `home/gtk.nix:108` substitutes `/dev/null`. Neither can leave an
  unsubstituted token, because each runs a token guard immediately
  afterwards. `home/hyprland.nix` has no such branch to check, which is
  exactly why only the Lua file is guarded.
- **The contradictory comment is corrected** to describe the fallback the code
  performs.

`epiphany` is wired into `homeConfigurations` as the worked example. All three
of its per-host files already exist, so it exercises the guard's passing path
without inventing hardware.

---

## Piece 6: the qemu rehearsal

A Debian 13 netinst installs into qemu with no desktop task selected:

```sh
qemu-system-x86_64 -enable-kvm -m 8G -smp 4 \
  -machine q35 -cpu host \
  -drive file=bootstrap.qcow2,if=virtio \
  -device virtio-gpu-gl-pci -display gtk,gl=on \
  -device virtio-net-pci,netdev=n0 -netdev user,id=n0 \
  -virtfs local,path=./debs,mount_tag=debs,security_model=mapped-xattr
```

Every argument is load-bearing. `-machine q35 -cpu host` gives the guest a
modern chipset and the host's feature flags. `virtio-gpu-gl-pci` with
`gl=on` is what routes GL through virglrenderer rather than to a software
fallback. The `-virtfs` share carries the two file-only packages in, because
neither is reachable from any repository.

Both prerequisites are present here: `libvirglrenderer1` 1.1.0-2 and
`qemu-system-gui`, and `qemu-system-x86_64 -device help` lists
`virtio-gpu-gl-pci`.

**This is what makes the rehearsal cover GL, and the coverage is partial in a
way worth stating precisely.** Nix's mesa ships a `virtio_gpu` DRI driver on
the same `LIBGL_DRIVERS_PATH` that `nixGLIntel` exports, so the VM proves the
**nixGL mechanism**: that the wrapper sets its five variables, that a unit
without its own wrapper gets none of them, and that the compositor starts. It
does not prove the Intel driver path. `iris` and `intel-media-driver` are
untested by it.

`nixGLIntel` needs no host parameter for this, and that is measured rather than
assumed. Its exports name generic mesa:

```
LIBGL_DRIVERS_PATH=…/mesa-26.1.5/lib/dri
GBM_BACKENDS_PATH=…/mesa-26.1.5/lib/gbm
__EGL_VENDOR_LIBRARY_FILENAMES=…/mesa-26.1.5/share/glvnd/egl_vendor.d/50_mesa.json
```

Only `intel-media-driver`, on `LIBVA_DRIVERS_PATH`, is vendor-specific. So the
wrapper covers Intel and AMD alike. That AMD works follows from mesa carrying
`radeonsi` and is **not** tested here.

### The rehearsal runs stage C wrong on purpose, once

Before stage C runs in order, `apt install ./calango-desktop.deb` is attempted
**before** the corp packages, and the exact apt error goes into the results
document. This converts ordering constraint 4 from a claim into a measurement.
A constraint nobody has watched bite is a constraint nobody can check.

### What the rehearsal cannot reach

- The Intel GL driver, as above.
- Real display hardware, and therefore any real machine's monitor layout.
- Bluetooth, and the corporate enrolment.
- `endpoint-verification` beyond the fact that its repository resolves.

---

## Guards

| guard | property | where | proven by |
|---|---|---|---|
| session-path agreement | every `calango.deb.files` entry under `wayland-sessions/` sits in a directory `greetdConfig`'s `--sessions` names | `assertions` | moving the entry to a directory not on the list |
| `groups` non-empty | the vacuity anchor for the group check | `assertions` | forcing the option to `[ ]` |
| `greetdConfig` non-empty | the vacuity anchor for the file check | `assertions` | forcing the option to `""` |
| per-host hyprland file | every `homeConfigurations` host has a `hypr/hosts/<name>.lua` | `checks` | adding a host with no file |
| drift check | live `/etc` agrees with the declaration | activation hook | three mutations, above |

The first guard is the best one available here, because it relates two
declarations that already exist in this flake and that nothing has ever
compared. `home/session.nix` says where the session entry goes.
`greetdConfig` says where the greeter looks. A machine whose greeter cannot
offer its own session boots to a greeter that works and a desktop that is not
listed.

---

## Acceptance

### In the VM, after stage E

```sh
id -nG | tr ' ' '\n' | grep -cx -e nix-users -e video -e input        # 3
cmp -s /etc/greetd/config.toml "$B/etc/greetd/config.toml"; echo $?   # 0
dpkg -V calango-desktop; echo $?                                      # 0
dpkg-query -W -f='${db:Status-Abbrev}\n' calango-desktop               # ii
apt-get -s autoremove | grep -c '^Remv '                               # 0
tr '\0' '\n' < /proc/$(pgrep -x .Hyprland-wrapp)/environ \
  | grep -c LIBGL_DRIVERS_PATH                                         # 1
```

The `pgrep` pattern is `.Hyprland-wrapp`, truncated at fifteen characters,
because Nix wraps the binary. `pgrep -x Hyprland` matches nothing in the
working state and the broken state alike.

### On suffer

- The three drift-check mutations, each measured before its switch.
- The functional-line diff of `greetdConfig` against the live file: no output.
- `nix flake check` runs its checks and exits 0. **Count them; do not quote a
  number.** This spec adds one, so the figure in `CLAUDE.md` moves:

```sh
sg nix-users -c 'nix flake check' 2>&1 | grep -o 'running [0-9]* flake checks'
```

- `packages.x86_64-linux.calangoBootstrap` builds, and `calangoDeb` still does.

---

## Out of scope, each with its reason

- **The live state.** 940 MB across fonts, syncthing, Signal, the keyring and
  `~/.ssh`. Decision 1: the second machine re-pairs and re-links.
- **The corporate enrolment.** `endpoint-verification` is a managed-device
  agent. No script should attempt it.
- **Installing the corp packages.** Decision 2: the bootstrap supplies the
  repositories and stops.
- **Per-host flake checks.** The four existing checks read
  `suffer.activationPackage` by name, so a second host's generation is checked
  by none of them. Widening them is a rework of the check block and belongs in
  its own spec. **This is a real coverage gap that this spec knowingly leaves
  open**, and the results document must say so rather than imply the new host
  is checked.
- **NVIDIA.** `nixGLIntel` covers mesa, so Intel and AMD. A proprietary driver
  needs a different wrapper.
- **The `docker` and `mise` repositories.** Present on suffer, in no keep set,
  and not part of the desktop.
- **`system/README.md`'s `render` group.** `id` shows the working account
  without it, so the instruction is unnecessary. Correcting that file is a
  one-line change and is included; re-surveying the rest of it is not.

---

## Risks

1. **`packages.base` is a hypothesis.** It is reasoned from a machine with 349
   manual packages. The qemu run falsifies it, and the plan must treat a
   missing package as an expected outcome of the rehearsal rather than a
   defect in it.
2. **The inline keys go stale.** A rotated vendor key fails at `apt update`.
   The failure names its repository and nothing automates a refresh. This is
   the same posture `bin/slack-latest` takes: report, do not automate.
3. **The drift check reports on suffer at the first switch.** By design, since
   `greetdConfig`'s comments are rewritten. Confirm the functional-line diff is
   empty before committing, then install and confirm the login.
4. **Hyprland may refuse to start under virgl** even with the device present.
   If it does, the rehearsal loses its login half. Record that rather than
   claim coverage that was lost.
5. **`/etc/greetd/config.toml` stays a modified conffile**, so every future
   `greetd` upgrade prompts on it. That is already true on suffer today. This
   spec inherits the condition and does not introduce it.

---

## Two things this spec fixes for free

- **`home/session.nix:156` says "/usr/share/wayland-sessions does not
  currently exist".** Spec 16 shipped the entry there, and
  `/usr/local/share/wayland-sessions/` is now the empty one. The comment is
  stale and is corrected.
- **On a bare machine there is no `/etc/default/slack` prompt at all.** On
  suffer that file existed unowned, so dpkg asked a question whose default
  answer re-armed a dead repository — spec 17's worst trap. Slack's `.deb`
  ships no such file; its cron job creates one. Install `calango-desktop` on
  the first day and dpkg asks nothing. The runbook states the ordering and the
  reason.
