# Does RUNBOOK.md work on a machine that has never seen this flake?

Everything else under `test/` asks a question about a build. This asks the one no
build can answer, by installing Debian in qemu and following the generated
`RUNBOOK.md` on it, stage by stage.

## Run it

```sh
./test/vm/vm final-pass          # fresh disk, install, boot, every stage
```

One command, and it is the only output worth quoting: it wipes the disk,
installs from the generated `preseed.cfg` served out of the store, boots, and
drives Gate A through Stage D, stopping at the first failure.

While finding a defect, drive one stage at a time against a machine that is
already up — the guest's Nix store stays warm, so this is much faster:

```sh
./test/vm/vm boot &                           # if nothing is running
./test/vm/vm drive test/vm/steps/30-stage-c.txt
```

or `./test/vm/vm run-all`, which drives every stage in order against a machine
that is already booted.

Nothing here is exported. `vm`'s own flags and environment variables resolve
the configuration once, in one place (`calangovm/config.py`), and `drive`
reads the account name straight out of the built `.#calangoBootstrap` the same
way `install` does — no caller can hand the driver a username or a socket path
that disagrees with the machine actually under test.

**Iterating and passing are different claims.** A stage that went green after
three fixes tells you the fix worked; only `vm final-pass` on a fresh disk,
against the *pushed* document, tells you the sequence works. Keep them apart
when reporting.

**A `final-pass` run must not be started from a managed background shell.**
See "Nine things not to undo" below — it is a rule about running this harness,
not about the harness's own code, which is why it lives there rather than here.

## Configuration

`./test/vm/vm --help` lists every subcommand together with every flag below.
Each flag also has an environment variable, both resolved once in
`calangovm/config.py`, and precedence is flag, then environment, then default;
an empty environment value counts as unset, the same as the old shell
version's `: "${VAR:=default}"`.

| variable | flag | default | note |
|---|---|---|---|
| `CALANGO_VM_DIR` | `--dir` | `~/vm/calango-runbook` | disk, logs, console socket. Not the repo: the disk is 30G |
| `CALANGO_VM_ISO` | `--iso` | `~/Downloads/debian-13.6.0-amd64-netinst.iso` | any Debian netinst |
| `CALANGO_VM_HOST` | `--host` | `calango-vm` | the VM's hostname, and the flake host Stage B adds |
| `CALANGO_VM_PW` | `--pw` | `rehearsal` | throwaway, typed over a serial console into a scratch VM. Not a secret, and not reusable anywhere |
| `CALANGO_VM_PORT` | `--port` | `2622` | forwarded to the guest's 22. Nothing listens: the preseed installs no sshd |

**The account name is not configurable.** `config.username()` reads it out of
the built `preseed.cfg`, which gets it from the flake's `home.username`, so the
harness cannot disagree with the account the installer actually creates.

## What keeps the harness honest

`steps/*.txt` transcribe the runbook's commands by hand — each needs a marker, a
timeout and a redirect around it — and that transcription is the one place this
harness can silently disagree with the document it tests. So every mirrored line
carries the runbook's own text above it:

```
#= sudo apt update
sudo apt update 2>&1 | tail -5
```

`checks.vm-step-lines-verbatim` asserts every `#=` line appears **verbatim** in
the rendered `RUNBOOK.md`. It is now the only implementation of that assertion
— the shell version was a script nobody was obliged to run — and
`./test/vm/vm final-pass` builds it before it starts any qemu
instance starts, so a drifted step file fails in seconds rather than after
Stage 0's several minutes. `nix flake check` runs the same check on its own,
with no VM involved at all. Both of its failure branches are proven by
mutation: change one `#=` line and it names the line; delete them all and the
vacuity anchor fires rather than reporting "0 of 0 verified".

Lines with no `#=` are the harness's own — accommodations, counts, probes — and
say so in a comment.

