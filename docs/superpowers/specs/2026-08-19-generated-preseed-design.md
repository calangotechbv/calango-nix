# Spec 19: a generated Debian preseed, so Stage A stops being typed

**Branch:** `generated-preseed`
**Written:** 2026-08-19
**Status:** design approved in chat; not implemented
**Follows:** spec 18, `docs/superpowers/specs/2026-08-19-bare-debian-bootstrap-design.md`

---

## The problem

Spec 18's runbook opens with a stage that installs twelve apt packages, adds a
user to four groups, and branches on whether the Debian installer happened to
put that user in `sudo`. Every one of those facts is already declared in
`home/bootstrap.nix`. A reader retypes them into a root shell.

That stage is also where spec 18's rehearsal found the most:

- `sudo` was missing from `packages.base`, and Stage C died at its first command.
- `fuse3` was missing, and the bootstrap ended with a failed unit.
- The `sudo`-versus-`su -` branch exists only because the installer's root
  password answer decides it.

Debian's answer file — **preseed**, its kickstart analogue — can do all of it at
install time, from the same declarations. The parts of Stage A that a human
retypes become a file the flake renders.

## Decisions

| # | Decision | Excludes |
|---|---|---|
| 1 | The flake **renders `preseed.cfg`** into `calangoBootstrap`; the reader serves it | A rebuilt ISO, a permanent server on suffer, hand-copying into a running installer |
| 2 | It drives **packages, groups and the account name — never the disk** | Partitioning, locale, mirror, timezone, root password |
| 3 | Proof is **the full runbook end to end** against a preseed-installed machine | A cheaper Gate-A-only run |

## What it renders

Three lines, each from a value the flake already holds. Nothing is written twice.

| preseed line | derived from |
|---|---|
| `d-i pkgsel/include string …` | `calango.bootstrap.packages.base` — 12 names, counted, not quoted |
| `d-i preseed/late_command string in-target usermod -aG …` | `calango.bootstrap.groups`, plus `sudo` |
| `d-i passwd/username string …` | `config.home.username` |

### What it refuses to render, which is the important half

No partitioning, no locale, no mirror, no timezone, no root password. Those stay
the installer's own prompts.

**This is not caution for its own sake.** They are decisions about a physical
disk, and suffer is LUKS-encrypted (`/dev/mapper/luks-…`), so a generated recipe
would either not match this project's own convention or would have to encode
encryption and apply it unattended to hardware. The one irreversible step in the
whole bootstrap stays where a human can see it.

### One branch disappears entirely

`late_command` adds `sudo` alongside the three groups, so the "did root get an
empty password" branch in Stage A stops mattering. That branch is where spec
18's two missing packages bit, and where the residual finding it parked lived.

## The measurement that changed the design

The design first carried a gate proving the packages had actually landed —
because if `pkgsel/include` merely warned on an unavailable package, a typo in a
generated list would ship a machine quietly missing one, and Stage A's absence
would make that silent.

**It does not warn. It fails the install step and stops.** Measured before the
spec was written, with the real twelve-package list plus one name that cannot
exist, on a Debian 13.6 netinst in qemu:

```
[!!] Select and install software
     Installation step failed
     An installation step failed. You can try to run the failing item
     again from the menu, or skip it and choose something else. The
     failing step is: Select and install software
```

The installer halts at that dialog. So a typo cannot produce a running machine
that is missing a package, Gate A's existing count is sufficient, and **the extra
gate was removed from this design rather than written.**

## Stage A does not disappear; it becomes conditional

**The preseed cannot replace Stage A, and a spec that claimed otherwise would be
wrong.** It only helps someone installing Debian from scratch. A machine that is
already installed — by someone else, on rented hardware, or `epiphany` after a
reinstall someone else drove — has no installer left to preseed.

So the runbook gains a stage ahead of Debian existing, and the old one becomes
conditional:

- **Stage 0 — before Debian is installed.** Serve the rendered file, boot the
  installer with `auto=true priority=critical url=…`, answer the disk and locale
  prompts.
- **Stage A — as root.** Unchanged, and headed *skip this if you installed with
  the generated preseed*.

Both paths stay. The runbook says which one the reader is on.

## Delivery

The rendered file sits in `calangoBootstrap` beside `RUNBOOK.md`. The runbook
gives the two commands that serve it and the one that consumes it:

```sh
B=$(sg nix-users -c 'nix build --no-link --print-out-paths .#calangoBootstrap')
(cd "$B" && python3 -m http.server 8000)
```

