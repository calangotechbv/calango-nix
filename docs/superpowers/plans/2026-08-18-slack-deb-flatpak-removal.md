# Slack `.deb` and flatpak removal — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Slack from flatpak to Slack's own standalone `.deb`, declare it and the flatpak removal in `calango-desktop`, and give this flake the machinery to own a file under `/etc` correctly.

**Architecture:** `lib/deb.nix` learns to derive `conffiles` from every `/etc` payload path rather than from `ufwProfiles` alone, enforced by a check inside its own builder. A new `home/slack.nix` owns the `slack-desktop` keep entry, ships `/etc/default/slack` with both cron knobs disabled, and packages a `bin/slack-latest` staleness reporter. `home/deb.nix` drops `flatseal` from `keep` and bans `flatpak` and `flatseal`. No agent performs the migration; the live sequence is the user's, and it is ordered so the flatpak rollback outlives the first host launch.

**Tech Stack:** Nix flakes, standalone Home Manager, `dpkg-deb`, apt, Debian 13 (`suffer`).

**Spec:** `docs/superpowers/specs/2026-08-18-slack-deb-flatpak-removal-design.md`

## Global Constraints

- Wrap **every** `nix` and `home-manager` invocation: `sg nix-users -c '...'`. A bare `nix` fails on the daemon socket directory and reads as a broken install.
- **No agent runs a privileged command.** No `apt`, `apt-get`, `dpkg`, `apt-mark`, `ufw` or `flatpak` mutation. No `sudo` of any kind. No `systemctl start/stop/restart/enable/disable/daemon-reload`. No `home-manager switch`. No `reboot`. Never run the activation script without `DRY_RUN=1`. Read-only probes (`apt-get -s`, `apt-cache`, `dpkg-query`, `dpkg-deb`, `dpkg -S`, `dpkg -V`) are allowed and used throughout.
- **No agent deletes anything outside the repository**, and no agent writes to `~/.config/Slack`, `~/.var`, `/etc` or `/var`.
- `grep` in the interactive shell is a **ugrep-backed function** that silently returns `0` for a pattern containing `${`, even on a file that holds it. Use `/usr/bin/grep`, with `-F` for a literal, whenever a count is load-bearing. Inside a Nix builder the shell is the real one and this does not apply.
- Never read a package version from `nixpkgs#<pkg>` — that reads the flake registry (nixpkgs-unstable), not this flake's pinned input. This applies to *behaviour* probes too: verify against `.#homeConfigurations."isutton@suffer".pkgs.<pkg>`.
- **A flake build does not see untracked files.** `git add` any newly created file before building anything that must observe it, or a mutation test will appear to pass while testing nothing.
- Inside a Nix builder, `set -e` and `pipefail` are on. Put a `grep` whose zero-match case is the passing case in a **condition** (`if grep -q …; then`), never in a bare command or a command substitution. A `while read … done < file` runs in the current shell; `cmd | while read` runs in a subshell, where `exit 1` exits only the subshell.
- **Prove every guard can fail, and confirm the mutation is valid before reading its build.** Spec 16 shipped two mutations that turned the build red without reaching the guard — a type error and a duplicate attribute — and "the build failed" was nearly recorded as "the guard fired". Verify the mutation is present with `/usr/bin/grep` before building.
- No reason string in `calango.deb.keep` or `calango.deb.ban` may contain the literal Nix store path prefix. Reasons are serialised into `manifest.json`, which the `noStorePaths` guard greps. Say "the Nix store" in prose.
- The package name is `calango-desktop`. The maintainer is `Igor Sutton <igor.sutton@calangotech.eu>`.
- Upstream Slack, measured 2026-08-18: version `4.51.180`, feed `https://slack.com/api/desktop.latestRelease?arch=x64&variant=deb`, artifact `slack-desktop-4.51.180-amd64.deb`, 94403330 bytes. If the feed reports something newer at execution time, use the newer version and say so — do not hardcode 4.51.180 anywhere in the tree.
- Every commit message ends with the two trailers used in this repo:
  `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_01U7jpCSHruSXqJYmsJ7vQzn`.

---

## File Structure

| file | responsibility |
|---|---|
| `lib/deb.nix` | **modify.** Derive `conffiles` from `ufwProfiles` ∪ every `files` key under `etc/`. Decouple the conffiles emission from `ufwProfiles`. Add the in-builder check that every `/etc` payload path is a conffile, with a vacuity anchor. |
| `bin/slack-latest` | **create.** A read-only staleness reporter: asks Slack's release feed, compares against dpkg, prints the download and install commands. Substitution tokens only; no hardcoded store paths. |
| `home/slack.nix` | **create.** Owns everything Slack: the `slack-desktop` keep entry, `calango.deb.files."etc/default/slack"`, and the `slackLatest` package with its leftover-token guard. |
| `flake.nix` | **modify.** Add `./home/slack.nix` to the module list at lines 144-149. |
| `home/deb.nix` | **modify.** Drop `flatseal` from `keep`; add `flatpak` and `flatseal` to `ban`; rewrite the `xdg-desktop-portal` ban reason, which currently explains a flatpak `Recommends` that stops existing. |
| `home/apps.nix` | **modify.** The `signalMimeappsId` comment names `slack.desktop` "where flatpak exports `com.slack.Slack.desktop`" — wrong once the `.deb` ships that id. |
| `CLAUDE.md` | **modify.** Seven corrections, four of them findings rather than rewording (the `xdg-mime query default` entry was added mid-execution). |
| `README.md` | **modify.** "What apt still owns" lists Signal, which spec 13 made false; add Slack. |

---

## Task 1: `lib/deb.nix` — conffiles from every `/etc` path, and the guard that enforces it

**Files:**
- Modify: `lib/deb.nix:77-81` (the `conffiles` binding), `lib/deb.nix:101-104` (the emission), and an insertion before `lib/deb.nix:113` (the `# Reproducibility.` comment).

**Interfaces:**
- Consumes: nothing. `build`'s signature is unchanged — `{ manifest, manifestFile, version, guards ? [ ] }`.
- Produces: `build` now emits `pkg/DEBIAN/conffiles` whenever the payload has any `/etc` path, listing `/etc/ufw/applications.d/<name>` for every `ufwProfiles` key and `/<path>` for every `files` key beginning `etc/`. `build` now **fails** if the payload has no `/etc` path at all, or if any `/etc` path is missing from that list. Task 2 relies on `calango.deb.files."etc/default/slack"` becoming a conffile with no further declaration.

- [ ] **Step 1: Write the failing test — a fixture with an `/etc` file, outside the repo**

The bug is that a `files` entry under `etc/` is shipped but not listed. Demonstrate it before fixing it. Write this outside the repository tree, because no path containing a scratch directory may appear in a committed file:

```bash
mkdir -p ~/.cache/spec17-probe
cat > ~/.cache/spec17-probe/fixture.nix <<'NIX'
let
  flake = builtins.getFlake (toString /home/isutton/Projects/calango-nix);
  pkgs = flake.homeConfigurations."isutton@suffer".pkgs;
  deb = import /home/isutton/Projects/calango-nix/lib/deb.nix { inherit pkgs; };
  manifest = {
    keep = { probe-keep = "A fixture reason."; };
    ban = { probe-ban = "A fixture reason."; };
    ufwProfiles."probe-ufw" = "[probe]\ntitle=probe\nports=1/tcp\n";
    files."etc/default/probe" = "probe_knob=\"false\"\n";
  };
in
deb.build {
  inherit manifest;
  manifestFile = pkgs.writeText "probe-manifest.json" (builtins.toJSON manifest);
  version = "0.0probe";
}
NIX
```

