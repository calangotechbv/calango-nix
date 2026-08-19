# Does RUNBOOK.md work on a machine that has never seen this flake?

Everything else under `test/` asks a question about a build. This asks the one no
build can answer, by installing Debian in qemu and following the generated
`RUNBOOK.md` on it, stage by stage.

## Run it

```sh
./test/vm/final-pass.sh          # fresh disk, install, boot, every stage
```

One command, and it is the only output worth quoting: it wipes the disk,
installs from the generated `preseed.cfg` served out of the store, boots, and
drives Gate A through Stage D, stopping at the first failure.

While finding a defect, drive one stage at a time against a machine that is
already up — the guest's Nix store stays warm, so this is much faster:

```sh
./test/vm/boot-headless.sh &                       # if nothing is running
CALANGO_VM_SOCK=~/vm/calango-runbook/console.sock \
CALANGO_VM_USER=$(...) CALANGO_VM_PW=rehearsal CALANGO_VM_HOST=calango-vm \
  python3 -u ./test/vm/drive.py ./test/vm/steps/30-stage-c.txt
```

or `./test/vm/run-all.sh`, which exports those four for you.

**Iterating and passing are different claims.** A stage that went green after
three fixes tells you the fix worked; only `final-pass.sh` on a fresh disk,
against the *pushed* document, tells you the sequence works. Keep them apart when
reporting.

## Configuration

Everything is an environment variable with a default (`lib-qemu.sh`):

| variable | default | note |
|---|---|---|
| `CALANGO_VM_DIR` | `~/vm/calango-runbook` | disk, logs, console socket. Not the repo: the disk is 30G |
| `CALANGO_VM_ISO` | `~/Downloads/debian-13.6.0-amd64-netinst.iso` | any Debian netinst |
| `CALANGO_VM_HOST` | `calango-vm` | the VM's hostname, and the flake host Stage B adds |
| `CALANGO_VM_PW` | `rehearsal` | throwaway, typed over a serial console into a scratch VM. Not a secret, and not reusable anywhere |
| `CALANGO_VM_PORT` | `2622` | forwarded to the guest's 22. Nothing listens: the preseed installs no sshd |

**The account name is not configurable.** `vm_username` reads it out of the
rendered `preseed.cfg`, which gets it from the flake's `home.username`, so the
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

`check-steps.sh` asserts every `#=` line appears **verbatim** in the rendered
`RUNBOOK.md`, and `final-pass.sh` runs it first. Both of its failure branches are
proven by mutation: change one `#=` line and it names the line; delete them all
and the vacuity anchor fires rather than reporting "0 of 0 verified".

Lines with no `#=` are the harness's own — accommodations, counts, probes — and
say so in a comment.

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
to surface — that is how `code`'s question was found — and `drive.py` forwards
prompt-shaped lines to the console for the same reason.

## Nine things not to undo

Each cost a debugging session.

- **Send nothing to the console before a prompt appears.** A probe beginning
  `echo` was typed into GRUB, where `e` opens the entry editor, and a whole final
  pass sat in the bootloader. A bare newline is the only safe blind keystroke: it
  boots in GRUB, reprints at a getty, prints a prompt in a shell.
- **A step's bulk output goes to a file, but prompt lines come back.** Redirecting
  a step wholesale hides an interactive prompt *and* makes it unanswerable. apt
  runs maintainer scripts under a pty, so redirecting apt does not make them
  non-interactive — only invisible.
- **Guest logs go to `~/rl`, never `/tmp`.** `/tmp` is cleared on boot, so the
  reboot taken to investigate a stall destroys the evidence of the stall.
- **`python3 -u`.** Without it the driver's own output sits in a buffer and a
  healthy run reads as a hung one.
- **`-vga none`.** With qemu's default VGA also present, Hyprland opens the bochs
  device and crashes in pixman — a convincing false failure.
- **Strip the five nixGL variables before exec'ing qemu** (`NIXGL_STRIP`). A
  calango session exports Nix's mesa paths; Debian's qemu then loads a Nix
  `libEGL` and aborts in epoxy.
- **`exit "$rc"` at the end of any wrapper.** A wrapper ending with
  `echo "exit=$?"` reported success for a failed pass, because the `echo`'s
  status won.
- **The `sudo` wrapper corrupts anything reading stdin.**
  `debconf-set-selections` took the password as its input once and reported
  `parse error on line 1: 'rehearsal'`. Steps that pipe into a command call
  `command sudo -S` directly.
- **Two `GET /preseed.cfg` lines are the pass, one is a failure.** slirp presents
  the guest as `127.0.0.1`, the same as a host-side `curl`, so the count and the
  timestamps are the only evidence that the installer fetched anything.

## What it cannot do

Gate D's last two lines read `loginctl` and Hyprland's own
`/proc/<pid>/environ`, so they need a person logged in at tuigreet — and whether
the desktop *looks* right is not a question any of this can answer:

```sh
./test/vm/run-with-display.sh    # from a graphical session, not a tty
```

A green `final-pass.sh` means Stage 0 through Stage D. The desktop is one person
and one window.
