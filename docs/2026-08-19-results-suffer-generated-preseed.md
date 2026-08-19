# Spec 19 — a generated Debian preseed: results

Branch `generated-preseed`, 13 commits. Four tasks, one whole-branch review, one
fix wave, one scoped re-review, one controller fix, and one qemu rehearsal that
found the branch's only defect in a live machine.

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
| 7 | `origin/main` is 33 commits behind and cannot serve this runbook | owner's call |

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

## What is not verified

Stages B to E were not re-run. They are unchanged by this branch, they were
rehearsed for spec 18 from a machine in the state Gate A now certifies, and
running them here would need the credential of finding 6 or the 9p deviation
that hid it. Getting past Stage B on a real new machine needs a push (finding 7)
and a token.

## Reproducing it

```sh
~/vm/spec19-rehearsal/install.sh        # Stage 0, headless, serial-logged
~/vm/spec19-rehearsal/boot-headless.sh
~/vm/spec19-rehearsal/gate-a.py
```

`~/vm/spec19-rehearsal/README.md` says which files are the product and which are
scaffolding; `FINDINGS.md` there is the long form of the table above.
