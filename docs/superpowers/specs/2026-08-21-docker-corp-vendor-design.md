# Spec 22: docker declared like the other corp vendors

**Branch:** `docker-corp-vendor`
**Written:** 2026-08-21
**Status:** design approved in chat; not implemented
**Follows:** spec 19, `docs/superpowers/specs/2026-08-19-generated-preseed-design.md`,
which is where `calango.bootstrap` got the option surface this spec extends.

---

## The problem

Docker is installed on suffer, in use, and declared nowhere.

`README.md:54` lists `docker-ce` in "the vendor stack", which reads as a
declaration and is not one. The flake names docker in no option:
`calango.bootstrap.packages.corp` holds six entries and none of them is docker,
`calango.bootstrap.aptSources` holds four files and none of them is docker's,
and `home/deb.nix`'s `keep` and `ban` name no docker package at all. Spec 18's
design says so on purpose:

> **The `docker` and `mise` repositories.** Present on suffer, in no keep set,
> and not part of the desktop.

That was the right call for a spec whose subject was the login path. It has two
consequences now.

**A bare-Debian bootstrap produces a machine with no docker and no docker
repository.** Everything else the corp workflow needs -- Chrome, Code,
1Password, endpoint-verification, Slack -- installs from a declared source in
Stage C. Docker is a human step nobody wrote down.

**Nothing holds docker on suffer.** The keep set's whole design is that
`calango-desktop`'s `Depends` does the holding and no `apt-mark` flag is needed.
Docker sits outside that: five of its six packages are `manual`, which is the
only thing between them and some later `apt autoremove`. CLAUDE.md's entry on
the 137-package backlog is what that looks like when it is left alone.

And one package is worse placed than the rest.
`golang-docker-credential-helpers` provides
`/usr/bin/docker-credential-secretservice`, which `~/.docker/config.json` names
as its `credsStore` for a private registry. It has **zero** installed reverse
dependencies. Docker runs it as a subprocess during a login or an authenticated
pull and never at rest, so no `/proc` walk, no `ps -eo args` union and no
in-use check taken at any instant can see that it is needed. It is the exact
shape CLAUDE.md describes under "A dependency a running-process check can never
see, at any moment", and its failure arrives later as a registry authentication
error attributed to whatever changed most recently.

## Decisions

| # | Decision | Excludes |
|---|---|---|
| 1 | Docker becomes a **fifth vendor repository**, declared in `aptSources` and installed in Stage C | A hand-written apt source; a human step in prose |
| 2 | The source is **durable**, not transient -- it gets no `aptSourcesTransient` entry | Deleting it after Stage C, which would leave docker with no candidate version |
| 3 | Six docker packages go in `packages.corp` **and** in `keep` | Naming `docker-ce` alone and trusting `Recommends` |
| 4 | `golang-docker-credential-helpers` goes in **`keep` only** | A `packages.corp` entry naming a repository it does not come from; a third package list |
| 5 | A **new `groupsFromCorp` option** carries the `docker` group, added in Stage C | Adding `docker` to `groups`, which fails Stage A on a bare machine |
| 6 | Docker **stays on apt permanently**, for the `bluez` and `rtkit` reason | Any future attempt to move `dockerd` to Nix |

---

## What was measured

Every claim below was taken on suffer on 2026-08-21 unless stated otherwise.

### The source is durable, not scaffolding

Chrome and 1Password write their own source file from their postinst, which
collides with the bootstrap copy and makes apt refuse to read any source at all.
`aptSourcesTransient` exists for exactly those two. Docker does neither:

```sh
/usr/bin/grep -c 'sources.list\|keyrings' /var/lib/dpkg/info/docker-ce.postinst
# 0
/usr/bin/grep -c 'sources.list\|keyrings' /var/lib/dpkg/info/containerd.io.postinst
# 0
# docker-ce-cli has no postinst at all
```

