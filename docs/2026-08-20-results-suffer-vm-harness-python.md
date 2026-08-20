# Spec 20 — the VM harness in Python: results

Branch `vm-harness-python`. Six code tasks, each with an independent review, four
fix rounds, and one uninterrupted green pass on a disk the run created itself.
Count the commits rather than quoting a number here:
`git log --oneline main..HEAD | wc -l`.

Nothing here was applied to suffer. The artifact is test tooling; its
verification is the thing it tests.

## What shipped

`test/vm/calangovm/`, six modules and an executable, replacing seven shell
scripts and `drive.py`:

| module | replaces | what it holds |
|---|---|---|
| `config.py` | `lib-qemu.sh` | five values, three derived, the store path, the account name |
| `qemu.py` | `lib-qemu.sh` | argv as a list, the nixGL strip as a dict, `/proc/*/comm` |
| `console.py` | `drive.py:28-78` | the unix socket, and the login that must not type |
| `driver.py` | `drive.py:80-131` | step files: parse, substitute, wrap, send, wait |
| `install.py` | `install.sh` | the initrd, the newc read-back guard, Stage 0 |
| `passes.py` | four wrappers | boot, display, run-all, final-pass, stop |

`./test/vm/vm` carries eight subcommands. `nix flake check` gained
`vm-harness-tests` and now runs **8** checks — count it, do not quote it.

## The pass

One command, on a disk that did not exist when it started:

```
######## Stage 0 -- the generated preseed  (11:27:15Z)
Stage 0 OK: 2 preseed fetches logged
PASS  05-gate-a   PASS  10-stage-b   PASS  20-gate-b
PASS  30-stage-c  PASS  40-gate-c    PASS  50-stage-d
---- 6 passed, 0 failed ----
GREEN: Stage 0 through Stage D, one uninterrupted pass.   (11:43:21Z)
```

Sixteen minutes. **It is a pass and not an iteration**, and that was checked
rather than asserted: `git log` showed zero commits since before the run began
and the working tree had zero modified files, so the sequence ran against the
committed tree with no edit before, during or after it.

Gate A's four readings are the whole case for the generated preseed:
`nix-daemon` active, groups **3**, sudo **1**, packages **12**.

### Stage 0 finished in 2m19s, which had to be checked rather than believed

A Debian netinst that installs a dozen packages finishing that fast is the shape
of a step that did not happen. It did happen:

```
Select and install software      1
Installing GRUB                  1
Finishing the installation       1
[  139.603662] reboot: Restarting system
```

139s of guest time matches the wall clock and `disk.qcow2` grew to 1.8G. It is
fast because the preseed installs only the `standard` task plus twelve packages,
under KVM with four cores — no desktop, nothing compiled.

**Carry this:** `install()`'s failure check greps for `Installation step failed`
and `Kernel panic` only. A fast pass is not evidence of a skipped install, and it
is not evidence of a complete one either. The three completion markers above are.

## Defects, findings and their owners

Every review found something. Four are worth carrying beyond this branch.

### 1. A guard that was inert under the tool's own defaults — `check_answers`

`human-answers.cfg`'s placeholders **are** `config.DEFAULTS`' values, and the
guard counted password lines by substring. Two consequences, both reproduced:

```
unrendered file vs the DEFAULTS (calango-vm / rehearsal):  PASSES
unrendered file vs pw="reh":                               PASSES
    while the four lines on disk still read: password rehearsal
```

The second is a false pass with a real cost: `vm install --pw reh` would report
success, install `rehearsal`, and leave the driver unable to log in — the exact
failure the guard exists to prevent.

Fixed in two parts, because one is not enough. Exact-line assertions kill the
substring case. Asserting the six `# CALANGO_VM_HOST` / `# CALANGO_VM_PW`
markers are gone kills the default case, since those markers occur 2 and 4 times
in the raw file, 0 and 0 after rendering, and sit on exactly the substituted
lines. A test anchors the markers themselves, so tidying a comment out of that
data file cannot weaken the guard silently.

**The obvious fix would have broken the common run.** A default-configuration
render produces values *equal* to the placeholders and must still be accepted;
"reject anything matching the placeholder" closes the vacuity by rejecting the
most frequent legitimate case.

