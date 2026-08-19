# Spec 19 — a generated Debian preseed: results

Branch `generated-preseed`, merged to `main` at `135d4d0`, and three commits
after it that this document's own second rehearsal produced. Four tasks, one
whole-branch review, one fix wave, one scoped re-review, one controller fix, and
**two** qemu rehearsals — the first proving Stage 0, the second running the
whole runbook and finding three defects in it. Count the commits rather than
quoting a number here: `git log --oneline b356777..HEAD | wc -l`.

Nothing here was applied to suffer. The artifact is a file that drives an
installer on hardware that does not exist yet, so its verification is a VM.

## What shipped

`bootstrap/preseed.cfg.in`, rendered by `home/bootstrap.nix` into
`.#calangoBootstrap` beside `RUNBOOK.md`, driving **six** directives:

| directive | from |
|---|---|
| `d-i passwd/username` | `home.username` |
| `d-i pkgsel/include` | `calango.bootstrap.packages.base`, all 12 |
| `tasksel tasksel/first` | fixed: `standard`, never a desktop task |
| `d-i pkgsel/upgrade` | fixed: `none`, declared rather than silent |
| `popularity-contest/participate` | fixed: false |
| `d-i preseed/late_command` | `calango.bootstrap.groups` plus `sudo` |

And nothing else. No partitioning, locale, mirror, timezone or root password —
the spec's central refusal, now guarded at build time by a `runCommand` that
fails on `partman`, `mirror/`, `time/zone`, `passwd/root`,
`debian-installer/locale` or `grub-installer` appearing in the rendered file.
`nix flake check` runs **6** checks; `preseed-package-list` is the sixth.

`RUNBOOK.md` gained Stage 0 and made Stage A conditional on having skipped it.

## The rehearsal

A Debian 13.6 netinst in qemu, the generated `preseed.cfg` served **verbatim out
of the store** (sha256 `60024326…10ab`), on the boot line the document prints:

```
auto=true url=http://10.0.2.2:8019/preseed.cfg
```

The human's 30 answers — every question the preseed refuses to drive — rode in
the initrd rather than on that line, and the reason is finding 1 below. The
install finished in **140 seconds** with no failed step and no dialog.

### Gate A, on the installed machine

```
systemctl is-active nix-daemon.service                                   active
id -nG isutton | tr ' ' '\n' | grep -cx -e nix-users -e video -e input        3
id -nG isutton | tr ' ' '\n' | grep -cx sudo                                 1
id -nG isutton   isutton cdrom floppy sudo audio dip video plugdev users input netdev nix-users
12 of 12 packages ii ; getent group nix-users -> nix-users:x:989:isutton
systemctl --failed | wc -l                                                   0
```

There is no ssh on this machine, on purpose: `tasksel/first` is `standard`, so
Gate A was driven over the serial console. Spec 18's rehearsal added
`ssh-server` as a harness deviation; not adding it here is what exposed
finding 6.

All six predictions written before the run held. Full text in
`~/vm/spec19-rehearsal/PREDICTIONS.md`.

## Defects, findings and their owners

| # | finding | owner |
|---|---|---|
| 1 | 30 preseed answers on the kernel command line **panic the kernel** | harness |
| 2 | `http.log` cannot tell the installer's fetch from the host's own `curl` | instrument |
| 3 | `pkill -f` killed the shell that issued it, exit 144 | operator |
| 4 | `late_command`'s ordering is now **measured**, not reasoned | product, resolved |
| 5 | one of Gate A's three counted groups is added by the installer anyway | product, accepted |
| 6 | **Stage B's clone cannot work as written, and had never been run** | product, fixed |
| 7 | `origin/main` is 33 commits behind and cannot serve this runbook | owner's call, done |
| 8 | **`code`'s postinst asks a debconf question**, against "dpkg asks nothing" | product, fixed |
| 9 | **`./bin/slack-latest` cannot work where Stage C invokes it** | product, fixed |
| 10 | Gate C's four lines joined with `&&` read as a failed gate | method |
| 11 | a redirected step makes a prompt invisible *and* unanswerable | harness |
| 12 | **Stage C stalled forever on `code`'s debconf question** | product, fixed |
| 13 | **Stage D's `activate` was the one nix line not wrapped in `sg`** | product, fixed |
| 14 | the driver typed `echo …` into GRUB, where `e` opens the entry editor | harness |
| 15 | a wrapper ending in `echo` reported success for a failed pass | harness |

Finding 1, in full, because it fails in a way that reads as a hung boot:

