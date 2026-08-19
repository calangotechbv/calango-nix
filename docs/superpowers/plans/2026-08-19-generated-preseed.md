# Generated Debian Preseed Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render a Debian preseed from the declarations the flake already holds,
so the runbook's Stage A stops being retyped into a root shell.

**Architecture:** `home/bootstrap.nix` gains a third rendered file alongside
`RUNBOOK.md` and the greetd config: `preseed.cfg`, built from
`calango.bootstrap.packages.base`, `.groups` and `config.home.username` through
the same Nix-level `builtins.replaceStrings` machinery the runbook uses. The
runbook gains a Stage 0 for installing Debian with it, and its Stage A becomes
conditional. Nothing new is built and nothing listens: the reader serves the
rendered file with `python3 -m http.server` for the minutes an install takes.

**Tech Stack:** Nix flakes, standalone Home Manager (`release-26.05`), the Nix
module system, `pkgs.runCommand`, `builtins.replaceStrings`, debian-installer
preseed (`auto=true priority=critical url=…`), qemu with KVM.

**Spec:** `docs/superpowers/specs/2026-08-19-generated-preseed-design.md`

## Global Constraints

Copied from the spec and from `CLAUDE.md`. Every task's requirements include
this section.

- **Wrap every `nix` and `home-manager` invocation:** `sg nix-users -c 'nix …'`.
  A process without that group fails on `/nix/var/nix/daemon-socket/socket`.
- **Use `/usr/bin/grep` explicitly, with `-F` for a literal, whenever a count is
  load-bearing.** The interactive `grep` is ugrep-backed and silently returns `0`
  for a pattern containing `${`.
- **Count the thing, not the word, and read the lines.** This spec's own draft
  said "eight assertions" where `grep -c 'assertion'` is 8 and
  `grep -c '^      assertion ='` is 5. `CLAUDE.md` gives the identical warning
  one file away and it still happened.
- **Substitute in Nix, never with `substituteInPlace`.** Its replacement value
  lands inside a single-quoted shell argument, so an apostrophe closes the quote
  and the builder dies with `unexpected EOF while looking for matching '`. The
  reason strings contain apostrophes.
- **In a Nix builder, test by condition** — `if grep -n … >&2; then … exit 1; fi`
  — never `n=$(grep -c …)`. Builders run with `-e` and `pipefail`, and for a
  negative check no-match is the PASS.
- **Every guard carries a vacuity anchor**, and every guard is proven by
  mutation with **the mutation confirmed by measurement before the build runs**.
- **`git add` a new file before you build.** Flake evaluation reads the
  git-tracked tree, so an unstaged new file fails with `path … does not exist`.
- **Revert a mutation with `git restore --worktree <path>`. Never add
  `--staged`**, which changes the source to HEAD and discards uncommitted work or
  deletes a file new to this task. Never `git checkout <path>`, which on a staged
  file restores the mutation and reports success. **Re-read the file after every
  revert and confirm the count the step gives.**
- **`git restore --worktree` restores from the INDEX, so commit or stage your real
  work BEFORE you mutate anything.** With real edits unstaged, the revert throws
  them away along with the mutation, silently and with no error — measured on this
  branch, where Task 2's implementer lost its edits mid-task and caught it only
  because a grep count disagreed. The rule is one order: finish the work, commit
  it, then mutate.
- **`checks.${system}` and `packages.${system}` are DYNAMIC keys.** A second
  binding through one is `error: dynamic attribute … already defined`, not a
  merge. A new check goes INSIDE the existing attrset.
- **No apostrophe inside a single-quoted shell body in a builder or an
  activation hook** — it closes the quote.
- **There is no test framework here.** A "test" is a build, a measurement, or a
  mutation.
- Match each file's voice: long comments explaining WHY, citing a measurement.

---

## File Structure

| file | responsibility |
|---|---|
| `bootstrap/preseed.cfg.in` **(create)** | The preseed template, with `@tokens@` for the three generated values and prose comments explaining every stanza. Data, not a module. |
| `home/bootstrap.nix` **(modify)** | Generalise `requireToken`; add the preseed's substitutions, its rendered derivation and its token guard; add it to `bootstrapTree`; add the `packages.base` vacuity anchor. |
| `flake.nix` **(modify)** | One new check, `preseed-package-list`, INSIDE the existing `checks.${system}` attrset. |
| `bootstrap/runbook.md.in` **(modify)** | A new Stage 0; Stage A's heading and opening made conditional. |
| `docs/2026-08-…-results-suffer-generated-preseed.md` **(create, at close-out)** | The results document, written from the rehearsal. |

`bootstrap/` is already a data directory consumed by one module, which is how
`hypr/`, `foot/`, `gtk/` and `quickshell/` work here.