and, at the installer's boot prompt on the new machine:

```
auto=true priority=critical url=http://<this-machine>:8000/preseed.cfg
```

This needs a second machine on the same network, which is exactly the situation:
the reader is already looking at the runbook on one machine while installing on
another. Nothing new is built, nothing listens permanently, and no ISO is
repacked or resigned.

**The store path is read-only, so `python3 -m http.server` in it works and
cannot be written to.** That is a property worth stating rather than assuming: a
served directory that a stranger could write to would be a different thing
entirely.

## Guards

| guard | property | where | proven by |
|---|---|---|---|
| `pkgsel/include` agreement | the rendered line names exactly the `packages.base` keys | `checks` | hand-editing the template's package line |
| `packages.base` non-empty | the vacuity anchor it does not have today | `assertions` | forcing the option to `{ }` |
| preseed tokens | no `@token@` survives, and none is deleted from the template | builder + `lib.hasInfix` throw | adding `@nosuchtoken@`; deleting one that is substituted |

The first guard's real job is not to catch a divergence between two
declarations — both sides come from one option, so they cannot diverge on their
own. It is to catch a **hand-edit of the template** or a mis-rendered token,
which is how a generated file stops being generated.

**`packages.base` has no vacuity anchor today**, verified rather than assumed:

```sh
/usr/bin/grep -c 'packages.base != { }' home/bootstrap.nix   # 0  -- no anchor
/usr/bin/grep -c 'assertion' home/bootstrap.nix              # 8  -- the WORD
/usr/bin/grep -c '^      assertion =' home/bootstrap.nix     # 5  -- the assertions
```

An empty list would render a `pkgsel/include` line naming nothing, and the
preseed would install a bare Debian while appearing to have worked.

**This spec's first draft said "eight existing assertions", and that was the
word count, not the thing.** Five of those eight lines are `assertion =`
bindings; the other three are the word inside a message or a comment. It is
recorded here because `CLAUDE.md` gives the identical warning about
`grep -n 'assertions' home/*.nix` returning six across two bindings and four
prose mentions, and the warning did not stop the same mistake being made one
file away from it. Count the thing, and read the lines.

## Verification

**The full runbook end to end against a preseed-installed machine**, Stage 0
through Gate E, ending at a live compositor. Roughly an hour, and mostly
re-treading spec 18's ground on the same commits.

The reason to pay that rather than stop at Gate A: nobody has a specific
hypothesis about how a preseed-installed machine differs from a hand-installed
one, and that is exactly the condition under which spec 18's rehearsal found
five defects nobody had a hypothesis for either.

Two things the run must record, because they are the difference from spec 18's:

- **Whether `late_command`'s `usermod` really lands.** It runs `in-target`
  before the first boot, where the group database exists but no session does.
  `nix-users` is created by `nix-setup-systemd`'s postinst, so the ordering
  inside `pkgsel` versus `late_command` is load-bearing and unmeasured.
- **Gate A with no Stage A run at all.** The count must read 3 and `sudo` must
  be present, from the preseed alone.

## Out of scope

- **A rebuilt ISO.** Decision 1. It would need isolinux and grub menu edits for
  both BIOS and UEFI, and would leave an unsigned image.
- **A service on suffer.** This flake has never run anything that listens, and
  a one-off `http.server` is enough for a bootstrap that happens rarely.
- **Encrypted or LVM partition recipes.** Decision 2.
- **`kickseed`.** Debian can consume real Kickstart files through it, which is a
  compatibility layer for people arriving from Red Hat. Nobody here is, and it
  would add a second format to keep honest.
- **FAI.** Debian's class-based installation framework is far more capable than
  preseed and is the right answer for a fleet. This is one machine occasionally.

## Risks

1. **`late_command` ordering against `nix-users`.** If the group does not exist
   when `usermod` runs, the preseed silently produces a machine whose user is
   missing it — and Gate A catches that, which is why Gate A stays.
2. **The served URL is the reader's own machine.** `http://<this-machine>:8000`
   means an address the new machine can reach, which is not always what the
   reader expects on a laptop with a captive-portal network. The runbook should
   say to check reachability before booting the installer, not after.
3. **A preseed is unauthenticated over HTTP.** It is served on a LAN for the
   minutes an install takes, and it contains no secret. Worth stating so nobody
   later assumes it is safe to leave running.