```
Kernel panic - not syncing: Too many boot env vars at `apt-setup/cdrom/set-first=false'
```

The kernel hands unrecognised `key=value` cmdline arguments to init as
environment variables and caps how many it takes. The serial log stopped at
11543 bytes. It panics rather than warning, and it names the argument, so the
limit is findable — but nothing warns before it. Not a product defect: the
runbook's own boot line carries two arguments.

Finding 4 settles what `preseed.cfg`'s comment declared unproven:

```
20:00:04 groupadd[30572]: new group: name=nix-users, GID=989
20:00:24 preseed: running preseed command preseed/late_command: in-target usermod -aG nix-users,video,input,sudo isutton
20:00:24 usermod[5560]: add 'isutton' to group 'nix-users'
```

`nix-setup-systemd`'s postinst creates the group during pkgsel, 19 seconds
before `late_command` needs it. The reasoning was right; it is now traced.

Finding 5 is the caveat on Gate A's own numbers. Attributing every group
addition to the pid that made it:

```
usermod[5439..5487]  audio cdrom dip floppy video plugdev netdev   <- user-setup, one pid each
usermod[5560]        input nix-users sudo                          <- late_command, one call
```

`video` arrives whether or not `late_command` runs. The gate still fails
correctly — `usermod -aG` is all-or-nothing, so a dead `late_command` leaves the
count at 1 — but the 3 is not three things this flake did. `sudo` is the clean
signal, and only because this run gave root a real password on purpose:
`passwd -S root` reads `root P`, and `grep -c 'user-setup.*sudo'` on the
installer's log reads 0.

Finding 6 is the one that matters, and it is the branch's only defect in a
document a person follows:

```
GIT_TERMINAL_PROMPT=0 git ls-remote https://github.com/calangotechbv/calango-nix.git HEAD
fatal: could not read Username for 'https://github.com': terminal prompts disabled
```

Measured from the freshly-installed machine and again from suffer. The
repository is not anonymously readable, so Stage B's clone prompts for a
credential the runbook never told the reader to bring. The org and repo names
match `git remote -v`, so it is not a typo, and the paragraph's ordering
argument survives: a **token** can be typed at git's own prompt on a machine
with nothing installed, where the ssh key this project uses lives in an agent
Stage C has not installed. Fixed in `e2c91c0`.

**Spec 18's rehearsal did not catch it because it never ran the command.** Its
own Stage B log shows `git init` output — "Using 'master' as the name for the
initial branch" — so that tree came off the 9p share rather than the network.
The clone line had never been executed in a rehearsal. A stage can be "rehearsed
end to end" and still contain a command nobody has run.

## The second rehearsal — the whole runbook, no 9p share, no ssh

Findings 6 and 7 were cleared by fixing them: the repository was made public and
`main` was pushed, so `origin/main` carries `bootstrap/` and `home/bootstrap.nix`.
A second machine was installed from the merged tree and driven through every
stage over the serial console — **no 9p share and no ssh**, because the share is
exactly the deviation that hid finding 6 for a whole spec.

| stage | result |
|---|---|
| Stage 0 | clean install, **145 s**, no failed step, no dialog |
| Gate A | `active`, `3`, `1`, 12 of 12 `ii`, `nix-users:x:989:isutton`, 0 failed units |
| Stage B | **the clone ran for the first time in this project's history** — anonymous https, landing `135d4d0` with `bootstrap/` and `home/bootstrap.nix` present |
| Gate B | `running 6 flake checks`; `.#calangoBootstrap` = `vr09fy4d…`, **the same store path suffer builds**; `all 4 source(s) verified` |
| Stage C | five corp packages from their real repositories, Slack 4.51.180 from its own feed, the metapackage as `0.0+dirty20260819201602` |
| Gate C | `ii calango-desktop`, `0`, `present`, `greetd-ok` |
| Stage D | first `activate` clean; `uwsm-present`, **0 failed user units**, `home-manager` off `PATH` and `26.05-pre` by full path |
| Gate D | **not run** — its last two lines read `loginctl` and Hyprland's own `/proc/<pid>/environ`, so they need a human at tuigreet |

Four of the document's own claims were confirmed on a machine that had nothing
on it that morning, which is worth as much as the defects:

- **the `Signed-By` collision is real and the deletion is the cure.** Before it,
  `apt update` gave `!= /usr/share/keyrings/google-chrome.gpg` and
  `Error: The list of sources could not be read.`; after it, seven sources
  fetched and all five packages `ii`. `code` and `endpoint-verification` kept
  their candidate versions, which is why their bootstrap files must stay.
