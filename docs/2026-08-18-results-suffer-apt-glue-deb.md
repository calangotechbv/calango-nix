# Spec 16 results: a glue `.deb`, built by Nix, on `suffer`

**Spec:** `docs/superpowers/specs/2026-08-18-apt-glue-deb-design.md`
**Plan:** `docs/superpowers/plans/2026-08-18-apt-glue-deb.md`
**Branch:** `apt-glue-deb`, merged to `main` as `497a29b`, 11 commits
**Executed and closed out:** 2026-08-18

---

## What changed

This flake had crossed the apt boundary fifteen times and could never *state*
anything about the Debian side. Twenty-two packages were `apt-mark manual` for
reasons that lived only in `CLAUDE.md`; the greetd session entry was owned by
nobody; and the syncthing ufw profile existed only as an `rc` leftover of the
package Nix had replaced.

Nix now builds a Debian metapackage. `lib/deb.nix` turns a manifest into a
`.deb`; `home/deb.nix` declares a `calango.deb.*` option namespace that any
module contributes to; `flake.nix` exposes it as `packages.calangoDeb`.

**Nix builds, apt installs, dpkg enforces.** No sudoers rule, no polkit action,
no privileged step inside a switch. `sudo -n` requires a password here, so an
unattended privileged step was never available — and this project had already
declined the analogous shape for `pam_gnome_keyring.so`.

| declaration | control field | enforced by |
|---|---|---|
| 22 keeps | `Depends:` | apt cannot autoremove a dependency of a manual package |
| 19 bans | `Conflicts:` | apt refuses to install them |
| 1 ufw profile | conffile in `/etc/ufw/applications.d/` | dpkg fires ufw's own trigger |
| 1 system file | ordinary package file | dpkg |

## The property, live

```sh
dpkg-query -W -f='${db:Status-Abbrev} ${Version}\n' calango-desktop
# ii  0.258
apt-cache rdepends --installed libpipewire-0.3-modules
# Reverse Depends:
#   calango-desktop            <- was empty before this work
```

Nine packages and 12 MB that a flag and a paragraph were the only thing
holding now hang off a real dependency, with the reason travelling in the
control file where `apt show calango-desktop` renders it.

## The central claim, proven by isolation rather than by agreement

That `Depends:` defeats `autoremove` was **reasoned, not measured**, for the
whole of the spec and the plan, and both said so. Proving it needed root, so it
was the user's step.

Flipping all 22 to `auto` and observing `autoremove` at 0 would have been
*consistent* with the claim without establishing it — most of the 22 have other
installed holders. The test that settles it uses the one package whose sole
holder is the metapackage:

```sh
sudo apt-mark auto libpipewire-0.3-modules
apt-cache rdepends --installed libpipewire-0.3-modules   # calango-desktop, alone
apt-get -s autoremove | grep -c '^Remv '                 # 0
```

Nothing else could account for that result. The remaining 21 were flipped
afterwards; all 22 verified `auto` one at a time.

**A count that agreed for the wrong reason.** `apt-mark showmanual | wc -l`
moved 370 → 349, which is **21, not 22** — `libffado2` had already been left
`auto` by an earlier acceptance test whose restoring `apt-mark manual` never
ran. The delta looked plausible. Only the per-package check found it.

## The login path

The greetd session entry is the one artefact here that can make a machine
unbootable into its desktop, so the handover was ordered **ship → login →
delete**, never delete-first.

Both copies were byte-identical and both yield `Desktop=hyprland-nix`, so the
running session cannot say which was used. The ordering can:

```sh
stat -c '%y' /usr/local/share/wayland-sessions   # 17:40:21  <- the deletion
loginctl show-session 42 -p Timestamp            # 17:57:20  <- the login
```

The old entry did not exist when the session started. `atime` cannot answer
this — the root filesystem is `relatime`, so a second read inside 24 hours does
not move it.

## Final state

```
calango-desktop     : ii 0.258
keep set auto       : 22 of 22
autoremove proposes : 0
manual total        : 349
ufw rule            : /etc/ufw/user.rules mtime 17:40:34
unowned files       : none outside $HOME
nix flake check     : 4 checks, exit 0
```

---

## Defects, and their owners

