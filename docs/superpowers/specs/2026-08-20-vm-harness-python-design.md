# Spec 20: the VM harness in Python, so its rules can be tested

**Branch:** `vm-harness-python`
**Written:** 2026-08-20
**Status:** design approved in chat; not implemented
**Follows:** spec 19, `docs/superpowers/specs/2026-08-19-generated-preseed-design.md`

---

## The problem

`test/vm/` is the only thing in this repository that answers a question no build
can: does `RUNBOOK.md` work on a machine that has never seen this flake. It is
462 lines of code across eight files, seven of them shell, and **not one line of it is
covered by anything**. `nix flake check` reaches `test/vm/steps/*.txt` through
`vm-step-lines-verbatim` and stops there. The code that drives the install, the
console and the stages is proven only by a forty-minute run against a real VM,
and only for the paths that run happened to take.

That is expensive in the ordinary way — a defect costs a rehearsal rather than a
build — and expensive in a way particular to this harness: **its failures look
like passes.** Spec 19 met four of them. A wrapper that ended `echo "exit=$?"`
reported success for a failed pass. A `pgrep -f` wait loop matched its own
command line and never exited. A `pkill -f` killed the shell that issued it, and
every command after it silently never ran. A step redirected wholesale hid a
debconf prompt and made it unanswerable, and the VM sat at 3% CPU for ten
minutes reading exactly like a hang.

Three of those four are shell-shaped. The fourth is not, and stays.

The harness also carries nine rules in its README under "Nine things not to
undo", each costing a debugging session. Prose is the weakest place to keep a
rule this project has already paid for. Two of the nine can become code, and
three more can become tests.

## Decisions

| # | Decision | Excludes |
|---|---|---|
| 1 | One **importable package** plus one executable with subcommands | A file per entry point; a shell shim for the old names |
| 2 | A **new flake check** runs the unit tests; there is no `selftest` subcommand | Tests that only run when someone remembers |
| 3 | **Transliteration**, except at three points where the shell shape *was* the workaround | A redesign around an object model |
| 4 | `check-steps.sh` is **deleted, not ported** | Two implementations of one assertion |
| 5 | Proof is **a green `final-pass` on a fresh disk**, before any deletion | A cheaper run against the installed VM |

## The layout

```
test/vm/
  vm                    the one executable; argparse, and nothing else
  calangovm/
    __init__.py
    config.py           the five values, their defaults, the derived http port
    qemu.py             argv list, environment strip, the running-VM check
    console.py          the unix socket: read, send, expect, login
    driver.py           step files: parse, substitute, send and wait
    install.py          initrd build, the preseed server, Stage 0
    passes.py           run-all and final-pass
    tests/              standard library unittest; no third-party package
  steps/*.txt           unchanged
  human-answers.cfg     unchanged
  README.md             rewritten
```

`console.py` and `driver.py` are one file today, `drive.py`. The split is what
makes either testable: the console is a protocol and the driver is a policy, and
only separated can the login state machine be driven against a `socketpair` with
no VM anywhere. `drive.py` as it stands cannot even be imported — it reads
`os.environ["CALANGO_VM_SOCK"]` at module level and calls `main()` at the
bottom.

### The CLI

Six subcommands, one for each script that exists today.

| subcommand | replaces |
|---|---|
| `vm install` | `install.sh` |
| `vm boot` | `boot-headless.sh` |
| `vm display` | `run-with-display.sh` |
| `vm drive <steps-file>` | `drive.py` |
| `vm run-all` | `run-all.sh` |
| `vm final-pass` | `final-pass.sh` |

Each of the five configuration values takes a flag; each flag falls back to its
environment variable; that falls back to the default in the table below. So the
README's iteration recipe — four exported variables around a `python3 -u` —
becomes `./test/vm/vm drive steps/30-stage-c.txt`.

| value | flag | environment | default |
|---|---|---|---|
| state directory | `--dir` | `CALANGO_VM_DIR` | `~/vm/calango-runbook` |
| installer image | `--iso` | `CALANGO_VM_ISO` | `~/Downloads/debian-13.6.0-amd64-netinst.iso` |
| guest hostname | `--host` | `CALANGO_VM_HOST` | `calango-vm` |
| throwaway password | `--pw` | `CALANGO_VM_PW` | `rehearsal` |
| forwarded ssh port | `--port` | `CALANGO_VM_PORT` | `2622` |