---

## Task 1: Generalise `requireToken`, then render the preseed

**Files:**
- Create: `bootstrap/preseed.cfg.in`
- Modify: `home/bootstrap.nix`

**Interfaces:**
- Consumes: `config.calango.bootstrap.packages.base` (`attrsOf str`),
  `.groups` (`listOf str`), `config.home.username` (`str`).
- Produces: `preseedText` and a `preseed` derivation in the module's `let`
  block, and `requireTokenIn : str -> str -> str -> str` replacing
  `requireToken`. Task 2 consumes the rendered file's path inside
  `config.calango.bootstrapDir`.

- [ ] **Step 1: Read the machinery you are extending, and note the trap in it**

```sh
sed -n "/  requireToken =/,+6p" home/bootstrap.nix
```

You will see the message hardcodes one filename:

```nix
      throw "runbook token ${tok} is not in bootstrap/runbook.md.in";
```

**Reusing this for the preseed would report a missing preseed token against the
runbook's filename.** That is the defect this project catalogues most — a message
asserting something untrue — so the first change generalises it.

- [ ] **Step 2: Replace `requireToken` with `requireTokenIn`**

Find the binding and replace it with:

```nix
  # Takes the FILE as well as the token, because there are two templates now and
  # a message naming the wrong one is worse than no message. The single-file
  # version hardcoded bootstrap/runbook.md.in in its throw, so a missing preseed
  # token would have been reported against the runbook.
  requireTokenIn =
    file: tok: body:
    if lib.hasInfix tok body then
      body
    else
      throw "token ${tok} is not in ${file}";
```

Then update the runbook's one call site, which currently reads
`lib.foldl' (body: tok: requireToken tok body)`:

```nix
        lib.foldl' (body: tok: requireTokenIn "bootstrap/runbook.md.in" tok body)
          (builtins.readFile ./../bootstrap/runbook.md.in)
          (builtins.attrNames substitutions)
```

- [ ] **Step 3: Create `bootstrap/preseed.cfg.in`**

Three `@tokens@`, and prose that says why each stanza is there or deliberately
absent. `<user>` and `<host>` are NOT used here — the account name is generated,
because the flake knows it.

```
# Debian preseed for a calango-nix machine, generated by home/bootstrap.nix.
#
# This file drives the three things the flake already declares -- the Stage A
# package list, the group memberships, and the account name -- and REFUSES to
# drive the disk. Partitioning, locale, mirror, timezone and the root password
# are the installer's own prompts, and they stay that way on purpose: they are
# decisions about a physical disk, and suffer is LUKS-encrypted, so a generated
# recipe would either not match this project's convention or would have to apply
# encryption unattended to hardware.
#
# Serve it and boot the installer against it:
#
#   B=$(sg nix-users -c 'nix build --no-link --print-out-paths .#calangoBootstrap')
#   (cd "$B" && python3 -m http.server 8000)
#
#   auto=true priority=critical url=http://<this-machine>:8000/preseed.cfg
#
# It is unauthenticated http on a LAN for the minutes an install takes, and it
# contains no secret. Do not leave it running afterwards.

# The account name is generated from the flake's home.username, because
# everything later resolves through it: the generation is built for
# <user>@<host>, and a mismatch here means nothing in Stage B applies.
d-i passwd/username string @username@

# Stage A's package list, generated from calango.bootstrap.packages.base.
#
# An unavailable name here FAILS the install rather than warning. Measured on a
# Debian 13.6 netinst with one deliberately bogus name added to the real list:
#
#   [!!] Select and install software
#        Installation step failed
#        The failing step is: Select and install software
#
# The installer halts at that dialog. That is why this file needs no separate
# gate proving the packages landed -- a typo cannot produce a running machine
# that is missing one.
d-i pkgsel/include string @basePackages@

# No desktop task. The desktop is Nix's, and tasksel's would install a second one.
tasksel tasksel/first multiselect standard
d-i pkgsel/upgrade select none
popularity-contest popularity-contest/participate boolean false

# The group memberships, generated from calango.bootstrap.groups, plus sudo.
#
# sudo is here and not only in the group list because Stage C runs sudo from the
# account's own shell. Without this line the runbook has to branch on whether
# the installer put the user in sudo, which it does only when root was given an
# empty password -- and that branch is where spec 18's rehearsal found two
# missing packages.
#
# in-target runs inside the installed system, after pkgsel, so nix-users exists:
# it is created by nix-setup-systemd's postinst, which pkgsel has already run.
# Gate A is what proves that ordering held, and it stays for exactly that reason.
d-i preseed/late_command string in-target usermod -aG @groupsWithSudo@ @username@
```

- [ ] **Step 4: Add the substitutions and the rendered derivation**

