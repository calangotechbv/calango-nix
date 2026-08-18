# Spec 17: Slack to a standalone `.deb`, and flatpak out entirely

**Date:** 2026-08-18
**Host:** `suffer`
**Status:** design, approved in chat

---

## The problem

Slack is the one member of the corp set that `CLAUDE.md` says is "permanently
apt" while not actually being on apt. It is a flatpak, and it is the only
flatpak left:

```sh
flatpak list --app
# Slack   com.slack.Slack   4.50.143   stable   system
du -sh /var/lib/flatpak
# 1.7G
```

The user decided on 2026-08-17 to move it to Slack's own `.deb` and phase
flatpak out. `org.gnome.Snapshot`, the blocker recorded at the time, was
removed that same day, so nothing else uses the runtime.

Unusually for this project, **apt is the freshest source and Nix the stalest**:

```
slack .deb, upstream   4.51.180     <- freshest
flatpak, installed     4.50.143
nixpkgs, pinned        4.49.89      <- stale, and unfree-blocked
```

`pkgs.slack` is unfree and `flake.nix` imports nixpkgs with overlays but no
`config`, so Nix cannot supply it without an `allowUnfree` decision taken on
its own merits. This move therefore aligns Slack with the corp-set rule rather
than breaking it.

---

## What is measured

Everything below was run on `suffer` on 2026-08-18. Nothing in this spec needs
re-deriving; anything the implementer must still measure is named as such.

### The upstream `.deb` exists and is versioned

```sh
curl -sS 'https://slack.com/api/desktop.latestRelease?arch=x64&variant=deb'
# {"ok":true,"version":"4.51.180","download_url":"https://downloads.slack-edge.com/desktop-releases/linux/x64/4.51.180/slack-desktop-4.51.180-amd64.deb","platform":"linux","arch":"x64"}
curl -sS -I -L <that url> | grep -iE '^(HTTP/|content-length)'
# HTTP/2 200
# content-length: 94403330
```

Slack's Linux page advertises only the `.rpm` unless it detects a Debian
client. The feed above is the reliable way to name the current version, and it
is what the helper in Piece 1 uses.

### The install is a clean single-package operation

```sh
apt-get -s install ./slack-desktop-4.51.180-amd64.deb
# The following NEW packages will be installed:
#   slack-desktop
# 0 upgraded, 1 newly installed, 0 to remove and 67 not upgraded.
```

Nothing is removed, nothing else is pulled, and the `pulseaudio` ban is
untroubled even though the package carries `Recommends: pulseaudio |
libasound2`.

**Four of its hard `Depends` do not exist as real packages in Debian 13, and
that is not a problem.** `apt-cache policy` is the misleading instrument here:

```sh
apt-cache policy libgtk-3-0 libappindicator3-1 libatspi2.0-0 libasound2
# Candidate: (none)   -- for all four
apt-cache showpkg libgtk-3-0 | sed -n '/Reverse Provides/,$p'
# libgtk-3-0t64 3.24.49-3 (= 3.24.49-3)
```

Each is a purely virtual name provided by the installed `t64` package, plus
`libayatana-appindicator3-1` for the indicator. `Candidate: (none)` for a name
that is fully satisfiable through `Provides` is a new entry for the
tools-that-answer-a-different-question list. The simulated install above is the
authority, not `apt-cache policy`.

### The package has no maintainer scripts — and that does not mean what it looks like

```sh
dpkg-deb --ctrl-tarfile slack-desktop-4.51.180-amd64.deb | tar -tv
# -rw-r--r-- root/root  504  ./control      <- and nothing else
```

No postinst, no postrm. **But the payload ships `/etc/cron.daily/slack`,** a
Chromium-derived script that re-creates the apt repository configuration and
its signing keys. Read against the `/etc/default/slack` already on this
machine:

```sh
cat /etc/default/slack
# repo_add_once="false"
# repo_reenable_on_distupgrade="true"
```