- **the ufw trigger needs no maintainer script.** `Processing triggers for ufw`
  fired on install and `/etc/ufw/applications.d/calango` landed. `dpkg -L
  calango-desktop` is exactly four files.
- **nothing prompted about `/etc/default/slack`**, and
  `find /etc -name '*.dpkg-*' -o -name '*.ucf-*'` finds nothing afterwards.
- **`home-manager` really is off `PATH` after the first activate**, exactly as
  Stage D says.

### The three defects it found

**Finding 8.** `code`'s postinst asks `code/add-microsoft-repo` at `db_input
high`, against the runbook's "On a bare machine dpkg asks **nothing** during any
of this". Either answer is safe — `has_existing_repo_source` sees
`calango-bootstrap-microsoft.sources` and suppresses the source write, so only
`/usr/share/keyrings/microsoft.gpg` differs — but the stage stops until someone
answers. That check runs *after* the question, so having the file cannot
suppress the prompt.

**Finding 9.** Stage C said to run `./bin/slack-latest`. In the clone that file
is a template with 6 unsubstituted tokens and exits 1; the substituted copy
appears in `~/.nix-profile/bin` only after Stage D. Measured at exactly that
point: `slack-latest is NOT on PATH`. This is an ordering contradiction rather
than a typo — `slack-desktop` is a hard `Depends` of `calango-desktop`, so Slack
must be installed before the metapackage, which is before Stage D. Stage C now
queries Slack's feed directly.

**Finding 10.** Gate C's four lines, joined with `&&`, abort at line 2:
`apt-get -s autoremove | grep -c '^Remv '` prints `0` and **exits 1**. That read
as a failed gate. The runbook prints them separately for this reason and now
says so out loud. The trap is documented in `CLAUDE.md`; the harness introduced
it anyway.

**Finding 11 is the harness's, and it cost the most time.** Each step's output
went to a file inside the guest so 115200 baud would not be the bottleneck —
which made finding 8's dialog both invisible and unanswerable. The VM sat at 3%
CPU with a silent console for ten minutes. Three compounding errors of the same
kind: the logs went to `/tmp`, which is cleared on boot, so rebooting to
investigate destroyed them; the driver ran without `python3 -u`, so its own
output stayed buffered at zero bytes; and **apt runs maintainer scripts under a
pty**, so redirecting apt's output does not make them non-interactive in the
first place. Recovered from `/var/log/apt/term.log`, which persists.

## The third run — the loop, and one uninterrupted green pass

Findings 8 and 9 were fixed but not *retested* by the second rehearsal, and a
document with a stall in it is not a document that works. So the stages were run
again in a loop: drive, fix what fails, re-run — then **one final pass on a
freshly installed machine, against the pushed document, with no fixes applied
mid-run**. A sequence assembled out of fixes is not evidence that the sequence
works, which is why the two are kept apart.

```
Stage 0 OK: 2 preseed fetches logged        21:55:58 -> 21:58:25
PASS  05-gate-a    PASS  10-stage-b    PASS  20-gate-b
PASS  30-stage-c   PASS  40-gate-c     PASS  50-stage-d
---- 6 passed, 0 failed ----                finished 22:11:52
```

Sixteen minutes, one command (`final-pass.sh`), the clone landing `749aee4`, and
Stage D taking the **wrapped** `sg nix-users -c "$p/activate"` path. Stage C
raised no dialog: `* code/add-microsoft-repo: false` took, and neither
`Package configuration` nor `Configuring code` appears anywhere in its log.

### The two product defects the loop found

**Finding 12.** Stage C stalled indefinitely on `code`'s debconf question, which
finding 8 had documented rather than removed. Stage C now preseeds the answer
before installing:

```sh
echo 'code code/add-microsoft-repo boolean false' | sudo debconf-set-selections
```

`false` is right because `calango-bootstrap-microsoft.sources` already provides
that repository with an inline key. Reading `code.postinst` afterwards showed the
fix is better than "auto-answering": `RET` is fetched by `db_get` at the top of
the script, so `false` short-circuits `WRITE_SOURCE` **before** the `db_input
high` call is reached. The prompt is never raised at all.

**Finding 13.** `"$p/activate"` was the only nix-touching command in the whole
document not wrapped in `sg nix-users -c` — and its failure is **silent**.
`activate:233` is `run --silence nix-store --realise …`, the script's first real
action, and `run --silence` is `"$@" > /dev/null 2>&1`; under `set -eu` the whole
activation aborts with no output. Measured in the VM from a shell with its
supplementary groups cleared:

```
error: getting status of '/nix/var/nix/daemon-socket/socket': Permission denied
```

**Why three rehearsals sailed past it:** on the Stage 0 path the preseed's
`late_command` adds `nix-users` during the install, so the reader's first login
already has the group. The failure belongs to the Stage A path, where `usermod
-aG` runs while the reader is already logged in and Stage D's "log out"
instruction comes *after* the activation. Every rehearsal took the good path. A
document-wide sweep now finds no other unwrapped line.

### The two harness defects, which are the more instructive pair

**Finding 14.** `final-pass.sh` drove the console the instant the socket
appeared, while **GRUB** still owned it — and the driver's probe began `echo`,
whose first character is GRUB's "edit this entry" key. A whole final pass sat in
the bootloader; the traceback showed `grub.cfg` being echoed back. Every earlier
run escaped by accident, because a few unrelated tool calls had given GRUB time
to time out. The driver now sends **nothing** until it has seen a prompt, and a
bare newline is the only thing it will send blind: it boots in GRUB, reprints at
a getty, prints a prompt in a shell.

**Finding 15.** That failed run was reported to the controller as **exit code
0**, because the wrapper ended `./final-pass.sh > log 2>&1; echo "exit=$?"` and
the compound command's status was the `echo`'s. It was caught by reading the log
instead of the status — the same species as every check-that-cannot-fail in this
project's history, in the reporting layer rather than in a guard.

### The tooling

It is **`test/vm/` now**, imported the same day it was written, because it had
already been written from scratch twice and each rewrite paid again for the same
traps. `test/vm/README.md` carries the method, the declared accommodations and
the nine things not to undo.

Three things changed in the move, and they are the difference between a script
that worked once and a tool:

- the account name is not configurable. `vm_username` reads it out of the
  rendered `preseed.cfg`, which gets it from the flake's `home.username`, so the
  harness cannot disagree with the account the installer creates.
- the hostname and the throwaway password are substituted into the initrd
  preseed from the environment, with two guards that fail the run if the
  substitution did not take. No step file spells an account or a host any more.
- the weakness the note flagged is now a guard that fails the build. The step
  files transcribe the runbook's commands, so each mirrored line carries the
  runbook's own text above it as a `#= ` comment, and
  `checks.vm-step-lines-verbatim` asserts all 33 appear verbatim in the rendered
  `RUNBOOK.md`. `nix flake check` runs **seven** checks now. Both failure
  branches were proven by mutation — a changed line is named, and stripping every
  `#= ` line fires the vacuity anchor rather than reporting "0 of 0 verified".

