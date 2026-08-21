# Spec 22 — docker declared like the other corp vendors: results

Branch `worktree-docker-corp-vendor`, merged to `main` at `3b742e3`, plus
`worktree-docker-stage-correction` at `5d451b9` carrying the rehearsal's own
finding. Count the commits rather than quoting a number:
`git log --oneline 14b3e1a..main | wc -l`.

Seven tasks planned, six implemented in one pass, one qemu rehearsal, and the
suffer-side install. Every guard added here was proven able to fail by
mutation, with the mutation confirmed by a count *before* the build ran.

## What shipped

| artifact | what it is |
|---|---|
| `bootstrap/keys/docker.asc`, `.fpr` | the armored signing key, fingerprint `9DC858229FC7DD38854AE2D88D81803C0EBFCD88`, one public key |
| `calango-bootstrap-docker.sources` | the fifth vendor source, **durable** — no `aptSourcesTransient` entry |
| six `packages.corp` entries | `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`, `docker-ce-rootless-extras` |
| seven `calango.deb.keep` entries | those six plus `golang-docker-credential-helpers` |
| `calango.bootstrap.groupsFromCorp` | a **second** group option, for groups a corp package creates |
| two runbook tokens | `@groupsFromCorpSection@`, `@groupsFromCorpGateLine@` |
| one new assertion | `groups` and `groupsFromCorp` disjoint — the seventh in `home/bootstrap.nix` |
| one widened drift hook | it now loops over both group lists |

The source's two unusual fields are correct and commented as such:
`Suites: trixie` is a **codename**, because docker's repository has no `stable`
suite, and `stable` is the **component**. That reads as a transposition error
and is not one.

## The rehearsal

`./test/vm/vm final-pass`, fresh disk, against `origin/main` at `3b742e3`,
16:24Z to 16:42Z:

```
05-gate-a PASS   10-stage-b PASS   20-gate-b PASS
30-stage-c PASS  40-gate-c PASS    50-stage-d PASS
---- 6 passed, 0 failed ----
GREEN: Stage 0 through Stage D, one uninterrupted pass.
FINAL_PASS_EXIT=0
```

Gate C, including the line this spec added:

```
ii  calango-desktop
0            <- apt-get -s autoremove | grep -c '^Remv '
present
greetd-ok
1            <- id -nG <user> | tr ' ' '\n' | grep -cx -e docker
```

The `0` is the load-bearing reading: all 28 `Depends` satisfied on a machine
that had never had docker, and nothing orphaned.

**Both decisions this spec turned on are now measured rather than argued.**
From `out-30-stage-c.log`: line 87 lists `calango-bootstrap-docker.sources`
*after* the step that deletes the two transient sources — decision 2, the
source is durable. Line 154 shows `Setting up
golang-docker-credential-helpers` with nothing naming it in `packages.corp` —
decision 4, a `keep` entry both installs and protects.

## What suffer reads now

```
calango-desktop                       ii  0.389   (was 0.273)
Depends                               28          (was 21)
docker-ce … golang-docker-credential-helpers   0 manual, all seven
dpkg -V calango-desktop               (no output)
docker-credential-secretservice list  {"registry.gitlab.internal.dropsolid.com":"igor.sutton@dropsolid.com"}
```

The last line is the one worth having: it exercises the path the whole
`golang-docker-credential-helpers` keep entry exists to protect, and it is the
only check here that could not be done in the VM.

The install proposed **no removal**: `1 upgraded, 0 newly installed, 0 to
remove`.

Nothing touched suffer's own `/etc/apt/sources.list.d/docker.sources`, which
predates this work. That is correct — the `calango-bootstrap-*` files are
scaffolding for an install that has not happened on this machine.

## Defects, and their owner

**1. The runbook's group block was piece-wise, and an empty set rendered two
failing commands. Mine, found by mutation before it shipped.** The first token
design substituted a comma-joined list and a grep-args list separately. With
`groupsFromCorp` emptied, the render was

```
sudo usermod -aG  <user>
id -nG <user> | tr ' ' '\n' | grep -cx        # 0
```

— two commands that *fail* rather than do nothing, on every machine rather
than on a misconfigured one. A piece-wise token cannot express "and if there
is nothing, say nothing". Two block-wise tokens replaced four piece-wise ones,
and the empty render was re-measured: no `usermod` with a blank list, no bare
`grep -cx`.

**2. Both design documents said Stage D installs the metapackage. Mine, found
by the rehearsal.** It is the last step of **Stage C** —
`test/vm/steps/30-stage-c.txt:64`. The mechanism was exactly as designed; the
stage was reasoned from the stage names rather than read out of the step file,
which is the shape this project keeps paying for. Corrected at `5d451b9`.

