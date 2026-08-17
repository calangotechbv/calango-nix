# Results: GUI applications round 2 — suffer

2026-08-17. Spec 13. Branch `gui-round-2`.

`signal-desktop` and `bitwarden` move from apt to Nix. Each was chosen because it
exercises a guard from spec 10 where that guard has never fired.

---

## Task 1: the GL verdict

Both packages are Electron, so both drive Chromium's GPU path — heavier than
anything spec 10 migrated. `CLAUDE.md` records that every Nix GUI binary needs
the nixGL wrapper, then spec 10 found `seahorse` and `gammastep` do not, so the
rule is narrower than stated and each application has to be asked separately.

`ldd` cannot answer it. `CLAUDE.md` excludes it precisely for toolkits that
`dlopen` their GL and platform plugins, where a binary starts, registers and dies
the instant it is asked to render. It was not consulted.

The only instrument is a person watching a window. The user ran each binary bare
and unwrapped, from a terminal inside the live Hyprland session:

```
/nix/store/2l2xlpbk6y4f5kk7z32wn8xpxqwnf1jz-signal-desktop-8.21.0/bin/signal-desktop
/nix/store/l3dy6i7lxh2vs5k3q3cylbkm57gchg52-bitwarden-desktop-2026.7.0/bin/bitwarden
```

**Both windows opened.** Reported by the user; no agent can observe this.

> ## The conclusion, after two corrections — read this before the rest
>
> **Neither application needs its own nixGL wrapper. Both need nixGL's
> environment, and both were inheriting it from the compositor's wrap.** The GL
> gate ran inside a session that already exported those variables, so it could
> never have distinguished "needs no nixGL" from "already has nixGL".
>
> Session children inherit; systemd units do not, which is why five things carry
> their own wrap. Do **not** scrub the session inheritance — a follow-up spec to
> do exactly that was one command from being written, and it would have broken
> both applications this spec migrated.
>
> Whether either renders on the GPU rather than in software was **not** measured
> for Signal or Bitwarden. It was measured for flatpak Slack, further down, and
> the answer there is yes.
>
> The two subsections below are kept as written, in order, because the sequence
> is the useful part. Neither states the final position on its own.

### First version: "neither needs nixGL", which was stronger than the evidence

A window appearing is not evidence of GPU acceleration. Both applications are
Electron, and Chromium falls back to **SwiftShader** — CPU rasterisation — on
its own, without a dialog, without a stderr line the user would recognise, and
with a window that looks identical. "It drew" and "it drew on the GPU" are two
claims and only the first was measured. The original wording asserted the
second by implication, which is this project's recurring failure shape: the
command was real, the conclusion written afterwards went further than it.

So, precisely: **neither requires nixGL to draw a window. Whether either is
GPU-accelerated is unmeasured.** Practically the migration stands either way —
a working window was the gate — but a later report of "Signal is sluggish"
must not be met with "we established GL is fine", because nothing here did.

**Superseded by the subsection below.** This version is still too generous: it
says nixGL is not *required*, when what the test showed is that no *additional*
wrapper is required on top of the one the session already provides.

### Second version, after the close-out: both DO need nixGL's environment

The paragraph above is still too generous, and the measurement that settles it
arrived only because the user asked why `nixglWrap` was needed at all.

Run with the five nixGL variables removed, Signal does not merely lose
acceleration — its GPU stack collapses:

```sh
env -u LIBGL_DRIVERS_PATH -u GBM_BACKENDS_PATH -u LIBVA_DRIVERS_PATH \
    -u __EGL_VENDOR_LIBRARY_FILENAMES -u LD_LIBRARY_PATH signal-desktop

MESA-LOADER: failed to open dri: /run/opengl-driver/lib/gbm/dri_gbm.so: …
ANGLE Display::initialize error 12289: Failed to get system egl display
eglInitialize OpenGL failed with error EGL_NOT_INITIALIZED, trying next display type
Initialization of all (2) EGL display types failed.
Exiting GPU process due to errors during initialization
```

Nix's mesa falls back to `/run/opengl-driver/lib` — the NixOS-only path this
project already records — and every EGL display type fails, four GPU process
attempts in a row.

