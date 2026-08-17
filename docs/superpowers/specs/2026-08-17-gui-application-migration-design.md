# Spec 10: GUI applications — the mechanism

2026-08-17

Specs 7 through 9 moved subsystems: the portal stack, then audio. What is left
on Debian's side, apart from four permanent residents, is applications. There
are eighteen manually-installed apt packages with a `.desktop` file, minus the
corp set.

This spec does **not** move eighteen applications. It establishes the three
mechanisms every GUI migration needs and proves them on two, chosen because
they exercise the mechanisms without risking anything.

Writing it as a package list would rediscover the same three problems eleven
times. Two of them fail *silently*, and one fails at startup in a way that
reads as the application being broken rather than the environment being wrong.

## Scope, in one sentence

Build a reusable way to run a Nix GUI application on this Debian desktop —
GL wrapping, GSettings schema registration, and `.desktop` identity — and
validate it by migrating `seahorse` and `gammastep`.

## The inventory, measured

Eighteen candidates, and they are not one kind of thing:

| Kind | Packages |
|---|---|
| Real GUI migrations | `firefox-esr`, `signal-desktop`, `bitwarden`, `displaycal`, `isoimagewriter`, `syncthingtray`, `virt-manager`, `seahorse` |
| Live provenance split | `gammastep` |
| Remove, not migrate | `kitty`, and `thunar`, `pcmanfm-qt`, `emacs-lucid`, `deskflow` |
| Trivial, no draw path | `vim-common`, `hx` |
| Stays on apt | `flatseal`, `fresh-editor` |

Versions, from the pinned input rather than the registry:

| Debian | | nixpkgs | |
|---|---|---|---|
| `seahorse` | 47.0.1-2 | 47.0.1 | identical |
| `gammastep` | 2.0.9-1+b1 | 2.0.11 | |
| `firefox-esr` | 140.12.0esr | 140.13.0esr | |
| `signal-desktop` | 8.19.0 | 8.21.0 | |
| `bitwarden` | 2026.6.1 | 2026.7.0 | attr is `bitwarden-desktop` |
| `displaycal` | 3.9.16-1 | 3.9.17 | |
| `isoimagewriter` | 25.04.0+dfsg-1 | 26.04.3 | attr is `kdePackages.isoimagewriter` |
| `syncthingtray` | 1.7.5-1 | 2.1.0 | a major |
| `virt-manager` | 1:5.0.0-5 | 5.1.0 | |
| `fresh-editor` | 0.4.7-1 | 0.3.6 | nixpkgs is **older** |

Two of those attribute names were not what the Debian package is called, and a
first guess reported them absent from nixpkgs. `bitwarden` and `isoimagewriter`
resolve only as `bitwarden-desktop` and `kdePackages.isoimagewriter`. Do not
conclude a package is missing from one attribute lookup.

`flatseal` is genuinely absent from nixpkgs and is really a flatpak.
`fresh-editor` would be a downgrade, so it stays.

### The four removals are a precondition, already agreed

`thunar`, `pcmanfm-qt`, `emacs-lucid` and `deskflow` are to be removed rather
than migrated — the user's decision, on the grounds of not needing them, with
`lf` already serving as the file manager (`hypr/hyprland.lua:107` runs
`foot --app-id lf lf`). At the time of writing they are all still `ii`.

`apt-get -s remove` on the four takes `thunar-volman` as well, installs
nothing, and leaves 131 packages autoremovable. Of those, only two ship
anything at system level: `libffado2` (a FireWire audio udev rule, unused
here) and `system-config-printer-udev`. **`cups` itself is not orphaned**, so
printing survives, but USB printer auto-configuration and the GUI setup tool
would go on a later `apt autoremove` — flag before running one. Neither `rtkit`
nor `bluez` is in that list.

## The three mechanisms

### 1. GL wrapping, and why `ldd` cannot decide it