**3. The plan misread the harness's `#T` directive. Mine, found before any
edit.** It said to raise the timeout below the corp `apt install`.
`test/vm/calangovm/driver.py:24-36` sets the timeout for every block *after*
the directive, so `#T 3000` already governed that step and `#T 300` governed
the `rm` below it. No timeout changed.

**4. A `git restore --worktree` discarded uncommitted work. Mine, and the trap
this project documents.** The block-token restructure of defect 1 was not yet
committed when a mutation was reverted, and the restore took it from the index.
It was reapplied, and the rebuilt store path was byte-identical to the
pre-loss build, which is how the reapplication was proven exact rather than
merely plausible. The rule the plan itself states — commit the real work before
its mutation tests — was written and then not followed.

## Two things the instruments said that were not true

**`wc -l` read 27 for a 28-entry `Depends`.** `dpkg-deb -f` ends its output
with a newline and `dpkg-query -W -f='${Depends}'` does not, and `wc -l` counts
newlines rather than lines:

```sh
/usr/bin/dpkg-deb -f "$D"/*.deb Depends | tr ',' '\n' | wc -l          # 28
dpkg-query -W -f='${Depends}' calango-desktop | tr ',' '\n' | wc -l    # 27
```

Both hold the same 28 entries — `diff` of the two sorted lists is empty. Sort
supplies the missing final newline, which is why normalising made them agree.
A count taken over `${Depends}` is one low unless the output is normalised
first.

**`ps -p` found nothing for a `setsid` launch that had succeeded.** `setsid`
exits after spawning, so the pid the shell echoes is the wrapper's, not the
harness's. The run was alive the whole time under a different pid. Ask
`ps -eo comm` for the process, not `ps -p` for the pid you were handed.

## The `usermod` question, answered

Spec 22's design recorded as unmeasured whether `usermod -aG a,b,nosuchgroup`
adds `a` and `b` or refuses all three. **It refuses all three**, exit 6.
Measured against a scratch passwd/group tree, with no root and no real account
touched:

```sh
unshare -r /usr/sbin/usermod --root "$D" -aG alpha,beta,nosuchgroup probe
# usermod: group 'nosuchgroup' does not exist        exit 6
# etc/group afterwards: alpha and beta gained NOTHING

# CONTROL, without which "nothing was added" and "the probe never ran" are
# indistinguishable:
unshare -r /usr/sbin/usermod --root "$D" -aG alpha,beta probe   # exit 0
# etc/group afterwards: alpha:x:5001:probe  beta:x:5002:probe
```

So the consequence is worse than the design assumed: `docker` put in `groups`
would leave Stage A having added **no group at all** — not `nix-users`, not
`video`, not `input` — while the message named only `docker`. A partial
application would at least show up as a missing group. This is recorded in the
`groupsFromCorp` option's own comment.

`unshare -r usermod` fails with `No such file or directory`, exit 127, because
`usermod` lives in `/usr/sbin` and is not on this user's `PATH`. That message
reads as a missing binary and is a missing path.

## Open

**`fresh-editor` is an orphan as of this install, and the decision was not
taken.** 0.273 held it through `Depends`; 0.389 does not, because it left the
keep set on 2026-08-19. It is still `ii 0.4.7-1`, it is `auto`, it has zero
installed reverse dependencies, and `apt-get -s autoremove` proposes removing
it:

```sh
apt-get -s autoremove | grep '^Remv '
# Remv fresh-editor [0.4.7-1]
```

Nothing removes it until someone runs `apt autoremove`. `sudo apt-mark manual
fresh-editor` keeps it; doing nothing lets the next `autoremove` take it. This
is exactly the shape CLAUDE.md's most expensive entry describes — an unmarked
orphan goes at some later sweep, where the breakage gets attributed to whatever
changed most recently. Recorded here rather than resolved silently.

**Gate D's last two lines still need a login at tuigreet.** The rehearsal's own
closing line says so; a green `final-pass` means Stage 0 through Stage D, and
the desktop is one manual step beyond it.

**`~/.docker/config.json` is owned by nothing**, and this spec's decision 4
depends on the `credsStore` value in it. Deliberately not managed here: a
`home.file` entry would take ownership of a file docker rewrites on `docker
login`. Spec 22's "Future work: the unmanaged dotfiles" says what a later spec
should do instead — survey the class, not this one file.

**The suite is hard-coded.** `trixie` is a codename and nothing in this flake
declares a Debian release to derive it from, so the next Debian major breaks
the source. `test/apt-sources.sh` catches it, and only when a person runs it.
