import socket
import threading
import unittest

from calangovm import console


def pair():
    """Two connected sockets: one for the Console, one standing in for the VM."""
    a, b = socket.socketpair()
    return console.Console(a, timeout=0.05), b


class ReadSendExpect(unittest.TestCase):
    def test_send_appends_a_newline(self):
        c, vm = pair()
        c.send("hello")
        self.assertEqual(vm.recv(64), b"hello\n")

    def test_expect_returns_when_the_pattern_arrives(self):
        c, vm = pair()
        vm.sendall(b"noise\nDONE-3=0\n")
        self.assertIn("DONE-3=0", c.expect(r"DONE-3=(\d+)", 5.0, poll=0.05))

    def test_expect_raises_and_names_the_tail(self):
        c, vm = pair()
        vm.sendall(b"this is not it\n")
        with self.assertRaises(TimeoutError) as caught:
            c.expect(r"NEVER-APPEARS", 0.4, poll=0.05)
        self.assertIn("this is not it", str(caught.exception))

    def test_the_log_accumulates_across_reads(self):
        c, vm = pair()
        vm.sendall(b"one\n")
        c.read(0.2)
        vm.sendall(b"two\n")
        c.read(0.2)
        self.assertIn("one", c.log)
        self.assertIn("two", c.log)


class Login(unittest.TestCase):
    def test_nothing_but_newlines_is_sent_before_a_prompt(self):
        """The rule that cost a whole final pass.

        login used to probe with `echo PROBE-OK-42`. On a machine that had just
        booted, those characters went to GRUB, whose serial console was still
        up -- and `e`, the first letter of `echo`, is GRUB's "edit this entry"
        key. A bare newline is the only safe blind keystroke.
        """
        c, vm = pair()
        seen = bytearray()
        stop = threading.Event()

        def collect():
            vm.settimeout(0.05)
            while not stop.is_set():
                try:
                    seen.extend(vm.recv(4096))
                except OSError:
                    pass

        t = threading.Thread(target=collect, daemon=True)
        t.start()
        with self.assertRaises(TimeoutError):
            console.login(c, "someone", "secret", timeout=0.6, poll=0.05)
        stop.set()
        t.join(2.0)
        self.assertGreater(len(seen), 0, "login sent nothing at all; it must poke")
        self.assertEqual(set(seen), {ord("\n")},
                         f"login sent something other than a newline: {bytes(seen)!r}")

    def test_a_login_prompt_gets_the_account_and_the_password(self):
        c, vm = pair()
        got = []

        def next_real_line():
            # Ignore the bare newlines login pokes with. Reading raw here races:
            # the poke can arrive before the account does, and the assertion
            # then fails on a healthy login.
            buf = b""
            while True:
                buf += vm.recv(4096)
                line = buf.replace(b"\n", b"")
                if line:
                    return line

        def guest():
            vm.settimeout(5.0)
            vm.sendall(b"\ncalango-vm login: ")
            got.append(next_real_line())        # the account
            vm.sendall(b"\nPassword: ")
            got.append(next_real_line())        # the password
            vm.sendall(b"\nsomeone@calango-vm:~$ ")

        t = threading.Thread(target=guest, daemon=True)
        t.start()
        console.login(c, "someone", "secret", timeout=20.0, poll=0.05)
        t.join(10.0)
        self.assertEqual(got, [b"someone", b"secret"])

    def test_the_password_reaches_the_guest_as_an_exported_variable(self):
        # The step files' sudo wrapper needs the password and must not spell it.
        c, vm = pair()
        vm.sendall(b"someone@calango-vm:~$ ")
        console.login(c, "someone", "s3cr3t", timeout=20.0, poll=0.05)
        vm.settimeout(1.0)
        got = b""
        try:
            while True:
                chunk = vm.recv(4096)
                if not chunk:
                    break
                got += chunk
        except OSError:
            pass
        self.assertIn(b"export CALANGO_PW='s3cr3t'", got)