**The account name gets no flag and no variable**, exactly as now: `config.py`
reads it out of the rendered `preseed.cfg`, which gets it from the flake's
`home.username`. The harness must not be able to disagree with the account the
installer creates.

### Exit codes

`0` green. `1` a stage or a step failed. `2` a precondition failed — no ISO, a
VM already holds the disk, no `nix-users` group. Today the last two exit `1`
alongside real failures, so a caller cannot tell a defect from a machine that
was not ready.

## The three places the shape changes

Everything else is a transliteration, comments included — the comments are the
expensive part of these files and every one of them travels. Three exceptions,
each a shell workaround rather than a decision:

| shell | why it is that shape | Python |
|---|---|---|
| `qemu_common()` echoes one string; callers rely on word splitting | a shell function cannot return a list | an argv `list`, asserted by test |
| `NIXGL_STRIP` is a string prefix, not a function | `exec` cannot run a shell function | an environment `dict`, asserted by test |
| `pgrep -x qemu-system-x86` | a name check must not match itself | read `/proc/*/comm`; the reader is `python3` |

The `/proc/*/comm` form also removes the 15-character guess. `comm` is truncated
at 15 by the kernel, which is why the shell version cannot spell
`qemu-system-x86_64`; reading `comm` directly compares against the truncated
name because that *is* the field being read, rather than in spite of it.

**The check stays machine-wide.** It matches any qemu, not one holding this
disk. A narrower check would have to read `/proc/<pid>/fd`, which is unreadable
for another user's process — and here a false positive ("a VM is already
running") is safe while a false negative is the write-lock failure that reads
like a corrupt image.

## What happens to the nine rules

`test/vm/README.md`'s "Nine things not to undo" is the harness's accumulated
cost. After the port:

| rule | after |
|---|---|
| `python3 -u` | **gone from prose.** `sys.stdout.reconfigure(line_buffering=True)` inside the program, so a caller cannot forget it |
| `exit "$rc"` in a wrapper | **gone from prose.** `raise SystemExit(rc)`; an `echo`'s status cannot win in Python |
| `-vga none` | a unit test: the argv holds `-vga none` and no other `-vga` |
| strip the five nixGL variables | a unit test: exactly those five are absent from the child environment |
| two `GET /preseed.cfg` is the pass | an in-process counter with an exact assertion, not `grep -ac` over a log |
| send nothing before a prompt | stays prose, and gains a unit test against a `socketpair` |
| prompt lines come back, bulk goes to a file | stays prose; it is a fact about apt and a pty |
| guest logs to `~/rl`, never `/tmp` | stays prose; it is a fact about the guest |
| the `sudo` wrapper corrupts stdin | stays prose; it lives in `steps/*.txt`, which this spec does not touch |

Two leave, three become tests, four stay. The README is rewritten around the
seven that remain.

## Guards

### The new flake check

`checks.vm-harness-tests` runs `python3 -m unittest discover` over the package in
the Nix sandbox. No VM, no network, no kvm. The check count moves off seven;
`CLAUDE.md` already instructs a reader to count rather than quote it.

**It needs no vacuity anchor, and that is measured rather than assumed.** Every
other guard in this flake carries one because "the property holds" and "the check
asserted nothing" are indistinguishable. `unittest discover` is the exception —
Python 3.13.5, three cases:

```sh
python3 -m unittest discover              # empty directory
# exit 5, "NO TESTS RAN"
python3 -m unittest discover -s tests     # a test file with no test methods
# exit 5, "NO TESTS RAN"
python3 -m unittest discover -s gone      # the directory is missing
# exit 1, ImportError: Start directory is not importable
```

An unimportable test module is reported as a failing test and exits 1, not
skipped. So a check whose suite has evaporated fails three different ways and
passes none. Do not add an anchor on top of this; do re-measure it if the Python
in the sandbox ever moves major version.

### The new cpio guard

`install.py` builds the appended cpio with `cpio`, then reads it back with a
small newc parser in Python and asserts exactly one member named `preseed.cfg`
with the expected length. The two implementations are independent, so a bug in
one cannot hide inside the other.

Nothing verifies this today. An empty appended archive gives an installer that
asks every question by hand over a serial console — which reads as a hang, and
is the failure spec 19 spent ten minutes on in a different guise.

### The tests

Roughly twenty cases. Standard library only, no `pytest`, matching
`bin/calango-serve-bootstrap`'s precedent.

