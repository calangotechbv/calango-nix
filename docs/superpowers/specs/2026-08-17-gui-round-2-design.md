# Spec 13: GUI applications, round 2 — signal-desktop and bitwarden

2026-08-17. Branch `gui-round-2`.

Spec 10 moved `seahorse` and `gammastep` and built three guards. This spec moves
the next two applications, and its interest is that **each of them exercises a
guard where it has never fired**. A guard that has never caught anything is not
yet a guard.

## The two packages, measured

```
                     Debian        Nix (pinned)      .desktop id
signal-desktop       8.19.0        8.21.0            signal-desktop.desktop -> signal.desktop
bitwarden            2026.6.1      2026.7.0          bitwarden.desktop      -> bitwarden.desktop
```

Both, measured from the built store paths:

| property | signal-desktop | bitwarden-desktop |
|---|---|---|
| `DBusActivatable` | no | no |
| `share/dbus-1/services/` | 0 files | 0 files |
| binaries in `bin/` | 1 | 1 |
| `.*-wrapped` siblings | **0** | **0** |
| `share/gsettings-schemas` dirs | 0 | 0 |
| `Exec` | `signal-desktop %U` | `bitwarden %U` |
| `MimeType` | `x-scheme-handler/sgnl;x-scheme-handler/signalcaptcha` | `x-scheme-handler/bitwarden` |

Note the attribute names differ from the Debian package names. nixpkgs has
`bitwarden-desktop`; evaluating plain `pkgs.bitwarden` fails with

```
error: 'bitwarden' has been renamed to/replaced by 'bitwarden-desktop'
```

which is a `throw` from nixpkgs' alias machinery rather than a missing
attribute — so a plan that writes `pkgs.bitwarden` fails at eval with a message
that names the fix, and will not silently install nothing.

Both `Exec` lines are bare names, so both are launchable from the Applications
panel only because of spec 11's `appPath`. Before that they would have joined the
57 of 59 bare-name entries that resolved against nothing.

## What this spec must build

### 1. An exemption for `wrappedGuiApps`, and it must be self-cleaning

Both packages have **zero** wrapped binaries and **zero** GSettings schemas, so
both fail the guard as it now stands.

That guard originally exempted any package shipping no schemas of its own,
justified as "nothing to wrap". Spec 10's review disproved the justification —
`gammastep` ships no schemas of its own yet its wrappers prefix
`XDG_DATA_DIRS` with its *dependencies'* schema directories — and the exemption
was deleted, with the prediction that the first legitimately-unwrapped
application would need a deliberate one. These are that case: Electron
applications with genuinely nothing to wrap.

The exemption must be an **explicit list mapping package to reason**, not a
derived rule. The derived rule is what was wrong before, and the failure mode of
deriving again is a second silently-wrong exemption.

It must also be **self-cleaning**, which is the part that distinguishes this from
an ordinary allowlist: if an exempt package ever *does* ship a wrapped binary,
the build fails and demands the exemption be removed. Without that, the list only
grows, and an entry that stopped being true keeps excusing a package that has
started needing the check. Both halves get proven by mutation.

### 2. Signal's `.desktop` id changes, and two handlers name the old one

`~/.config/mimeapps.list` has:

```
x-scheme-handler/sgnl=signal-desktop.desktop
x-scheme-handler/signalcaptcha=signal-desktop.desktop
```

Neither id will exist after the migration. This is precisely the failure
`gui-desktop-ids` was written for, and the reason nixpkgs' naming was recorded in
`CLAUDE.md` before any Signal migration was planned.

**Decision, taken by the user:** rewrite those two lines to `signal.desktop`,
with an idempotent, non-fatal activation hook. Rejected alternatives, recorded so
they are not re-proposed: a hidden alias `signal-desktop.desktop` shim, which
avoids touching a user-owned file but leaves a permanent shim maintaining a stale
reference; and doing nothing on the theory that `signal.desktop`'s own
`MimeType=` re-registers the association, which may well be true but leaves
`mimeapps.list` naming a dead id that `mimeappsIds` warns about at every switch.