Nor does any of the six ship a cron job, which is the other way a vendor
recreates its own repository -- the trap `/etc/cron.daily/slack` documents:

```sh
for p in docker-ce docker-ce-cli containerd.io docker-buildx-plugin \
         docker-compose-plugin docker-ce-rootless-extras; do
  dpkg -L "$p" | /usr/bin/grep -cE '/etc/(cron|apt)'
done
# 0 0 0 0 0 0
```

So docker joins `microsoft` and `google-cloud` in the half that must **stay**.
Deleting it would leave six installed packages with no candidate version, which
is the state `slack-desktop` is in and the state spec 18 measured for `code`
and `endpoint-verification` on the rehearsal machine.

### The suite is a codename, and that inverts two fields

The live file on suffer:

```
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: trixie
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc
```

Docker's repository has no `stable` suite -- its suites are Debian codenames --
and `stable` is the component. Every other source in `aptSources` reads
`Suites: stable` with the `main` default. The pair therefore reads like a
transposition error and is not one; the declaration carries a comment saying so.

`Signed-By` pointing into `/etc/apt/keyrings` repeats the exception
`google-cloud` already had, and the `stanza` function normalises both to an
inline armored key.

`trixie` is hard-coded. Nothing in this flake declares a Debian release that it
could be derived from -- the release appears only in prose comments -- so the
next Debian major needs an edit here.

### The credential helper is Debian's, not Docker's

```sh
apt-cache policy golang-docker-credential-helpers
#  *** 0.6.4+ds1-1+b18 500
#         500 http://deb.debian.org/debian trixie/main amd64 Packages
apt-cache policy docker-ce
#  *** 5:29.7.2-1~debian.13~trixie 500
#         500 https://download.docker.com/linux/debian trixie/stable amd64 Packages
```

So it cannot be a `packages.corp` entry under the docker source: that option
maps a package to the vendor repository that provides it.

Nothing holds it, and it is in use:

```sh
apt-cache rdepends --installed golang-docker-credential-helpers
# Reverse Depends:          <- empty
apt-mark showmanual | /usr/bin/grep -c '^golang-docker-credential-helpers$'
# 1                          <- the flag is the only thing keeping it
dpkg -L golang-docker-credential-helpers | /usr/bin/grep '^/usr/bin/'
# /usr/bin/docker-credential-pass
# /usr/bin/docker-credential-secretservice
cat ~/.docker/config.json
# { "auths": { "registry.gitlab.internal.dropsolid.com": {} },
#   "credsStore": "secretservice" }
```

It `Depends: gnome-keyring, libsecret-1-0`, and CLAUDE.md already fixes
`gnome-keyring` on apt permanently, so that chain needs no new decision.

### The package set resolves from one name, and is declared as six anyway

```
docker-ce              Depends: containerd.io (>= 2.1.5), docker-ce-cli, iptables, nftables
                       Recommends: apparmor, ca-certificates, docker-ce-rootless-extras,
                                   git, pigz, procps, xz-utils
docker-ce-cli          Recommends: docker-buildx-plugin, docker-compose-plugin
docker-compose-plugin  Recommends: docker-buildx-plugin (>= 0.17.0)
containerd.io          Depends: libc6, libseccomp2
```

`apt install docker-ce` with `Recommends` on pulls all six. The declaration
names all six anyway, because `keep` protects the names it holds and not the
names those pull, and because a `keep` entry carries a reason string a person
had to write.

Five are `manual` today (`containerd.io`, `docker-buildx-plugin`, `docker-ce`,
`docker-ce-cli`, `docker-compose-plugin`); `docker-ce-rootless-extras` is `auto`
and arrived as a `Recommends`. A `keep` entry **promotes** it to a `Depends` of
`calango-desktop`. That is a strengthening nobody measured a need for, and its
reason string says so rather than implying rootless mode is configured. It is
not: `dockerd` runs as a root system service.