In `home/bootstrap.nix`'s `let` block, after the runbook's `substitutions`
attrset, add a second one. Keep them separate: a token belonging to one template
must not silently satisfy the other's presence check.

```nix
  # A SECOND substitutions attrset, deliberately not merged with the runbook's.
  # requireTokenIn asserts every token of a set appears in its template, so a
  # merged set would demand the runbook carry @username@ and the preseed carry
  # @corpPackagesTable@ -- and each would then have to grow a token it has no
  # use for.
  preseedSubstitutions = {
    "@username@" = config.home.username;
    "@basePackages@" = lib.concatStringsSep " " (builtins.attrNames cfg.packages.base);
    # sudo is appended to the declared groups rather than added to the option:
    # calango.bootstrap.groups is what the DESKTOP needs, and the drift check
    # reports on it. sudo is what Stage C needs, which is a different question.
    # NOT named @groupsComma@: the runbook's own substitutions attrset already
    # has that token, holding cfg.groups WITHOUT sudo, and its template uses it.
    # Two different values must not share one token name -- a reader seeing it in
    # either template could not tell which they get, and moving a line between
    # templates would silently change behaviour.
    "@groupsWithSudo@" = lib.concatStringsSep "," (cfg.groups ++ [ "sudo" ]);
  };

  preseedText =
    builtins.replaceStrings (builtins.attrNames preseedSubstitutions)
      (builtins.attrValues preseedSubstitutions)
      (
        lib.foldl' (body: tok: requireTokenIn "bootstrap/preseed.cfg.in" tok body)
          (builtins.readFile ./../bootstrap/preseed.cfg.in)
          (builtins.attrNames preseedSubstitutions)
      );

  preseed =
    pkgs.runCommand "calango-bootstrap-preseed"
      { src = pkgs.writeText "preseed-substituted.cfg" preseedText; }
      ''
        cp "$src" "$out"

        # The same token guard the runbook carries. A CONDITION, not a bare
        # command: a builder runs with errexit and a grep matching nothing exits
        # 1, which here is the PASSING case.
        if grep -n '@[a-zA-Z]*@' "$out" >&2; then
          echo "" >&2
          echo "An unsubstituted token survived in the preseed." >&2
          echo "  Either add it to home/bootstrap.nix's" >&2
          echo "  preseedSubstitutions attrset, or remove it from" >&2
          echo "  bootstrap/preseed.cfg.in." >&2
          exit 1
        fi
      '';
```

- [ ] **Step 5: Add it to the tree**

In `bootstrapTree`, after the `cp ${runbook}` line:

```nix
    cp ${preseed} "$out/preseed.cfg"
```

- [ ] **Step 6: Stage the new file and build**

```sh
git add bootstrap/preseed.cfg.in home/bootstrap.nix
B=$(sg nix-users -c 'nix build --no-link --print-out-paths .#calangoBootstrap')
find "$B" -type f | sort
```

Expected: seven files — the greetd config, four apt sources, `RUNBOOK.md` and
`preseed.cfg`.

- [ ] **Step 7: Read the rendered file end to end**

```sh
cat "$B/preseed.cfg"
```

Confirm by eye, and then by command, that all three generated values landed:

```sh
# Count TOKEN-SHAPED @…@, not bare @: the template's own prose says
# "<user>@<host>", which is a literal @ and must not be read as a stray token.
/usr/bin/grep -cE '@[a-zA-Z]+@' "$B/preseed.cfg"           # 0
/usr/bin/grep -o 'd-i passwd/username string .*' "$B/preseed.cfg"
/usr/bin/grep -o 'd-i pkgsel/include string .*' "$B/preseed.cfg" \
  | sed 's|^d-i pkgsel/include string ||' | tr ' ' '\n' | /usr/bin/grep -c .
/usr/bin/grep -o 'usermod -aG [^ ]*' "$B/preseed.cfg"
# and confirm the two token names did not get crossed:
/usr/bin/grep -c '@groupsComma@' bootstrap/preseed.cfg.in     # 0 -- that one is the runbook's
/usr/bin/grep -c '@groupsWithSudo@' bootstrap/preseed.cfg.in  # 1
```

Expected: `0` token-shaped matches; the username `isutton`; **12** packages; and
`usermod -aG nix-users,video,input,sudo`.

**Strip the directive before counting the packages, and count non-empty fields.**
An earlier version of this step piped the whole matched line through
`tail -n +5`, which drops one package because `d-i pkgsel/include string` is
three words, not four. It read 11 against a real 12 — a count that looks
plausible and is wrong, which is the shape this project keeps paying for.

**A generated file nobody has read is a file nobody can run.** If any rendered
line is wrong, that is a finding about the template, and finding it here is the
point of this step.

- [ ] **Step 8: Prove the token guard can fail**