`CLAUDE.md` already records that every Nix GUI binary on this machine needs the
nixGL wrapper, because nixpkgs' GL libraries resolve a NixOS-only
`/run/opengl-driver/lib`. It also records that `ldd` cannot answer the question
for Qt, because Qt `dlopen`s its platform and GL plugins — so `ldd` is clean
for a binary that aborts on first draw.

Three of the migration set are Qt: `isoimagewriter`, `syncthingtray`,
`displaycal`. One is Electron (`signal-desktop`, `bitwarden`), which is Chromium
and certainly needs GL. `firefox-esr` needs GL. So the set cannot be decided by
inspection, and eleven guesses is not a method.

What exists to build on: `home/default.nix` has `nixglWrap = name: exe:` which
wraps **one binary path**, used for `hyprpolkitagent`. `home/session.nix` has
`hyprland-nixgl` in the same shape. Neither wraps a *package* — and a package is
what an application needs, because its `.desktop` file names a binary and that
binary must be the wrapped one.

### 2. GSettings schemas, which nixpkgs relocates out of `XDG_DATA_DIRS`

This is the one that fails at startup rather than silently, and the one this
spec found by accident:

```
/nix/store/…-seahorse-47.0.1/share/gsettings-schemas/seahorse-47.0.1/glib-2.0/schemas/
  gschemas.compiled, org.gnome.seahorse.gschema.xml, …

~/.nix-profile/share/glib-2.0/schemas/   →  0 entries, no gschemas.compiled
```

nixpkgs deliberately puts schemas under `share/gsettings-schemas/<name>/`, a
path GLib never searches. On NixOS the module system adds those directories to
`XDG_DATA_DIRS`; standalone Home Manager on Debian does nothing of the kind, and
this repository has no such mechanism today — `grep -rn 'gsettings-schemas'`
over `home/` and `flake.nix` finds only prose.

A GTK application whose schema is missing does not degrade. It aborts:
`Settings schema 'org.gnome.seahorse' is not installed`. Read cold, that looks
like a broken package.

Every GNOME or GTK application in the set is exposed: `seahorse`,
`virt-manager`, `displaycal`, `gammastep-indicator`.

### 3. `.desktop` identity, which is not preserved across the boundary

```
mimeapps.list   x-scheme-handler/sgnl          = signal-desktop.desktop
                x-scheme-handler/signalcaptcha = signal-desktop.desktop
                x-scheme-handler/bitwarden     = bitwarden.desktop
Debian signal-desktop ships   signal-desktop.desktop
Nix    signal-desktop ships   signal.desktop        ← different id
```

Migrate Signal and both scheme handlers stop resolving. Nothing errors; links
do nothing, and `signalcaptcha` breaks Signal's own registration flow.

The ID is *sometimes* preserved — `firefox-esr.desktop` and
`org.gnome.seahorse.Application.desktop` are identical on both sides — which is
worse than never, because it invites the assumption. `~/.config/mimeapps.list`
holds ten associations; three name packages in the migration set.

There is a second, milder half: during any migration both trees are on
`XDG_DATA_DIRS`, so launchers show duplicate entries until Debian's package
goes.

## Decisions

**`seahorse` is the first subject.** It is the ideal canary: identical version
on both sides, so nothing can be blamed on an upgrade; matching `.desktop` ID,
so mechanism 3 is not in play; no `mimeapps.list` or autostart reference; a GUI
opened occasionally, so failure costs nothing — and it *forces* mechanism 2,
because it ships schemas and will abort without them.

**`seahorse` moves while `gnome-keyring` and `gcr` stay on Debian.** The
coupling is D-Bus, not shared libraries: `libsecret` talking to
`org.freedesktop.secrets`, a stable cross-version API. Nix's seahorse links
Nix's own gcr, in its own process. Nothing requires a client and a daemon to
come from the same packaging system, and this spec's endpoint proves it.