### The group has an ordering trap, and root-equivalent meaning

`bootstrap/runbook.md.in:152` runs `usermod -aG @groupsComma@ <user>` in
**Stage A**. The `docker` group is created by `docker-ce`'s postinst, in
**Stage C**. So `docker` added to `calango.bootstrap.groups` makes Stage A fail
on a machine that has never had docker.

Whether `usermod -aG a,b,nosuchgroup` adds `a` and `b` or refuses all three is
**not measured**. Both readings fail Stage A loudly, so the design does not turn
on the answer; the runbook's wording about recovery does, and the rehearsal is
where it gets settled.

What the group means:

```sh
ls -l /var/run/docker.sock
# srw-rw---- 1 root docker 0 /var/run/docker.sock
```

Write access to that socket is write access to the host. Declaring the group is
declaring that, and the reason string says it.

### Docker cannot move to Nix

```sh
dpkg -L docker-ce | /usr/bin/grep systemd
# /usr/lib/systemd/system/docker.service
# /usr/lib/systemd/system/docker.socket
dpkg -L containerd.io | /usr/bin/grep systemd
# /lib/systemd/system/containerd.service
dpkg -L docker-ce-rootless-extras | /usr/bin/grep -c systemd
# 0
```

All system units. Standalone Home Manager writes only
`~/.config/systemd/user`, which is the same architectural reason `bluez` and
`rtkit` are permanent apt residents. This becomes a standing fact in CLAUDE.md
so it is not re-opened.

The absence of any **user** unit is worth recording for the opposite reason:
CLAUDE.md's trap about a removed package leaving a dangling root-owned
`/etc/systemd/user/*.wants` symlink does not apply to any of the six. The census
reads `0` now and stays `0`.

---

## The design

### 1. `home/bootstrap.nix` -- a fifth vendor

A new key pair under `bootstrap/keys/`, per that directory's own README:
`docker.asc` fetched from `https://download.docker.com/linux/debian/gpg`, and
`docker.fpr` beside it so a rotation shows up in review as a changed
fingerprint.

A fifth entry in `aptSources`, using the existing `stanza` function:

```nix
# Docker's repository has no `stable` SUITE -- its suites are Debian
# codenames, and `stable` is the COMPONENT. The two fields therefore read
# inverted against every other source here, and are not.
#
# `trixie` is hard-coded because nothing in this flake declares a Debian
# release to derive it from. The next Debian major edits this line;
# test/apt-sources.sh is what catches it, and only when someone runs it.
"calango-bootstrap-docker.sources" = stanza {
  uris = "https://download.docker.com/linux/debian";
  suites = "trixie";
  components = "stable";
  key = "docker";
};
```

**No `aptSourcesTransient` entry**, per decision 2 and the measurement above.

Six new `packages.corp` entries, each naming the source file the way the
existing five do. None of their reason strings starts with `NO repository`, so
`corpFileOnlyNames` leaves them on the repo-backed side and they join
`@corpRepoPackagesOneLine@` automatically.

The module's **header comment gets corrected** as part of this work. It says the
apt sources are "SCAFFOLDING, not state", that each vendor "writes its own copy
from its own postinst", and that "the runbook deletes them immediately after the
corp packages install". That is true of two of the four and was never true of
the other two -- the `aptSourcesTransient` comment 400 lines below already
contradicts it. Docker makes it two of five.

### 2. `home/bootstrap.nix` -- the group split

```nix
groupsFromCorp = lib.mkOption {
  type = lib.types.attrsOf lib.types.str;
  default = { };
  description = "Group -> which corp package creates it. Added in Stage C.";
};
```

with one member, whose reason carries both the ordering fact and the security
one:

```nix
groupsFromCorp = {
  docker = "docker-ce's postinst creates this group, so Stage A -- which runs
    before Stage C installs docker-ce -- cannot add it. Membership is write
    access to /var/run/docker.sock, which is srw-rw---- root:docker, and so is
    root-equivalent.";
};
```