### 2. A regression the port introduced, invisible to every test — `run_all`

`run-all.sh` ran `drive.py` as a **subprocess**, so anything it raised arrived as
a nonzero exit and got the ordinary FAIL line, log tail and summary. The port
calls `drive()` in-process and the exception boundary did not travel with it.
`Console.connect` against a dead qemu, or `login`'s 420s `TimeoutError` when a
stage leaves the VM at an unexpected prompt, escaped as a raw traceback.

Nothing in the suite could have caught it: `boot`, `display` and `final_pass` are
not unit-testable, so that path first executes during the forty-minute run —
where it would have appeared as a traceback *after* Stage 0 had already
succeeded. Found by review, fixed before the run.

### 3. A test that named a property and asserted a sixth of it

`PROMPT_PATTERN` forwards debconf prompts back to the console; without it a
maintainer script's question is drawn into a redirected log where it can be
neither seen nor answered, which is what cost spec 19 ten minutes on `code`'s
postinst. The reviewer cut the pattern from six alternatives to two — deleting
`<Yes>`, `[Y/n]`, `[y/N]` and the trailing `?` — and **all 56 tests still
passed**.

The reviewer's proposed one-line fix, `assertIn(PROMPT_PATTERN, wrapped)`, was
rejected: `wrap()` interpolates the constant, so that assertion holds whatever
the constant contains, and would pass with all six alternatives deleted. A
vacuous fix for a vacuity finding. Replaced with a behavioural test that compiles
the pattern and matches one real prompt line per alternative.

### 4. Coverage gaps the brief created, three times

`drive()`, `find_repo()`, and four of `qemu.py`'s functions were named in the
plan's own Interfaces blocks and had no test behind them. The plan wrote the
interface and forgot the test, in three separate tasks. Two implementers caught
their own before review did.

## An instrument defect that undermines the method itself

**Python serves stale bytecode when a source file's size and integer mtime are
both unchanged, and `-B` does not prevent it.** Measured here:

```
disk says "BBBB"; python imports        AAAA
with -B:                                AAAA      <- -B only stops WRITING
after rm -rf __pycache__:               BBBB
```

A scripted same-length mutation sweep reproduced it **20 times out of 20**, every
run testing the code compiled before the first edit.

This matters more than any single defect above. Mutation is how every guard in
this project is proven able to fail. Under this defect a sweep tests the
*original* code each time, every mutation looks harmless, and the conclusion
drawn is "these tests cannot fail" — when the truth is the mutation never ran.
Same shape as a `grep` returning 0 for a pattern it cannot express: the reading
and "the property holds" are indistinguishable.

`-B` is the natural remedy and it is the wrong one. Clear `__pycache__`.

No result in this branch is in doubt: every mutation was separated from its
predecessor by a full nine-second test run and each produced its expected
failure, so each demonstrably recompiled. The risk is scripted back-to-back
sweeps, which is exactly what surfaced it.

## Two harness lessons about running the harness

**A forty-minute pass must not be started from a managed background shell.** The
first launch died with

```
qemu-system-x86_64: terminating on signal 15 from pid 2337139 (claude bg-spare)
```

Use `setsid nohup ... < /dev/null &` and confirm the session id differs from the
calling shell's, rather than assuming detachment.

**`cpio` had to be added to the check's `nativeBuildInputs`.** The guard is
deliberately two implementations — the archive is written by `cpio` and read back
by a Python newc parser, so a bug in one cannot hide inside the other. The
sandbox had `python3` and not `cpio`, so both tests failed there while passing
locally. Verifying with `cpio -t`, or skipping the tests in the sandbox, would
each have removed the guard rather than fixed it.

## The desktop, verified by a person

`./test/vm/vm display` on the disk the green pass produced: the desktop came up
and Hyprland is running. That is the one question no part of this harness can
answer, and it is what licensed the deletion of the shell version.

It also exercised `display()`, one of the three functions that cannot have a
unit test.

