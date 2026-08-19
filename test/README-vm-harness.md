# TODO: bring the RUNBOOK.md VM harness into this repository

**Status: a note, not the tooling.** The harness described here exists and works
— it drove `RUNBOOK.md` end to end on 2026-08-19 and found four defects — but it
lives outside the repository, in `~/vm/runbook-loop/`, and will be lost with that
directory. It was written from scratch twice already (spec 18's rehearsal, then
spec 19's), and each rewrite paid again for the same traps. That is the reason to
import it.

Everything under `test/` today answers a question about a *build*
(`apt-sources.sh`, `run.sh`, `title-slot.qml`). This answers a question no build
can: **does the document work on a machine that does not have this flake on it?**

## What is out there

In `~/vm/runbook-loop/`, roughly 600 lines:

| file | what it does |
|---|---|
| `lib-qemu.sh` | one device list shared by install and boot, so PCI enumeration cannot differ between them |
| `install.sh` | Stage 0: serves the generated `preseed.cfg` **out of the store**, boots a netinst against it |
| `human-answers.cfg` | the disk/locale/mirror/timezone answers a person gives, as an initrd preseed |
| `boot-headless.sh` | boots the installed machine with its console on a unix socket |
| `run-with-display.sh` | the same machine in a window, with the five nixGL variables stripped |
| `drive.py` | runs a step file inside the guest over the serial console |
| `steps/*.txt` | Gate A, Stage B, Gate B, Stage C, Gate C, Stage D — one file per stage |
| `run-all.sh` | the stages in order, stopping at the first failure |
| `final-pass.sh` | fresh disk, install, boot, all stages: the whole thing as one command |
| `README.md` | the method, and which accommodations are declared |

## What it must not lose in the move

Each of these cost a debugging session. They are the whole value of importing
rather than rewriting.

- **No 9p share and no ssh.** Spec 18's rehearsal had both, and the share is why
  its Stage B looked rehearsed while the `git clone` in the document was broken:
  the harness answered the question the document was supposed to answer. If the
  harness supplies something, the runbook is not being tested on it.
- **Send nothing to the console before a prompt appears.** A probe that began
  `echo …` was typed into GRUB, where `e` opens the entry editor, and a whole
  final pass sat in the bootloader. A bare newline is the only safe blind
  keystroke — it boots in GRUB, reprints at a getty, prints a prompt in a shell.
- **`DEBIAN_FRONTEND` stays unset.** A debconf prompt has to be able to surface;
  that is how `code`'s question was found. `drive.py` forwards prompt-shaped
  lines to the console for the same reason.
- **A step's output goes to a file *and* prompt lines come back.** Redirecting a
  step wholesale hides an interactive prompt and makes it unanswerable — apt runs
  maintainer scripts under a pty, so redirecting apt does not make them
  non-interactive, only invisible.
- **Guest logs go to `~/rl`, never `/tmp`.** `/tmp` is cleared on boot, so the
  reboot taken to investigate a stall destroys the evidence of the stall.
- **`python3 -u`.** Without it the driver's own output sits in a buffer and reads
  as a hung run.
- **`-vga none`.** With qemu's default VGA also present, Hyprland opens the bochs
  device and crashes in pixman — a convincing false failure.
- **Strip the five nixGL variables before exec'ing qemu.** This session exports
  Nix's mesa paths; Debian's qemu then loads a Nix `libEGL` and aborts in epoxy.
- **End the wrapper with `exit "$rc"`.** A run that ended with `echo "exit=$?"`
  reported success for a failed pass, because the `echo`'s status won.

## What has to change before it is committed

It is a harness for one machine right now:

- `isutton`, `calango-vm` and the password `rehearsal` are hard-coded in
  `drive.py`, `human-answers.cfg` and `steps/*.txt`. The user and host should
  come from arguments; the password is a throwaway for a VM and should be
  obviously that.
- absolute paths to `/home/isutton/vm/...` and to the netinst ISO in
  `lib-qemu.sh`.
- `steps/*.txt` transcribe the runbook's commands by hand, which is the one place
  this harness can silently disagree with the document it tests. Either generate
  them from `RUNBOOK.md`'s fenced blocks, or add a check that every command in a
  step file appears verbatim in the rendered runbook.
- the `sudo` wrapper that feeds the password corrupts anything reading stdin —
  `debconf-set-selections` took the password as input once. Worth a comment at
  the definition.

## What it cannot do

Gate D's last two lines read `loginctl` and Hyprland's own `/proc/<pid>/environ`,
so they need a person logged in at tuigreet. A green harness run means Stage 0
through Stage D; the desktop itself is still verified by one person and one
window.