the script's `MAIN` block takes these branches:

| knob | value | effect |
|---|---|---|
| `repo_add_once` | `false` | runs `update_bad_sources`, which returns at its first test when `slack.list` is unreadable |
| `repo_reenable_on_distupgrade` | `true` | runs `handle_distro_upgrade` **and `install_new_key`, unconditionally** |

So with today's knobs, precisely one deletion does not stick:
`install_new_key` rewrites `/etc/apt/trusted.gpg.d/slack-desktop.gpg` every
day. `packagecloud.gpg` is written by `install_key`, which is reached only on
the `repo_add_once=true` path, so that one and `slack.list` would stay deleted.

**And deleting `/etc/default/slack` is the worst move available.** With the file
absent the script's own first act is to recreate it with *both* knobs `"true"`,
then install both keys and write `slack.list` **active**, pointing at Slack's
retired packagecloud `jessie` repo. The file is inert residue today — no
`slack-desktop` is installed, so nothing runs it — and becomes load-bearing the
moment the `.deb` lands.

This is the same species as the `deb-systemd-helper` trap `CLAUDE.md` already
records: a `rm` that a maintainer's own automation undoes. There the mechanism
was a postinst; here it is cron.

**Control for that reading:** `/etc/cron.daily/google-chrome` is the same script
on this machine, with an identical `/etc/default/google-chrome` carrying the
same two values — and Chrome's repo is genuinely live, so its copy is doing
legitimate work. Chrome's is out of scope. It is cited only because it confirms
the semantics above against a working case, and because it is a second instance
of the unowned-file shape counted below.

### Four unowned files in `/etc` are Slack's, and one of them is the knob

```sh
cat /var/lib/dpkg/info/*.list | sort -u > owned.txt          # 164842 paths
find /etc -xdev -type f | sort -u > etcfiles.txt             # 1232 files
comm -23 etcfiles.txt owned.txt | wc -l                      # 182
comm -23 etcfiles.txt owned.txt | grep -iE 'slack|packagecloud'
# /etc/apt/sources.list.d/slack.list
# /etc/apt/trusted.gpg.d/packagecloud.gpg
# /etc/apt/trusted.gpg.d/slack-desktop.gpg
# /etc/default/slack
```

`slack.list` holds a preamble and one commented `deb` line for the retired
`jessie` repo — no active configuration. `packagecloud.gpg` is expired
(`gpg --show-keys --with-colons` reports `uid:e`), and `slack.list` is the only
file on this machine that references packagecloud at all.

**That same command disproves a standing fact.** `CLAUDE.md` says "There is no
longer a file outside `$HOME` that no package owns", and spec 16's close-out
reported `unowned files : none outside $HOME`. The true figure is 182 in `/etc`
alone. Most are legitimate — generated config (`adjtime`, `aliases`,
`ca-certificates.conf`), apt keyrings, admin-created apparmor locals — so
"unowned" is not "wrong" here. What was actually surveyed in spec 16 was the
files *that project created*. The claim gets restated to that scope in Piece 7;
it is not repairable as written.

### Two Slack profiles exist, and the stale one is what a host Slack reads

```sh
du -sh ~/.config/Slack                          # 822M
stat -c '%y' ~/.config/Slack                    # 2026-07-23 07:45:30
du -sh ~/.var/app/com.slack.Slack/config/Slack  # 707M
stat -c '%y' ~/.var/app/com.slack.Slack/config/Slack   # 2026-08-18 17:56:21
```

The flatpak tree starts at 07:52 that same morning, so `~/.config/Slack` is a
snapshot frozen at the moment of the flatpak move. A host Slack reads the
frozen one. Both record the same Electron generation, so the live profile is
portable to the host path:

```sh
head -c 60 <either>/local-settings.json
# {"lastEffectiveClientEnvironment":1000,"lastElectronVersionLaunched":"42.4.1"
```