**`gammastep` is the second, and it closes a live split.** Today the
night-light unit runs Nix's 2.0.11 from `nightLightPath` while a shell and both
`.desktop` files get Debian's 2.0.9 — `pkgs.gammastep` is in the unit's
`Environment=PATH` and has never been in `home.packages`. Nix's package has
full parity: `gammastep`, `gammastep-indicator`, and both `.desktop` files. It
exercises mechanism 1 and 3 lightly and mechanism 2 through the indicator.

**The remaining seven are follow-on batches, not this spec.** Once the
mechanisms exist and are proven, each is `home.packages` plus an apt removal
plus the checks. Sequencing them by blast radius is a later decision;
`firefox-esr` and `signal-desktop` are the two with real daily cost.

**`kitty` is removed, not migrated.** `home/quickshell.nix:75` records that this
project installs foot and that the theme switcher's kitty path was deleted.
Migrating it would be adopting something already decided against.

**A `.desktop` identity check becomes a flake check**, beside
`no-dangling-home-files` and `no-pulseaudio-daemon`. A mismatch between what a
migrated package ships and what `mimeapps.list` names must be a build failure,
not a dead link discovered weeks later.

## Non-goals

- **The corp set** — `google-chrome-stable`, `code`, `1password`,
  `1password-cli`, `endpoint-verification`, flatpak Slack. Permanent.
- **The four permanent apt residents** — `bluez`, `rtkit`, `gnome-keyring`
  (with `gcr4`), `dbus-broker`. All four are recorded in `CLAUDE.md` with the
  measurement behind each.
- **`flatseal` and `fresh-editor`** — absent from nixpkgs, and a downgrade,
  respectively.
- **`vim-common` and `hx`** — terminal programs with no draw path; they can
  move any time and need none of these mechanisms.
- **The remaining seven GUI applications** — batches after this.
- **`apt autoremove`** — 131 packages are pending across this and the audio
  removal. Its own decision, with the printing caveat above.
- **The unmanaged font piles and `/run/opengl-driver`** — inherited unchanged.

## Design

### Phase 0 — decide the GL question by measurement, not inspection

Establish a procedure that says whether a given Nix GUI binary needs the nixGL
wrapper, and that works for Qt. `ldd` is excluded by `CLAUDE.md`; the honest
test is to run the binary both ways against the real compositor and observe
whether it draws.

Deliverable: the procedure, and its answer for `seahorse` and both `gammastep`
binaries. Nothing is written to the flake in this phase.

### Phase 1 — the schema mechanism, and `seahorse`

A reusable way to expose a package's `share/gsettings-schemas/<name>` to the
application. Two candidate shapes, to be settled by measurement in this phase:
wrapping the binary with `XDG_DATA_DIRS` prepended, or assembling one merged
schema directory for the profile and prepending that once.

The wrapper shape is per-application and cannot collide. The merged shape is
one place but must handle `gschemas.compiled` from several packages, which is a
single file per directory and therefore a genuine collision — that is the
question to answer before choosing.

Then `seahorse` from Nix, Debian's removed.