Three consequences:

- **The runbook** gains `@groupsFromCorpComma@` and `@groupsFromCorpTable@`.
  The Stage C `usermod` line renders **only when the set is non-empty**: an
  empty set must not produce a bare `usermod -aG  <user>`, which would fail
  Stage C on every machine. `requireTokenIn` already asserts that a token added
  to the module appears in the template, so a forgotten template edit fails the
  build rather than rendering literally.
- **The drift hook** at `home/bootstrap.nix:726` loops over `cfg.groups`
  and gains `++ builtins.attrNames cfg.groupsFromCorp`. This is the whole reason
  to declare the group in the module rather than in runbook prose: suffer then
  gets told when the membership goes away.
- **One assertion**, the seventh in that file: `groups` and `groupsFromCorp`
  name disjoint sets, the same shape as `deb.nix`'s `keep`/`ban` disjointness.
  A name in both renders two `usermod` lines and hides which stage owns it.

  State plainly what that assertion does not do. Nothing at build time knows
  which groups a bare Debian machine has, so disjointness cannot stop someone
  putting `docker` in `groups` alone -- which is the failure the split exists to
  prevent. The comment carries that, and the rehearsal is the real check.

### 3. `home/deb.nix` -- seven keep entries

| package | reason, in one line |
|---|---|
| `docker-ce` | the daemon; pulls `containerd.io` and `docker-ce-cli` by `Depends` |
| `docker-ce-cli` | the client; named because `keep` protects what it names, not what its members pull |
| `containerd.io` | the runtime |
| `docker-buildx-plugin` | reaches the machine only as a `Recommends` of the cli |
| `docker-compose-plugin` | the same |
| `docker-ce-rootless-extras` | `auto` today, a `Recommends`; this entry promotes it to a `Depends`, which nobody measured a need for |
| `golang-docker-credential-helpers` | Debian's archive, not docker's. `credsStore` in `~/.docker/config.json`. Zero reverse dependencies, and no in-use check can ever see it |

`calango-desktop`'s `Depends` goes from 21 names to 28. `keep` and `ban` stay
disjoint -- docker appears in neither today -- so the existing assertions hold
unchanged, as does `noStorePaths`.

A `keep` entry both **installs and protects**: the runbook's
`apt install "$D"/calango-desktop_*.deb` resolves the new `Depends` from
Debian's archive. That is why decision 4 needs no `packages.corp` entry and no
third package list for the credential helper.