So the true statement is narrower than either previous version. **Neither needs
its own nixGL wrapper. Both need nixGL's environment, and both were getting it
by inheritance from the compositor's wrap**, because `home/session.nix` launches
Hyprland through `nixGLIntel` and the session descends from it. Every GL test in
this spec, including Task 1's, ran with those variables already set. Task 1 asked
"does it draw?" and could not have distinguished "needs no nixGL" from "already
has nixGL", because nothing in the test varied that.

That distinction is not academic. On the strength of the earlier wording a
follow-up was nearly specified to scrub those variables from the session as a
leak — which would have broken both applications this spec had just migrated. The
one command that prevented it was the user's question.

### The same inheritance breaks flatpak, and that part IS a defect

Debian's flatpak Slack, launched from this session:

```
MESA-LOADER: failed to open dri: /nix/store/…-mesa-26.1.5/lib/gbm/dri_gbm.so:
  cannot open shared object file: No such file or directory
[…] vaInitialize failed: unknown libva error
```

The file exists on the host — checked — and the compositor has it mapped. What
fails is the namespace: the sandbox has no `/nix/store`, so the inherited paths
name nothing inside it. Reproduced directly:

```sh
flatpak run --command=sh com.slack.Slack -c 'echo $GBM_BACKENDS_PATH'
# /nix/store/…-mesa-26.1.5/lib/gbm:…
```

Flatpak ships its own matched GL stack, `org.freedesktop.Platform.GL.default`,
and that is Slack's accelerated path. Our variables override it with paths that
resolve to nothing, so mesa loads no driver and Chromium falls back to software;
`LIBVA_DRIVERS_PATH` costs it hardware video decode at the same time. Removing
the override does not take acceleration away — it returns Slack's own.

The fix therefore belongs at the flatpak boundary and nowhere else:

```sh
flatpak override --user --unset-env=LIBGL_DRIVERS_PATH \
  --unset-env=GBM_BACKENDS_PATH --unset-env=LIBVA_DRIVERS_PATH \
  --unset-env=__EGL_VENDOR_LIBRARY_FILENAMES --unset-env=LD_LIBRARY_PATH \
  com.slack.Slack
```

Run by the user, and verified afterwards. Flatpak records it:

```
$ flatpak override --user --show com.slack.Slack
[Environment]
LIBGL_DRIVERS_PATH=
__EGL_VENDOR_LIBRARY_FILENAMES=
LD_LIBRARY_PATH=
LIBVA_DRIVERS_PATH=
GBM_BACKENDS_PATH=

[Context]
unset-environment=LIBGL_DRIVERS_PATH;__EGL_VENDOR_LIBRARY_FILENAMES;LD_LIBRARY_PATH;LIBVA_DRIVERS_PATH;GBM_BACKENDS_PATH;
```

Both stanzas are quoted because both are printed; an earlier version showed only
`[Context]` and would have puzzled anyone who ran the command.

and the sandbox no longer sees them — checked from inside, which is the only
place the question means anything:

```
$ flatpak run --command=sh com.slack.Slack -c 'echo ${LIBGL_DRIVERS_PATH:-(unset)}; …'
  LIBGL_DRIVERS_PATH                 (unset)
  GBM_BACKENDS_PATH                  (unset)
  LIBVA_DRIVERS_PATH                 (unset)
  __EGL_VENDOR_LIBRARY_FILENAMES     (unset)
  LD_LIBRARY_PATH                    (unset)
```

### Measured afterwards: Slack is on the GPU

The paragraph that stood here said this was unmeasured, and offered
`grep -cE 'swiftshader|iris_dri' /proc/<pid>/maps`. Run against a single pid that
returns **0**, and the zero is an artifact of the instrument twice over — which
is worth recording, because the same document had already warned about the first
of the two and then handed over a command that walked into it.

- **Wrong process.** Electron puts GL in a `--type=gpu-process` child. The pid
  `pgrep` returns first is the `bwrap` or launcher parent, which maps no GL at all.
- **Wrong token.** Mesa 25 and later fold the DRI drivers into a gallium
  megadriver, so `iris_dri.so` is absent on a perfectly healthy GPU path. Its
  absence means nothing here.