| # | defect | owner | how it was caught |
|---|---|---|---|
| 1 | A `keep` reason contained the literal store-path prefix; reasons are serialised into `manifest.json`, which the `noStorePaths` guard greps. Would have failed the first clean build. | controller | pre-flight scan |
| 2 | Task 1's drift expectation said the "current" case prints nothing, and two sentences later that every run prints the banned line. | controller | pre-flight scan |
| 3 | `lib/deb.nix` said "dpkg-deb clamps to its own 1980 floor". It clamps nothing — that is a ZIP/FAT behaviour. The 1980 came from `SOURCE_DATE_EPOCH`, which a simplification to `@0` removed while the comment stayed. | controller | Task 1's implementer flagged the measurement; the reviewer proved it by reading a tar member's mtime with Python |
| 4 | The same false claim had reached the plan twice and the spec once. | controller | follow-up enumeration |
| 5 | Guard 1's mutation was invalid twice — `lib.mkForce {} // {}` is a type error, a second dotted path is a duplicate-attribute error. Both turn the build red without reaching the guard. | controller | Task 3's implementer, which declined to read "the build failed" as "the guard fired" |
| 6 | Three attribute names unquoted (`libpipewire-0.3-modules`, `libroc0.4`, `libglibmm-2.4-1t64`) are Nix parse errors: a dot followed by a digit lexes as a float. The same block already quoted the `+` names. | controller | Task 4's implementer |
| 7 | The brief described `home/deb.nix`'s three assertions as guarding `.ufwProfiles` and `.files`; they guard `keep`/`ban`. | controller | Task 5's implementer |
| 8 | The `fakeroot` evidence in `CLAUDE.md`, the plan and the spec was `cmp with-fakeroot.deb without-fakeroot.deb`. Those files never existed here. | controller | final review, which ran the commands |
| 9 | **`Conflicts:` was said to make flatpak's unsatisfied `Recommends` "fail loudly". It does not** — the portal is silently omitted; only an explicit request fails. This one shipped into `manifest.json` and `apt show`. | controller | final review |
| 10 | **The store-path guard rode only in `home.packages`, which `nix build .#calangoDeb` never evaluates** — so the command that produces the installable artifact was unguarded and would happily write a `.deb` naming the store. | controller | final review, by mutation |
| 11 | Adding a `packages` output made `CLAUDE.md`'s own check-counting command return 5 against nix's summary of 4. | controller | close-out |

**Eleven defects, all mine, none in the `.nix` code.** No reviewer found a
Critical or Important defect in any module this branch wrote; `lib/deb.nix`,
`home/deb.nix`, the flake wiring and all three module contributions were
approved as written. What failed, eleven times, was the sentence beside the
measurement and the recipe for taking it.

Defect 10 is the one worth keeping. `CLAUDE.md` already says *prove a check
against the property it claims to cover, not merely against itself*. The guard
was proven able to fail — by a mutation built against the activation package,
which was the wrong target. It could not fail on the path that matters.

Defect 9 is second, for a different reason: every other claim defect here
stayed in a document. That one was serialised into the package and rendered on
the user's machine by `apt show`.

## Guards added

| guard | property | where | proven by |
|---|---|---|---|
| `keep` non-empty | the vacuity anchor | `assertions` | forcing the option empty; fires with its own message |
| `keep` ∩ `ban` = ∅ | no package both required and forbidden | `assertions` | adding `lf` to `keep`, which `ban` already holds |
| every reason non-empty | a name must carry a sentence | `assertions` | emptying `flatseal`'s reason |
| `noStorePaths` | no root-owned file names the Nix store | `home.packages` **and** `deb.build`'s inputs | a store path in the payload; both build targets fail |

## Known limitations, accepted

- **`ufw` rules are still not declared anywhere.** The package ships the
  vocabulary; `sudo ufw allow calango-syncthing` was a human act, and remains
  one. `/etc/ufw/user.rules` is `0640 root:root`, and `nft` and `iptables` both
  refuse an unprivileged read, so nothing here could ever verify a rule.
- **Removing the metapackage is now a 22-package operation**, `bluez`,
  `google-chrome-stable`, `1password` and `code` among them. apt lists them and
  asks, so it cannot happen silently — but `apt-mark showmanual calango-desktop`
  is the check that matters before trusting any of it.