- [ ] **Step 2: Run it and confirm the `/etc` file is shipped but not a conffile**

```bash
P=$(sg nix-users -c 'nix build --no-link --print-out-paths --impure --expr "import ~/.cache/spec17-probe/fixture.nix"')
/usr/bin/dpkg-deb -c "$P"/*.deb | awk '{print $6}' | /usr/bin/grep -E '^\./etc/'
/usr/bin/dpkg-deb --ctrl-tarfile "$P"/*.deb | tar -xO ./conffiles
```

Expected, and this is the defect. Verified on 2026-08-18 against the fixture
above; note `dpkg-deb -c` lists directory entries as well as files:

```
./etc/
./etc/default/
./etc/default/probe                    <- shipped
./etc/ufw/
./etc/ufw/applications.d/
./etc/ufw/applications.d/probe-ufw
/etc/ufw/applications.d/probe-ufw      <- conffiles lists only the ufw profile
```

`/etc/default/probe` is a package file under `/etc` with no conffiles entry. dpkg would overwrite a local edit to it on every upgrade without asking.

- [ ] **Step 3: Derive `conffiles` by path syntax**

Replace `lib/deb.nix:77-81` exactly:

```nix
      # Only /etc entries may be conffiles, per Debian policy. The ufw profiles
      # are the only /etc payload this package has.
      conffiles =
        lib.concatMapStrings (n: "/etc/ufw/applications.d/${n}\n")
          (builtins.attrNames manifest.ufwProfiles);
```

with:

```nix
      # Only /etc entries may be conffiles, per Debian policy -- and EVERY /etc
      # entry must be one, or dpkg replaces a locally edited file on upgrade
      # without asking. So this is derived from the payload by PATH SYNTAX, not
      # from a list of names.
      #
      # The comment here used to read "the ufw profiles are the only /etc
      # payload this package has". That was true when it was written and false
      # the moment home/slack.nix shipped etc/default/slack -- a file whose
      # whole purpose is to hold two values dpkg must not clobber, since
      # restoring their defaults re-arms Slack's cron job. Nothing would have
      # warned: the package builds, installs and works, and the loss shows up
      # only at the next upgrade. Enumerate by syntax, never by a remembered
      # list of names.
      etcPayload = lib.filter (lib.hasPrefix "etc/") (builtins.attrNames manifest.files);
      conffiles =
        lib.concatMapStrings (n: "/etc/ufw/applications.d/${n}\n")
          (builtins.attrNames manifest.ufwProfiles)
        + lib.concatMapStrings (p: "/${p}\n") etcPayload;
```

- [ ] **Step 4: Decouple the emission from `ufwProfiles`**

`conffiles` is currently copied only inside the `ufwProfiles != { }` branch, so an `/etc` file with no ufw profile would still ship no conffiles at all. Replace `lib/deb.nix:101-104` exactly:

```nix
        ${lib.optionalString (manifest.ufwProfiles != { }) ''
          mkdir -p pkg/etc/ufw/applications.d
          cp "$conffilesPath" pkg/DEBIAN/conffiles
        ''}
```

with:

```nix
        ${lib.optionalString (manifest.ufwProfiles != { }) ''
          mkdir -p pkg/etc/ufw/applications.d
        ''}
        ${lib.optionalString (conffiles != "") ''
          cp "$conffilesPath" pkg/DEBIAN/conffiles
        ''}
```

- [ ] **Step 5: Re-run the probe and confirm the fix**

```bash
P=$(sg nix-users -c 'nix build --no-link --print-out-paths --impure --expr "import ~/.cache/spec17-probe/fixture.nix"')
/usr/bin/dpkg-deb --ctrl-tarfile "$P"/*.deb | tar -xO ./conffiles
```

Expected — both paths, and `/etc/default/probe` now among them:

```
/etc/ufw/applications.d/probe-ufw
/etc/default/probe
```

- [ ] **Step 6: Add the check inside the builder**

Insert immediately **before** the `# Reproducibility.` comment at `lib/deb.nix:113`, after the `manifest.files` emission loop:

```nix
        # Every /etc path in the assembled tree must be listed in
        # DEBIAN/conffiles. The list is derived by path syntax above, so this
        # can only disagree with it when the EMISSION is wrong -- a files entry
        # written to a path its key does not name, a conffiles copy skipped by a
        # stale optionalString. That is precisely the bug this task fixed, and
        # a derived value cannot catch it: asserting the derivation against
        # itself is vacuous. So this reads the tree.
        #
        # It lives in the builder rather than in `guards`, and that is forced:
        # guards are INPUTS to this derivation, so a guard cannot inspect the
        # artifact it gates. Being the same derivation, it also runs on both
        # `nix build .#calangoDeb` and the activation build -- which is spec
        # 16's defect 10, a guard proven able to fail against a target the
        # installable artifact never touched.
        #
        # Conditions and files, never counts in command substitutions: this
        # builder runs with -e and pipefail, so `n="$(grep -c …)"` aborts on
        # grep's exit status before any message can print. And `done < file`
        # keeps the loop in THIS shell -- `cmd | while read` would put `exit 1`
        # in a subshell.
        if [ -d pkg/etc ]; then
          ( cd pkg && find etc -type f ) | sed 's,^,/,' | LC_ALL=C sort > etcpaths
        else
          : > etcpaths
        fi

        # The vacuity anchor. Without it a manifest that lost its ufw profile
        # and its /etc files builds green while this whole check requires
        # nothing of anything. This builder is not generic -- it already
        # hardcodes /etc/ufw/applications.d -- so coupling it to "this package
        # has /etc payload" costs nothing and is deliberate.
        if [ ! -s etcpaths ]; then
          echo "calango-desktop has no /etc payload at all." >&2
          echo "  The ufw profiles and system files this flake declares are" >&2
          echo "  absent, so nothing in the built package can be a conffile." >&2
          exit 1
        fi

        if [ ! -f pkg/DEBIAN/conffiles ]; then
          echo "calango-desktop ships /etc files and no DEBIAN/conffiles:" >&2
          sed 's/^/  /' etcpaths >&2
          exit 1
        fi

        : > notconffiles
        while read -r p; do
          grep -qxF "$p" pkg/DEBIAN/conffiles || echo "$p" >> notconffiles
        done < etcpaths

        if [ -s notconffiles ]; then
          echo "calango-desktop ships /etc files that are not conffiles:" >&2
          sed 's/^/  /' notconffiles >&2
          echo "DEBIAN/conffiles holds:" >&2
          sed 's/^/  /' pkg/DEBIAN/conffiles >&2
          exit 1
        fi

        rm -f etcpaths notconffiles
```

- [ ] **Step 7: Prove branch 1 — an `/etc` file missing from the list**

Mutate the derivation so `etcPayload` is empty while the file is still shipped:

```bash
sed -i 's/^      etcPayload = lib.filter (lib.hasPrefix "etc\/")/      etcPayload = lib.filter (lib.hasPrefix "NOPE\/")/' lib/deb.nix
/usr/bin/grep -n 'hasPrefix "NOPE/"' lib/deb.nix     # confirm the mutation is present: 1 line
```

Then build the probe. Expected — the guard fires, naming the path:

```
calango-desktop ships /etc files that are not conffiles:
  /etc/default/probe
DEBIAN/conffiles holds:
  /etc/ufw/applications.d/probe-ufw