Walked over the whole tree, and read by open file descriptor rather than by a
library name that upstream can rename:

```
pid 385003  --type=gpu-process --ozone-platform=wayland --render-node-override=/dev/dri/renderD128
  /dev/dri/renderD128      5 open fds
  libgallium-26.1.6.so     the flatpak runtime's mesa (ours is 26.1.5)
  dri_gbm.so               loaded, from inside the sandbox
  libdrm_intel.so.1.134.0  the Intel DRM path
  swiftshader / llvmpipe   absent
```

**Five open handles on the render node settle it** — a software rasteriser has no
reason to hold one. And the mesa in use is `26.1.6`, the runtime's own, not the
`26.1.5` our variables were pointing at. So the override did not merely silence
an error: Slack is rendering on the Intel GPU using the stack flatpak shipped for
it, which is exactly what the change was for.

For anything Electron in future, the instrument is: walk the process tree, prefer
an open fd on `/dev/dri/render*`, and treat `libgallium` rather than `*_dri.so` as
the driver's name.

**And this override is not owned by this flake.** It lives at
`~/.local/share/flatpak/overrides/com.slack.Slack`, alongside six others written
by hand in August that no module knows about — `grep -rc 'flatpak/overrides'
home/*.nix` finds zero. So it survives a switch and does not survive a reinstall,
and nothing will notice if it disappears. A later spec could take ownership with
an `xdg.dataFile` entry; that is a real question about how far this flake should
reach into flatpak's state, and it is not answered here.

### One more thing that test disturbed, and did not damage

The stripped-environment run also printed:

```
Detected change in safeStorage backend, can't decrypt DB key
  (previous: kwallet6, current: basic_text)
ERROR CORE sqlcipher_page_cipher: hmac check failed for pgno=1
```

Electron chose a different `safeStorage` backend under the stripped environment
and could not decrypt the database key. **Nothing was written:**
`~/.config/Signal/config.json` is byte-identical to the pre-migration backup —
226 bytes, same md5 — so this was a failed read, not a rewrite. Do not repeat
that invocation: a backend change is exactly the kind of thing that could rewrite
a key record on some path, and the point has now been made.

The check that settles it needs one of them **running**, because it reads a
live process's maps — the instrument this project trusts:

```sh
grep -cE 'swiftshader|libEGL_mesa|iris_dri' /proc/<pid>/maps
```

Read it by which token is present, not by the count: `swiftshader` mapped means
software rendering; `iris_dri` mapped means the Intel GPU path. Run it over
every pid in the application's process tree rather than the one the launcher
started — Electron puts its GL stack in a child process, so the top-level pid
is the one most likely to give a misleading zero.

Not run here: at the time this was written neither application was up.

```sh
ps -eo args= | grep -icE 'signal-desktop|bitwarden'
# 3   -- the uwsm signal-handler.sh, a busctl signal monitor, and this grep;
#        no Signal and no Bitwarden process among them
```

### A risk the spec missed, caught before the run and not by the spec

Both applications open a config directory on first launch, and a newer build
migrates it:

```
~/.config/Signal       116M    attachments.noindex, blob_storage, config.json
~/.config/Bitwarden    4.8M
```

Signal Desktop keeps its message history in an encrypted database there and
refuses to start against one a newer version has migrated. So running 8.21.0 once
could leave Debian's 8.19.0 unable to open 116 MB of history — the same one-way
shape recorded for syncthing, except undocumented and triggered by the GL test
itself rather than by a deliberate conversion.

The spec's risk section did not mention it. It listed a GL failure after removal,
damage to `mimeapps.list`, exemption drift and a version regression, and missed
the one risk the very first task would trigger. Caught by asking what the test
would touch before running it, which is not a substitute for having written it
down.

Backups were taken first:

```
~/.config/Signal.pre-nix-backup       116M
~/.config/Bitwarden.pre-nix-backup    4.8M
```

And the risk was not hypothetical. Both live directories were written during the
test:

```
Signal      mtime 2026-08-17 16:26:10
Bitwarden   mtime 2026-08-17 16:26:26
(run at     2026-08-17 16:27:22)
```