```sh
sed -i 's|^d-i pkgsel/upgrade select none|d-i pkgsel/upgrade select none @nosuchtoken@|' bootstrap/preseed.cfg.in
/usr/bin/grep -c '@nosuchtoken@' bootstrap/preseed.cfg.in     # 1
sg nix-users -c 'nix build --no-link .#calangoBootstrap' 2>&1 | tail -8
git restore --worktree bootstrap/preseed.cfg.in
/usr/bin/grep -c '@nosuchtoken@' bootstrap/preseed.cfg.in     # 0
```

Expected: the build fails naming `@nosuchtoken@` and its line number, and the
message names `bootstrap/preseed.cfg.in`, not the runbook.

- [ ] **Step 9: Prove `requireTokenIn` names the right file**

This is the trap Step 2 exists for, so it gets its own mutation.

**`@username@` appears TWICE in the template** — in the `passwd/username` line
and in the `late_command` line — and `lib.hasInfix` is satisfied by a single
surviving occurrence. A mutation that removes only one proves nothing, so remove
both and confirm the count is 0 before building:

```sh
sed -i 's|@username@|GENERATED|g' bootstrap/preseed.cfg.in
/usr/bin/grep -c '@username@' bootstrap/preseed.cfg.in        # 0 -- BOTH gone
sg nix-users -c 'nix build --no-link .#calangoBootstrap' 2>&1 | tail -4
git restore --worktree bootstrap/preseed.cfg.in
/usr/bin/grep -c '@username@' bootstrap/preseed.cfg.in        # 2 -- both restored
```

Expected: **evaluation** fails with
`error: token @username@ is not in bootstrap/preseed.cfg.in`. If the message
names `bootstrap/runbook.md.in`, Step 2 was not applied.

- [ ] **Step 10: Prove the runbook's own guard still names the runbook**

Generalising a shared helper can break the caller you were not thinking about.

```sh
sed -i 's|@groupsCount@|GENERATED|' bootstrap/runbook.md.in
/usr/bin/grep -c '@groupsCount@' bootstrap/runbook.md.in      # 0
sg nix-users -c 'nix build --no-link .#calangoBootstrap' 2>&1 | tail -4
git restore --worktree bootstrap/runbook.md.in
/usr/bin/grep -c '@groupsCount@' bootstrap/runbook.md.in      # 1
```

Expected: `error: token @groupsCount@ is not in bootstrap/runbook.md.in`.

- [ ] **Step 11: Commit**

```sh
git add bootstrap/preseed.cfg.in home/bootstrap.nix
git commit -m "bootstrap: render a Debian preseed from what the flake declares

Stage A's twelve packages, the group memberships and the account name are
already declared here, and a reader retypes them into a root shell. The preseed
takes all three at install time from the same values.

It refuses the disk. Partitioning, locale, mirror, timezone and root password
stay the installer's prompts, because they are decisions about a physical disk
and suffer is LUKS-encrypted.

requireToken became requireTokenIn, taking the file as well as the token: its
throw hardcoded bootstrap/runbook.md.in, so a missing preseed token would have
been reported against the runbook. Both callers' messages proven by mutation.

An unavailable package name fails the install rather than warning -- measured,
'The failing step is: Select and install software' -- so the file needs no gate
of its own beyond Gate A's existing count."
```

---

## Task 2: The two guards the spec requires

**Files:**
- Modify: `home/bootstrap.nix` (the `packages.base` vacuity anchor)
- Modify: `flake.nix` (the `preseed-package-list` check)

**Interfaces:**
- Consumes: `config.calango.bootstrapDir` from Task 1, which now contains
  `preseed.cfg`; `config.calango.bootstrap.packages.base`.
- Produces: `checks.x86_64-linux.preseed-package-list`. Nothing later consumes
  it.

- [ ] **Step 1: Confirm the anchor is missing before adding it**

```sh
/usr/bin/grep -c 'packages.base != { }' home/bootstrap.nix     # 0
/usr/bin/grep -c '^      assertion =' home/bootstrap.nix       # 5
```

Count the assertions, not the word: `grep -c 'assertion'` reads 8 because three
of those lines are the word inside a message or comment.

- [ ] **Step 2: Add the vacuity anchor**

Inside the existing `config.assertions` list, as a new element:

```nix
    {
      # Without this, an empty packages.base renders `d-i pkgsel/include string`
      # with nothing after it. The preseed would install a bare Debian, the
      # install would succeed, and Stage A's absence would make the omission
      # silent -- which is the one failure mode the loud pkgsel behaviour does
      # NOT protect against, because there is no name for it to fail on.
      assertion = cfg.packages.base != { };
      message = ''
        calango.bootstrap.packages.base is empty, so the generated preseed's
        pkgsel/include line would name no packages and the runbook's Stage A
        would install none. The install would still succeed, which is what
        makes this worth an assertion rather than a gate.
      '';
    }
```