**Gate:** seahorse launches, shows the `login.keyring` contents served by
Debian's `gnome-keyring-daemon`, and `busctl --user status
org.freedesktop.secrets` still names the Debian daemon's PID — proving the
client moved and the daemon did not. No `Settings schema` abort in its output.

### Phase 2 — `gammastep`, and the split closed

`pkgs.gammastep` into `home.packages`, Debian's package removed.

**Gate:** `command -v gammastep` resolves into `/nix/store`; the night-light
unit still runs and its child is still the store binary; `gammastep-indicator`
launches; both `.desktop` entries appear exactly once.

### Phase 3 — the `.desktop` identity check

The obvious form of this check is not implementable, and saying so is part of
the design. A flake check runs in the Nix sandbox: it cannot read
`~/.config/mimeapps.list`, and it cannot see `/usr/share/applications` — both
are impure. So "assert every ID in `mimeapps.list` resolves" cannot be a flake
check at all. This is the same trap as spec 9's `/dev/null` mask, which passed
a runtime probe and then failed to build.

It splits into two checks at two layers, and both are needed:

- **Build time, in `flake.nix`:** for a list of `mimeapps.list` ID → package
  pairs *declared in Nix*, assert the package actually ships that `.desktop`
  file. This catches `signal.desktop` versus `signal-desktop.desktop` at the
  moment the package is added, which is the failure that matters. The declared
  list is the thing that can go stale, so it is cross-checked by syntax the way
  `home/uwsm.nix` cross-checks its unit list — not trusted as written.
- **Activation time, in `home.activation`:** read the real
  `~/.config/mimeapps.list`, and warn for any ID that no longer resolves
  anywhere on `XDG_DATA_DIRS`. Non-fatal, because that file holds ten
  associations and several name things this flake does not own — flatpak Slack,
  `claude-code-url-handler.desktop` — whose absence is not this flake's
  business and must not abort a switch.

Both proven to fail by mutation, per this project's rule: point a declared pair
at an ID the package does not ship, and point a `mimeapps.list` entry at an ID
nothing provides.

This is the phase that protects the seven follow-ons, and it is deliberately
last: it needs at least one migrated application to be meaningful.

## Verification

The rules in `CLAUDE.md` apply. Three deserve restating because this spec
touches each:

**`ldd` is not a decision procedure for a `dlopen` question.** It is excluded
for Qt's GL plugins exactly as it is for PipeWire's SPA plugins. Phase 0 exists
because of this.

**A check that cannot fail is not a check.** The `.desktop` identity check must
be shown to fail — the natural mutation is pointing a `mimeapps.list` entry at
an ID nothing provides.

**Probe every layer the change passes through.** Spec 9 probed a systemd mask
by hand, passed, and then failed to build because Nix would not import
`/dev/null`. A schema mechanism has the same shape: the runtime question (does
GLib find the schema) and the build question (can Home Manager express the
path) are different questions.

And one specific to applications: **the failure mode is a window that does not
appear, which looks like a broken package.** Every gate here ends with a person
opening the application, not with a unit being active.

## Recovery

| Phase | Recovery |
|---|---|
| 0 | Nothing is changed. |
| 1 | `sudo apt install seahorse`, and remove the flake lines. |
| 2 | `sudo apt install gammastep`. The night-light unit is unaffected either way — it names the store path directly. |
| 3 | Remove the check. |

All of Debian's packages here are downloadable from trixie. A Home Manager
rollback is **not** a recovery path, for the reasons recorded since spec 6.

Worst case in this spec is an application that will not start. Nothing here is
in the login path, and nothing here can cost audio, the session or the
compositor.

## Endpoint

- Three mechanisms that exist, are documented, and have each been proven to
  fail when broken: GL wrapping, schema registration, `.desktop` identity.
- `seahorse` from Nix, talking to Debian's keyring — the first demonstration in
  this project that a client can cross the boundary while its daemon does not.
- `gammastep` entirely Nix's, and a two-provenance split closed.
- Eight fewer apt packages. Two are this spec's own migrations, `seahorse` and
  `gammastep`. Five are removals rather than migrations: `kitty`, and the four
  agreed as a precondition — `thunar`, `pcmanfm-qt`, `emacs-lucid`, `deskflow`.
  `thunar-volman` comes along with Thunar, making eight.
- Seven GUI applications reduced to mechanical follow-on work.

## Corrections

Appended 2026-08-17, after execution. The prose above is deliberately left as
it was argued at the time — rewriting it would erase that mechanism 2 was
wrong. Every measurement behind the corrections below, and the full defect
list, is in `docs/2026-08-17-results-suffer-gui-applications.md`.

**Mechanism 2 did not need building.** The relocation this spec measured is
real — nixpkgs puts schemas under `share/gsettings-schemas/<name>/`, which GLib
never searches — but the conclusion that nothing on this machine handled it was
never checked, and it is false. `wrapGAppsHook` already produces a per-package
`bin/<name>` wrapper that prefixes `XDG_DATA_DIRS` with every schema directory
the application needs. So the choice this spec posed between "wrap the binary"
and "assemble one merged schema directory", including the `gschemas.compiled`
collision question, does not arise. What shipped instead is a build-time
*guard* that each `guiPackages` member is wrapped — a smaller artefact than the
mechanism specified here, and a different one.

**Mechanism 3 named the cosmetic half of its risk and missed the serious one.**
The spec's "second, milder half" — duplicate launcher entries while both trees
are on `XDG_DATA_DIRS` — is real and harmless. The hazard it does not name is
that the winning `.desktop` entry and the winning binary are chosen by **two
independent search paths**: `XDG_DATA_DIRS` picks the entry, and a bare-name
`Exec=` is then resolved through `PATH`. With both packages installed those can
disagree, so a Nix entry can run a Debian binary or the reverse — the same
shape as spec 6's `fumon`. `seahorse`'s entry is exactly the bare-name form
(`Exec=seahorse %u`), and `~/.nix-profile/bin` was measured at PATH position 30
against `/usr/bin` at 34. This makes the apt removal part of correctness rather
than tidying afterwards, which is a different reason than the one given above.

**A third search path exists that this spec discusses nowhere.**
`org.gnome.seahorse.Application.desktop` declares `DBusActivatable=true`, so a
launcher never runs `Exec=` at all and asks the session bus to activate the
name instead. The bus's own `XDG_DATA_DIRS` carries no `~/.nix-profile/share`,
so the activation file inside the package was invisible and seahorse could not
be launched by any launcher. The remedy — an `xdg.dataFile` entry under
`dbus-1/services/` — was already recorded in `CLAUDE.md` since spec 7 and
already applied five times in `home/portals.nix`. A build-time guard named
`dbusActivatableGuiApps` now covers the class for every `guiPackages` member.
Named rather than numbered on purpose: an earlier version of this line called it
"a fourth build-time guard", an ordinal with no established base that also
disagreed with `CLAUDE.md`'s own count of the guards riding in `home.packages` —
which was itself wrong. Guards in this repo are enumerated by grepping for them,
never by position in a remembered sequence.

**Phase 3's build-time check could not exist as specified.** This spec
correctly says the obvious single-check form is not implementable in the Nix
sandbox, then specifies a build-time half over "`mimeapps.list` ID → package
pairs" — which still names a file the sandbox cannot see. What shipped asserts
a hand-maintained `required` list, each entry carrying the reason it is
required, and searches **two** trees rather than one, because this flake ships
`.desktop` entries through both `home.packages` and `xdg.dataFile`. The
correspondence between that list and `mimeapps.list` is a human's to keep; the
non-fatal activation hook is what covers the gap. The first version of the
check read one tree only, which made its own stated purpose unreachable by its
own mechanism, and a reviewer rather than the build is what caught it.

**Phase 2's gate looked for a child process that cannot exist.**
`quickshell/night-light/run.sh:112` is `exec "$@"`, so `night-light.service`'s
`MainPID` *is* gammastep and has no children. The gate reads `MainPID`'s own
`exe` instead.

**The endpoint's "eight fewer apt packages" holds, and conceals three dpkg
states.** Four have no dpkg record at all, three are `rc` (removed, conffiles
retained), and `emacs-lucid` alone is `un` — all six of the removals from one
`apt remove` with no `purge`. The eight-package figure is right; "eight
removed" would flatten a distinction this project checks for deliberately.

**The endpoint's gammastep bullet is true on provenance and the machine's
night light is currently broken.** The split is closed and apt has no
`gammastep` at all, but since 2026-08-17 08:57 Hyprland refuses every gamma
client on this machine. The trigger is unidentified; a gamma control leaked by
this spec's own interrupted GL probes is not ruled out, which would mean the
verification activity caused it. The re-login test that would separate the
candidates was deferred and has not been run.