That install is the **last step of Stage C**, not Stage D. This paragraph said
Stage D until the rehearsal disproved it: `test/vm/steps/30-stage-c.txt:64` is
the line, and Stage C's own pass log shows `Setting up
golang-docker-credential-helpers` immediately before `Setting up
calango-desktop`. The mechanism is exactly what decision 4 claimed — a `keep`
entry installed a package no `packages.corp` entry named — and the stage it was
attributed to was wrong. Worth recording rather than quietly fixing: the claim
was reasoned from the stage names rather than read out of the step file, which
is the shape this project keeps paying for.

### 4. The runbook, the harness, the tests

Most of the runbook regenerates itself. `@corpPackagesTable@`,
`@corpRepoPackagesOneLine@`, `@aptSourceCount@`, `@aptDurableFiles@` and the
transient table are computed from the options. Three counts move: corp packages
6 -> 12, repo-backed corp packages 5 -> 11, apt sources 4 -> 5.

`test/vm/steps/30-stage-c.txt` mirrors the generated apt line verbatim:

```
34:#= sudo apt install 1password 1password-cli code endpoint-verification google-chrome-stable
35:sudo apt install -y 1password 1password-cli code endpoint-verification google-chrome-stable 2>&1 | tail -8
```

Six new names change that generated line, so both lines here change with it,
plus a new pair for the `usermod`. `vm-step-lines-verbatim` fails
`nix flake check` when they disagree, which is the check working.

**Coverage, stated honestly:**

- `nix flake check` -- eight checks, all offline. They prove the tree renders
  and the step files match the rendered runbook. They prove nothing about
  docker's repository.
- `test/apt-sources.sh` -- the real check for the new source. It loops over
  every `.sources` file in the built tree and requires a real `InRelease` to
  land, so a wrong suite or a wrong key fails. Docker gets that coverage with no
  new code. It is **manual**: not one of the eight, and nothing runs it for you.
- `./test/vm/vm final-pass` -- the only thing that proves the Stage C ordering,
  on a machine that has never had docker.

---

## Out of scope

- **Docker as a Nix package.** Decision 6, measured above.
- **Rootless mode.** `docker-ce-rootless-extras` is declared because it is
  installed, not because rootless mode is configured. It is not.
- **The `mise` repository**, which spec 18 excluded alongside docker and which
  nothing in this spec touches. It remains undeclared, and remains a real gap.
- **`corpFileOnlyNames`' prefix match.** The corp list splits by testing whether
  a reason string starts with the literal `NO repository`. Docker's strings do
  not, so the six land correctly. The mechanism is still a guard reading prose,
  which this project has been bitten by three times. Recorded, not changed.

## Future work: the unmanaged dotfiles

`~/.docker/config.json` is owned by nothing. It holds
`credsStore: secretservice` and a private registry entry, and this spec's
decision 4 depends on that value while the flake owns no part of the file.

It is one of a family: user dotfiles carrying configuration this flake's
decisions rest on, managed by neither apt nor Nix nor Home Manager. The 218 MB
of unowned fonts under `~/.local/share/fonts` in CLAUDE.md's standing facts is
the same species, as is `~/.config/mimeapps.list` -- which the flake now
partially owns through two activation hooks, and which is the nearest thing to a
precedent for how to take a file over incrementally.

This spec deliberately does **not** manage `~/.docker/config.json`. A
`home.file` entry would take ownership of a file docker itself rewrites on
`docker login`, which is the shape of conflict `home/syncthing.nix` sidestepped
with a distinct filename and which has no such escape here.

A future spec should survey the class rather than this one file: enumerate the
dotfiles under `~/.config` and `~` that carry load-bearing configuration, decide
for each whether it is written by its own application at runtime, and only then
decide what can be declared. Starting from `~/.docker/config.json` alone would
answer the narrow question and miss the shape.

## Risks

1. **`trixie` goes stale.** The next Debian major breaks the source.
   `test/apt-sources.sh` catches it, and only when a person runs it.
2. **The keep set reaches 28 names.** `apt remove calango-desktop` becomes a
   28-package operation that now includes the container runtime. apt lists them
   and asks first, so it cannot happen silently.
3. **The inline key goes stale on rotation**, exactly as the existing four do.
   The failure names its repository at `apt update` and nothing automates a
   refresh.
4. **The `apt-mark auto` step is human.** Six of the seven keeps are `manual` on
   suffer. If the step is skipped the "held by a `Depends`, not a flag"
   invariant is quietly false, and nothing warns.

## Proof

The spec is done when all of these hold:

1. `sg nix-users -c 'nix flake check'` passes, with the count read rather than
   quoted.
2. `test/apt-sources.sh` verifies five sources, docker's among them, against
   their real repositories.
3. `./test/vm/vm final-pass` reaches Gate D on a fresh disk, with docker
   installed from its own repository and `id -nG` showing `docker` after
   Stage C.
4. On suffer, after the rebuilt `.deb` installs: six `apt-mark auto` calls, then
   `apt-get -s autoremove | grep -c '^Remv '` reads `0`.
5. The keep-set size is read out of the built package --
   `dpkg-deb -f "$D"/*.deb Depends | tr ',' '\n' | wc -l` -- rather than
   predicted from this document.