- [ ] **Step 3: Prove it can fail**

```sh
sed -i 's|^    packages.base = {|    packages.base = lib.mkForce { } // {|' home/bootstrap.nix
/usr/bin/grep -c 'lib.mkForce { } // {' home/bootstrap.nix     # 1
sg nix-users -c 'nix build --no-link .#homeConfigurations."isutton@suffer".activationPackage' 2>&1 | tail -6
git restore --worktree home/bootstrap.nix
/usr/bin/grep -c 'lib.mkForce { } // {' home/bootstrap.nix     # 0
```

**If that mutation produces a Nix type or syntax error rather than the
assertion's message, it has not tested the guard.** Spec 16 lost two rounds to
exactly that. In that case use this instead, which cannot be a type error:

```sh
python3 - <<'EOF'
p="home/bootstrap.nix"; s=open(p).read()
a="    packages.base = {"
assert a in s
s=s.replace(a, "    packages.base = { };\n    _unusedBase = {", 1)
open(p,"w").write(s)
EOF
/usr/bin/grep -c '_unusedBase' home/bootstrap.nix              # 1
sg nix-users -c 'nix build --no-link .#homeConfigurations."isutton@suffer".activationPackage' 2>&1 | tail -6
git restore --worktree home/bootstrap.nix
/usr/bin/grep -c '_unusedBase' home/bootstrap.nix              # 0
```

Read the failure message and confirm it is the assertion's own.

- [ ] **Step 4: Add the `preseed-package-list` check to `flake.nix`**

`checks.${system}` is a **dynamic** key, so this goes INSIDE the existing
attrset, never as a second `checks.${system}.x = …;` binding — two bindings
through one computed key are `error: dynamic attribute 'x86_64-linux' already
defined` rather than a merge.

```nix
        # The rendered preseed's pkgsel/include line must name exactly the
        # packages.base keys.
        #
        # Both sides come from one option, so they cannot diverge on their own.
        # The guard's real job is a hand-edit of bootstrap/preseed.cfg.in -- the
        # moment someone types a package name into the template instead of the
        # module, the file stops being generated and starts being a copy that
        # drifts.
        preseed-package-list =
          let
            declared = builtins.attrNames
              suffer.config.calango.bootstrap.packages.base;
          in
          pkgs.runCommand "preseed-package-list" { } ''
            f=${suffer.config.calango.bootstrapDir}/preseed.cfg

            # The vacuity anchor. Without it, a preseed that had lost the line
            # entirely would compare an empty list against an empty list.
            if ! grep -q '^d-i pkgsel/include string ' "$f"; then
              echo "The preseed has no pkgsel/include line at all." >&2
              echo "  This check would then compare nothing with nothing." >&2
              exit 1
            fi

            sed -n 's|^d-i pkgsel/include string ||p' "$f" | tr ' ' '\n' \
              | grep -v '^$' | sort > rendered
            printf '%s\n' ${lib.escapeShellArgs declared} | sort > declared

            if ! diff -u declared rendered; then
              echo "" >&2
              echo "The preseed's pkgsel/include line does not match" >&2
              echo "  calango.bootstrap.packages.base. Left is the option," >&2
              echo "  right is the rendered file. Do not fix this by editing" >&2
              echo "  bootstrap/preseed.cfg.in -- the line is generated, and a" >&2
              echo "  name typed into the template is a copy that will drift." >&2
              exit 1
            fi
            echo "ok  $(wc -l < declared) package(s) agree"
            touch "$out"
          '';
```

- [ ] **Step 5: Count the checks, and build the new one alone**

```sh
sg nix-users -c 'nix flake check' 2>&1 | /usr/bin/grep -o 'running [0-9]* flake checks'
sg nix-users -c 'nix build --no-link .#checks.x86_64-linux.preseed-package-list' 2>&1 | tail -3
```

Count the checks; do not compare against a number written down anywhere. This
task adds one, so `CLAUDE.md`'s figure moves and Task 4 updates it.

- [ ] **Step 6: Prove the check can fail, by hand-editing the template**

This is the exact scenario the guard exists for.

**Keep `@basePackages@` somewhere in the file, or this mutation tests the wrong
guard.** Deleting the token outright makes `requireTokenIn` throw at evaluation
with `error: token @basePackages@ is not in bootstrap/preseed.cfg.in`, and the
build never reaches the check you are trying to test. Measured — an earlier
version of this step did exactly that, while Step 7 below already explained the
same interaction. Park the token in a trailing comment:

```sh
sed -i 's|^d-i pkgsel/include string @basePackages@|d-i pkgsel/include string git greetd  # was @basePackages@|' bootstrap/preseed.cfg.in
/usr/bin/grep -c 'string git greetd' bootstrap/preseed.cfg.in   # 1
/usr/bin/grep -c '@basePackages@' bootstrap/preseed.cfg.in      # 1 -- still present, so the
                                                                #      token guard stays quiet
sg nix-users -c 'nix build --no-link .#checks.x86_64-linux.preseed-package-list' 2>&1 | tail -12
git restore --worktree bootstrap/preseed.cfg.in
/usr/bin/grep -c 'string git greetd' bootstrap/preseed.cfg.in   # 0
```

Expected: the check fails, and the `diff -u` names the ten missing packages.
Build the single check, not the whole `nix flake check` — another check failing
first would not have tested this one, and neither does a build that dies at
evaluation before any check runs.

- [ ] **Step 7: Prove the check's own vacuity anchor can fail**

```sh
sed -i 's|^d-i pkgsel/include string @basePackages@|# removed: @basePackages@|' bootstrap/preseed.cfg.in
/usr/bin/grep -c '^d-i pkgsel/include string ' bootstrap/preseed.cfg.in   # 0
sg nix-users -c 'nix build --no-link .#checks.x86_64-linux.preseed-package-list' 2>&1 | tail -5
git restore --worktree bootstrap/preseed.cfg.in
/usr/bin/grep -c '^d-i pkgsel/include string @basePackages@' bootstrap/preseed.cfg.in   # 1
```

Expected: `The preseed has no pkgsel/include line at all.` Note the token is
kept inside a comment so the token guard stays satisfied and this mutation tests
the anchor rather than the other guard.

- [ ] **Step 8: Commit**

```sh
git add home/bootstrap.nix flake.nix
git commit -m "bootstrap: guard the preseed's package list, and anchor packages.base

The rendered pkgsel/include line must name exactly the packages.base keys. Both
sides come from one option so they cannot diverge on their own; the guard's real
job is a hand-edit of the template, which is how a generated file stops being
generated. Proven by editing the template to name two packages and watching the
diff report the other ten.

packages.base had no vacuity anchor, verified rather than assumed. An empty list
renders a pkgsel/include line naming nothing, the install still succeeds, and
with Stage A skipped the omission is silent -- the one case the loud pkgsel
failure cannot catch, because there is no name for it to fail on.

The check carries its own anchor too: a preseed that had lost the line entirely
would otherwise compare an empty list against an empty list."
```

---

## Task 3: Stage 0 in the runbook, and Stage A made conditional

**Files:**
- Modify: `bootstrap/runbook.md.in`

**Interfaces:**
- Consumes: nothing new. The runbook's existing tokens are unchanged, and the
  preseed's tokens live in the other template.
- Produces: nothing later consumes it.

- [ ] **Step 1: Add Stage 0, before the existing Stage A**

Insert immediately after the `Each stage ends with a **gate**` paragraph and its
`---` rule, before `## Stage A`:

```markdown
## Stage 0 — before Debian is installed

Skip this whole stage if the machine already has Debian on it. **It is the one
stage that cannot be done afterwards**, and it exists to make Stage A
unnecessary rather than easier.

The generated `preseed.cfg` beside this file drives Debian's installer through
the three things this flake already declares: the Stage A package list, the
group memberships, and the account name. Serve it from the machine you are
reading this on:

```sh
B=$(sg nix-users -c 'nix build --no-link --print-out-paths .#calangoBootstrap')
(cd "$B" && python3 -m http.server 8000)
```

Then boot the new machine from a Debian 13 netinst image and, at the boot menu,
edit the kernel command line to add:

```
auto=true priority=critical url=http://<this-machine>:8000/preseed.cfg
```

`<this-machine>` is an address the new machine can reach — check that before you
boot the installer rather than after, because a laptop on a captive-portal
network often cannot.

**Answer the installer's disk, locale, mirror and timezone prompts yourself.**
The preseed deliberately drives none of them: they are decisions about a
physical disk, and a recipe generated by this flake would either not match the
encryption this project uses or would apply encryption unattended to hardware.

**What it saves you.** The whole of Stage A, including the branch on whether the
installer put your account in `sudo` — the preseed adds that group itself. An
unavailable package name fails the install loudly rather than shipping a machine
missing one, measured: `The failing step is: Select and install software`.

Stop the `http.server` when the install finishes. It is unauthenticated, and it
has nothing more to serve.

### Gate 0

There is none, and that is deliberate: Gate A below is the gate for this stage
too. It counts the groups and checks the daemon on the installed machine, which
is the only place either can be observed.

---
```

- [ ] **Step 2: Make Stage A conditional**