```

Revert: `git checkout lib/deb.nix` is wrong here — it would discard Steps 3-6. Reverse the `sed` instead:

```bash
sed -i 's/^      etcPayload = lib.filter (lib.hasPrefix "NOPE\/")/      etcPayload = lib.filter (lib.hasPrefix "etc\/")/' lib/deb.nix
/usr/bin/grep -c 'hasPrefix "etc/"' lib/deb.nix      # 1
```

- [ ] **Step 8: Prove branch 2 — `/etc` payload with no conffiles file**

Mutate the emission condition to never copy the file:

```bash
sed -i 's/lib.optionalString (conffiles != "")/lib.optionalString false/' lib/deb.nix
/usr/bin/grep -n 'lib.optionalString false' lib/deb.nix   # confirm: 1 line
```

Build the probe. Expected:

```
calango-desktop ships /etc files and no DEBIAN/conffiles:
  /etc/default/probe
  /etc/ufw/applications.d/probe-ufw
```

Reverse it and confirm:

```bash
sed -i 's/lib.optionalString false/lib.optionalString (conffiles != "")/' lib/deb.nix
/usr/bin/grep -c 'lib.optionalString (conffiles != "")' lib/deb.nix   # 1
```

- [ ] **Step 9: Prove branch 3 — the vacuity anchor**

This one is proven from the fixture, not by mutating the tree. Copy the fixture, empty both payload attributes, and build it:

```bash
sed -e 's/^    ufwProfiles.*$/    ufwProfiles = { };/' \
    -e 's/^    files\..*$/    files = { };/' \
    ~/.cache/spec17-probe/fixture.nix > ~/.cache/spec17-probe/vacuous.nix
/usr/bin/grep -nE 'ufwProfiles|files' ~/.cache/spec17-probe/vacuous.nix   # both now `= { };`
sg nix-users -c 'nix build --no-link --impure --expr "import ~/.cache/spec17-probe/vacuous.nix"'
```

Expected:

```
calango-desktop has no /etc payload at all.
  The ufw profiles and system files this flake declares are
  absent, so nothing in the built package can be a conffile.
```

- [ ] **Step 10: Confirm the real package is unaffected and still reproducible**

The real manifest has one ufw profile and no `etc/` file yet, so its conffiles must be byte-identical to before this task:

```bash
P=$(sg nix-users -c 'nix build --no-link --print-out-paths .#calangoDeb')
/usr/bin/dpkg-deb --ctrl-tarfile "$P"/*.deb | tar -xO ./conffiles
# /etc/ufw/applications.d/calango        <- exactly one line, unchanged
sg nix-users -c 'nix build --no-link --rebuild .#calangoDeb'
# no error, exit 0: still bit-reproducible
sg nix-users -c 'nix flake check' 2>&1 | /usr/bin/grep -o 'running [0-9]* flake checks'
# running 4 flake checks
```

- [ ] **Step 11: Commit**

```bash
git add lib/deb.nix
git commit -F - <<'MSG'
deb: conffiles from every /etc path, enforced in the builder

conffiles was derived from ufwProfiles alone, with a comment saying those
were the only /etc payload. True when written; false the moment a
calango.deb.files key names a path under etc/ -- the file ships as an
ordinary package file, and dpkg replaces a locally edited copy on upgrade
without asking. For etc/default/slack that would restore the defaults that
re-arm Slack's cron job.

Derived by path prefix now, and the copy no longer rides inside the
ufwProfiles branch. The check reads the assembled tree rather than the value
that produced it, because asserting a derived list against itself is
vacuous; it lives in the builder because `guards` are inputs to this
derivation and so cannot inspect the artifact they gate. All three branches
proven by mutation, each mutation confirmed present before its build.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01U7jpCSHruSXqJYmsJ7vQzn
MSG
```

---

## Task 2: `bin/slack-latest` and `home/slack.nix`

**Files:**
- Create: `bin/slack-latest`
- Create: `home/slack.nix`
- Modify: `flake.nix:144-149` (the module list)

**Interfaces:**
- Consumes: Task 1's `conffiles` derivation, which turns `calango.deb.files."etc/default/slack"` into a conffile with no further declaration.
- Produces: `calango.deb.keep.slack-desktop` (a reason string), `calango.deb.files."etc/default/slack"` (two shell assignments), and a `slackLatest` package in `home.packages` exposing `bin/slack-latest`. Task 3 relies on `keep` still totalling 22 after `flatseal` leaves.

- [ ] **Step 1: Create `bin/slack-latest`**

```bash
#!/usr/bin/env bash
#
# report whether the installed slack-desktop is the current one.
#
# Slack ships standalone .deb files with no repository behind them, so nothing
# upgrades this package and `apt upgrade` will never mention it. This asks
# Slack's own release feed and compares. It downloads nothing, installs
# nothing, and needs no privilege: the whole privileged half is two commands it
# prints for a human to run.
#
# There is deliberately no activation hook doing this. A version check needs
# the network, and a home-manager switch must not fail or hang because the
# network is down.

set -euo pipefail

feed='https://slack.com/api/desktop.latestRelease?arch=x64&variant=deb'
admindir=/var/lib/dpkg

# dpkg-query's own diagnostic cannot distinguish "no such package" from "no
# such database": both print `no packages found matching <name>` and exit 1.
# Measured on 2026-08-18 against --admindir=/nonexistent. So the database is
# checked separately, or an unreadable one reads as "Slack is not installed".
if [ ! -r "$admindir/status" ]; then
  printf 'slack-latest: cannot read dpkg'"'"'s database at %s\n' "$admindir" >&2
  exit 1
fi

# --admindir explicitly, so the answer cannot depend on how the Nix build of
# dpkg was configured. It happens to default to /var/lib/dpkg today (verified
# against this flake's pinned pkgs.dpkg 1.23.7, which reads calango-desktop
# 0.258 out of Debian's database), and a future bump changing that default
# would otherwise fail silently and look like an uninstalled package.
#
# ${db:Status-Abbrev} and not ${Version} alone: dpkg-query prints a version and
# exits 0 for an `rc` package, which is exactly what `apt remove` leaves.
# Measured -- signal-desktop is `rc` here and reports `rc 8.19.0`. A
# version-only query would call a removed package installed.
status=$(@dpkgQuery@ --admindir="$admindir" -W \
           -f='@statusFmt@ ${Version}' slack-desktop 2>/dev/null || true)

installed=""
case $status in
  'ii '*) installed=${status#ii } ;;
esac

json=$(@curl@ -sS --max-time 20 "$feed") || {
  printf 'slack-latest: could not reach the release feed\n' >&2
  printf '  %s\n' "$feed" >&2
  exit 1
}

latest=$(printf '%s' "$json" | @jq@ -r '.version // empty')
url=$(printf '%s' "$json" | @jq@ -r '.download_url // empty')

if [ -z "$latest" ] || [ -z "$url" ]; then
  printf 'slack-latest: the release feed named no version\n' >&2
  printf '  %s\n' "$json" >&2
  exit 1
fi

deb=${url##*/}

if [ -z "$installed" ]; then
  if [ -n "$status" ]; then
    printf 'slack-desktop is %s, not installed; upstream is %s\n' \
      "${status%% *}" "$latest"
  else
    printf 'slack-desktop is not installed; upstream is %s\n' "$latest"
  fi
elif @dpkg@ --compare-versions "$installed" ge "$latest"; then
  printf 'slack-desktop %s is current (upstream %s)\n' "$installed" "$latest"
  exit 0
else
  printf 'slack-desktop %s is behind upstream %s\n' "$installed" "$latest"
fi