What is **not** established is whether a schema migration actually occurred, or
whether those writes are ordinary cache and log activity. The version gap is two
minor releases, so a migration may not have happened at all. Nobody attempted to
start Debian's 8.19.0 afterwards to find out, and nobody should: if it has
migrated, the attempt teaches nothing the backup does not already cover, and if
it has not, a failed start could itself do damage. The backups are the recovery
path either way.

A tempting alternative was considered and rejected: Electron's `--user-data-dir`
would have pointed the test at a throwaway directory and touched nothing.
Whether Signal honours that flag rather than computing its own userData path was
unverified, and an unverified flag standing between a test and 116 MB of message
history is not a trade worth making. Copying was certain.

---

## Task 2: the exemption, and both packages

`home/gui-apps.nix` and `flake.nix`. Commit `ba6b46d`.

`guiPackages` grew from two members to four. Versions read from the pinned
input, never from `nixpkgs#`:

```sh
for a in signal-desktop bitwarden-desktop seahorse gammastep; do
  sg nix-users -c "nix eval --raw .#homeConfigurations.\"isutton@suffer\".pkgs.$a.version"
done
# signal-desktop     8.21.0
# bitwarden-desktop  2026.7.0
# seahorse           47.0.1
# gammastep          2.0.11
```

Both new members have zero wrapped binaries and zero `share/gsettings-schemas`
directories, so both failed `wrappedGuiApps` as spec 10 left it. That is the
whole reason this task exists: the guard had never been asked to excuse
anything, and the first thing it was asked to excuse was legitimate.

### The shape: an explicit table, checked in both directions

`wrapExemptions` is an attrset of pname → reason, keyed by `lib.getName` so an
entry survives a version bump and only a version bump.

It is **not** derived, and that is the decision rather than an implementation
detail. The derived predicate — "ships no schemas of its own, therefore nothing
to wrap" — is exactly what the guard shipped with in spec 10, and it was
deleted after review disproved the justification. Deriving a second predicate
would exempt every future package that happens to satisfy it, with nobody being
asked a question at that moment. A name in a table has to be typed by a person
who then has to write the sentence beside it.

The half that makes it more than an allowlist is the **staleness** branch: an
exempt package that acquires a wrapped binary upstream fails the build and
demands its entry be deleted. An allowlist only grows, and an entry that has
stopped being true goes on excusing a package that has started needing the
check — silently, because nothing re-reads it.

### The guard's own log, green

Recovered from the derivation's build log rather than retyped:

```sh
sg nix-users -c 'nix log /nix/store/1m95hm5bpjwaqsfv1myka6hvvmn0yh2d-gui-apps-schema-wrapped'
# ok (1 wrapped): seahorse
# ok (2 wrapped): gammastep
# ok (exempt): signal-desktop
# ok (exempt): bitwarden-desktop
```

Four lines for four members. The name is `lib.getName`'s, passed in from Nix,
not the store path's basename — a basename carries the hash and the version and
could never be compared against a table key meant to survive a rebuild.

### Three mutation proofs, each count-confirmed before the build ran

A `sed` that matches nothing exits 0 and proves nothing, so every mutation was
verified by a count first.

**1. Missing exemption.** `signal-desktop`'s entry deleted;
`grep -c '^    signal-desktop = "Electron'` 1 → 0.

```
ok (1 wrapped): seahorse
ok (2 wrapped): gammastep
signal-desktop has no wrapped binary in bin/.
ok (exempt): bitwarden-desktop
error: builder for '…-gui-apps-schema-wrapped.drv' failed with exit code 1
```

**2. Stale exemption.** `seahorse` — which *is* wrapped — added to the table;
`grep -c '^    seahorse = '` 0 → 1.

```
seahorse is on wrapExemptions but ships 1 wrapped binary(ies).
ok (2 wrapped): gammastep
ok (exempt): signal-desktop
ok (exempt): bitwarden-desktop
error: builder for '…-gui-apps-schema-wrapped.drv' failed with exit code 1
```

The other three still report `ok`: the guard failed on the one property that
was false and on nothing else.

