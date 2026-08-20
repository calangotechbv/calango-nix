"""The VM's serial console: a unix socket, and the login that must not type.

Ported from drive.py's Console class and login(). The socket is a parameter
rather than read from the environment at import time, which is what makes any of
this testable against a socketpair.
"""

import re
import socket
import time


class Console:
    def __init__(self, sock, timeout: float = 1.0):
        self.s = sock
        self.s.settimeout(timeout)
        self.log = ""

    @classmethod
    def connect(cls, path, timeout: float = 1.0) -> "Console":
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(str(path))
        return cls(s, timeout)

    def read(self, seconds: float = 1.0) -> str:
        end, out = time.monotonic() + seconds, ""
        while time.monotonic() < end:
            try:
                data = self.s.recv(65536)
                if not data:
                    break
                out += data.decode("utf-8", "replace")
            except socket.timeout:
                pass
        self.log += out
        return out

    def send(self, line: str) -> None:
        self.s.sendall((line + "\n").encode())

    def interrupt(self) -> None:
        """Ctrl-C. `send` appends a newline, which is the wrong thing here:
        a newline at a continuation prompt continues the line."""
        self.s.sendall(b"\x03")

    def expect(self, pattern: str, seconds: float = 120.0,
               poll: float = 3.0) -> str:
        end, acc, rx = time.monotonic() + seconds, "", re.compile(pattern)
        while time.monotonic() < end:
            acc += self.read(min(poll, seconds))
            if rx.search(acc):
                return acc
        raise TimeoutError(f"{pattern} after {seconds}s; tail: {acc[-500:]!r}")


ANSI = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]")


def at_continuation(tail: str) -> bool:
    """Is the shell sitting at a PS2 continuation prompt?

    bash's default PS2 is `> `. Matched on the LAST LINE being exactly `>`
    rather than on the tail ending in `>`, because `RDY> ` -- the PS1 this
    harness sets -- also ends in `> `, and because a step's own output can end
    in `>` for its own reasons. The ANSI strip is needed for real terminals:
    bracketed-paste leaves `\x1b[?2004h` immediately before the prompt.
    """
    lines = [l for l in ANSI.sub("", tail).splitlines() if l.strip()]
    return bool(lines) and lines[-1].strip() == ">"


def login(c: Console, user: str, pw: str, timeout: float = 420.0,
          poll: float = 3.0) -> None:
    """Wait for a prompt, then log in. Sends NOTHING until one appears.

    This used to probe with `echo PROBE-OK-42`. On a machine that had just
    booted, those characters went to GRUB, whose serial console was still up --
    and `e`, the first letter of `echo`, is GRUB's "edit this entry" key. The
    final pass sat in GRUB's editor until it timed out, and the traceback showed
    grub.cfg being echoed back. A bare newline is the only safe thing to send
    blind: in GRUB it boots the highlighted entry, at a login prompt it reprints
    it, and in a shell it prints the prompt again.
    """
    acc, state, interrupts = "", None, 0
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        acc += c.read(poll)
        tail = acc[-3000:]
        if re.search(r"login:\s*$", tail) or "login:" in acc[-300:]:
            state = "login"
            break
        if re.search(r"(RDY> |\$ ?)$", tail):
            state = "shell"
            break
        if at_continuation(tail) and interrupts < 3:
            # An unbalanced quote in an earlier command leaves the shell at a
            # continuation prompt, where a newline is answered with another
            # continuation -- so the poke below would run for the whole timeout
            # and then report "no prompt", which reads as a dead VM. Measured:
            # one probe with a stray quote hung this function for its full 420s
            # against a perfectly healthy machine. Ctrl-C is what leaves it.
            #
            # Bounded, and it falls through to the newline afterwards: if
            # something else in the world ends its last line with a bare `>`,
            # three interrupts is a cheap thing to have been wrong about,
            # whereas retrying for ever would trade one hang for another.
            c.interrupt()
            interrupts += 1
            acc = ""          # the prompt search restarts after the interrupt
            continue
        c.send("")            # safe in GRUB, at a getty, and in a shell alike
    if state is None:
        raise TimeoutError(f"no prompt in {timeout}s; tail: {acc[-400:]!r}")
    if state == "login":
        c.send(user)
        c.expect(r"[Pp]assword:", 60, poll)
        c.send(pw)
        c.expect(r"\$", 90, poll)
    c.send("stty -echo 2>/dev/null; PS1='RDY> '")
    # The step files' sudo wrapper needs the password, and must not spell it.
    c.send("export CALANGO_PW='" + pw + "'")
    c.read(2.0)