printf '\n'
printf '  curl -fL -o ~/Downloads/%s \\\n      %s\n' "$deb" "$url"
printf '  sudo apt install ~/Downloads/%s\n' "$deb"
```

- [ ] **Step 2: Track it, or the build will not see it**

```bash
chmod +x bin/slack-latest
git add bin/slack-latest
git status --short bin/slack-latest    # A, not ??
```

- [ ] **Step 3: Create `home/slack.nix`**

```nix
# Everything about Slack, which as of spec 17 is apt's.
#
# This module exists rather than three entries in home/deb.nix because
# home/deb.nix's own comment states the rule: entries with no natural owner
# live there, and anything a module is responsible for lives in that module.
# Slack now has an owner.
#
# The direction is inverted from every other migration in this project. apt is
# the FRESHEST source here (4.51.180) and Nix the stalest (4.49.89, and unfree,
# so flake.nix would need a `config` it deliberately does not have). Slack was
# a flatpak until this spec; it is not a Nix candidate.
#
# Bare `home.packages` and `calango.deb.*` keys, with no `config.` prefix. That
# is the house form for a CONTRIBUTING module -- home/audio.nix:385,394 and
# home/syncthing.nix:81,88 are the precedents. home/deb.nix uses the explicit
# `options.` / `config.` form because it DECLARES the options; mixing the two
# shapes in one file makes the module system read `home` as an unknown
# top-level module key rather than as configuration.
{ pkgs, ... }:

let
  # Substituted rather than resolved at runtime, the same shape as
  # home/apps.nix's binConfig. `${db:Status-Abbrev}` cannot be written into
  # this Nix string directly -- `''${db:...}` is correct, unreadable, and
  # exactly the kind of thing a later editor "fixes" into a format string that
  # silently returns empty for every package. lib/deb.nix builds the same token
  # by concatenation for the same reason.
  statusFmt = "$" + "{db:Status-Abbrev}";

  slackLatest = pkgs.runCommand "slack-latest" { } ''
    mkdir -p "$out/bin"
    cp ${./../bin/slack-latest} "$out/bin/slack-latest"
    chmod u+w "$out/bin/slack-latest"

    substituteInPlace "$out/bin/slack-latest" \
      --replace-fail '@curl@' '${pkgs.curl}/bin/curl' \
      --replace-fail '@jq@' '${pkgs.jq}/bin/jq' \
      --replace-fail '@dpkg@' '${pkgs.dpkg}/bin/dpkg' \
      --replace-fail '@dpkgQuery@' '${pkgs.dpkg}/bin/dpkg-query' \
      --replace-fail '@statusFmt@' '${statusFmt}'

    # --replace-fail already fails on a token the Nix side names and the script
    # does not. This catches the other direction: a token the SCRIPT names and
    # the Nix side forgot, which would otherwise ship a literal @foo@ into a
    # command line. Same guard as home/apps.nix's calango-open.
    if grep -q '@[a-zA-Z]*@' "$out/bin/slack-latest"; then
      echo "unsubstituted token left in slack-latest:" >&2
      grep -n '@[a-zA-Z]*@' "$out/bin/slack-latest" >&2
      exit 1
    fi

    chmod 555 "$out/bin/slack-latest"
  '';
in
{
  home.packages = [ slackLatest ];

  calango.deb.keep.slack-desktop =
    "Corp set, permanently apt, and the one member where apt is the freshest source: 4.51.180 upstream against nixpkgs' unfree 4.49.89. A standalone .deb with no repository behind it, so nothing upgrades it and apt upgrade will never mention it -- bin/slack-latest asks Slack's release feed and a human acts on the answer. Its /etc/cron.daily/slack would re-create the retired packagecloud repo and its signing keys, which is why this package also ships /etc/default/slack.";

  # The knob file, shipped rather than edited, and the load-bearing part of
  # spec 17.
  #
  # slack-desktop ships no maintainer scripts at all -- its control archive
  # holds ./control and nothing else -- which reads as "the repo cannot come
  # back". It can: the payload ships /etc/cron.daily/slack, a Chromium-derived
  # script that recreates both. Traced against the values below:
  #
  #   repo_add_once=false               -> update_bad_sources, which returns at
  #                                        its first test while slack.list is
  #                                        unreadable
  #   repo_reenable_on_distupgrade=false -> install_new_key is never reached
  #
  # With reenable=true -- the value this machine carried before spec 17 --
  # install_new_key runs UNCONDITIONALLY and rewrites
  # /etc/apt/trusted.gpg.d/slack-desktop.gpg every day, so deleting that key is
  # not a deletion. And with the FILE ABSENT the script's first act is to write
  # it back with both knobs "true", install both keys, and create slack.list
  # ACTIVE against a retired jessie repo. Deleting it is the worst move
  # available, which is why this ships it instead.
  #
  # Same species as the deb-systemd-helper trap in CLAUDE.md: a rm that the
  # maintainer's own automation undoes. There the mechanism was a postinst;
  # here it is cron. /etc/cron.daily/google-chrome is the identical script for
  # a repo that genuinely works, and is out of scope.
  #
  # lib/deb.nix makes this a conffile because the key begins `etc/`. That is
  # required, not cosmetic: an /etc file with no conffiles entry is replaced by
  # dpkg on upgrade without asking, which would restore the defaults above.
  calango.deb.files."etc/default/slack" = ''
    repo_add_once="false"
    repo_reenable_on_distupgrade="false"
  '';
}
```

- [ ] **Step 4: Wire it into `flake.nix` and track it**

Add the module after `./home/deb.nix` at `flake.nix:149`:

```nix
          ./home/deb.nix
          ./home/slack.nix
```

```bash
git add home/slack.nix flake.nix
git status --short home/slack.nix    # A, not ??
```

- [ ] **Step 5: Build the helper and run it**

`config.home.path` is the generation's merged profile, so building it proves
the package reached `home.packages` as well as that it runs:

```bash
L=$(sg nix-users -c 'nix build --no-link --print-out-paths \
      .#homeConfigurations."isutton@suffer".config.home.path')
"$L/bin/slack-latest"
```

Expected today, since `slack-desktop` is not installed:

```
slack-desktop is not installed; upstream is 4.51.180

  curl -fL -o ~/Downloads/slack-desktop-4.51.180-amd64.deb \
      https://downloads.slack-edge.com/desktop-releases/linux/x64/4.51.180/slack-desktop-4.51.180-amd64.deb
  sudo apt install ~/Downloads/slack-desktop-4.51.180-amd64.deb
```

If the feed reports a version newer than 4.51.180, that is the correct output; record the version you saw.

- [ ] **Step 6: Prove the `rc` branch, which is the trap this script exists around**

`slack-desktop` is absent, so the `ii` test cannot be exercised against it directly. Exercise it against a package that *is* `rc`:

```bash
sed 's/slack-desktop/signal-desktop/g' "$L/bin/slack-latest" > ~/.cache/spec17-probe/rc-probe
chmod +x ~/.cache/spec17-probe/rc-probe
/usr/bin/grep -c 'signal-desktop' ~/.cache/spec17-probe/rc-probe    # confirm the mutation: 2
~/.cache/spec17-probe/rc-probe
```

Expected — it must report `rc`, **not** a version, because `signal-desktop` is `rc 8.19.0` in dpkg:

```
slack-desktop is rc, not installed; upstream is 4.51.180
```

Confirm the naive form would have been wrong:

```bash
dpkg-query -W -f='${Version}\n' signal-desktop    # 8.19.0, exit 0 -- the trap
```

- [ ] **Step 7: Prove the leftover-token guard**

```bash
sed -i "s/--replace-fail '@jq@' '\${pkgs.jq}\/bin\/jq' \\\\/\\\\/" home/slack.nix
/usr/bin/grep -c '@jq@' home/slack.nix    # 0 -- the Nix side no longer names it
sg nix-users -c 'nix build --no-link .#homeConfigurations."isutton@suffer".config.home.path' 2>&1 | tail -5
```

Expected — the guard fires and names the line:

```
unsubstituted token left in slack-latest:
NN:latest=$(printf '%s' "$json" | @jq@ -r '.version // empty')
```

Restore from the index, which holds the good version because Step 4 staged it:

```bash
git checkout -- home/slack.nix
/usr/bin/grep -c '@jq@' home/slack.nix    # 1 -- the token is named again
```

- [ ] **Step 8: Confirm the declaration and the built package**

```bash
sg nix-users -c 'nix eval --json .#homeConfigurations."isutton@suffer".config.calango.deb.keep' \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d), "slack-desktop" in d, "flatseal" in d)'
# 23 True True     <- flatseal still present; Task 3 removes it