`4.51.180` against a `4.50.143` profile is still a one-way first launch — spec
13 established that the first launch, not the apt removal, is the irreversible
step. `~/.config/Bitwarden.pre-nix-backup` is this project's naming convention
for the backup. 300 G is free, so size is not a constraint.

### The `.desktop` id already matches, which repairs a dead association

```sh
dpkg-deb -c slack-desktop-4.51.180-amd64.deb | grep applications
# ./usr/share/applications/slack.desktop
grep -n slack ~/.config/mimeapps.list
# 8:x-scheme-handler/slack=slack.desktop
```

`slack.desktop` is one of the dead ids `CLAUDE.md` records, because the only
Slack entry on the search path today is flatpak's `com.slack.Slack.desktop`.
The `.deb` ships exactly the id the handler already names, so the association
is repaired by the install and not by a fixer hook. This is the identical-id
case sitting beside spec 13's non-identical one; do not generalise from either.

`home/apps.nix`'s `mimeappsIds` walks `$XDG_DATA_DIRS` plus
`$HOME/.local/share`, and `/usr/share` is in `XDG_DATA_DIRS`, so the repair is
directly observable: the hook stops naming `slack.desktop`. No entry is added to
`flake.nix`'s `required` list — `gui-desktop-ids` reads this flake's own trees,
and `slack.desktop` is apt's.

### Removing flatpak today takes the metapackage with it

```sh
apt-cache depends calango-desktop | grep flatseal   # Depends: flatseal
apt-cache depends flatseal | grep flatpak           # Depends: flatpak
apt-cache rdepends --installed flatpak              # flatseal

apt-get -s remove flatpak
# The following packages were automatically installed and are no longer required:
#   gir1.2-adw-1 gir1.2-appstream-1.0 gir1.2-graphene-1.0 gir1.2-gtk-4.0
#   gir1.2-javascriptcoregtk-6.0 gir1.2-soup-3.0 gir1.2-webkit-6.0 gjs
#   libadwaita-1-0 libgjs0g libhidapi-hidraw0 libjavascriptcoregtk-6.0-1
#   libmalcontent-0-0 libmanette-0.2-0 libmozjs-128-0 libostree-1-1
#   libwebkitgtk-6.0-4 xdg-dbus-proxy
# The following packages will be REMOVED:
#   calango-desktop flatpak flatseal
```

`calango-desktop` is `ii 0.258` and solely holds 22 packages, so a removal of
the metapackage orphans all of them in one step. The chain above makes ordering
the central constraint of this spec, not a detail of it.

---

## Design

### Piece 1 — `home/slack.nix`, a new module

`home/deb.nix:118` states the rule: entries with no natural owner live in
`home/deb.nix`, and anything a module is responsible for lives in that module.
This spec creates an owner for Slack, so a new module carries three things.

**The keep entry.**

```nix
calango.deb.keep.slack-desktop =
  "Corp set, permanently apt, and the one member where apt is the freshest "
  + "source: 4.51.180 upstream against nixpkgs' unfree 4.49.89. A standalone "
  + ".deb with no repository behind it, so nothing upgrades it -- bin/slack-latest "
  + "reports staleness and a human acts on it. Its /etc/cron.daily/slack would "
  + "re-add the retired packagecloud repo and its keys, which is why this package "
  + "also ships /etc/default/slack with both knobs false.";
```

Rendered as one string in the module; broken across lines here only to fit.
No reason string may contain the literal Nix store path prefix — every reason is
serialised into `manifest.json`, which `noStorePaths` greps, so a reason that
merely *talks* about store paths fails the build. This cost spec 16 a clean
build once.

**The keep set stays at 22.** `flatseal` leaves and `slack-desktop` arrives, so
the count is unchanged and the single-point-of-failure property
`CLAUDE.md` records is unchanged with it: `apt remove calango-desktop` remains a
22-package operation.