Change the heading and add one paragraph immediately under it:

```markdown
## Stage A — as root, and only if you skipped Stage 0

**If you installed with the generated preseed, this whole stage is already
done — go to Gate A and confirm it.** What follows is for a machine that was
already installed when you got it: someone else's install, rented hardware, or a
reinstall you did not drive.
```

- [ ] **Step 3: Rebuild and read both stages end to end**

```sh
git add bootstrap/runbook.md.in
B=$(sg nix-users -c 'nix build --no-link --print-out-paths .#calangoBootstrap')
sed -n '/^## Stage 0/,/^## Stage B/p' "$B/RUNBOOK.md"
```

Read it as prose, as the person at the keyboard. Confirm the served URL, the
kernel command line and the `http.server` command are each runnable as written.

- [ ] **Step 4: Confirm the stage claim in the header is still true**

The runbook's opening says each stage ends with a gate. Stage 0 deliberately has
none, so that sentence is now false unless it is qualified.

```sh
/usr/bin/grep -n 'Each stage ends with a' "$B/RUNBOOK.md"
```

Amend it to name the exception, in `bootstrap/runbook.md.in`:

```markdown
Each stage from A onward ends with a **gate**. Run it. Do not go on until it
answers as shown. Stage 0 has no gate of its own because nothing it does can be
observed until the machine has booted — Gate A is its gate too.
```

Rebuild and confirm:

```sh
B=$(sg nix-users -c 'nix build --no-link --print-out-paths .#calangoBootstrap')
/usr/bin/grep -c 'Each stage from A onward' "$B/RUNBOOK.md"    # 1
/usr/bin/grep -cE '@[a-zA-Z]+@' "$B/RUNBOOK.md"                # 0
```

- [ ] **Step 5: Commit**

```sh
git add bootstrap/runbook.md.in
git commit -m "runbook: a Stage 0 that installs Debian, and Stage A made conditional

The preseed does not replace Stage A -- a machine already installed has no
installer left to preseed -- so both paths exist and the runbook says which one
the reader is on. Stage 0 is headed as skippable and Stage A as conditional.

Stage 0 has no gate, and the header's claim that every stage ends with one is
amended to say so rather than left false. Gate A is Stage 0's gate: it counts
the groups and checks the daemon on the installed machine, which is the only
place either can be observed."
```

---

## Task 4: The documentation counts

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: the check count from Task 2 and the runbook changes from Task 3.
- Produces: nothing.

- [ ] **Step 1: Derive every figure before writing any of them**

```sh
ls -1 docs/*results-suffer-*.md | wc -l
sg nix-users -c 'nix flake check' 2>&1 | /usr/bin/grep -o 'running [0-9]* flake checks'
sg nix-users -c 'nix flake check' 2>&1 | /usr/bin/grep -c '^checking derivation checks\.'
/usr/bin/grep -c '^      assertion =' home/bootstrap.nix
```

**The spec count must NOT be incremented.** This branch writes its results
document at close-out, not now; until that file exists the authority command's
answer is unchanged, and `CLAUDE.md` opens with a standing instruction to count
rather than increment.

- [ ] **Step 2: Update `CLAUDE.md`'s check count and path list**

Update the `nix flake check` figure to the measured number, and add
`bootstrap/preseed.cfg.in` to the list of paths whose change requires re-running
the checks — the list that already names `bootstrap/greetd-config.toml` and
`bootstrap/runbook.md.in`.

- [ ] **Step 3: Record the two measurements worth keeping**

In the "Tools that answer a different question than the one asked" section, add:

```markdown
**`pkgsel/include` fails the install on an unavailable package; it does not
warn.** Measured on a Debian 13.6 netinst with one bogus name added to a real
twelve-package list:

    [!!] Select and install software
         Installation step failed
         The failing step is: Select and install software

The installer halts at that dialog rather than producing a machine missing a
package. That is why the generated preseed carries no gate of its own for the
package list — and why `calango.bootstrap.packages.base` needs a vacuity anchor
instead: an EMPTY list renders a `pkgsel/include` line with no names, which
installs successfully and fails nothing.
```

And in the assertions enumeration, note `home/bootstrap.nix` now carries six
rather than five, with the sixth being `packages.base` non-empty — and that the
count of the word `assertion` in that file is a different, larger number.

- [ ] **Step 4: Point `README.md` at Stage 0**

Its Bootstrap section currently gives five commands and points at the runbook.
Add one sentence: a machine that has not had Debian installed yet should start
at the runbook's Stage 0, which drives the installer from the same declarations.

- [ ] **Step 5: Look for anything else this branch moved and nobody updated**

```sh
/usr/bin/grep -n 'five flake checks\|four flake checks\|assertions' CLAUDE.md | head
/usr/bin/grep -n 'RUNBOOK\|preseed' README.md CLAUDE.md | head
```