P=$(sg nix-users -c 'nix build --no-link --print-out-paths .#calangoDeb')
/usr/bin/dpkg-deb -c "$P"/*.deb | awk '{print $6}' | /usr/bin/grep -E '^\./etc/.+'
# ./etc/default/                        <- directories are listed too
# ./etc/default/slack
# ./etc/ufw/
# ./etc/ufw/applications.d/
# ./etc/ufw/applications.d/calango
/usr/bin/dpkg-deb --ctrl-tarfile "$P"/*.deb | tar -xO ./conffiles
# /etc/ufw/applications.d/calango
# /etc/default/slack          <- Task 1's derivation, with no declaration here
/usr/bin/dpkg-deb -f "$P"/*.deb Depends | tr ',' '\n' | /usr/bin/grep -c slack-desktop
# 1
```

Note the keep count reads **23** at this point, not 22. That is expected mid-plan: `slack-desktop` has arrived and `flatseal` has not yet left.

- [ ] **Step 9: Commit**

```bash
git add bin/slack-latest home/slack.nix flake.nix
git commit -F - <<'MSG'
slack: a module for it, the cron knob, and a staleness reporter

Slack moves to its own .deb, so it gets an owner. home/slack.nix holds the
keep entry, the knob file, and bin/slack-latest.

The knob file is the point. slack-desktop ships no maintainer scripts, which
reads as "the retired packagecloud repo cannot come back" -- but its payload
ships /etc/cron.daily/slack, which recreates the repo and both signing keys.
With repo_reenable_on_distupgrade=true, install_new_key rewrites
slack-desktop.gpg every day, so deleting it is not a deletion; with the file
absent the script writes it back with both knobs true and creates slack.list
active. Shipping it with both false makes the cron job a no-op, and
lib/deb.nix makes it a conffile so dpkg cannot restore the defaults.

bin/slack-latest reads ${db:Status-Abbrev} and requires `ii` rather than
reading ${Version}, which prints a version and exits 0 for an rc package --
signal-desktop reports rc 8.19.0 here. It passes --admindir explicitly, since
dpkg-query cannot distinguish "no such package" from "no such database".

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01U7jpCSHruSXqJYmsJ7vQzn
MSG
```

---

## Task 3: `home/deb.nix` — `flatseal` out of `keep`, `flatpak` and `flatseal` banned

**Files:**
- Modify: `home/deb.nix` — the `flatseal` line in `config.calango.deb.keep`, two additions to `config.calango.deb.ban`, and the `xdg-desktop-portal` ban reason.

**Interfaces:**
- Consumes: Task 2's `slack-desktop` keep entry, which is what keeps the total at 22 after `flatseal` leaves.
- Produces: `ban` grows from 19 to 21 keys. `home/deb.nix`'s activation hook feeds `builtins.attrNames cfg.ban` to `lib/deb.nix`'s `driftCheck`, so from this task until the user removes them, **every switch warns that `flatpak` and `flatseal` are installed and banned.** That is the intended behaviour, not a defect.

- [ ] **Step 1: Prove the disjointness assertion first, before changing anything**

`flatseal` is about to move from one set to the other, and the assertion that no package is in both is what makes that a decision rather than an accident. Prove it fires:

```bash
sed -i 's|^  config.calango.deb.ban = {|  config.calango.deb.ban = {\n    flatseal = "A deliberate collision, to prove the assertion fires.";|' home/deb.nix
/usr/bin/grep -c 'A deliberate collision' home/deb.nix    # 1 -- mutation present
sg nix-users -c 'nix build --no-link .#calangoDeb' 2>&1 | tail -6
```

Expected — the assertion names the package:

```
A package is in both calango.deb.keep and calango.deb.ban: flatseal
```

Revert: `git checkout home/deb.nix`, then `/usr/bin/grep -c 'A deliberate collision' home/deb.nix` must read 0.

- [ ] **Step 2: Remove `flatseal` from `keep`**

Delete this line from `config.calango.deb.keep`:

```nix
    flatseal = "Absent from nixpkgs, and really a flatpak.";
```

- [ ] **Step 3: Add the two bans**

Add to `config.calango.deb.ban`. Put them together, with the comment, because they are a different *kind* of entry from the other 19:

```nix
    # These two are unlike every other entry here, and the reasons have to say
    # so. The other 19 mean "the Nix side owns this now". These mean "removed
    # deliberately, and nothing replaces them" -- a reader who generalises from
    # the rest will look for the Nix flatpak and not find one.
    flatpak = "Removed deliberately in spec 17, and nothing here replaces it. Slack was the last flatpak and moved to its own .deb; org.gnome.Snapshot, the other one, was removed on 2026-08-17. The sandbox is not wanted back: the session exports five nixGL variables that name paths a flatpak namespace does not contain, so every flatpak application needed a per-application override to undo them. Note gnome-software-plugin-flatpak, plasma-discover-backend-flatpak, flatpak-builder and podman-toolbox all Depend on flatpak, so installing any of them would propose removing this metapackage instead.";
    flatseal = "Removed deliberately in spec 17, with flatpak. It edits flatpak permissions and there is no flatpak. It was in keep until then, for being absent from nixpkgs -- which was a reason to keep it only while flatpak existed. It is also why the removal had to be ordered: this metapackage Depends on flatseal and flatseal Depends on flatpak, so apt remove flatpak took calango-desktop and all 22 keeps with it.";
```

- [ ] **Step 4: Rewrite the `xdg-desktop-portal` ban reason**

The current reason ends with a measured claim about flatpak's unsatisfied `Recommends` — spec 16's defect 9 — and that situation stops existing. Replace the whole reason with:

```nix
    xdg-desktop-portal = "Nix's. Until spec 17 this reason also recorded that flatpak Recommends it (not Depends) with the recommendation sitting unsatisfied, and that Conflicts only fails loudly when the package is named explicitly -- on the recommends-processing path apt silently leaves it uninstalled instead. Both were verified with apt-get -s install, and both are now historical: flatpak is gone and banned. The general lesson is not: an unsatisfied Recommends against a Conflicts is silent.";
```

- [ ] **Step 5: Confirm both sets, by evaluation**

```bash
sg nix-users -c 'nix eval --json .#homeConfigurations."isutton@suffer".config.calango.deb.keep' \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d), "slack-desktop" in d, "flatseal" in d)'
# 22 True False

sg nix-users -c 'nix eval --json .#homeConfigurations."isutton@suffer".config.calango.deb.ban' \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d), "flatpak" in d, "flatseal" in d)'
# 21 True True
```

- [ ] **Step 6: Confirm the built control file**

```bash
P=$(sg nix-users -c 'nix build --no-link --print-out-paths .#calangoDeb')
/usr/bin/dpkg-deb -f "$P"/*.deb Conflicts | tr ',' '\n' | /usr/bin/grep -cE '^ ?(flatpak|flatseal)$'
# 2
/usr/bin/dpkg-deb -f "$P"/*.deb Depends | tr ',' '\n' | /usr/bin/grep -c flatseal
# 0
/usr/bin/dpkg-deb -f "$P"/*.deb Depends | tr ',' '\n' | /usr/bin/grep -c slack-desktop
# 1
```

- [ ] **Step 7: Confirm apt's view, by simulation only**

`apt-get -s` mutates nothing. This is the transaction the user will run as step 3 of the live sequence, and it must be read now rather than discovered then:

```bash
apt-get -s install "$P"/*.deb 2>&1 | tail -20
```

Expected shape: `calango-desktop` upgraded, `flatpak` and `flatseal` **REMOVED**, and `slack-desktop` either already installed or reported missing. If `slack-desktop` is not yet installed, apt refuses the whole transaction on the unsatisfiable `Depends` — which is correct and is exactly why the user's sequence installs Slack first. Record whichever you see; both are informative.

- [ ] **Step 8: Run the drift script and read the new warning**

No option exposes the drift script: `home/deb.nix:223` builds it inline inside
the activation hook. Extract it from the activation script's own text, which is
the only handle on it. Verified working on 2026-08-18, where it printed nothing
and exited 0 — the clean before-state:

```bash
A=$(sg nix-users -c 'nix build --no-link --print-out-paths \
      .#homeConfigurations."isutton@suffer".activationPackage')
D=$(/usr/bin/grep -o '/nix/store/[a-z0-9]*-calango-deb-drift' "$A/activate" | head -1)
echo "$D"        # must be non-empty; if it is empty the hook was renamed
"$D"
```

Running it directly is safe and is the point: it is read-only, and the
activation script only ever runs it under `DRY_RUN=1` for anyone but the user,
where `run` echoes its argument instead of executing it. Expected — two new
lines, because both packages are installed and now banned:

```
apt: flatpak is installed and this flake declares it banned.
apt: flatseal is installed and this flake declares it banned.
```

This warning persists at every switch until the user removes them. Record it in the results document so it is not read as a regression.

- [ ] **Step 9: Commit**

```bash
git add home/deb.nix
git commit -F - <<'MSG'
deb: flatseal out of keep, flatpak and flatseal banned

flatseal was kept for being absent from nixpkgs, which was a reason only
while flatpak existed. It also made the removal order load-bearing:
calango-desktop Depends on flatseal and flatseal Depends on flatpak, so
`apt remove flatpak` proposed removing the metapackage and orphaning all 22
keeps.

The two ban entries say what the other 19 do not: nothing replaces these.
Every existing reason means "the Nix side owns this now", and a reader who
generalises from them will look for a Nix flatpak.

The xdg-desktop-portal reason loses its account of flatpak's unsatisfied
Recommends -- spec 16's defect 9 -- since flatpak is gone. The lesson it
recorded is kept; the live claim is not.

keep stays at 22: flatseal out, slack-desktop in. ban goes 19 to 21. Until
the user removes both packages, every switch warns that a banned package is
installed, which is the drift check working.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01U7jpCSHruSXqJYmsJ7vQzn
MSG
```

---

## Task 4: the documents

**Files:**
- Modify: `CLAUDE.md` (six edits), `README.md:44-50`, `home/apps.nix` (the `signalMimeappsId` comment).

**Interfaces:**
- Consumes: everything Tasks 1-3 established.
- Produces: nothing any task reads.

- [ ] **Step 1: `CLAUDE.md` — the standing fact that is false**

`CLAUDE.md:1095` opens "**There is no longer a file outside `$HOME` that no package owns.**" Replace that sentence — keep the paragraph about the greetd entry that follows it, which is true — with:

```markdown
- **No file *this project created* outside `$HOME` is unowned — which is a
  narrower claim than the one that stood here, and the wider one was false.**
  This entry read "there is no longer a file outside `$HOME` that no package
  owns", and spec 16's close-out reported `unowned files : none outside
  $HOME`. Both were a survey of the files that work created, stated as a
  survey of the filesystem. Spec 17 took the wider measurement:

  ```sh
  cat /var/lib/dpkg/info/*.list | sort -u > /tmp/owned
  find /etc -xdev -type f | sort -u | comm -23 - /tmp/owned | wc -l
  # 182   -- in /etc alone
  ```

  Most are legitimately unowned: generated config (`adjtime`, `aliases`,
  `ca-certificates.conf`), apt keyrings, admin-created `apparmor.d/local`
  entries, and `/etc/default/google-chrome`, which Chrome's own cron job
  writes. So "unowned" is not "wrong" here, and the 182 is not a defect list.
  What is worth keeping is the scope discipline: a claim about a filesystem
  needs a command that walks the filesystem.
```

- [ ] **Step 2: `CLAUDE.md` — the corp set**

At `CLAUDE.md:1084`, replace `and flatpak Slack (com.slack.Slack)` with Slack's new provenance, and add the cron trap. The whole bullet becomes:

```markdown
- **The corp set stays on apt permanently:** `google-chrome-stable`, `code`,
  `1password`, `1password-cli`, `endpoint-verification`, and `slack-desktop`.
  Note `1password` is load-bearing beyond its own window:
  `~/.ssh/config` sets `IdentityAgent ~/.1password/agent.sock` for `github.com`,
  and that agent holds the SSH keys — which is why Debian's `ssh-agent` and
  `gcr-ssh-agent` serve nothing here.
- **Slack is a standalone `.deb` with no repository behind it, and its
  `.deb` ships a cron job that tries to create one.** As of spec 17 Slack is
  apt's — 4.51.180, where nixpkgs has an unfree 4.49.89 — installed from a file
  rather than a repo, so `apt upgrade` will never mention it.
  `bin/slack-latest` asks Slack's release feed and prints the two commands; a
  human runs them.

  The package has **no maintainer scripts at all** — its control archive holds
  `./control` and nothing else — which reads as "the retired packagecloud repo
  cannot come back". It can. The payload ships `/etc/cron.daily/slack`, a
  Chromium-derived script that recreates `/etc/apt/sources.list.d/slack.list`
  and two signing keys, controlled by two values in `/etc/default/slack`:

  ```
  repo_add_once="false"                -> update_bad_sources; returns at once
                                          while slack.list is unreadable
  repo_reenable_on_distupgrade="true"  -> install_new_key runs UNCONDITIONALLY
  ```

  So with `reenable=true`, deleting `slack-desktop.gpg` is not a deletion — the
  job rewrites it daily. And with `/etc/default/slack` **absent** the script's
  first act is to recreate it with *both* knobs `"true"`, install both keys, and
  write `slack.list` **active**. Deleting that file is the worst move available.
  `calango-desktop` therefore ships it, both knobs `"false"`, as a conffile so
  dpkg cannot restore the defaults on upgrade.

  Same species as the `deb-systemd-helper` trap below: a `rm` that a
  maintainer's own automation undoes. There it was a postinst; here it is cron.
  `/etc/cron.daily/google-chrome` is the identical script for a repo that
  genuinely works, which is the control that proves this reading.
```

- [ ] **Step 3: `CLAUDE.md` — the flatpak/GL entry becomes historical**

The entry at `CLAUDE.md:1221` ("**That same inheritance breaks flatpak…**") describes a live mechanism that no longer has a subject. **Do not delete it** — the GL inheritance half is load-bearing and the entry is what stops someone scrubbing it. Rewrite its opening and closing so the flatpak part is past tense:

- opening: "**That same inheritance broke flatpak, and there is no flatpak here any more — kept because it explains why the session inheritance must not be scrubbed.**"
- keep the reproduction and the `GBM_BACKENDS_PATH` measurement verbatim, marked as measured 2026-08-17 while `com.slack.Slack` was still installed.
- closing: state that `~/.local/share/flatpak` was deleted with the runtime in spec 17, that the seven override files went with it, and that **if a flatpak is ever installed again the per-application `--unset-env` treatment is required, for the reason the entry gives.**

- [ ] **Step 4: `CLAUDE.md` — `flatseal` no longer stays on apt**

`CLAUDE.md:1376` reads "**`flatseal` and `fresh-editor` stay on apt.**" Split it, because half of it stopped being true:

```markdown
- **`fresh-editor` stays on apt.** nixpkgs' `fresh-editor` is 0.3.6 against
  Debian's 0.4.7, so moving it would be a downgrade.
- **`flatseal` is gone**, with flatpak, in spec 17. It edited flatpak
  permissions and there is no flatpak. It was kept for being absent from
  nixpkgs, which was a reason to keep it only while flatpak existed — and it
  was what made the removal order load-bearing, since `calango-desktop`
  `Depends: flatseal` and `flatseal` `Depends: flatpak`.
```

- [ ] **Step 5: `CLAUDE.md` — the `mimeapps.list` count drops to one**

In the entry at `CLAUDE.md:1379`, `slack.desktop` is no longer dead: Slack's `.deb` ships exactly that id. Rewrite the entry to name `eu.calangotech.KBrowserSelector.desktop` as the remaining one, keep the "at least" qualifier and its reason verbatim, and add:

```markdown
  `slack.desktop` was the second until spec 17. It is live now, and repaired by
  nothing: Slack's `.deb` ships `/usr/share/applications/slack.desktop`, the
  exact id `mimeapps.list` already named. No fixer hook was needed, which is the
  opposite of spec 13's Signal case — where nixpkgs' id differed from Debian's
  and `home/apps.nix`'s `signalMimeappsId` hook had to rewrite the file. Two
  migrations, two outcomes; do not generalise from either.
```

- [ ] **Step 6: `CLAUDE.md` — `apt-cache policy` joins the wrong-instrument list**

Add to the "Tools that answer a different question than the one asked" section, after the **Package presence** entry at `CLAUDE.md:235`:

```markdown
**`apt-cache policy` reports `Candidate: (none)` for a name that is fully
satisfiable.** A purely virtual package — one that exists only as another
package's `Provides` — has no candidate version, and the output is
indistinguishable from a package Debian does not have at all. Four of Slack's
hard `Depends` read that way:

```sh
apt-cache policy libgtk-3-0 libappindicator3-1 libatspi2.0-0 libasound2
# Candidate: (none)      -- for all four
apt-cache showpkg libgtk-3-0 | sed -n '/Reverse Provides/,$p'
# libgtk-3-0t64 3.24.49-3 (= 3.24.49-3)
```

All four are provided by installed packages (`libgtk-3-0t64`,
`libayatana-appindicator3-1`, `libatspi2.0-0t64`, `libasound2t64`) and the
install is clean. The authority on whether a dependency can be met is
`apt-get -s install`, which simulates the solver; `apt-cache policy` only
answers about a real package of that name.
```

- [ ] **Step 7: `README.md` — Signal has not been apt's since spec 13**

`README.md:44-50` lists Signal under "What apt still owns". `signal-desktop` has been in `calango.deb.ban` since spec 13. Replace `Signal` with `Slack` in the vendor-stack sentence, and add one line after the paragraph:

```markdown
Slack is a standalone `.deb` with no repository behind it —
`slack-latest` reports when it is behind upstream.
```

- [ ] **Step 8: `home/apps.nix` — the comment that names flatpak's export**

Find the `signalMimeappsId` comment naming `slack.desktop` "where flatpak exports `com.slack.Slack.desktop`, a different id":

```bash
/usr/bin/grep -n 'com.slack.Slack.desktop' home/apps.nix
```

That parenthetical is why `slack.desktop` had to survive the hook untouched. It still must survive untouched, but for the opposite reason. Replace it with: `slack.desktop`, which apt's `slack-desktop` ships and which this flake does not own either — so it must survive untouched for the same reason, not because it is dead.

- [ ] **Step 9: Verify every documentation claim is still true as written**

```bash
# the mimeapps id count the CLAUDE.md entry now claims
/usr/bin/grep -c 'KBrowserSelector' ~/.config/mimeapps.list          # 2
xdg-mime query default x-scheme-handler/slack                        # slack.desktop
# the check count CLAUDE.md's opening section states
sg nix-users -c 'nix flake check' 2>&1 | /usr/bin/grep -o 'running [0-9]* flake checks'
# running 4 flake checks
# the module-count claims CLAUDE.md tells the reader to re-derive
/usr/bin/grep -l 'source =' home/*.nix | wc -l
/usr/bin/grep -n 'home.packages' home/*.nix
/usr/bin/grep -n 'assertions' home/*.nix
```

`home/slack.nix` adds one `home.packages` list, so the `grep -n 'home.packages'` enumeration returns one more line than `CLAUDE.md`'s prose describes. `CLAUDE.md` already tells the reader to enumerate rather than trust the number, so no count in it needs editing — but confirm the new module appears, and if any sentence names a specific total, fix it.

- [ ] **Step 10: Commit**

```bash
git add CLAUDE.md README.md home/apps.nix
git commit -F - <<'MSG'
docs: Slack is apt's, flatpak is gone, and one standing fact was false

Six corrections to CLAUDE.md. Two are findings rather than rewording:

"There is no longer a file outside $HOME that no package owns" is false --
182 dpkg-unowned files under /etc alone. Most are legitimate, so the 182 is
not a defect list; what was wrong was stating a survey of the files this
project created as a survey of the filesystem. Restated to that scope, with
the command.

flatseal does not "stay on apt" any more, and the entry saying so was half
true. Split.

The rest: the corp set gains Slack and the cron-job trap; the flatpak/GL
entry goes past tense while keeping the inheritance rule it exists to
protect; mimeapps.list is down to one dead association, because Slack's .deb
ships the exact id the handler already named; and apt-cache policy joins the
wrong-instrument list for reporting Candidate: (none) on a name that is
satisfiable through Provides.

README listed Signal under what apt owns, which spec 13 made false.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01U7jpCSHruSXqJYmsJ7vQzn
MSG
```

---

## Task 5: whole-tree verification

**Files:** none modified unless a check fails.

**Interfaces:**
- Consumes: Tasks 1-4.
- Produces: the evidence the close-out document quotes.

- [ ] **Step 1: The flake's own checks**

```bash
sg nix-users -c 'nix flake check' 2>&1 | /usr/bin/grep -o 'running [0-9]* flake checks'
# running 4 flake checks
sg nix-users -c 'nix flake check' 2>&1 | /usr/bin/grep -c '^checking derivation checks\.'
# 4
echo "exit=$?"
```

- [ ] **Step 2: The package builds, is reproducible, and names no store path**

```bash
P=$(sg nix-users -c 'nix build --no-link --print-out-paths .#calangoDeb')
sg nix-users -c 'nix build --no-link --rebuild .#calangoDeb'
# no error, exit 0
/usr/bin/dpkg-deb --fsys-tarfile "$P"/*.deb | tar -xO ./usr/share/calango-desktop/manifest.json \
  | /usr/bin/grep -c '/nix/store'
# 0
/usr/bin/dpkg-deb -c "$P"/*.deb | head -3
# drwxr-xr-x root/root ... -- root/root ownership, unchanged
```

- [ ] **Step 3: The generation builds and the activation script is well-formed**

```bash
A=$(sg nix-users -c 'nix build --no-link --print-out-paths \
      .#homeConfigurations."isutton@suffer".activationPackage')
DRY_RUN=1 "$A/activate" 2>&1 | tail -25
```

`DRY_RUN=1` is mandatory. Expect the drift hook to report `calango-desktop is out of date` (the manifest changed) and to name `flatpak` and `flatseal` as installed-and-banned. Both are correct at this point in the sequence.

- [ ] **Step 4: The helper is on the generation's path**

```bash
L=$(sg nix-users -c 'nix build --no-link --print-out-paths \
      .#homeConfigurations."isutton@suffer".config.home.path')
"$L/bin/slack-latest"
# slack-desktop is not installed; upstream is <version>
/usr/bin/grep -c '@[a-zA-Z]*@' "$L/bin/slack-latest"
# 0
```

- [ ] **Step 5: Record the before-state for the user's steps**

These are the numbers the close-out compares against. Take them now, before anything privileged happens:

```bash
dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' flatpak flatseal calango-desktop
dpkg-query -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' slack-desktop 2>&1
dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' | awk '$1=="rc"' | wc -l
du -sh /var/lib/flatpak ~/.var ~/.config/Slack ~/.local/share/flatpak
find /etc/systemd/user -xtype l | wc -l
apt-get -s autoremove | /usr/bin/grep -c '^Remv '
```

- [ ] **Step 6: Commit only if a fix was needed**

If every check above passed with no edit, there is nothing to commit and the branch is ready for review. If a check failed and you fixed it, commit the fix with a message naming the check that caught it.

---

## After the plan: the user's steps

**None of these may be run by an agent.** They are listed so the close-out
knows what to verify, and **in this order**, which is forced: once `flatpak` is
banned, installing the new metapackage removes it, so the rollback must outlive
the first host launch.

1. **Install Slack's `.deb`.** Run `slack-latest`, then the two commands it
   prints. Expect one new package and nothing removed. The flatpak Slack stays
   installed and usable through steps 1 and 2.

2. **Hand over the profile.** Quit the flatpak Slack first.

   ```sh
   cp -a ~/.config/Slack ~/.config/Slack.pre-deb-backup
   cp -a ~/.var/app/com.slack.Slack/config/Slack ~/.config/Slack.flatpak-backup
   rm -rf ~/.config/Slack
   cp -a ~/.var/app/com.slack.Slack/config/Slack ~/.config/Slack
   ```

   Then launch Slack from the Applications panel. **This launch is the
   irreversible step** — 4.51.180 opening a 4.50.143 profile may migrate it.
   Confirm the login and the workspaces before going further.

3. **Settle GL**, while Slack is running:

   ```sh
   for p in $(pgrep -f slack); do
     printf '%s ' "$p"; grep -cE 'swiftshader|libEGL_mesa|iris_dri' /proc/$p/maps
   done
   ```

   The GL stack is in a child process, so the top-level pid gives a misleading
   zero. `iris_dri` is the Intel path; `swiftshader` is software.

4. **Install the new `calango-desktop`.** Simulate first:

   ```sh
   sg nix-users -c 'nix build .#calangoDeb'
   apt-get -s install ./result/calango-desktop_*_all.deb
   ```

   Expect exactly: `calango-desktop` upgraded, `flatpak` and `flatseal`
   removed, nothing else touched. Then run it for real.

   **Expect a dpkg prompt on `/etc/default/slack`, and answer it `Y`.** That
   path exists on this machine today as an unowned file carrying
   `repo_reenable_on_distupgrade="true"`; `calango-desktop` ships the same
   path as a conffile with `"false"`. dpkg does not overwrite a conffile whose
   path already holds a differing file — it prompts, default `N` (keep the
   current version):

   ```
   Configuration file '/etc/default/slack'
    ==> File on system created by you or by a script.
    ==> File also in package provided by package maintainer.
    The default action is to keep your current version.
   *** slack (Y/I/N/O/D/Z) [default=N] ?
   ```

   Pressing Enter takes the default and silently keeps
   `repo_reenable_on_distupgrade="true"` — the transaction still matches the
   simulation exactly, but step 6's deletion of `slack-desktop.gpg` stops
   being a deletion, which is the failure this whole mechanism exists to
   prevent. Answer **`Y`**. Do not add `-y`/`DEBIAN_FRONTEND=noninteractive`
   to this install: either takes the wrong branch with no prompt at all.

   Alternative: `sudo rm -f /etc/default/slack` immediately before this step
   makes dpkg install its copy silently. Safe only right now (before step 1;
   confirm with `ls /etc/cron.daily/` — the script does not exist yet) or in
   the window immediately before this step — **not** unattended between step 1
   and this one, because once Slack's `.deb` is installed the cron job exists
   and, finding the file absent, recreates it with both knobs `"true"`,
   installs both keys, and writes `slack.list` active.

5. **`apt autoremove`, reading the "no longer required" list at that moment.**
   18 packages as of 2026-08-18. Read the list apt prints then, not this
   document's copy of it. For each candidate, union a `/proc` walk (`maps` and
   `exe`) with the first field of `ps -eo args` over *every* process, resolved
   through `dpkg -S` — and for anything that might be a script, ask `dpkg -S`
   about the full command line, not `argv[0]`. `libhidapi-hidraw0` has
   plausible non-flatpak consumers; check it rather than assuming it is
   flatpak's. `apt-mark manual` anything still in use.

6. **Delete the residue.**

   ```sh
   sudo rm -rf /var/lib/flatpak                    # 1.7 G
   rm -rf ~/.var/app/com.slack.Slack               # 711 M
   rm -rf ~/.local/share/flatpak                   # the seven override files
   rm -rf ~/.config/Slack.pre-deb-backup           # 822 M, once Slack is proven
   sudo rm -f /etc/apt/sources.list.d/slack.list \
              /etc/apt/trusted.gpg.d/slack-desktop.gpg \
              /etc/apt/trusted.gpg.d/packagecloud.gpg
   ```

   **Not** `/etc/default/slack`. `calango-desktop` owns it, and deleting it
   re-arms everything above.

7. **Prove the knob, by running the job rather than waiting a day.**

   ```sh
   sudo /etc/cron.daily/slack
   ls /etc/apt/sources.list.d/slack.list \
      /etc/apt/trusted.gpg.d/slack-desktop.gpg \
      /etc/apt/trusted.gpg.d/packagecloud.gpg      # all three absent
   dpkg -V calango-desktop                          # no output
   ```

   `dpkg -V` does cover conffiles — verified able to fail, since `dpkg -V` with
   no argument reports `??5?????? c /etc/greetd/config.toml` on this machine.

   `dpkg -V calango-desktop` reporting `??5?????? c /etc/default/slack` here
   means step 4's prompt was answered the wrong way (`N` instead of `Y`).
   Recover with `sudo rm -f /etc/default/slack && sudo apt install --reinstall
   calango-desktop`.

8. **`home-manager switch`**, then confirm the drift hook has gone quiet: no
   `out of date` line, and no `flatpak`/`flatseal` banned-and-installed
   warnings.

9. **Check after the reboot, not before.** Removing a package does not kill its
   running process, and `rc` counts, dangling `/etc/systemd/user` links and
   `autoremove` totals are all read then. Re-take every number from Task 5
   Step 5.