```sh
sg nix-users -c 'nix eval --json .#homeConfigurations."isutton@suffer".config.calango.deb.keep' \
  | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'
# 22    -- before; and 22 after, with flatseal swapped for slack-desktop
```

**The knob file, shipped rather than edited.**

```nix
calango.deb.files."etc/default/slack" = ''
  repo_add_once="false"
  repo_reenable_on_distupgrade="false"
'';
```

Both `"false"`. This is what makes the cron job a total no-op:
`update_bad_sources` returns at its first test with `slack.list` absent, and
`install_new_key` is never reached. Shipping it rather than editing it in place
means dpkg owns it, the value is declared in the tree with its reason beside
it, and the file cannot be "cleaned up" back into its armed state.

The `.deb` itself does not ship this path — its payload under `/etc` is
`cron.daily/slack` alone — so there is no dpkg file conflict between the two
packages.

**The helper.** `bin/slack-latest`, packaged the way `home/apps.nix` packages
`bin/calango-open`: copied into a `runCommand`, `substituteInPlace` for its
tool paths, and the established guard that fails the build on a leftover
`@token@`. It queries the `latestRelease` feed, compares against the installed
version, and prints the download URL and the `apt install` command. It never
downloads, never installs, and needs no privilege.

Two things the implementer must measure rather than assume:

- **Which `dpkg-query` it calls.** `pkgs.dpkg` exists and `lib/deb.nix` already
  uses it, but whether nixpkgs' build defaults its admindir to `/var/lib/dpkg`
  is unverified here. Check it; if it does not read Debian's database, use
  `/usr/bin/dpkg-query` absolutely and say why in a comment. A Debian-only
  helper naming Debian's binary is honest, not a workaround.
- **Version comparison.** `dpkg --compare-versions` is the correct instrument;
  string comparison is not. `4.51.180` against `4.9.x` is exactly where a
  string compare gives the wrong answer.

Add `./home/slack.nix` to the module list at `flake.nix:144-149`.

### Piece 2 — `home/deb.nix`: one keep out, two bans in