Read each hit. `CLAUDE.md`'s own opening rule is that a remembered list of names
silently excuses whatever is not on it; report anything you find and did not
change, and why.

- [ ] **Step 6: Verify the whole tree, then commit**

```sh
sg nix-users -c 'nix flake check' 2>&1 | /usr/bin/grep -o 'running [0-9]* flake checks'
sg nix-users -c 'nix build --no-link .#calangoBootstrap' && echo bootstrap-ok
sg nix-users -c 'nix build --no-link .#calangoDeb' && echo deb-ok
B=$(sg nix-users -c 'nix build --no-link --print-out-paths .#calangoBootstrap'); ./test/apt-sources.sh "$B"
sg nix-users -c 'home-manager switch --flake .#isutton@suffer' 2>&1 | tail -6
```

```sh
git add CLAUDE.md README.md
git commit -m "docs: the check count moves, and two preseed measurements are recorded

pkgsel/include fails the install on an unavailable package rather than warning,
measured on a 13.6 netinst. That is why the generated preseed needs no gate for
its package list -- and why packages.base needs a vacuity anchor instead, since
an EMPTY list renders a line with no names, installs cleanly, and fails nothing.

Every figure re-derived with the command CLAUDE.md prescribes. The spec count is
NOT incremented: this branch writes its results document at close-out."
```

---

## After the plan: the user's steps

The rehearsal cannot be done from this session — it needs a qemu install driven
by the generated file, and the decision to run it is the user's.

### Step 1 — the full runbook, end to end, from Stage 0

Spec 19's verification decision. The harness from spec 18 is at
`~/vm/spec18-rehearsal/`, and this run needs a **fresh disk**, because a machine
that has already been bootstrapped cannot test Stage 0:

```sh
D=~/vm/spec19-preseed
mkdir -p "$D"; cp ~/vm/spec18-rehearsal/{lib-qemu.sh,vmlinuz,initrd.gz,id_rehearsal,id_rehearsal.pub} "$D"/
qemu-img create -f qcow2 "$D/disk.qcow2" 40G
mkdir -p "$D/http" && cp "$(sg nix-users -c 'nix build --no-link --print-out-paths .#calangoBootstrap')"/preseed.cfg "$D/http/"
```

Two things the generated preseed does **not** carry that spec 18's harness one
did, and both must be added to the served copy for an unattended run — as
harness deviations, recorded as such:

- the partitioning, locale, mirror and timezone answers, since the generated
  file deliberately refuses them and an unattended run has nobody to answer them;
- the `late_command` line that installs the ssh key, so the run can be driven at
  all. The generated file already uses `late_command` for `usermod`, so the two
  must be **combined into one directive**: a second `d-i preseed/late_command`
  line replaces the first rather than adding to it.

**That last claim is measured, not reasoned.** A preseed line is loaded through
debconf, and debconf holds one value per key, so the test is at that layer rather
than needing an installer:

```sh
printf 'd-i preseed/late_command string echo ONE\nd-i preseed/late_command string echo TWO\n' > two.cfg
DEBCONF_SYSTEMRC=./scratch.conf debconf-set-selections two.cfg
DEBCONF_SYSTEMRC=./scratch.conf debconf-communicate d-i <<< 'GET preseed/late_command'
# 0 echo TWO          <- the second line won; the first is gone
```

The scratch database's own file agrees: `Value: echo TWO`. So a harness that adds
its ssh-key line as a second directive would silently lose the `usermod`, and
Gate A would then report two groups instead of three — which reads exactly like
the ordering risk in the spec rather than like a harness mistake. Combine them,
and say in the results document which shape was used.

### Step 2 — what the run must record

- **Gate A with no Stage A run at all.** The group count must read 3 and `sudo`
  must be present, from the preseed alone.
- **Whether `late_command`'s `usermod` really landed**, which is risk 1: it runs
  `in-target` before the first boot, and `nix-users` is created by
  `nix-setup-systemd`'s postinst during `pkgsel`. If the ordering is wrong, the
  group is missing and Gate A is what catches it.
- **Stages B through E**, per the verification decision, ending at a live
  compositor with the five nixGL variables and `libgallium` in its maps.
- **Whether a preseed-installed machine differs from a hand-installed one** in
  any way at all. Nobody has a hypothesis, which is exactly the condition under
  which spec 18's rehearsal found five defects.

### Step 3 — the close-out

Write `docs/2026-08-…-results-suffer-generated-preseed.md` from the run, then
update `CLAUDE.md`'s spec count — **counted with
`ls -1 docs/*results-suffer-*.md | wc -l`, never incremented.** That file records
a spec landing with the wrong number because someone added one to it.
