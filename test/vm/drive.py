#!/usr/bin/env python3
"""Runs runbook steps inside the VM over its serial console, one at a time.

No ssh and no sudoers file: this run has NO harness deviation, which is the
whole point after spec 19's finding 6 -- spec 18's Stage B looked rehearsed
because its tree came off a 9p share. Every command here is one RUNBOOK.md
prints, typed as the reader would type it.

The console is 115200 baud, so a step's output goes to a file inside the guest
and only a marker plus a tail comes back:

    ( <step> ) > /tmp/step-N.log 2>&1 ; echo "DONE-N=$?"

Usage: drive.py <steps-file>
  Steps file: blank-line-separated blocks. A block starting with "#T " sets the
  timeout in seconds for the block that follows.
"""
import os, re, socket, sys, time

# Set by run-all.sh / final-pass.sh out of lib-qemu.sh. CALANGO_VM_USER is read
# from the rendered preseed, not configured, so it cannot disagree with the
# account the installer actually created.
SOCK = os.environ["CALANGO_VM_SOCK"]
USER = os.environ["CALANGO_VM_USER"]
PW = os.environ["CALANGO_VM_PW"]
HOST = os.environ["CALANGO_VM_HOST"]

class Console:
    def __init__(self, path=SOCK, timeout=1.0):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.connect(path); self.s.settimeout(timeout); self.log = ""
    def read(self, seconds=1.0):
        end, out = time.monotonic() + seconds, ""
        while time.monotonic() < end:
            try:
                d = self.s.recv(65536)
                if not d: break
                out += d.decode("utf-8", "replace")
            except socket.timeout:
                pass
        self.log += out; return out
    def send(self, line): self.s.sendall((line + "\n").encode())
    def expect(self, pat, seconds=120.0):
        end, acc, rx = time.monotonic() + seconds, "", re.compile(pat)
        while time.monotonic() < end:
            acc += self.read(3.0)
            if rx.search(acc): return acc
        raise TimeoutError(f"{pat} after {seconds}s; tail: {acc[-500:]!r}")

def login(c):
    """Wait for a prompt, then log in. Sends NOTHING until one appears.

    This used to probe with `echo PROBE-OK-42`. On a machine that had just
    booted, those characters went to GRUB, whose serial console was still up --
    and `e`, the first letter of `echo`, is GRUB's "edit this entry" key. The
    final pass sat in GRUB's editor until it timed out, and the traceback showed
    grub.cfg being echoed back. A bare newline is the only safe thing to send
    blind: in GRUB it boots the highlighted entry, at a login prompt it reprints
    it, and in a shell it prints the prompt again.
    """
    acc, state = "", None
    end = time.monotonic() + 420.0
    while time.monotonic() < end:
        acc += c.read(3.0)
        tail = acc[-3000:]
        if re.search(r"login:\s*$", tail) or "login:" in acc[-300:]:
            state = "login"; break
        if re.search(r"(RDY> |\$ ?)$", tail):
            state = "shell"; break
        c.send("")            # safe in GRUB, at a getty, and in a shell alike
    if state is None:
        raise TimeoutError(f"no prompt in 420s; tail: {acc[-400:]!r}")
    if state == "login":
        c.send(USER); c.expect(r"[Pp]assword:", 60); c.send(PW); c.expect(r"\$", 90)
    c.send("stty -echo 2>/dev/null; PS1='RDY> '")
    # The step files' sudo wrapper needs the password, and must not spell it.
    c.send("export CALANGO_PW='" + PW + "'")
    c.read(2.0)

def parse(path):
    steps, timeout = [], 300
    for block in open(path).read().split("\n\n"):
        block = block.strip()
        if not block: continue
        if block.startswith("#T "):
            timeout = int(block.split()[1]); continue
        steps.append((timeout, block))
    return steps

def main():
    steps = parse(sys.argv[1])
    c = Console(); login(c)
    for i, (timeout, body) in enumerate(steps, 1):
        one = "; ".join(l for l in body.splitlines() if not l.startswith("#"))
        # @USER@ / @HOST@ are the harness's own tokens, the same shape the flake
        # uses in bootstrap/runbook.md.in. A step file must never spell an
        # account or hostname, so one copy of this harness cannot quietly
        # hard-code the machine it was written on.
        one = one.replace("@USER@", USER).replace("@HOST@", HOST)
        print(f"\n===== step {i} (timeout {timeout}s) =====\n{body}\n----- output -----")
        # Three lessons from the run that stalled, all mine:
        #   * /tmp is cleared on boot, so a reboot to investigate destroyed the
        #     evidence. Logs go to ~/rl now.
        #   * a redirected step makes an interactive prompt invisible AND
        #     unanswerable -- code's postinst asked a debconf question and the
        #     VM sat idle for ten minutes with a silent console. tee forwards
        #     prompt-shaped lines to the console while the bulk still goes to
        #     the file.
        #   * apt runs maintainer scripts under a pty, so redirecting apt's own
        #     output does NOT make them non-interactive. The prompt is real.
        c.send(
            f"mkdir -p ~/rl; ( {one} ) 2>&1 | tee ~/rl/step-{i}.log"
            " | grep -aE --line-buffered "
            "'Package configuration|Configuring |<Yes>|\\[Y/n\\]|\\[y/N\\]|\\?$'"
            f" ; echo \"DONE-{i}=${{PIPESTATUS[0]}}\""
        )
        try:
            c.expect(rf"DONE-{i}=(\d+)", timeout)
        except TimeoutError as e:
            print(f"TIMEOUT: {e}")
            c.send(f"tail -25 ~/rl/step-{i}.log"); time.sleep(4); print(c.read(6.0))
            sys.exit(f"step {i} timed out")
        m = re.search(rf"DONE-{i}=(\d+)", c.log)
        rc = m.group(1)
        c.send(f"echo '--- tail of step {i} ---'; tail -18 ~/rl/step-{i}.log")
        time.sleep(4); print(c.read(8.0))
        print(f"exit={rc}")
        if rc != "0":
            sys.exit(f"step {i} exited {rc}")
    print("\nALL STEPS OK")

main()
