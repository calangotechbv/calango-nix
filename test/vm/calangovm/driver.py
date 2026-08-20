"""Step files: parse them, substitute the tokens, send them, wait for the marker.

Ported from drive.py's parse() and main(). The console is a parameter and the
output stream is a parameter, so run_all can drive several files in one process
and redirect each to its own log.
"""

import re
import sys
import time
from pathlib import Path

from .console import Console, login

DEFAULT_TIMEOUT = 300

# What a maintainer script's prompt looks like on the console. apt runs
# maintainer scripts under a pty, so redirecting apt's own output does NOT make
# them non-interactive -- it makes them invisible AND unanswerable. These lines
# come back while the bulk still goes to a file inside the guest.
PROMPT_PATTERN = r"Package configuration|Configuring |<Yes>|\[Y/n\]|\[y/N\]|\?$"


def parse(text: str) -> list[tuple[int, str]]:
    """Blank-line-separated blocks. A block starting with '#T ' sets the timeout
    for every block after it."""
    steps, timeout = [], DEFAULT_TIMEOUT
    for block in text.split("\n\n"):
        block = block.strip()
        if not block:
            continue
        if block.startswith("#T "):
            timeout = int(block.split()[1])
            continue
        steps.append((timeout, block))
    return steps


def command(body: str, user: str, host: str) -> str:
    """The one line a block becomes.

    @USER@ and @HOST@ are the harness's own tokens, the same shape the flake
    uses in bootstrap/runbook.md.in. A step file must not spell the account or
    the hostname, so one copy of this harness cannot quietly hard-code the
    machine it was written on.
    """
    one = "; ".join(l for l in body.splitlines() if not l.startswith("#"))
    return one.replace("@USER@", user).replace("@HOST@", host)


def wrap(cmd: str, index: int) -> str:
    """Three lessons from the run that stalled, all of them paid for:

      * /tmp is cleared on boot, so a reboot to investigate destroyed the
        evidence. Logs go to ~/rl.
      * a redirected step makes an interactive prompt invisible AND
        unanswerable -- code's postinst asked a debconf question and the VM sat
        idle for ten minutes with a silent console. tee forwards prompt-shaped
        lines to the console while the bulk still goes to the file.
      * PIPESTATUS[0], not $?. $? is grep's status, and grep matches nothing on
        a healthy step.
    """
    return (
        f"mkdir -p ~/rl; ( {cmd} ) 2>&1 | tee ~/rl/step-{index}.log"
        f" | grep -aE --line-buffered '{PROMPT_PATTERN}'"
        f' ; echo "DONE-{index}=${{PIPESTATUS[0]}}"'
    )


def drive(cfg, steps_path, user: str, out=sys.stdout) -> int:
    steps = parse(Path(steps_path).read_text())
    c = Console.connect(cfg.console_sock)
    login(c, user, cfg.pw)
    for index, (timeout, body) in enumerate(steps, 1):
        print(f"\n===== step {index} (timeout {timeout}s) =====\n{body}\n"
              "----- output -----", file=out)
        c.send(wrap(command(body, user, cfg.host), index))
        try:
            c.expect(rf"DONE-{index}=(\d+)", timeout)
        except TimeoutError as exc:
            print(f"TIMEOUT: {exc}", file=out)
            c.send(f"tail -25 ~/rl/step-{index}.log")
            time.sleep(4)
            print(c.read(6.0), file=out)
            print(f"step {index} timed out", file=out)
            return 1
        rc = re.search(rf"DONE-{index}=(\d+)", c.log).group(1)
        c.send(f"echo '--- tail of step {index} ---'; tail -18 ~/rl/step-{index}.log")
        time.sleep(4)
        print(c.read(8.0), file=out)
        print(f"exit={rc}", file=out)
        if rc != "0":
            print(f"step {index} exited {rc}", file=out)
            return 1
    print("\nALL STEPS OK", file=out)
    return 0
