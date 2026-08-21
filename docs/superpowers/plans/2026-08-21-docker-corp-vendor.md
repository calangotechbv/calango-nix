# Docker as a Corp Vendor — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Declare docker in this flake the way Chrome, Code, 1Password and endpoint-verification are declared — a signing key, an apt source, corp packages, keep entries, and the `docker` group — so a bare-Debian bootstrap produces a machine with docker, and so `calango-desktop`'s `Depends` holds it on suffer instead of an `apt-mark` flag.

**Architecture:** Docker is a fifth vendor repository in `calango.bootstrap.aptSources`, with an inline armored key rendered by the existing `stanza` function. Its source is **durable**, so it gets no `aptSourcesTransient` entry. Six docker packages join `packages.corp` and, with `golang-docker-credential-helpers`, `calango.deb.keep`. The `docker` group cannot go in `calango.bootstrap.groups` — Stage A runs before the group exists — so a new `groupsFromCorp` option carries it into Stage C.

**Tech Stack:** Nix (Home Manager module system, `lib.mkOption`, `assertions`), deb822 apt sources, Bash (the runbook's own commands and the activation hook), the existing `test/vm/` Python harness.

**Spec:** `docs/superpowers/specs/2026-08-21-docker-corp-vendor-design.md`

## Global Constraints

- **Wrap every `nix` and `home-manager` invocation:** `sg nix-users -c '...'`. A bare `nix` fails on `/nix/var/nix/daemon-socket/` and reads as a broken install.
- **`/usr/bin/grep` whenever a count is load-bearing.** The interactive shell's `grep` is ugrep and returns `0` for a pattern containing `${` against a file that holds it. This does not apply inside a Nix builder.
- **No reason string in `calango.deb.keep` may contain the literal Nix store path prefix.** Every reason is serialised into `manifest.json`, which the `noStorePaths` guard greps, so a reason that merely *talks about* store paths fails the build. `home/deb.nix:127-131` records that this cost a clean build once. Write "the Nix store" in prose.
- **Count `nix flake check`'s checks, never quote a number.** `sg nix-users -c 'nix flake check' 2>&1 | grep -c '^checking derivation checks\.'`. The `checks\.` part is load-bearing.
- **Every guard added here is proven able to fail by mutation, and the step records the mutation.** Three checks in this project's history passed while the property they stood for was false.
- **Commit the real work before its mutation tests.** `git restore --worktree <path>` restores from the **index**, so staged good content survives a revert and unstaged work does not. Never add `--staged`: that restores from HEAD and deletes a file new to this branch.
- **New files must be `git add`ed before `nix flake check`.** A flake evaluates only tracked paths.
- **Do not edit any `docs/*results-suffer-*.md`.** They record runs that happened.
- **The docker apt source is DURABLE.** It must never gain an `aptSourcesTransient` entry. Deleting it would leave six installed packages with no candidate version.
- Docker's signing key fingerprint is `9DC858229FC7DD38854AE2D88D81803C0EBFCD88`, one public key in the file.
- Docker's repository: `URIs: https://download.docker.com/linux/debian`, `Suites: trixie`, `Components: stable`. The suite is a **codename** and `stable` is the **component** — inverted against every other source in this flake, and correct.

## File Structure

| file | change | responsibility |
|---|---|---|
| `bootstrap/keys/docker.asc` | create | Docker's armored signing key, read by `home/bootstrap.nix` |
| `bootstrap/keys/docker.fpr` | create | Its fingerprint, so a rotation shows in review as a changed fingerprint |
| `home/bootstrap.nix` | modify | The fifth `aptSources` entry, six `packages.corp` entries, the new `groupsFromCorp` option and its value, one new assertion, three new substitution tokens, the drift hook |
| `home/deb.nix` | modify | Seven `keep` entries |
| `bootstrap/runbook.md.in` | modify | The Stage C `usermod` block; the hard-coded "Two of the four" made generated |
| `test/vm/steps/30-stage-c.txt` | modify | The mirrored corp `apt install` line, and a new mirrored `usermod` line |
| `README.md` | modify | Line 54's vendor-stack sentence, which currently describes the machine and reads as a declaration |
| `CLAUDE.md` | modify | A standing fact: docker cannot move to Nix, for the `bluez` reason |

**Why the keep entries go in `home/deb.nix` and not in a new `home/docker.nix`.** `home/deb.nix:118` states the rule — entries with no natural owner live there, anything a module is responsible for lives in that module — and `home/slack.nix` follows it. Slack's module exists because it *ships* things: a `slackLatest` binary in `home.packages` and `/etc/default/slack` as a conffile. Docker ships neither. A `home/docker.nix` holding nothing but seven strings would have no responsibility to justify the file, and the four other corp vendors' keeps already live in `home/deb.nix` for exactly that reason. Note also that Slack's `packages.corp` entry stayed at `home/bootstrap.nix:555` even after its module was created: the vendor tables live with the other vendors. If docker ever gains real behaviour here — a daemon config, a shipped file — that is when the module earns its existence.

---

### Task 1: the signing key and the apt source

**Files:**
- Create: `bootstrap/keys/docker.asc`
- Create: `bootstrap/keys/docker.fpr`
- Modify: `home/bootstrap.nix` — the `aptSources` attrset, currently ending at the `calango-bootstrap-google-cloud.sources` entry around line 504

**Interfaces:**
- Consumes: the `stanza` function at `home/bootstrap.nix:88`, signature `{ uris, suites, key, components ? "main", architectures ? "amd64" }`, and `keyFile` at `:85`, which reads `bootstrap/keys/<name>.asc`.
- Produces: a rendered file `etc/apt/sources.list.d/calango-bootstrap-docker.sources` inside `.#calangoBootstrap`, which Task 2's runbook text and Task 7's verification both depend on.

- [x] **Step 1: Run the existing source test and record the current number**

```bash
B=$(sg nix-users -c 'nix build --no-link --print-out-paths .#calangoBootstrap')
./test/apt-sources.sh "$B"
```

Expected: `validating 4 source(s)` and `all 4 source(s) verified`. This is the pre-change reading. Record it; Task 1 is done when it reads 5.

- [x] **Step 2: Fetch the key and record its fingerprint**

```bash
curl -fsSL https://download.docker.com/linux/debian/gpg -o bootstrap/keys/docker.asc
gpg --show-keys --with-colons bootstrap/keys/docker.asc | awk -F: '/^pub:/{c++} END{print c" public key(s)"}'
gpg --show-keys --with-colons bootstrap/keys/docker.asc | awk -F: '/^fpr:/{print $10; exit}' > bootstrap/keys/docker.fpr
cat bootstrap/keys/docker.fpr
```

Expected: `1 public key(s)`, and the fingerprint file holds exactly

```
9DC858229FC7DD38854AE2D88D81803C0EBFCD88
```

If the fingerprint differs from that value, **stop**. Docker rotated its key, and that is a fact to establish deliberately rather than to absorb into this task. `bootstrap/keys/README.md` explains why the `.fpr` exists: a rotation must show up in review as a changed fingerprint rather than as a silent replacement of an opaque blob.

The file must be armored ASCII, like its four siblings:

```bash
head -1 bootstrap/keys/docker.asc
```

Expected: `-----BEGIN PGP PUBLIC KEY BLOCK-----`

- [x] **Step 3: Add the source entry**

In `home/bootstrap.nix`, inside `config.calango.bootstrap.aptSources`, after the `calango-bootstrap-google-cloud.sources` entry:

```nix
      # Docker's repository has no `stable` SUITE -- its suites are Debian
      # codenames -- and `stable` is the COMPONENT. So these two fields read
      # inverted against every other source here, and are not. A reader who
      # "fixes" them gets a repository that does not exist.
      #
      # `trixie` is hard-coded because nothing in this flake declares a Debian
      # release to derive it from; the release appears only in prose comments.
      # The next Debian major edits this line. test/apt-sources.sh is what
      # catches a stale one, and only when a person runs it.
      #
      # DURABLE, not transient. Measured 2026-08-21: no docker postinst writes
      # a source file or a keyring, and none of the six ships a cron job. So
      # this file must never gain an aptSourcesTransient entry -- deleting it
      # would leave six installed packages with no candidate version, the
      # position slack-desktop is in.
      "calango-bootstrap-docker.sources" = stanza {
        uris = "https://download.docker.com/linux/debian";
        suites = "trixie";
        components = "stable";
        key = "docker";
      };
```

- [x] **Step 4: Track the new files, then build and run the test**

```bash
git add bootstrap/keys/docker.asc bootstrap/keys/docker.fpr
B=$(sg nix-users -c 'nix build --no-link --print-out-paths .#calangoBootstrap')
./test/apt-sources.sh "$B"
```

Expected: `validating 5 source(s)`, a line `ok   calango-bootstrap-docker.sources`, and `all 5 source(s) verified`.

- [x] **Step 5: Read the rendered file and confirm the four fields**

```bash
sed -n '1,6p' "$B/etc/apt/sources.list.d/calango-bootstrap-docker.sources"
```

Expected, exactly:

```
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: trixie
Components: stable
Architectures: amd64
Signed-By:
```

- [x] **Step 6: Commit, before the mutation**

```bash
git add bootstrap/keys/docker.asc bootstrap/keys/docker.fpr home/bootstrap.nix
git commit -m "bootstrap: docker's repository, declared as the fifth vendor source"
```

- [x] **Step 7: Prove the test can fail — mutate the suite**

```bash
sed -i 's/suites = "trixie";/suites = "bookworm-nonesuch";/' home/bootstrap.nix
/usr/bin/grep -c 'bookworm-nonesuch' home/bootstrap.nix
```

Expected: `1`. Confirm the mutation landed before building — a mutation that did not apply produces a pass that means nothing.

```bash
B=$(sg nix-users -c 'nix build --no-link --print-out-paths .#calangoBootstrap')
./test/apt-sources.sh "$B"
```

Expected: `FAIL calango-bootstrap-docker.sources`, an apt log naming the missing release, and a non-zero exit.

- [x] **Step 8: Revert the mutation and confirm the revert**

```bash
git restore --worktree home/bootstrap.nix
/usr/bin/grep -c 'suites = "trixie";' home/bootstrap.nix
/usr/bin/grep -c 'bookworm-nonesuch' home/bootstrap.nix
```

Expected: `1` then `0`. Do **not** pass `--staged`: that restores from HEAD.

---

### Task 2: the six corp packages

**Files:**
- Modify: `home/bootstrap.nix` — `config.calango.bootstrap.packages.corp`, around line 549
- Modify: `test/vm/steps/30-stage-c.txt` — the two lines mirroring the corp `apt install`, currently 34 and 35

**Interfaces:**
- Consumes: Task 1's `calango-bootstrap-docker.sources`, named in each reason string.
- Produces: `@corpRepoPackagesOneLine@` gains six names, which Task 4's runbook and this task's step file both mirror. `corpFileOnlyNames` at `home/bootstrap.nix:199` filters on the literal prefix `NO repository`; none of these reasons starts with it, so all six land on the repo-backed side.

- [x] **Step 1: Record the counts before the change**

```bash
sg nix-users -c 'nix eval --json .#homeConfigurations."isutton@suffer".config.calango.bootstrap.packages.corp' | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'
```

Expected: `6`.

- [x] **Step 2: Add the six entries**

In `home/bootstrap.nix`, inside `config.calango.bootstrap.packages.corp`:

```nix
      # Six names, not one. `apt install docker-ce` alone would pull the rest
      # -- docker-ce Depends containerd.io and docker-ce-cli, docker-ce-cli
      # Recommends the two plugins -- but this list is also read by a person
      # deciding what the machine is meant to have, and a Recommends is not a
      # promise.
      docker-ce = "https://download.docker.com/linux/debian -- calango-bootstrap-docker.sources. The daemon. dockerd runs from /usr/lib/systemd/system/docker.service, a system unit, so this can never move to Nix -- the bluez and rtkit reason.";
      docker-ce-cli = "The same repository as docker-ce. The client; a Depends of docker-ce.";
      "containerd.io" = "The same repository as docker-ce. The container runtime; a Depends of docker-ce.";
      docker-buildx-plugin = "The same repository as docker-ce. Reaches the machine only as a Recommends of docker-ce-cli, which is why it is named here.";
      docker-compose-plugin = "The same repository as docker-ce. Also only a Recommends of docker-ce-cli.";
      docker-ce-rootless-extras = "The same repository as docker-ce. A Recommends of docker-ce, and auto on suffer. Named here because it is installed, not because rootless mode is configured -- it is not, and dockerd runs as a root system service.";
```

- [x] **Step 3: Build, and watch `vm-step-lines-verbatim` fail**

```bash
sg nix-users -c 'nix flake check' 2>&1 | tail -20
```

Expected: a failure from `vm-step-lines-verbatim`, naming the line in `test/vm/steps/30-stage-c.txt` that no longer appears in the rendered `RUNBOOK.md`. **This is the failing test for this task**, not an obstacle: the check exists so a runbook change with no matching step-file change cannot pass silently.

- [x] **Step 4: Read the generated line out of the rendered runbook**

Do not hand-write the package list. Copy it from what the flake actually renders:

```bash
D=$(sg nix-users -c 'nix build --no-link --print-out-paths .#calangoBootstrap')
/usr/bin/grep -n 'sudo apt install ' "$D/RUNBOOK.md" | head -3
```

Expected to contain, on one line:

```
sudo apt install 1password 1password-cli code containerd.io docker-buildx-plugin docker-ce docker-ce-cli docker-ce-rootless-extras docker-compose-plugin endpoint-verification google-chrome-stable
```

That ordering is `attrNames`' byte order, and it is a prediction — take the rendered text as the authority if the two disagree.

- [x] **Step 5: Update the two mirrored lines in the step file**

`test/vm/steps/30-stage-c.txt`, replacing the current lines 34 and 35:

```
#= sudo apt install 1password 1password-cli code containerd.io docker-buildx-plugin docker-ce docker-ce-cli docker-ce-rootless-extras docker-compose-plugin endpoint-verification google-chrome-stable
sudo apt install -y 1password 1password-cli code containerd.io docker-buildx-plugin docker-ce docker-ce-cli docker-ce-rootless-extras docker-compose-plugin endpoint-verification google-chrome-stable 2>&1 | tail -8
```

The `#= ` line must match the runbook **verbatim**; the line below it is the harness's own version and carries `-y` and a `tail`.

**Change no timeout.** An earlier draft of this step said to raise the `#T 300` below the apt install, on the reading that it applied to the block above it. It does not: `test/vm/calangovm/driver.py:24-36` sets the timeout for every block **after** the directive, so `#T 3000` already governs this apt install and `#T 300` governs the `rm` that follows. 3000 seconds is ample for six more packages.

- [x] **Step 6: Build and confirm the check passes**

```bash
sg nix-users -c 'nix flake check' 2>&1 | grep -c '^checking derivation checks\.'
```

Expected: the same number this flake had before this task — read it, do not quote it. No new check is added here.

- [x] **Step 7: Confirm the counts moved**

```bash
sg nix-users -c 'nix eval --json .#homeConfigurations."isutton@suffer".config.calango.bootstrap.packages.corp' | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'
/usr/bin/grep -c 'docker' "$D/RUNBOOK.md"
```

Expected: `12` for the first. The second is a sanity reading, not an assertion.

- [x] **Step 8: Commit**

```bash
git add home/bootstrap.nix test/vm/steps/30-stage-c.txt
git commit -m "bootstrap: the six docker packages, and the step file that mirrors them"
```

---

### Task 3: the `groupsFromCorp` option, its assertion, and the drift hook

**Files:**
- Modify: `home/bootstrap.nix` — the options block around line 400 (`groups`), the config block around line 466 (`groups`'s value), `config.assertions` around line 572, and the drift hook's group loop at line 726

**Interfaces:**
- Consumes: `cfg.groups`, already a `listOf str`.
- Produces: `cfg.groupsFromCorp`, an `attrsOf str` mapping a group name to why a corp package owns it. Task 4's runbook substitutions read `builtins.attrNames cfg.groupsFromCorp`.

- [x] **Step 1: Declare the option**

In `home/bootstrap.nix`, immediately after the `groups` option:

```nix
    # Groups a CORP PACKAGE creates, so they cannot be added in Stage A.
    #
    # Split from `groups` rather than merged into it because the two are added
    # at different stages and one usermod cannot serve both: Stage A runs
    # `usermod -aG @groupsComma@` before Stage C installs anything, and
    # docker-ce's postinst is what creates the docker group. A name put in
    # `groups` instead fails Stage A on a machine that has never had docker.
    #
    # Same shape as aptSourcesTransient, which splits the sources by the stage
    # that acts on them rather than by what they are.
    groupsFromCorp = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Group -> which corp package creates it. Added in Stage C.";
    };
```

- [x] **Step 2: Set its value**

In `config.calango.bootstrap`, immediately after `groups = [ ... ];`:

```nix
    groupsFromCorp = {
      docker = "docker-ce's postinst creates this group, so Stage A -- which runs before Stage C installs docker-ce -- cannot add it. Membership is write access to /var/run/docker.sock, which is srw-rw---- root:docker, and so is root-equivalent.";
    };
```

- [x] **Step 3: Write the failing test — add the assertion, then break it**

Add to `config.assertions`, after the `aptSourcesTransient` consistency assertion:

```nix
    {
      # A name in both lists renders two usermod lines and hides which stage
      # owns the group. Same shape as home/deb.nix's keep/ban disjointness.
      #
      # What this does NOT do: nothing at build time knows which groups a bare
      # Debian machine has, so this cannot stop someone putting `docker` in
      # `groups` alone -- which is the failure the split exists to prevent.
      # ./test/vm/vm final-pass is the check for that.
      assertion =
        lib.intersectLists cfg.groups (builtins.attrNames cfg.groupsFromCorp) == [ ];
      message = ''
        calango.bootstrap.groups and calango.bootstrap.groupsFromCorp name the
        same group:

          groups        : ${lib.concatStringsSep " " cfg.groups}
          groupsFromCorp: ${lib.concatStringsSep " " (builtins.attrNames cfg.groupsFromCorp)}

        A group belongs to exactly one stage. Stage A adds `groups` before any
        corp package exists; Stage C adds `groupsFromCorp` after. A name in
        both renders two usermod lines and leaves it ambiguous which stage is
        responsible.
      '';
    }
```

- [x] **Step 4: Prove the assertion can fire**

```bash
sed -i 's/groups = \[ "nix-users" "video" "input" \];/groups = [ "nix-users" "video" "input" "docker" ];/' home/bootstrap.nix
/usr/bin/grep -c '"nix-users" "video" "input" "docker"' home/bootstrap.nix
```

Expected: `1`. Confirm the mutation landed.

```bash
sg nix-users -c 'nix build --no-link .#homeConfigurations."isutton@suffer".activationPackage' 2>&1 | tail -12
```

Expected: the evaluation fails with the message above, listing `docker` in both lines.

- [x] **Step 5: Revert and confirm**

**Do not use `git restore` here.** `home/bootstrap.nix` holds unstaged work from steps 1-3, and restoring the worktree copy discards it. Revert only the mutation:

```bash
sed -i 's/groups = \[ "nix-users" "video" "input" "docker" \];/groups = [ "nix-users" "video" "input" ];/' home/bootstrap.nix
/usr/bin/grep -c '"nix-users" "video" "input" "docker"' home/bootstrap.nix
/usr/bin/grep -c '"nix-users" "video" "input" \]' home/bootstrap.nix
```

Expected: `0` then `1`. This is why the global constraints say to commit real work before mutating: had steps 1-3 been committed, `git restore --worktree` would have been safe.

- [x] **Step 6: Widen the drift hook**

At `home/bootstrap.nix:726`, the loop currently reads:

```nix
        for g in ${lib.concatStringsSep " " cfg.groups}; do
```

Replace with:

```nix
        for g in ${lib.concatStringsSep " " (cfg.groups ++ builtins.attrNames cfg.groupsFromCorp)}; do
```

This is the whole reason the group is declared in the module rather than written into runbook prose: suffer gets told when the membership goes away. The loop's existing `grep -qx` whole-line match is unchanged and remains correct.

- [x] **Step 7: Prove the hook reports the new group**

`isutton` is already in `docker`, so the hook is silent for the real value. Mutate the value to a group nobody holds:

```bash
sed -i 's/^      docker = "docker-ce/      dockernosuchgroup = "docker-ce/' home/bootstrap.nix
/usr/bin/grep -c 'dockernosuchgroup' home/bootstrap.nix
```

Expected: `1`.

```bash
A=$(sg nix-users -c 'nix build --no-link --print-out-paths .#homeConfigurations."isutton@suffer".activationPackage')
/usr/bin/grep -c 'dockernosuchgroup' "$A/activate"
```

Expected: `1` — the group name reaches the generated activation script, which is the property. Running `activate` is not required and would switch the generation.

- [x] **Step 8: Revert the mutation and confirm**

```bash
sed -i 's/^      dockernosuchgroup = "docker-ce/      docker = "docker-ce/' home/bootstrap.nix
/usr/bin/grep -c 'dockernosuchgroup' home/bootstrap.nix
/usr/bin/grep -c '^      docker = "docker-ce' home/bootstrap.nix
```

Expected: `0` then `1`.

- [x] **Step 9: Confirm the assertion count moved**

```bash
/usr/bin/grep -c '^      assertion =' home/bootstrap.nix
```

Expected: `7`, where it read `6` before this task. A bare `grep -c 'assertion'` over the same file reads more, because it also matches comments and the binding itself.

- [x] **Step 10: Commit**

```bash
git add home/bootstrap.nix
git commit -m "bootstrap: groupsFromCorp, for a group a corp package creates"
```

---

### Task 4: the runbook's Stage C block

**Files:**
- Modify: `home/bootstrap.nix` — the `substitutions` attrset, around lines 228-260
- Modify: `bootstrap/runbook.md.in` — the Stage C corp block around lines 326-356
- Modify: `test/vm/steps/30-stage-c.txt` — a new mirrored `usermod` pair

**Interfaces:**
- Consumes: `cfg.groupsFromCorp` from Task 3, `cfg.aptSourcesTransient` and `cfg.aptSources` already present, and `reasonTable` at `home/bootstrap.nix:182`.
- Produces: three new tokens — `@groupsFromCorpComma@`, `@groupsFromCorpTable@`, `@aptTransientCount@`. `requireTokenIn` asserts every token of the set appears in the template, so a token added here and forgotten in the template fails the build.

- [x] **Step 1: Write the failing test — add the tokens before the template uses them**

In `home/bootstrap.nix`'s `substitutions`, after the `@groupsCount@` entry:

```nix
    # Rendered into Stage C, not Stage A. An empty groupsFromCorp must produce
    # NO usermod line at all: `usermod -aG  <user>` with an empty list fails,
    # and it would fail on every machine rather than on a misconfigured one.
    "@groupsFromCorpComma@" = lib.concatStringsSep "," (
      builtins.attrNames cfg.groupsFromCorp
    );
    "@groupsFromCorpTable@" =
      "| group | why it is added here and not in Stage A |\n|---|---|\n"
      + reasonTable cfg.groupsFromCorp;
```

and beside the other apt tokens:

```nix
    # Generated rather than written, because the runbook's own prose said "Two
    # of the four vendor packages" -- a count that was correct when written and
    # goes stale on every vendor added.
    "@aptTransientCount@" = toString (
      builtins.length (builtins.attrNames cfg.aptSourcesTransient)
    );
```

- [x] **Step 2: Build and watch `requireTokenIn` fail**

```bash
sg nix-users -c 'nix build --no-link .#calangoBootstrap' 2>&1 | tail -8
```

Expected: an evaluation failure naming `bootstrap/runbook.md.in` and one of the three new tokens as absent from the template. **This is the failing test for this task.**

- [x] **Step 3: Add the Stage C `usermod` block to the template**

In `bootstrap/runbook.md.in`, after the `sudo apt update` fence that follows the source deletion (currently around line 351) and before the "The other files stay" paragraph:

````markdown
**Now add the group that only exists once docker is installed.** Stage A added
the groups a fresh Debian machine already has. This one is created by
`docker-ce`'s own `postinst`, so it could not have been added there — a
`usermod` naming a group that does not exist fails, and Stage A would have
stopped before installing anything.

```sh
sudo usermod -aG @groupsFromCorpComma@ <user>
```

@groupsFromCorpTable@

The membership takes effect at the **next login**, so `docker ps` in this shell
still fails with a permission error until then. `id -nG <user>` reads the new
group immediately; `id -nG` alone reads the current session's, which is stale.
````

- [x] **Step 4: Make the hard-coded count generated**

In the same file, the paragraph beginning "**Now delete the two colliding source files**" currently reads:

```
write their own source file from their `postinst`, naming a keyring under
```

preceded by `Two of the four vendor packages`. Replace that phrase with the generated form:

```
@aptTransientCount@ of the @aptSourceCount@ vendor packages write their own
source file from their `postinst`, naming a keyring under
```

Check the surrounding sentence still reads correctly after substitution — it renders as `2 of the 5 vendor packages`.

Leave the sentence lower down that reads "Measured: after all four were deleted" **unchanged**. That records a measurement taken on a particular machine on a particular day, and rewriting it would make the record claim something nobody measured.

- [x] **Step 5: Build and confirm the render**

```bash
D=$(sg nix-users -c 'nix build --no-link --print-out-paths .#calangoBootstrap')
/usr/bin/grep -n 'usermod -aG docker' "$D/RUNBOOK.md"
/usr/bin/grep -n 'of the 5 vendor packages' "$D/RUNBOOK.md"
```

Expected: one hit each. If `usermod -aG ,` or `usermod -aG <user>` with nothing between appears, the empty-set case has leaked — stop and fix it.

- [x] **Step 6: Mirror the new line in the step file**

Add to `test/vm/steps/30-stage-c.txt`, after the `sudo apt update` block:

```
#T 60

#= sudo usermod -aG docker <user>
echo "$CALANGO_PW" | command sudo -S -p '' usermod -aG docker "$USER" && id -nG "$USER"
```

The `#= ` line must be the runbook's own text verbatim, `<user>` placeholder included. The line below is the harness's version: it substitutes the real account and prints the resulting group list, so the pass log carries the evidence rather than only an exit status.

- [x] **Step 7: Run the full check**

```bash
sg nix-users -c 'nix flake check' 2>&1 | grep -c '^checking derivation checks\.'
```

Expected: the count read in Task 2, unchanged, and no failure.

- [x] **Step 8: Commit**

```bash
git add home/bootstrap.nix bootstrap/runbook.md.in test/vm/steps/30-stage-c.txt
git commit -m "runbook: add the docker group in Stage C, where it exists"
```

- [x] **Step 9: Prove the empty-set case is handled**

Replace the whole `groupsFromCorp` value block in `home/bootstrap.nix` with the empty form:

```nix
    groupsFromCorp = { };
```

Confirm the set really is empty before building — a mutation that did not apply produces a pass that means nothing:

```bash
sg nix-users -c 'nix eval --json .#homeConfigurations."isutton@suffer".config.calango.bootstrap.groupsFromCorp' | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'
```

Expected: `0`. Then render, and look for the broken command:

```bash
D=$(sg nix-users -c 'nix build --no-link --print-out-paths .#calangoBootstrap')
/usr/bin/grep -n 'usermod -aG  ' "$D/RUNBOOK.md"
```

Expected: **no hit**. A hit means the template renders a `usermod` with an empty group list, which would fail Stage C on every machine. If the render is wrong, the Stage C block needs a conditional in the module rather than an unconditional token — build the whole block in Nix and substitute one token for it.

- [x] **Step 10: Revert and confirm**

```bash
git restore --worktree home/bootstrap.nix
/usr/bin/grep -c '^      docker = "docker-ce' home/bootstrap.nix
```

Expected: `1`. The work of this task is committed, so `git restore --worktree` is safe here.

---

### Task 5: the seven keep entries

**Files:**
- Modify: `home/deb.nix` — `config.calango.deb.keep`, around line 121

**Interfaces:**
- Consumes: nothing from earlier tasks. `keep` is an option `home/deb.nix` declares and three modules contribute to — `home/deb.nix`, `home/audio.nix:683` and `home/slack.nix:58`.
- Produces: seven names in `calango-desktop`'s `Depends`, which Task 7's verification reads out of the built `.deb`.

- [x] **Step 1: Record the count before the change**

```bash
sg nix-users -c 'nix eval --json .#homeConfigurations."isutton@suffer".config.calango.deb.keep' | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'
```

Expected: `21`.

- [x] **Step 2: Add the seven entries**

In `home/deb.nix`, inside `config.calango.deb.keep`, after the `endpoint-verification` entry. Note the comment above `1password-cli` in that file: no reason string may contain the literal Nix store path prefix, because `noStorePaths` greps the rendered manifest. None of these do.

```nix
    docker-ce = "Corp set, permanently apt. dockerd runs from /usr/lib/systemd/system/docker.service, a system unit, and standalone Home Manager writes only ~/.config/systemd/user -- the same architectural reason bluez and rtkit are permanent.";
    docker-ce-cli = "Corp set, permanently apt. A Depends of docker-ce, named here because keep protects the names it holds and not the names those pull.";
    "containerd.io" = "Corp set, permanently apt. The container runtime, a Depends of docker-ce.";
    docker-buildx-plugin = "Corp set, permanently apt. Reaches the machine only as a Recommends of docker-ce-cli, so nothing would hold it if this entry did not.";
    docker-compose-plugin = "Corp set, permanently apt. Also only a Recommends of docker-ce-cli.";
    docker-ce-rootless-extras = "Corp set, permanently apt. A Recommends of docker-ce and auto before this entry, which promotes it to a Depends -- a strengthening nobody measured a need for. It is named because it is installed, not because rootless mode is configured; dockerd runs as a root system service.";
    golang-docker-credential-helpers = "Debian's own archive, not docker.com. Provides docker-credential-secretservice, which ~/.docker/config.json names as its credsStore for a private registry. It has ZERO installed reverse dependencies, so only its apt-mark flag held it, and docker runs it as a subprocess during a login rather than holding it open -- so no /proc walk and no ps union can ever see that it is needed. Its failure arrives later as a registry authentication error.";
```

- [x] **Step 3: Build and confirm the count**

```bash
sg nix-users -c 'nix eval --json .#homeConfigurations."isutton@suffer".config.calango.deb.keep' | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d)); print(" ".join(sorted(k for k in d if "docker" in k or "containerd" in k)))'
```

Expected: `28`, then the seven names.

- [x] **Step 4: Confirm the guards still pass**

```bash
sg nix-users -c 'nix build --no-link .#calangoDeb'
D=$(sg nix-users -c 'nix build --no-link --print-out-paths .#calangoDeb')
/usr/bin/dpkg-deb -f "$D"/*.deb Depends | tr ',' '\n' | wc -l
```

Expected: a clean build — which means `noStorePaths` passed and both `deb.nix` assertions held — and `28`.

- [x] **Step 5: Commit, before the mutation**

```bash
git add home/deb.nix
git commit -m "deb: hold docker and its credential helper by Depends, not by a flag"
```

- [x] **Step 6: Prove `noStorePaths` still guards these reasons**

```bash
sed -i 's|Debian.s own archive, not docker.com.|Debian archive. See /nix/store for nothing.|' home/deb.nix
/usr/bin/grep -cF '/nix/store' home/deb.nix
```

Expected: at least `1`. Use `/usr/bin/grep -F`: the shell's `grep` is ugrep and this count is load-bearing.

```bash
sg nix-users -c 'nix build --no-link .#calangoDeb' 2>&1 | tail -6
```

Expected: the build fails, naming the store-path needle. This is the guard the file's own comment says cost a clean build once.

- [x] **Step 7: Revert and confirm**

```bash
git restore --worktree home/deb.nix
/usr/bin/grep -cF '/nix/store' home/deb.nix
/usr/bin/grep -c 'golang-docker-credential-helpers' home/deb.nix
```

Expected: `0` then `1`.

---

### Task 6: the documentation that is now wrong

**Files:**
- Modify: `home/bootstrap.nix` — the header comment, lines 10-27
- Modify: `README.md` — line 54
- Modify: `CLAUDE.md` — the standing-facts list

**Interfaces:** none. This task changes no behaviour and no test.

- [x] **Step 1: Correct the module header**

`home/bootstrap.nix`'s header says the apt sources are `SCAFFOLDING`, that "afterwards each vendor package writes its own copy from its own postinst", and that "the runbook deletes them immediately after the corp packages install". That was true of two of the four and never of the other two — the `aptSourcesTransient` comment 400 lines below already contradicts it, and docker makes it two of five. Replace the `SCAFFOLDING` paragraph with:

```
#   TRANSIENT    two of the apt sources in Task 2. Chrome's and 1Password's
#                own postinst writes a copy naming a keyring under
#                /usr/share/keyrings, which collides with the inline key here.
#                That collision is an apt ERROR rather than a warning -- two
#                Signed-By values for one repository -- and apt then refuses to
#                read the source list at all, so every later apt command
#                fails. Measured on a bare Debian 13.6 in the spec 18
#                rehearsal. The runbook deletes exactly those two, immediately
#                after the corp packages install.
#
#   DURABLE-BUT- the other sources. microsoft, google-cloud and docker are
#   NOT-STATE    never replaced by anything, so they stay -- deleting one
#                leaves its packages installed with no candidate version at
#                all. They are still not watched for drift: they exist so apt
#                can resolve a vendor, not as a property of the machine.
#
# Which of the two a source is belongs in aptSourcesTransient, not in a
# reader's memory of this comment.
```

Keep the `DURABLE` entry above it, which describes `/etc/greetd/config.toml` and the group memberships, unchanged.

- [x] **Step 2: Correct README.md line 54**

It currently reads, under "What apt still owns":

```
The vendor stack (Google Chrome, docker-ce, 1Password, Google
endpoint-verification, Slack, VS Code), the login path (greetd, tuigreet),
```

That sentence described the machine while reading as a declaration, and docker was the one member of the list the flake did not declare. It is now accurate as written. Add one sentence after the paragraph so a reader knows where the declaration lives:

```
Every member of that vendor stack is declared: `calango.bootstrap.packages.corp`
names the package and its repository, `calango.bootstrap.aptSources` renders the
source file, and `calango.deb.keep` puts it in `calango-desktop`'s `Depends`.
```

- [x] **Step 3: Add the standing fact to CLAUDE.md**

In the "Standing facts about this machine" section, beside the `bluez` and `rtkit` entries:

```markdown
- **`docker` cannot move to Nix,** for the same architectural reason as `bluez`
  and `rtkit`: `dockerd` runs from `/usr/lib/systemd/system/docker.service` and
  `containerd` from `/lib/systemd/system/containerd.service`, both *system*
  units, and standalone Home Manager writes only `~/.config/systemd/user`. As
  of spec 22 the six docker packages and
  `golang-docker-credential-helpers` are held by `calango-desktop`'s `Depends`,
  not by an `apt-mark` flag. None of the six ships a systemd *user* unit, so
  the dangling `/etc/systemd/user` residue trap does not apply to them.

  `golang-docker-credential-helpers` is the member worth knowing about. It
  comes from **Debian's** archive, not from docker.com; it provides
  `docker-credential-secretservice`, which `~/.docker/config.json` names as its
  `credsStore`; and it has **zero** installed reverse dependencies. Docker runs
  it as a subprocess during a login and never holds it open, so no `/proc`
  walk and no `ps -eo args` union can see that it is needed — the same species
  as `libpipewire-0.3-modules` above, and the reason it is declared rather than
  left to a measurement.
```

- [x] **Step 4: Confirm nothing else in CLAUDE.md now contradicts**

```bash
/usr/bin/grep -n 'docker' CLAUDE.md
```

Read every hit. The one at the `gcr4` entry mentions `golang-docker-credential-helpers` as a package `apt-get -s remove gcr4` would take with it; that is still true and needs no edit.

- [x] **Step 5: Commit**

```bash
git add home/bootstrap.nix README.md CLAUDE.md
git commit -m "docs: docker is declared now, and the sources comment says which are transient"
```

---

### Task 7: verification, on a VM and then on suffer

**Files:** none modified. This task produces the results document.

**Interfaces:** consumes everything above.

- [x] **Step 1: The full offline check**

```bash
sg nix-users -c 'nix flake check' 2>&1 | grep -c '^checking derivation checks\.'
sg nix-users -c 'nix flake check' 2>&1 | grep -o 'running [0-9]* flake checks'
```

Expected: the two agree. Read the number; do not compare it against any figure in `CLAUDE.md`.

- [x] **Step 2: The five sources, against their real repositories**

```bash
B=$(sg nix-users -c 'nix build --no-link --print-out-paths .#calangoBootstrap')
./test/apt-sources.sh "$B"
```

Expected: `all 5 source(s) verified`.

- [x] **Step 3: Answer the one unmeasured question — ANSWERED, and it needed no VM**

The spec records that nobody had measured whether `usermod -aG a,b,nosuchgroup` adds `a` and `b` or refuses all three. It refuses all three. Measured 2026-08-21 against a scratch passwd/group tree, with no root and no real account touched:

```bash
mkdir -p "$D/etc"
printf 'probe:x:5000:5000::/home/probe:/bin/sh\n' > "$D/etc/passwd"
printf 'probe:x:5000:\nalpha:x:5001:\nbeta:x:5002:\n'  > "$D/etc/group"
printf 'probe:!:20000:0:99999:7:::\n'                  > "$D/etc/shadow"
printf 'probe:!::\nalpha:!::\nbeta:!::\n'              > "$D/etc/gshadow"

unshare -r /usr/sbin/usermod --root "$D" -aG alpha,beta,nosuchgroup probe
# usermod: group 'nosuchgroup' does not exist        exit 6
cat "$D/etc/group"
# alpha:x:5001:      beta:x:5002:        <- neither gained the member

# CONTROL, so the probe is not vacuous:
unshare -r /usr/sbin/usermod --root "$D" -aG alpha,beta probe
# exit 0
cat "$D/etc/group"
# alpha:x:5001:probe  beta:x:5002:probe
```

Two notes for anyone repeating it. `unshare -r usermod` fails with `No such file or directory`, exit 127, because `usermod` is in `/usr/sbin` and not on this user's `PATH` — that message reads as a missing binary and is a missing path. And the control is the half that makes this an answer: without it, "nothing was added" is equally consistent with the probe never having worked.

The consequence is stronger than the spec assumed. `docker` in `groups` would leave Stage A having added **no group at all** — not `nix-users`, not `video`, not `input` — while the message names only `docker`. The measurement is recorded in the `groupsFromCorp` option's own comment.

- [x] **Step 4: The full VM rehearsal — GREEN, 2026-08-21**

Run against `origin/main` at `3b742e3`, on a fresh disk, 16:24Z to 16:42Z:

```
================ 05-gate-a ================  PASS
================ 10-stage-b ================  PASS
================ 20-gate-b ================  PASS
================ 30-stage-c ================  PASS
================ 40-gate-c ================  PASS
================ 50-stage-d ================  PASS
---- 6 passed, 0 failed ----
GREEN: Stage 0 through Stage D, one uninterrupted pass.
FINAL_PASS_EXIT=0
```

Gate C's own output, including the new group line:

```
ii  calango-desktop
0            <- apt-get -s autoremove | grep -c '^Remv '
present
greetd-ok
1            <- id -nG <user> | tr ' ' '\n' | grep -cx -e docker
```

`0` from `autoremove` is the load-bearing one: all 28 `Depends` are satisfied on a machine that has never had docker, and nothing is orphaned.

**One process note, recorded because it is the trap this harness documents.** The first launch used `setsid nohup ./test/vm/vm final-pass > log 2>&1 &`, which **discards the exit status** — the shape `test/vm/README.md`'s last "do not undo" entry says once reported success for a failed run. It was killed two minutes in and relaunched as `setsid nohup sh -c '…; rc=$?; echo "FINAL_PASS_EXIT=$rc" >> log; exit $rc'`. Detachment itself was correct both times: the harness ran as its own session leader, which is the rule that exists because a forty-minute run was once killed by a SIGTERM from `claude bg-spare`.

The blocker that held this step, resolved by the merge at `3b742e3` and kept because the reasoning applies to every future rehearsal:

`test/vm/steps/10-stage-b.txt:17` clones with no branch argument, so the VM gets whatever `origin/main` points at. Measured 2026-08-21:

```bash
git ls-remote --heads origin | grep -E 'main|docker-corp'
# 4ce3761…  refs/heads/main                          <- origin
# 18e685c…  refs/heads/worktree-docker-corp-vendor   <- this work
git rev-parse main
# 14b3e1a…  <- LOCAL main, 14 commits ahead of origin
```

So a run started now rehearses a tree with neither this work nor the local spec 21 commits, and Gate C's docker line does not exist in it. `test/vm/README.md` says as much — "only `vm final-pass` on a fresh disk, against the *pushed* document, tells you the sequence works". Merge and push first, or the run tests the wrong document and passes.

**And do not start it from a managed background shell.** `test/vm/README.md`'s "things not to undo" list records a forty-minute run killed mid-way by `qemu-system-x86_64: terminating on signal 15 from pid … (claude bg-spare)`. Launch it as that list prescribes and confirm the session id really changed:

```bash
setsid nohup ./test/vm/vm final-pass < /dev/null &
ps -o pid,sid,cmd -p $!    # sid must differ from the calling shell's
```

Expected: Gate D reached on a fresh disk. Read `test/vm/README.md` first — its "things not to undo" list is where this harness's paid-for rules live.

- [x] **Step 5: Confirm docker inside the VM — CONFIRMED from the pass logs, 2026-08-21**

Read out of `~/vm/calango-runbook/out-30-stage-c.log` rather than from a live guest, which carries the same evidence and does not need the VM kept alive:

```
30:  calango-bootstrap-docker.sources            <- the source installed
63:  #= sudo apt install … containerd.io docker-buildx-plugin docker-ce
     docker-ce-cli docker-ce-rootless-extras docker-compose-plugin …
87:  calango-bootstrap-docker.sources            <- SURVIVED the transient rm
117: isutton … nix-users docker                  <- id -nG after the usermod
154: Setting up golang-docker-credential-helpers (0.6.4+ds1-1+b18) …
```

Line 87 is the one worth naming: the docker source is still listed *after* the step that deletes the two transient ones, which is decision 2 proven on a real machine rather than argued from a postinst. Line 154 is decision 4 proven: nothing named the credential helper in `packages.corp`, and the metapackage's `Depends` pulled it from Debian's archive.

The equivalent live-guest commands, if a future run keeps the VM up:

```bash
apt-cache policy docker-ce | head -4
id -nG | tr ' ' '\n' | grep -cx docker
dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' docker-ce containerd.io golang-docker-credential-helpers
```

Expected: the docker.com repository as the source, `1` for the group, and `ii` for all three. The credential helper proves the `keep`-only decision worked: nothing named it in `packages.corp`, and the metapackage install pulled it from Debian's archive.

**That install is the last step of Stage C, not Stage D.** This step said Stage D until the rehearsal disproved it — `test/vm/steps/30-stage-c.txt:64` is the line. The claim was reasoned from the stage names rather than read out of the step file.

- [ ] **Step 6: On suffer — install the rebuilt package**

```bash
D=$(sg nix-users -c 'nix build --no-link --print-out-paths .#calangoDeb')
sudo apt install "$D"/calango-desktop_*.deb
```

Read the removal list before answering. The `Depends` grew by seven names, all of which are already installed, so apt should propose no removal at all.

- [ ] **Step 7: Restore the "held by a Depends, not a flag" invariant**

Six of the seven are `apt-mark manual` on suffer today.

```bash
sudo apt-mark auto docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin golang-docker-credential-helpers
apt-get -s autoremove | grep -c '^Remv '
```

Expected: `0`. If it is not `0`, read what apt proposes and stop — that is a real finding, not a step to force through.

- [ ] **Step 8: Verify by enumeration, not by the total**

`apt-mark showmanual | wc -l` is no help: it moved 370 → 349 across a change of 22 packages once, because one had already been left `auto`. Check each name:

```bash
for p in docker-ce docker-ce-cli containerd.io docker-buildx-plugin \
         docker-compose-plugin docker-ce-rootless-extras \
         golang-docker-credential-helpers; do
  printf '%-36s %s\n' "$p" "$(apt-mark showmanual "$p" | wc -l)"
done
```

Expected: `0` for all seven.

- [ ] **Step 9: Read the keep-set size out of the package**

```bash
/usr/bin/dpkg-deb -f "$D"/*.deb Depends | tr ',' '\n' | wc -l
```

Expected: `28`. Read it; do not predict it from this plan.

- [ ] **Step 10: Confirm the credential helper still works**

```bash
docker-credential-secretservice list
```

Expected: a JSON object, and specifically not `credentials not found` from a missing binary. This exercises the path the whole `keep` entry exists to protect.

- [ ] **Step 11: Write the results document**

`docs/2026-08-21-results-suffer-docker-corp-vendor.md`, following the shape of the existing results documents. It must record:

- Every defect found and its owner.
- The answer to step 3's `usermod` question.
- The `dpkg-deb -f Depends` count as read, not as predicted.
- Whether `apt install` of the rebuilt package proposed any removal.
- That `docker-ce-rootless-extras` moved from `auto`-by-Recommends to a `Depends` of `calango-desktop`, which is a strengthening this work chose deliberately.

- [ ] **Step 12: Commit**

```bash
git add docs/2026-08-21-results-suffer-docker-corp-vendor.md
git commit -m "docs: spec 22 results, and the usermod question answered"
```

---

## Self-review notes

**Spec coverage.** Spec section 1 (key, source, corp packages, header comment) → Tasks 1, 2, 6. Section 2 (`groupsFromCorp`, runbook, drift hook, assertion) → Tasks 3, 4. Section 3 (seven keep entries, the `apt-mark auto` step) → Tasks 5, 7. Section 4 (runbook, harness, tests) → Tasks 2, 4, 7. Decision 6 (docker stays on apt) → Task 6, step 3. The spec's "Future work: the unmanaged dotfiles" is deliberately unimplemented; it is future work and has no task.

**The one thing this plan adds beyond the spec.** Task 4, step 4 makes the runbook's hard-coded "Two of the four vendor packages" generated, with a new `@aptTransientCount@` token. The spec did not name it because the spec did not read that paragraph. It is in scope: it is a count in the file this work edits, and it goes stale on exactly the change this work makes.