**`boot()` is not among the exercised, and an earlier draft of this document
said it was.** `final_pass` does not call `boot()`; it re-implements its body —
`console_sock.unlink()` plus `spawn_qemu(cfg, BOOT_ARGS(cfg), out)` — omitting
`boot()`'s own `require_no_running_vm`. So the green pass exercised that
duplicated code, not the function. `boot()` has no unit test, no execution of
its qemu path, and a duplicate that will drift from it: the whole-branch review
found this and the correction is the point of recording it. Only its guard has
run, refusing while the display VM held the disk.

Two things done by hand around it are worth keeping:

- **The guest was shut down through its own console, not with `vm stop`.**
  `vm stop` sends SIGTERM to qemu, which flushes the host side but is a power cut
  as far as the guest is concerned. `systemctl poweroff` over the serial console
  gave `reboot: Power down`, which is what a machine that has just written a Nix
  store deserves.
- **`vm display` cannot attach to a running VM, and neither can qemu.**
  `display()` refuses while anything holds the disk — correctly, since a second
  qemu on one image fails with `Failed to get "write" lock`, which reads like
  corruption. And `-display` is fixed at startup: there is no runtime attach
  unless the VM was started with VNC or SPICE, which `egl-headless` is not.

## After the merge

Two things landed after `4b410cf`, and both close something this document
recorded as open.

**The green pass was re-run against the fixed tree, by the user.** The pass
above was taken before the whole-branch review's four blockers were fixed
(`e84562e`), so it proved a tree that then changed. Neither fix could alter a
pass or a fail — one is file buffering, one is a new exception branch — but the
strongest form of the claim wanted a re-run, and it was deferred rather than
skipped because the user's own desktop VM was sitting on the disk `final-pass`
wipes. They ran it themselves afterwards and it passed.

**The entry point's exit-code contract was fixed, and `vm` now has tests.** It
was the branch's only stated behavioural promise and the one file in the tree
with no test, no import and no syntax check, because `unittest discover` never
looks at a file with no `.py` extension. Two real holes:

- `vm --port abc config` exited `1` with a `ValueError` traceback — the code
  reserved for "a stage failed" — so a typo in a caller's own command line was
  indistinguishable from the harness finding a defect. A bad port is now a
  `Precondition`, exit `2`, with a message naming the value.
- **Every unmapped exception exited `1`.** A bug in the harness and a real
  failure of the thing under test read identically. That is exactly the
  conflation `Precondition` was introduced to end, left in place at the one
  point where every code path converges. Unmapped exceptions now exit `3`, and
  the traceback still prints, because a harness bug is someone's to read.

`calangovm/tests/test_entrypoint.py` holds all five codes and imports `vm`,
which is also the syntax check `bin/calango-serve-bootstrap` gets from its own
builder. Both fixes were proven by mutation: restoring `return 1` in place of
`return 3`, and restoring the bare `int()`, each fail exactly one test.

### The pass re-taken on the finished tree

`b74583a` — the exit-code contract, the stage-log buffering and `login()`'s
continuation escape all in — GREEN again on a fresh disk, 14:22:26Z to
14:38:30Z, six stages, zero failures, Gate A reading `active` / **3** / **1** /
**12**. Zero commits and zero modified files during it.

**The buffering fix was confirmed against that run rather than only by test.**
Sampling the stage log while its stage was still executing:

```
14:25:15Z  out-05-gate-a.log: 135 bytes,  5 lines   (step 1 running)
14:25:39Z  out-05-gate-a.log: 396 bytes, 15 lines   (step 2 running)
```

Before the fix that file was `0` bytes until the stage ended, and empty rather
than truncated if the run were killed. Three independent confirmations now: a
reviewer reading the code, a unit test, and a file growing during a real stage.

## What is not verified
- **Stage 0's fidelity to the document.** `RUNBOOK.md` tells the reader to serve
  the preseed with `calango-serve-bootstrap`; `install.py` runs its own
  `http.server`. No check spans the difference, because `vm-step-lines-verbatim`
  reads only `steps/*.txt` and Stage 0 has no step file.

## Reproducing it

```sh
./test/vm/vm final-pass        # fresh disk, Stage 0 through Stage D, ~16 min
./test/vm/vm display           # from a graphical session; a person confirms
```