`flatseal` leaves `keep`. Its reason ("Absent from nixpkgs, and really a
flatpak") stops being a reason to keep anything once flatpak is gone, and while
it stands the metapackage transitively holds flatpak.

`flatpak` and `flatseal` join `ban`. **These are a new kind of ban entry and
the reasons must say so.** Every one of the 19 existing entries means "the Nix
side owns this now"; these two mean "removed deliberately, and nothing here
replaces them". The reason strings carry that distinction explicitly, because a
reader who generalises from the other 19 will conclude Nix ships a flatpak
replacement.

The cost is real and belongs in the reason text: `gnome-software-plugin-flatpak`,
`plasma-discover-backend-flatpak`, `flatpak-builder` and `podman-toolbox` all
`Depends: flatpak`, so any of them would demand the metapackage's removal
instead of installing. That is the declaration working.

The `xdg-desktop-portal` ban reason is rewritten. It currently explains, at
length and correctly, that flatpak's unsatisfied `Recommends` sits there
silently — spec 16's defect 9. That situation stops existing. The ban itself
stays, on its own grounds.

### Piece 3 — `lib/deb.nix`: conffiles by path, and a guard inside the builder

Today:

```nix
# lib/deb.nix:77
# Only /etc entries may be conffiles, per Debian policy. The ufw profiles
# are the only /etc payload this package has.
conffiles =
  lib.concatMapStrings (n: "/etc/ufw/applications.d/${n}\n")
    (builtins.attrNames manifest.ufwProfiles);
```

That comment is true today and false the moment `etc/default/slack` ships. An
`/etc` file without a conffiles entry means dpkg silently overwrites local
edits on upgrade, which for this file would re-arm the cron job.

`conffiles` becomes `ufwProfiles` ∪ every `files` key under `etc/`, derived by
**path syntax** rather than by a list of names — the rule this project opens
with. The comment is corrected to state the derivation.

**The guard goes inside the builder, and the obvious shape does not work.** A
`runCommand` in `guards` that unpacks the `.deb` and inspects
`DEBIAN/conffiles` is circular: `guards` are *inputs* to the deb derivation, so
a guard cannot inspect the artifact it gates. The check belongs in
`lib/deb.nix`'s own `buildCommand`, after `pkg/` is assembled:

- every path under `pkg/etc/` must appear in `pkg/DEBIAN/conffiles`;
- a `pkg/etc/` that exists with no `pkg/DEBIAN/conffiles` at all fails;
- the vacuity anchor: the package must have at least one `/etc` payload entry,
  since it has two by construction and a build producing none means the
  manifest lost something.

Written as a **condition**, not as a counting assignment: the builder runs with
`-e` and `pipefail`, so `n="$(grep -c … )"` aborts before it can print. That
trap is recorded twice in `CLAUDE.md` and cost spec 11 a build.

Because it is the same derivation, this runs on both `nix build .#calangoDeb`
and the activation build for free. That is the specific failure spec 16's
defect 10 was: a guard proven able to fail, against the wrong target, unable to
fail on the path that produces the installable artifact.

### Piece 4 — the live sequence, in this order

The order is forced by `Conflicts:`. Once flatpak and flatseal are banned,
installing the new metapackage *removes* them — which would destroy the
rollback before a host Slack had been proven to work.

1. **Install Slack's `.deb`.** Download via the feed, verify the version, and
   `sudo apt install ./slack-desktop-4.51.180-amd64.deb`. Flatpak Slack stays
   installed and usable throughout this step and the next.
2. **Hand over the profile.** Back up both directories, then copy the live
   flatpak profile to `~/.config/Slack`. Keep the frozen one as
   `~/.config/Slack.pre-deb-backup`. Launch Slack, confirm the login and the
   workspace, and settle GL (Piece 5). This is the irreversible step.
3. **Install the new `calango-desktop`.** Build it, then **simulate the install
   first** — a `Depends` is being dropped and two `Conflicts` added in one
   transaction. The expectation is exact: flatpak and flatseal are removed, and
   every one of the 21 keeps that is not `flatseal` is untouched. Verify that
   before running it, and do not read a plausible-looking transaction as the
   expected one.
4. **`apt autoremove`, reading the "no longer required" list at that moment.**
   18 packages today. Per the standing rule this list is read at the moment of
   removal, not inherited from this document. Each candidate needs the union
   instrument — `/proc` `maps` and `exe` unioned with the first field of
   `ps -eo args` over *every* process, resolved through `dpkg -S`, and for
   anything that might be a script, `dpkg -S` on the full command line rather
   than `argv[0]`. `libhidapi-hidraw0` in particular has plausible non-flatpak
   consumers and must be checked rather than assumed to be flatpak's.
5. **Delete the residue.** `/var/lib/flatpak` (1.7 G), `~/.var/app/com.slack.Slack`
   (711 M), `~/.local/share/flatpak` including its seven override files, and
   the three dead `/etc` files — `slack.list`, `slack-desktop.gpg`,
   `packagecloud.gpg`. **Not** `/etc/default/slack`, which the metapackage now
   owns.

### Piece 5 — GL, measured rather than inferred

The flatpak drew through `org.freedesktop.Platform.GL.default`, the runtime's
own matched stack, and the `flatpak override --user --unset-env=…` applied on
2026-08-17 existed because the session's nixGL variables named `/nix/store`
paths that did not exist inside the sandbox.

A host Slack has no sandbox, so those inherited paths are valid and it will
draw through Nix's mesa, exactly as Signal and Bitwarden already do. **The
override becomes unnecessary because the sandbox is gone, not because the
variables stopped being set** — the session inheritance stays load-bearing and
must not be "cleaned up".

Confirm rather than reason:

```sh
grep -cE 'swiftshader|libEGL_mesa|iris_dri' /proc/<pid>/maps
```

over **every** pid in the Slack tree, because Electron's GL stack lives in a
child process and the top-level pid gives a misleading zero. `swiftshader`
means software rendering; `iris_dri` means the Intel GPU path. Spec 13 left this
question open for Signal and Bitwarden; this spec answers it for Slack and does
not answer it for those two.

### Piece 6 — verify the knob directly

After the deletions, run the cron job by hand rather than waiting a day:

```sh
sudo /etc/cron.daily/slack
```

Then assert `slack.list` is still absent, neither key file is back, and
`/etc/default/slack` is byte-identical to what the package shipped.
`dpkg -V calango-desktop` is the instrument, and it does cover conffiles —
verified able to fail, since `dpkg -V` with no package argument reports
`??5?????? c /etc/greetd/config.toml` on this machine right now. This tests the
property.
Checking that nothing has reappeared without running the job tests only that a
day has not passed.

### Piece 7 — the documents

`CLAUDE.md` takes six corrections, three of which are findings:

1. **The standing fact "there is no longer a file outside `$HOME` that no
   package owns" is false**, by 182 files in `/etc` alone. Restate it to the
   scope that was really surveyed: no file *this project created* outside
   `$HOME` is unowned. Include the enumeration command so the next reader can
   re-take it.
2. **The corp-set entry** gains Slack, and with it the cron-job trap: a
   standalone `.deb` with no repository, whose daily job re-arms the repo and
   the keys unless `/etc/default/slack` says otherwise — which
   `calango-desktop` now ships.
3. **The flatpak/GL entry.** The GL inheritance rule stays; the flatpak half
   becomes historical, including the note that this flake deliberately does not
   own the override files. Nothing on this machine is a flatpak afterwards.
4. **The `mimeapps.list` entry.** `slack.desktop` is repaired, so "at least two
   dead associations" becomes at least one —
   `eu.calangotech.KBrowserSelector.desktop`. The "at least" qualifier stays
   for the reason it was written: the count was taken in one shell's
   `XDG_DATA_DIRS`.
5. **`apt-cache policy` joins the tools-that-answer-a-different-question
   list**, for `Candidate: (none)` on a name that is fully satisfiable through
   `Provides`.
6. **"`flatseal` and `fresh-editor` stay on apt" is half false**, found while
   writing the plan rather than while writing this spec. `flatseal` does not
   stay: it edits flatpak permissions and there is no flatpak. Split the entry,
   and record that `flatseal`'s keep reason — absent from nixpkgs — was a reason
   to keep it only while flatpak existed, and was what made the removal order
   load-bearing.

Outside `CLAUDE.md`:

- `home/apps.nix`'s comment naming `slack.desktop` "where flatpak exports
  `com.slack.Slack.desktop`" becomes wrong and is corrected.
- `README.md`'s "What apt still owns" lists **Signal**, which spec 13 made
  false — `signal-desktop` has been in `ban` since then. Fix it, and add Slack.
- `lib/deb.nix:77`'s comment, per Piece 3.
- Spec 16's results document keeps its `unowned files : none outside $HOME`
  line. Results documents are the historical record of what was believed and
  measured at the time; `CLAUDE.md` is what gets corrected.

---

## Guards

| guard | property | where | proven by |
|---|---|---|---|
| `/etc` ⊆ conffiles | every `/etc` payload path is a conffile | `lib/deb.nix` `buildCommand` | adding an `etc/` `files` entry excluded from the derivation, and mutating the derivation to drop it |
| `/etc` non-empty | the vacuity anchor: the package has `/etc` payload at all | same | forcing `ufwProfiles` and the `etc/` files empty |
| `@token@` residue | the helper has no unsubstituted token | `home.packages` | the established `home/apps.nix` pattern; mutate one token name |
| `keep` ∩ `ban` = ∅ | unchanged, and it now covers `flatseal` moving sides | `assertions` | already proven; re-run with `flatseal` left in both |

Every mutation must be confirmed to be a *valid* mutation before its build is
read as evidence. Spec 16's defect 5 was two mutations that turned the build
red without reaching the guard — a type error and a duplicate attribute — and
"the build failed" was nearly recorded as "the guard fired".

---

## Acceptance criteria

```sh
# Slack is apt's, and it is the fresh one
dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' slack-desktop
command -v slack

# flatpak is gone, root and branch
dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' flatpak flatseal
ls /var/lib/flatpak ~/.var/app ~/.local/share/flatpak 2>&1

# the metapackage survived intact, and still holds 22 -- flatseal out, slack in
apt-mark showmanual calango-desktop                  # must print it
apt-get -s autoremove | grep -c '^Remv '             # 0
sg nix-users -c 'nix eval --json .#homeConfigurations."isutton@suffer".config.calango.deb.keep' \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d), "slack-desktop" in d, "flatseal" in d)'
# 22 True False

# the three dead files are gone and stay gone
sudo /etc/cron.daily/slack
ls /etc/apt/sources.list.d/slack.list \
   /etc/apt/trusted.gpg.d/slack-desktop.gpg \
   /etc/apt/trusted.gpg.d/packagecloud.gpg 2>&1     # all absent
dpkg -V calango-desktop                              # no output

# the association is repaired, and the reporter agrees
xdg-mime query default x-scheme-handler/slack        # slack.desktop
# a switch prints no "missing .desktop id: slack.desktop" line

# the guards can fail, and the checks still pass
sg nix-users -c 'nix flake check' 2>&1 | grep -o 'running [0-9]* flake checks'
sg nix-users -c 'nix build --no-link .#calangoDeb'
```

Plus, not as a command: Slack opens, is logged in, shows the same workspaces,
and its GL path is recorded as software or hardware with the pid evidence.

---

## Out of scope

- **Chrome's copy of the same cron script.** `/etc/cron.daily/google-chrome`
  and its unowned `/etc/default/google-chrome` do the same job for a repo that
  actually works. Cited as a control, not touched.
- **The other 178 unowned files in `/etc`.** The claim gets its scope
  corrected; the files are not surveyed one by one. Most are legitimately
  unowned.
- **`allowUnfree`.** Not opened. Nix's Slack is stale anyway, so nothing here
  turns on it.
- **`flatseal`'s replacement.** Nothing replaces it; it managed flatpak
  permissions and there is no flatpak.
- **Signal's and Bitwarden's GL question**, still unmeasured from spec 13.
- **`ufw` rules.** Slack needs none, and `/etc/ufw/user.rules` remains
  unreadable unprivileged.

---

## Risks

- **The profile hand-over is one-way.** 4.51.180 opening a 4.50.143 profile may
  migrate it. Mitigated by two backups, and by the fact that both are the same
  Electron generation. Establishing *whether* a schema migration happened is
  deliberately not attempted: it teaches nothing the backup does not cover.
- **Step 3 removes flatpak through `Conflicts:` while the user may have Slack
  open.** Removing a package does not kill its running process, and absence is
  only measurable after the session ends. Close the flatpak Slack first, and
  read the reboot rather than the immediate state.
- **The autoremove list is 18 packages and none of them was orphaned by
  anything current until this spec.** Read it at the moment, mark manual what
  is still in use, and do not let the backlog regrow — this is the rule whose
  neglect produced a 137-package pile once.
- **`slack-desktop` in `keep` makes the metapackage uninstallable without
  Slack present.** Same shape as `google-chrome-stable` and `1password`
  already, and it means a fresh bootstrap installs Slack before
  `calango-desktop`. Worth stating in the results document.
- **No upgrade path.** The helper reports staleness; a human acts on it. Slack's
  in-app nag is the backstop. This is the real cost of the move and it is
  accepted.