`checks.vm-harness-tests` runs the harness's own Python unit suite — no VM, no
network, no kvm, just argv construction, string handling, a socketpair and a
fake `/proc` tree. It needs no vacuity anchor of its own: `unittest discover`
is the one guard shape in this flake that cannot pass having asserted
nothing — measured against Python 3.13.5, an empty test directory or a file
with no test methods exits 5 ("NO TESTS RAN"), not 0.

## What is a deviation and what is not

There is **no 9p share and no ssh** here. Spec 18's rehearsal had both, and the
share is why its Stage B passed while the `git clone` in the document was broken:
the harness answered the question the document was supposed to answer. If the
harness supplies something, the runbook is not being tested on it.

Declared accommodations, each standing in for a person at a keyboard, none of
them changing what runs:

| accommodation | why |
|---|---|
| `sudo` is a shell function feeding the password | so each step reads as the runbook prints it, rather than rewritten around `sudo -S` |
| `apt` gets `-y` | nothing to answer `Do you want to continue? [Y/n]` |
| Stage 0's disk, locale, mirror and timezone answers ride in the initrd | `human-answers.cfg`; a person answers these at the installer |
| Stage B's `flake.nix` edit is a `sed` | the runbook shows that edit as a snippet to make by hand, not as a command |

**`DEBIAN_FRONTEND` is deliberately never set.** A debconf prompt has to be able
to surface — that is how `code`'s question was found — and `calangovm.driver`'s
`wrap()` forwards prompt-shaped lines to the console for the same reason.

## Exit codes

A wrapper may rely on these:

| code | meaning |
|---|---|
| `0` | green |
| `1` | a stage or a step failed — the thing under test is broken |
| `2` | the harness did not run: a usage error, or a precondition (a VM already holds the disk, no ISO, no `nix-users` group) |
| `3` | the harness itself failed — a bug in `vm`, not in what it tests |
| `130` | interrupted |

`2` covers usage as well as preconditions on purpose: argparse exits `2` for a
usage error by long convention and cannot be talked out of it, and from a
caller's side the two are one case — nothing was attempted.

`3` exists because everything unmapped used to exit `1`, which is the code for
"a stage failed". A bug in the harness and a real defect in the thing it tests
were indistinguishable, which is the conflation `config.Precondition` was
introduced to end. `calangovm/tests/test_entrypoint.py` holds all five, and is
also the only thing in the tree that imports `vm` at all — `unittest discover`
never looks at a file with no `.py` extension.

## What is not covered