| module | cases |
|---|---|
| `config.py` | each value falls back flag → environment → default; port 2622 gives http port 8622; the account name is read from a fixture `preseed.cfg` |
| `qemu.py` | `-vga none` present and no other `-vga`; exactly five variables stripped; the running-VM check against a fake `/proc` tree, positive and negative |
| `console.py` | `login` sends nothing until a prompt appears; `expect` raises on timeout and names the tail |
| `driver.py` | `#T` sets the timeout for the block after it; a `#` line is dropped; `@USER@` and `@HOST@` are substituted; a step file that spells an account name literally fails |
| `install.py` | a failed hostname substitution stops the run; a failed password substitution stops the run; the appended cpio holds exactly one `preseed.cfg` |
| `passes.py` | `run-all` stops at the first failure and names the log to read |

**Every test is proven able to fail by mutation, and the plan records which
mutation.** Three checks in this project's history passed while the property
they stood for was false, and all three were caught by mutation or by a
reviewer, never by the check itself.

## Verification

The order is ship, confirm, delete — the same order this project used for the
greetd session entry, and for the same reason: nothing is removed before the
thing replacing it has been proven on a machine that did not exist when the
proof started.

1. Land `calangovm/`, the `vm` executable and the flake check. The seven shell
   files and `drive.py` stay, untouched. Both harnesses work, and the old one
   is the fallback.
2. `sg nix-users -c 'nix flake check'` — the new check runs, and the count is
   re-measured rather than assumed.
3. `./test/vm/vm final-pass` on a fresh disk. About forty minutes, unattended.
   Green means Stage 0 through Stage D in one pass, against the pushed
   `RUNBOOK.md`.
4. A person runs `./test/vm/vm display` and confirms Hyprland comes up. No
   harness can answer this; it is one person and one window.
5. One commit deletes the seven shell files and `drive.py`, rewrites
   `test/vm/README.md`, and edits `CLAUDE.md`.

**Iterating and passing stay different claims.** A `final-pass` assembled out of
fixes proves the fixes; only a clean run on a fresh disk proves the sequence.
Step 3 may be repeated as often as needed while defects are found — the run that
counts is the one with no edits after it.

### `CLAUDE.md` edits, all three re-measured

- The sentence naming `test/vm/check-steps.sh` describes a script that will not
  exist. Rewrite it around `vm-step-lines-verbatim`, which becomes the only
  implementation.
- The check-count passage enumerates the four branches that moved the number.
  It gains a fifth clause. Count with the documented command; do not add one.
- `bar-title-slot` is described as "unlike four of the other six". With one more
  check that phrase is stale. Recount the checks that run this flake's own code
  against those that inspect a built tree; do not adjust by arithmetic.

## Out of scope

- **`steps/*.txt` and `human-answers.cfg` do not change.** They are the
  harness's transcription of the document under test, and
  `vm-step-lines-verbatim` guards them. A port that also edited them would make
  a green run un-attributable.
- **`vm-step-lines-verbatim` stays shell.** It is a Nix builder; a Nix builder
  runs shell. This is why decision 4 deletes the script instead of porting it.
- **Stage 0 keeps its own HTTP server.** `RUNBOOK.md` Stage 0 now tells a reader
  to run `calango-serve-bootstrap`, and the harness does not — so the harness
  tests a Stage 0 the document no longer describes. Nothing catches this:
  `check-steps.sh` covers only `steps/*.txt`, and Stage 0 has no step file. The
  gap is recorded in the new README rather than closed, because the tree's copy
  of that script carries an unsubstituted `#!@python3@` shebang and cannot be
  run from a checkout. Closing it properly is its own piece of work.
- **No new stages, no new reporting, no structured result objects.** The
  extension story is what the package shape buys; spending it now would make the
  diff unreviewable against the originals.

## Risks

| risk | mitigation |
|---|---|
| The port silently loses a rule that only a real run exercises | Every comment travels; the nine README rules are tracked one by one in the table above |
| A new file is untracked, so the flake cannot see it | A flake evaluates only tracked paths. `git add` before the first `nix flake check`, or the new check passes against a directory missing most of what it tests |
| The cpio read-back parser is wrong in the same way the writer is | The writer is `cpio`; only the reader is ours. Independent implementations |
| The console rewrite changes timing and a stage becomes flaky | `console.py` is a transliteration, timeouts included; the split is structural, not behavioural |
| Forty minutes of `final-pass` is spent on a defect a test would have caught | The check runs first, in step 2, before any VM starts |
| The shell fallback is deleted too early | Deletion is step 5, after both a green pass and a person at a window |