The imported copy was then run end to end from the repository before being
trusted: `ok 33 step lines`, `Stage 0 OK`, six of six stages, GREEN.

## The desktop, verified by a person

The machine the green pass produced was booted with a display on 2026-08-19 and
**the desktop came up: greetd offered the session, the login worked, and Hyprland
is running.** That is the step no harness here could answer, and it closes the
runbook end to end — Stage 0 through Stage D by measurement, the desktop itself
by one person and one window.

Not captured, and worth knowing that it was not: Gate D's two exact command
outputs, `loginctl show-session … -p Type` and the `LIBGL_DRIVERS_PATH` count out
of the compositor's own `/proc/<pid>/environ`. The desktop rendering *is* strong
evidence for both — the session is wayland or Hyprland would not have started,
and a compositor without the nixGL variables aborts rather than draws — but that
is an inference, not the two numbers. Anyone repeating this should type them in a
terminal inside the session.

## What is not verified

`fresh-editor` was installed from a file served by the host rather than fetched
upstream — the one declared deviation in this run, and out of scope by decision.
It has since left `home/deb.nix`'s `keep` and
`calango.bootstrap.packages.corp` entirely, taking the keep set 22 → 21.

## Reproducing it

```sh
./test/vm/final-pass.sh        # fresh disk, install, boot, every stage
./test/vm/run-with-display.sh  # then log in and look at it
```

`test/vm/README.md` says which files are the product and which are scaffolding,
and `test/vm/drive.py` carries findings 10, 11 and 14 as comments on the lines
that fix them. The two scratch directories these runs used --
`~/vm/spec19-rehearsal` and `~/vm/spec19-full` -- are superseded and can be
deleted; the harness rebuilds either from nothing in about twenty minutes.