**3. Vacuity — the implementer's own branch, not the plan's.** `seahorse` and
`gammastep` both exempted, making all four members exempt;
`grep -cE '^    (seahorse|gammastep) = '` 0 → 2.

```
every guiPackages member is on wrapExemptions.
error: builder for '…-gui-apps-schema-wrapped.drv' failed with exit code 1
```

The plan asked for two directions — an unexempted package with no wrapper, and
an exempt package that has gained one — and missed the case where the table
grows until nothing is being checked at all. A guard whose every subject is
exempt passes while asserting nothing, which is this project's defining failure
mode in a fourth costume, and it is the same anti-vacuity anchor
`gui-desktop-ids` and `no-pulseaudio-daemon` each already carry. The branch was
accepted. Its cost if the reasoning is wrong is nil: it fires only when the
guard has stopped being a guard.

**Restoration.** `git checkout home/gui-apps.nix` reverts the whole file and
would have discarded the implementation along with the mutation. Each mutation
was instead restored from a copy taken before the first one, with the md5
compared after each.

### `gui-desktop-ids` gained both ids

`required` now lists **6** ids, and this is the first spec in which the check
covers ids a handler actually references:

```sh
for id in org.gnome.seahorse.Application.desktop gammastep.desktop \
          gammastep-indicator.desktop eu.calangotech.CalangoOpen.desktop \
          signal.desktop bitwarden.desktop; do
  printf '%-45s %s\n' "$id" "$(grep -cF "$id" ~/.config/mimeapps.list || true)"
done
# org.gnome.seahorse.Application.desktop        0
# gammastep.desktop                             0
# gammastep-indicator.desktop                   0
# eu.calangotech.CalangoOpen.desktop            5
# signal.desktop                                2
# bitwarden.desktop                             1
```

3 of the 6 required ids are named by a handler, across 8 handler lines
(5 + 2 + 1). The other 3 are launcher ids with no association. Spec 10 declared
this coverage and could not reach it; spec 11 widened the check to both trees;
this spec supplies an id a handler actually names.

### What was deliberately not built

No `dbusActivatableGuiApps` entry. Neither package ships a
`share/dbus-1/services` directory, and the existing guard says so itself in its
own log — `ok (no activation files)` for each — rather than the absence being
asserted by a person. A mirror of a service file that does not exist would be a
dangling `xdg.dataFile` source, which builds cleanly and is what
`no-dangling-home-files` exists to catch afterwards.

---

## Task 3: Signal's two scheme handlers

`home/apps.nix` only. Commit `b622e8a`.

`config.home.activation.signalMimeappsId` rewrites the token
`signal-desktop.desktop` to `signal.desktop` in `~/.config/mimeapps.list`, only
where that token is a whole value. Narrow, idempotent and non-fatal, because it
writes a file this flake does not own.

### The deviation from the plan: `entryBetween`, not `entryAfter`

The plan specified `entryAfter [ "writeBoundary" ]`. Built exactly that first,
and measured where it landed in the generated `activate`:

```
386:_iNote "Activating %s" "mimeappsIds"
463:_iNote "Activating %s" "signalMimeappsId"
```

Dead last, **after** `mimeappsIds`, for no reason but that `s` sorts after `r`:
`hm.dag.topoSort` feeds attribute-name-sorted `builtins.attrValues` into a
stable `lib.toposort`, so any pair with no stated relation is ordered
alphabetically. The hook that *reports* dead ids would have read the file
before the hook that *fixes* one of them ran, and warned about
`signal-desktop.desktop` at every switch.

Changed to `entryBetween [ "mimeappsIds" ] [ "writeBoundary" ]`, with the
argument order confirmed against the in-repo precedent at `home/audio.nix:529`
rather than from memory. Measured after, on the current build:

```sh
NEW=$(sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage' | tail -1)
grep -n 'signalMimeappsId\|mimeappsIds' "$NEW/activate"
# 386:_iNote "Activating %s" "signalMimeappsId"
# 398:_iNote "Activating %s" "mimeappsIds"
```

Fixer before reporter. Only the one `before` edge is claimed: the hook reads no
`.desktop` search path, so `linkGeneration` and `installPackages` are
irrelevant to it, and declaring edges that do not exist is the mistake
`mimeappsIds`' own comment warns against.