The hook writes a file this flake does not own. That is the cost of the chosen
option and it must be handled carefully: idempotent, non-fatal, and touching only
those two assignments. `mimeapps.list` also contains ids this flake will never
own — a dead `eu.calangotech.KBrowserSelector.desktop`, and `slack.desktop` where
flatpak exports `com.slack.Slack.desktop` — and the hook must leave them exactly
as it found them.

### 3. `gui-desktop-ids` gains both ids

`signal.desktop` and `bitwarden.desktop` join `required`. For `signal.desktop`
this is the id `mimeapps.list` will name after the rewrite, so the check finally
covers an id a handler actually references — the property it declared in spec 10
and could not reach until spec 11 widened it to both trees.

## What this spec must NOT build

`dbusActivatableGuiApps` needs no new entry. Neither package declares
`DBusActivatable` nor ships a `share/dbus-1/services/` file, so the guard passes
for them by having nothing to assert. Do not add an entry to be safe: a
`xdg.dataFile` mirror of a service file that does not exist would be a dangling
`source`, and `no-dangling-home-files` exists because that builds cleanly.

## The open question, and it is the risk

**Whether either application needs the nixGL wrapper is unknown and cannot be
settled by any automated check.**

`CLAUDE.md` records that every Nix GUI binary needs nixGL, listing the
compositor, quickshell, hyprlock, hyprpolkitagent and the hyprland portal — and
spec 10 then found that `seahorse` and `gammastep` do not, so the rule is
narrower than stated. It also records that `ldd` is a false negative for anything
that `dlopen`s its GL plugins.

These two are heavier GL users than anything spec 10 migrated. Both are Electron,
so both drive Chromium's GPU path. That makes this the first migration where a GL
failure is genuinely likely rather than theoretical.

The only instrument is the one spec 10 used: **the user runs the binary by hand,
bare and unwrapped, from a terminal inside the live Hyprland session, and reports
whether a window appears.** No agent can watch a window. This is a gate before
the apt packages are removed, not after — if a binary cannot draw, the Debian
copy must still be there.

If either fails to draw, the options in order of preference are: wrap it in
`nixGLIntel` as `home/session.nix` does for the compositor; pass Electron's
`--disable-gpu`, accepting software rendering; or abandon that half of the
migration and record why. The spec does not choose in advance, because the
failure mode determines the fix.

## Removal, and the orphan list

`apt-get -s remove signal-desktop bitwarden` currently proposes **no** orphans.
That is a real change: before spec 12 the same command printed 137, and reading
it was hopeless. The list is now meaningful, and it must still be read at the
moment of removal rather than trusted from this document.

## Out of scope

- The remaining apt GUI candidates: `displaycal`, `firefox-esr`, `helix`,
  `syncthingtray`, `virt-manager`. `virt-manager` in particular must first
  strengthen `wrappedGuiApps` to compare the wrapper count against the binary
  count, since it ships four binaries and four wrappers today and an upstream
  change wrapping only the GUI entry point would pass the current test.
- Syncthing, which is owed a spec of its own because 1.29.5 → 2.1.2 converts its
  database irreversibly.
- `flatseal`, `fresh-editor` and `isoimagewriter`, all previously ruled out.

## Risks

- **A GL failure after the apt package is gone.** Mitigated by making the
  hand-run draw test a gate before removal. Recovery would otherwise mean
  reinstalling from apt, which is possible but is exactly the avoidable kind of
  scramble.
- **The mimeapps rewrite damages a file the flake does not own.** Mitigated by
  idempotence, by touching only the two named assignments, and by recording the
  file's full content before and after so the diff is exactly two lines.
- **The exemption list becomes a dumping ground.** Mitigated by the staleness
  check, which fails the build when an exemption stops being true.
- **A version regression.** Neither is: 8.19.0 → 8.21.0 and 2026.6.1 → 2026.7.0
  are both forward. Verify from the pinned input at implementation time rather
  than from this table, since the input can move.