Stage 0 in this harness serves the preseed with its own `http.server`
(`install.py`'s `make_server`, straight off the store path). `RUNBOOK.md`'s own
Stage 0 tells a real person to serve it with `calango-serve-bootstrap` instead.
No check spans that difference: `checks.vm-step-lines-verbatim` reads only
`steps/*.txt`, and Stage 0 has no step file — it is driven by `install()`
directly, not by a mirrored runbook line. So `calango-serve-bootstrap` and this
harness's own server could disagree and nothing here would notice. Recorded,
not closed.

## Ten things not to undo

Each cost a debugging session. Two that used to live here are gone from the
list entirely, not because the lesson stopped mattering but because it moved
into the code where undoing it is no longer possible from a caller: `python3
-u` is now `vm`'s own `main()` line-buffering both streams once, and the
internal `rc=$?` bookkeeping is now every subcommand's return value becoming the
process's exit code directly, with no shell arithmetic — and no stray `echo` —
in between.

- **Send nothing to the console before a prompt appears.** A probe beginning
  `echo` was typed into GRUB, where `e` opens the entry editor, and a whole final
  pass sat in the bootloader. A bare newline is the only safe blind keystroke: it
  boots in GRUB, reprints at a getty, prints a prompt in a shell.
  `test_console.py::Login.test_nothing_but_newlines_is_sent_before_a_prompt`
  starves `login()` of any prompt and asserts every byte it sent was `\n`.
- **A step's bulk output goes to a file, but prompt lines come back.** Redirecting
  a step wholesale hides an interactive prompt *and* makes it unanswerable. apt
  runs maintainer scripts under a pty, so redirecting apt does not make them
  non-interactive — only invisible.
  `test_driver.py::Wrap.test_prompt_shaped_lines_come_back_line_buffered` and
  `test_every_kind_of_prompt_line_matches` cover this now — one real prompt
  line per `PROMPT_PATTERN` alternative, so deleting any one of them fails a
  named test.
- **Guest logs go to `~/rl`, never `/tmp`.** `/tmp` is cleared on boot, so the
  reboot taken to investigate a stall destroys the evidence of the stall.
  `test_driver.py::Wrap.test_the_bulk_goes_under_rl_and_never_tmp` asserts the
  wrapped command names `~/rl/step-N.log` and never writes into `/tmp/`.
- **`-vga none`.** With qemu's default VGA also present, Hyprland opens the bochs
  device and crashes in pixman — a convincing false failure.
  `test_qemu.py::Argv.test_vga_none_is_present` asserts it in
  `qemu.common_args()`.
- **Strip the five nixGL variables before exec'ing qemu.** A calango session
  exports Nix's mesa paths; Debian's qemu then loads a Nix `libEGL` and aborts
  in epoxy. `test_qemu.py::NixglStrip.test_exactly_five_are_removed` and
  `test_the_five_are_the_right_five` pin both the count and the five names, so
  a sixth stray variable added to `NIXGL_VARS` — or one of the five dropped —
  fails a test instead of surfacing as a pixman crash stages later.
- **The `sudo` wrapper corrupts anything reading stdin.**
  `debconf-set-selections` took the password as its input once and reported
  `parse error on line 1: 'rehearsal'`. Steps that pipe into a command call
  `command sudo -S` directly, as `steps/30-stage-c.txt` does around
  `debconf-set-selections`. Not unit tested: it is a convention living in the
  step files' own shell, not a property `calangovm` can inspect.
- **Two `GET /preseed.cfg` lines are the pass, one is a failure.** slirp presents
  the guest as `127.0.0.1`, the same as a host-side probe, so the count and the
  timestamps are the only evidence that the installer fetched anything.
  `install()` enforces this as an assertion now — the shell version only
  printed the number, so a one-fetch run failed nothing.
- **Clear `__pycache__` before trusting a mutation sweep.** Python serves stale
  bytecode when a source file's size and its integer mtime are both unchanged
  after an edit, and `-B` does not prevent it — `-B` only stops *writing* new
  bytecode, it does not stop *reading* a stale `.pyc` already on disk. A
  scripted same-length mutation sweep reproduced this 20 times out of 20,
  every run silently testing the code compiled before the first edit. This
  matters more than an ordinary trap: mutation is how every test above is
  proven able to fail, and under this defect a sweep tests the *original* code
  every time while reading every mutation as harmless.
- **A `final-pass` run must not be started from a managed background shell.**
  A forty-minute attempt died mid-run with
  `qemu-system-x86_64: terminating on signal 15 from pid … (claude bg-spare)`
  — a SIGTERM the managing shell sent on its own schedule, unrelated to
  whether the install had finished. Use
  `setsid nohup ./test/vm/vm final-pass < /dev/null &` and confirm the new
  process's session id differs from the calling shell's; do not assume
  backgrounding alone detached it.

- **End any wrapper around `vm final-pass` with the exit status you collected.**
  This rule was nearly retired with `exit "$rc"`, and that was wrong: the hazard
  lives in the CALLER's wrapper, which Python cannot reach. A wrapper ending
  `echo "exit=$?"` once reported success for a failed pass, and
  `./test/vm/vm final-pass | tee log; echo done` still loses the status today.
  The recommended launch below is itself such a wrapper.

## What it cannot do

Gate D's last two lines read `loginctl` and Hyprland's own
`/proc/<pid>/environ`, so they need a person logged in at tuigreet — and whether
the desktop *looks* right is not a question any of this can answer:

```sh
./test/vm/vm display              # from a graphical session, not a tty
```

A green `vm final-pass` means Stage 0 through Stage D. The desktop is one
person and one window.