Its practical effect on Task 4's switch was nil — `signal-desktop.desktop`
still resolved from the apt package at that moment, so `mimeappsIds` would not
have warned either way. The edge matters for every switch *after* the removal
in which the file has not yet been rewritten: a rollback, a re-clone, a
hand-edit.

### The two-line diff, proven against a copy

Every test drove the body **extracted from the built `activate`**, not a
retyped `sed` — the two can silently diverge through Nix and shell quoting, and
`\(^\|[=;]\)` nested in a `''…''` inside a `'…'` inside a `"…"` is exactly
where that would happen. `HOME` was pointed at a `mktemp -d` scratch tree.

```diff
-x-scheme-handler/sgnl=signal-desktop.desktop
-x-scheme-handler/signalcaptcha=signal-desktop.desktop
+x-scheme-handler/sgnl=signal.desktop
+x-scheme-handler/signalcaptcha=signal.desktop
```

```sh
diff … | grep -c '^[<>]'
# 4        -- 2 removed + 2 added == exactly two changed lines
```

Untouched and byte-identical: both `eu.calangotech.KBrowserSelector.desktop`
lines under `[Added Associations]` including their trailing `;`, which the
regex's `\($\|;\)` branch could plausibly have disturbed; `slack.desktop`;
`bitwarden.desktop`; `claude-code-url-handler.desktop`; and all four
`CalangoOpen` lines. One hunk, no reordering, no whitespace change.

### Idempotence, by checksum

```
once  : 8d8af45dd2a72d508c907c32ffe98a13
twice : 8d8af45dd2a72d508c907c32ffe98a13
thrice: 8d8af45dd2a72d508c907c32ffe98a13
```

**And the plan's stated *reason* for it was wrong while its behaviour was
right.** The plan's comment said "the grep guard means a second run finds
nothing and exits before sed is invoked". On a synthetic file carrying negative
controls — `xsignal-desktop.desktop`, `signal-desktop.desktop.bak`,
`my-signal-desktop.desktop` — runs 2 and 3 *did* print the rewrite message
while the md5 stayed fixed from run 2 onward. The guard is a plain **substring**
test; the `sed` matches only **whole values**. The guard is the broader of the
two, so where the token appears only inside a longer id the guard passes, `sed`
runs, and correctly changes nothing. Idempotence holds unconditionally, but it
belongs to the `sed`, not to the `grep`. On the real file the guard does go
quiet, which is why runs 2 and 3 above printed nothing — and that is a property
of this file's contents, not of the mechanism.

The comment in `home/apps.nix` was corrected to state the measured property.
The code was left as approved.

### One real limitation, recorded rather than fixed

Adjacent duplicates take two invocations: `s///g` consumes the separator it
matched, so in `signal-desktop.desktop;signal-desktop.desktop` the second token
has no `[=;]` prefix left to match. Run 2 completes it and run 3 is a no-op, so
it **converges** rather than losing data, and the next switch would finish the
job. A value listing the same id twice is degenerate and does not occur in the
real file. A `:a;s///;ta` loop would close it; that is a shape change to
user-approved code for a case that cannot arise.

### The live file was not touched by this task

```
before: 1cc1f84c05e3a4cc2df10ba3bef7569c  691 bytes  mtime 2026-08-14 17:23:10.467658973 -0300
after : 1cc1f84c05e3a4cc2df10ba3bef7569c  691 bytes  mtime 2026-08-14 17:23:10.467658973 -0300
```

Identical to the nanosecond, which a write-then-restore would not reproduce.

---

## Task 4: switch, remove, verify

Every mutating command was the user's. What follows is the controller's
independent verification afterwards.

### The mimeapps rewrite landed, and moved exactly what it claimed

```sh
diff <before> ~/.config/mimeapps.list | grep -cE '^[<>]'
# 4
```

```
11,12c11,12
< x-scheme-handler/sgnl=signal-desktop.desktop
< x-scheme-handler/signalcaptcha=signal-desktop.desktop
---
> x-scheme-handler/sgnl=signal.desktop
> x-scheme-handler/signalcaptcha=signal.desktop
```

