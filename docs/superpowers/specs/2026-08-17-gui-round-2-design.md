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

---

## Corrections

Appended at close-out. **Append-only** — nothing above this line is rewritten,
including the parts execution overturned, because a spec that quietly agrees
with its own outcome teaches nobody what it got wrong. Results in
`docs/2026-08-17-results-suffer-gui-round-2.md`.

### 1. The plan's dag placement was wrong: `entryAfter [ "writeBoundary" ]`

The plan gave `signalMimeappsId` as `lib.hm.dag.entryAfter [ "writeBoundary" ]`.
Built exactly as written, it landed at line 463 of the generated `activate` —
**after** `mimeappsIds` at 386 — because `hm.dag.topoSort` feeds
attribute-name-sorted `builtins.attrValues` into a stable `lib.toposort`, so
any pair with no stated relation is ordered alphabetically and `s` sorts after
`r`. The hook that *reports* dead `.desktop` ids would have read the file
before the hook that *fixes* one of them ran, and warned about
`signal-desktop.desktop` at every switch.

Corrected in execution to
`entryBetween [ "mimeappsIds" ] [ "writeBoundary" ]`; measured after, the
fixer is at 386 and the reporter at 398.

Only that one `before` edge is claimed. The hook reads no `.desktop` search
path, so `linkGeneration` and `installPackages` are irrelevant to it, and
`defaultBrowser`'s `xdg-settings` write is a read-modify-write that preserves
unrelated assignments — declaring edges against either would state constraints
that do not exist.

This is a hazard `home/apps.nix` already documents at length, having paid for
it once in `home/audio.nix`. It was written into the plan anyway.

### 2. The risk section missed the risk Task 1 itself triggered

The spec listed four risks: a GL failure after the apt package is gone, damage
to `mimeapps.list`, the exemption list becoming a dumping ground, and a version
regression. It missed the one the **very first task** would set off.

Both applications open a config directory on first launch, and a newer build
can migrate it irreversibly. `~/.config/Signal` is 116 MB — an encrypted
message-history database that Signal Desktop refuses to open once a newer
version has migrated it. So running the store-path binary bare, which is the
GL gate this spec designed, is itself the one-way step; the apt removal it was
meant to gate is reversible by comparison.

Caught before the run by asking what the test would touch, not by the spec.
Backups were taken, and both live directories were written during the test, so
the risk was real rather than theoretical. Whether a schema migration actually
occurred was deliberately left unestablished.

The general lesson, now in `CLAUDE.md`: for a GUI migration, treat the **first
launch** as the irreversible step, not the removal. This spec had the right
shape available to it — it already cites syncthing's one-way database
conversion under Out of scope — and did not apply it to its own gate.

### 3. The plan's stated reason for the `sed`'s idempotence was wrong

Behaviour right, reason wrong. The plan's comment said "the grep guard means a
second run finds nothing and exits before sed is invoked". Tested against a
synthetic file carrying negative controls (`xsignal-desktop.desktop`,
`signal-desktop.desktop.bak`, `my-signal-desktop.desktop`), runs 2 and 3 *did*
invoke the `sed` and print the rewrite message, while the checksum stayed fixed
from run 2 onward.

The `grep -q` guard is a plain **substring** test; the `sed` matches only
**whole values**. The guard is therefore the broader of the two: where the
token appears only inside a longer id, the guard passes, `sed` runs, and
correctly changes nothing. Idempotence holds unconditionally, but it belongs to
the `sed`. That the guard goes quiet on the real file is a property of that
file's contents, not of the mechanism.

Corrected in `home/apps.nix`'s comment; the code was left as approved.

A related limitation found by the same test and deliberately not fixed:
adjacent duplicates (`…;signal-desktop.desktop;signal-desktop.desktop`) take
two invocations, because `s///g` consumes the separator it matched. It
converges rather than losing data, and the case does not occur in the real
file.

### 4. The open question was answered narrowly, not fully

The spec asked "whether either application needs the nixGL wrapper". What the
gate could answer is narrower: **neither requires nixGL to draw a window.**
Both are Electron, and Chromium falls back to SwiftShader — software rendering
— silently, with a window indistinguishable from an accelerated one. So
**whether either is GPU-accelerated remains unmeasured**, and the results
document carries the check that would settle it
(`grep -cE 'swiftshader|libEGL_mesa|iris_dri' /proc/<pid>/maps`, over every pid
in the tree, with one of them running).

The migration stands either way — a working window was the gate the spec
specified, and it passed. The correction is to the strength of the conclusion,
which the first draft of the results document overstated as "neither needs
nixGL".