The two intended lines and nothing else — reproducing Task 3's hunk on the live
file exactly. `defaultBrowser`'s `xdg-settings` write, which runs in the same
activation, moved nothing.

### The apt side

```sh
dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' signal-desktop bitwarden
# rc  bitwarden 2026.6.1
# rc  signal-desktop 8.19.0
```

`rc`, not absent: removed with conffiles retained. This is why package presence
is never asked with `dpkg-query -W -f='${Version}'`, which prints a version and
exits 0 for exactly this state.

### Provenance

```sh
command -v signal-desktop bitwarden
# /home/isutton/.nix-profile/bin/signal-desktop
# /home/isutton/.nix-profile/bin/bitwarden
```

### The three handlers

```sh
xdg-mime query default x-scheme-handler/sgnl           # signal.desktop
xdg-mime query default x-scheme-handler/signalcaptcha  # signal.desktop
xdg-mime query default x-scheme-handler/bitwarden      # bitwarden.desktop
```

`bitwarden.desktop` was already correct before the migration — the id is
identical on both sides — and is quoted here because "unchanged" is a result
too, and because an id that happens to match is the case `CLAUDE.md` warns
invites the assumption that all of them do.

### Spec 12's endpoint survived

```sh
apt-get -s autoremove | grep -c '^Remv '
# 0
```

Zero new orphans. Removing two packages did not reopen the backlog spec 12
closed.

### The launcher test

The user opened the Applications panel and launched **Signal** and
**Bitwarden** from it — not from a shell — and both worked. This is the path
that failed silently for a migrated application in spec 10 and was fixed in
spec 11, and this is the first migration since to exercise it. No agent can
observe it; the result is the user's.

---

## Close-out

### The spec number, counted

```sh
ls -1 docs/*results-suffer-*.md | wc -l
# 13
```

Counted, not incremented. `CLAUDE.md` records that spec 10 landed saying "Nine"
because eight had been incremented once and spec 9 had never bumped it at all —
two errors in opposite directions arriving at one wrong number, which is
exactly what incrementing produces and counting cannot. This document is the
thirteenth file that command counts, and `CLAUDE.md`'s opening line was moved
from "Twelve" to "Thirteen" from the same reading.

### The `rc` count moved, 145 → 147

```sh
dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' | awk '$1=="rc"' | wc -l
# 147
```

Both removals left conffiles, so both produced an `rc` entry — two removals,
two entries, and the reading moves by exactly two. `CLAUDE.md` already said to
count this rather than quote it, and it already said `rc` is **not** a running
total of what has been removed. This spec is the clean illustration of both
halves at once: here the delta happens to equal the number of packages removed,
which is the coincidence that makes the general claim tempting. Spec 12 removed
128 packages and moved the reading by part of 17.

### What the endpoint is

| property | value |
|---|---|
| mimeapps diff | 4 diff lines — the 2 intended, nothing else moved |
| apt side | `signal-desktop` `rc` 8.19.0, `bitwarden` `rc` 2026.6.1 |
| provenance | both resolve to `~/.nix-profile/bin` |
| `x-scheme-handler/sgnl` | `signal.desktop` |
| `x-scheme-handler/signalcaptcha` | `signal.desktop` |
| `x-scheme-handler/bitwarden` | `bitwarden.desktop` |
| `apt-get -s autoremove` | 0 |
| guard log | `ok (1 wrapped): seahorse` / `ok (2 wrapped): gammastep` / `ok (exempt): signal-desktop` / `ok (exempt): bitwarden-desktop` |
| hook order | `signalMimeappsId` 386, `mimeappsIds` 398 |
| launcher test | the user launched both from the Applications panel; both work |
| `rc` packages | 147 |

### A second correction: what gammastep actually demonstrates

`home/gui-apps.nix` says, in the comment justifying the exemption's shape, that
`gammastep` disproves the derived rule "ships no schemas of its own, therefore
nothing to wrap". The disproof of the *rule* stands. What the file lets a
reader infer — that gammastep is a package which would have broken under the
derived rule — is not supported, and Task 5 measured the difference.

`seahorse` is the load-bearing case:

```sh
SH=$(sg nix-users -c 'nix eval --raw .#homeConfigurations."isutton@suffer".pkgs.seahorse')
find "$SH" -name '*.gschema.xml' | wc -l
# 3   -- org.gnome.seahorse{,.window,.manager}.gschema.xml
strings "$SH/bin/.seahorse-wrapped" | grep -oE 'org\.gnome\.[a-z.]*' | sort -u
# org.gnome.crypto.pgp / org.gnome.keyring. / org.gnome.seahorse{,.manager,.window}
```

Three schemas of its own, and the binary names them. Its wrapper is doing work.

`gammastep` is not:

```sh
GA=$(sg nix-users -c 'nix eval --raw .#homeConfigurations."isutton@suffer".pkgs.gammastep')
find "$GA" -path '*gsettings-schemas*' | wc -l
# 0
strings "$GA/bin/.gammastep-wrapped" | grep -oE 'org\.[a-z]+\.[a-zA-Z.]*' | sort -u
# org.freedesktop.DBus.Error.AccessDenied
# org.freedesktop.DBus.Properties.Set
# org.freedesktop.GeoClue
```

Zero schemas, and the only dotted names in the binary are D-Bus interface and
service names, not GSettings schema ids. The two schema directories its wrapper
prefixes onto `XDG_DATA_DIRS` — `gtk+3-3.24.52` and
`gsettings-desktop-schemas-50.1` — look **incidental**: `wrapGAppsHook` adds
what the closure offers, whether the binary reaches for it or not.

So gammastep's **main binary** is the counterexample to the *reasoning*, not an
instance of a package that would have broken. The package that would break is a
GTK application shipping no schemas of its own that reads a **dependency's**,
and no package on the Nix side of this machine is measured to be one — with the
qualification immediately below, which is the closest candidate and is
undecided rather than absent.

**And one more turn, because the brief for this correction was itself slightly
wrong and the measurement says so.** The claim handed to Task 5 was that
`.gammastep-indicator-wrapped` "is a Python script with no `Gio`/`Gtk`/
`GSettings`/`AppIndicator` token in it at all". True of that file, and it is
16 lines long — but it is a launcher stub, and the module it imports is not:

```sh
grep -cE 'Gio|Gtk|GSettings|AppIndicator' "$GA/bin/.gammastep-indicator-wrapped"
# 0        -- the stub
M="$GA/lib/python3.13/site-packages/gammastep_indicator"
grep -ohE 'Gtk|Gio|GLib|GSettings|AppIndicator|AyatanaAppIndicator' "$M"/*.py | sort | uniq -c
# 2 AppIndicator / 2 AyatanaAppIndicator / 24 GLib / 28 Gtk
grep -h 'require_version' "$M"/*.py
# gi.require_version('GLib', '2.0')
# gi.require_version('Gtk', '3.0')
# gi.require_version('AyatanaAppIndicator3', '0.1')
# gi.require_version('AppIndicator3', '0.1')
```

`gammastep-indicator` **is** a GTK 3 application with no schemas of its own —
the exact shape named above. What is *not* established is whether it reads a
dependency's schema: none of the module's five `.py` files mentions `Gio` or
`Settings` (`grep -nE 'Settings|Gio' "$M"/*.py` matches nothing), and GTK 3's
own schemas here are six
files (`org.gtk.Settings.{ColorChooser,Debug,EmojiChooser,FileChooser}`,
`org.gtk.Demo`, `org.gtk.exampleapp`) that a status-icon application plausibly
never opens. Plausibly is not measured. So the honest reading is:

- gammastep's **main binary** is definitely not the casualty the file implies.
- gammastep's **indicator** is the nearest candidate on this machine and cannot
  be ruled in or out without running it and watching for
  `Settings schema … is not installed`.
- Either way the exemption table is unaffected — gammastep is wrapped, so it
  takes the checked path, not the exempt one, and the guard's verdict on it
  does not depend on which of these is true.

Recorded in `CLAUDE.md` rather than in `home/gui-apps.nix`, because Task 5 is
documentation-only and must not edit a `.nix` file. The comment in that file
therefore still overstates gammastep's role; a future spec touching
`home/gui-apps.nix` should narrow it there.
