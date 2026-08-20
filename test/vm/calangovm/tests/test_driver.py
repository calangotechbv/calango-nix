import io
import re
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
from unittest.mock import patch

from calangovm import driver


class Parse(unittest.TestCase):
    def test_a_timeout_block_sets_the_timeout_for_what_follows(self):
        self.assertEqual(driver.parse("#T 120\n\nfirst\n\n#T 45\n\nsecond\n"),
                         [(120, "first"), (45, "second")])

    def test_the_timeout_persists_until_it_is_changed(self):
        steps = driver.parse("#T 120\n\nfirst\n\nsecond\n")
        self.assertEqual([t for t, _ in steps], [120, 120])

    def test_a_file_with_no_timeout_block_uses_the_default(self):
        self.assertEqual(driver.parse("only\n"),
                         [(driver.DEFAULT_TIMEOUT, "only")])

    def test_blank_blocks_are_dropped(self):
        self.assertEqual(len(driver.parse("a\n\n\n\n\nb\n")), 2)

    def test_a_multi_line_block_stays_one_step(self):
        self.assertEqual(driver.parse("one\ntwo\n"), [(driver.DEFAULT_TIMEOUT, "one\ntwo")])


class Command(unittest.TestCase):
    def test_comment_lines_are_dropped(self):
        self.assertEqual(driver.command("#= runbook text\nreal --cmd", "u", "h"),
                         "real --cmd")

    def test_lines_are_joined_with_semicolons(self):
        self.assertEqual(driver.command("one\ntwo", "u", "h"), "one; two")

    def test_tokens_are_substituted(self):
        self.assertEqual(
            driver.command("id -nG @USER@ on @HOST@", "isutton", "calango-vm"),
            "id -nG isutton on calango-vm")

    def test_the_doubled_token_stage_b_uses_substitutes(self):
        # steps/10-stage-b.txt writes "@USER@@@HOST@" for "user@host".
        self.assertEqual(driver.command('"@USER@@@HOST@"', "isutton", "calango-vm"),
                         '"isutton@calango-vm"')


PROMPT_LINES = [
    "Package configuration",
    "Configuring code",
    "      <Yes>                    <No>",
    "Do you want to continue? [Y/n]",
    "Install these packages without verification? [y/N]",
    "Which display manager should manage the default session?",
]
ORDINARY_LINES = [
    "Setting up nix-bin (2.24.9-1) ...",
    "Reading package lists... Done",
    "Preparing to unpack .../greetd_0.10.3-2_amd64.deb ...",
]


class Wrap(unittest.TestCase):
    def test_the_marker_reads_the_first_pipeline_status(self):
        # Not $? -- that is grep's status, and grep matches nothing on a healthy
        # step, so every passing step would report a failure.
        self.assertIn('echo "DONE-7=${PIPESTATUS[0]}"', driver.wrap("true", 7))

    def test_the_bulk_goes_under_rl_and_never_tmp(self):
        # /tmp is cleared on boot, so the reboot taken to investigate a stall
        # destroys the evidence of the stall.
        w = driver.wrap("true", 7)
        self.assertIn("~/rl/step-7.log", w)
        self.assertNotIn("/tmp/", w)

    def test_prompt_shaped_lines_come_back_line_buffered(self):
        # apt runs maintainer scripts under a pty, so redirecting apt does not
        # make them non-interactive -- only invisible and unanswerable.
        w = driver.wrap("true", 1)
        self.assertIn("Package configuration", w)
        self.assertIn("--line-buffered", w)

    # PROMPT_PATTERN is consumed by `grep -aE` inside the guest, not by
    # Python -- these two tests use Python's `re` as a proxy for that. That is
    # sound only because every construct this pattern uses (`|`, `\[`, `\]`,
    # `\?`, `$`) means the same thing in POSIX ERE and in Python's regex
    # dialect. If a future alternative needs a construct where the two
    # disagree, this proxy stops being valid and the disagreement needs to be
    # resolved before trusting these tests again.
    def test_every_kind_of_prompt_line_matches(self):
        # One line per alternative in PROMPT_PATTERN, so deleting any one of
        # them (as opposed to merely asserting the constant is embedded
        # verbatim, which is vacuous -- true no matter what the constant says)
        # fails exactly the line that alternative was for. See Step 6 of the
        # fix-round report for the mutation that proves each of these.
        rx = re.compile(driver.PROMPT_PATTERN)
        for line in PROMPT_LINES:
            self.assertRegex(line, rx, f"did not match: {line!r}")

    def test_ordinary_build_output_never_matches(self):
        rx = re.compile(driver.PROMPT_PATTERN)
        for line in ORDINARY_LINES:
            self.assertNotRegex(line, rx, f"falsely matched: {line!r}")


class Drive(unittest.TestCase):
    """Console.connect, login and time.sleep are patched at the module's own
    import site -- drive()'s real timing (a hard time.sleep(4) per step) would
    otherwise cost several real seconds per test, against a suite that
    currently runs in under 9s. parse/command/wrap are exercised for real
    above; this class is only about drive()'s own control flow: what it sends,
    what it reads back out of a fake Console.log, and when it stops."""

    def _cfg(self):
        return SimpleNamespace(console_sock=Path("/fake/console.sock"),
                                pw="rehearsal", host="calango-vm")

    def _steps_file(self, text):
        d = TemporaryDirectory()
        self.addCleanup(d.cleanup)
        p = Path(d.name) / "steps.txt"
        p.write_text(text)
        return p

    def test_all_steps_ok_returns_zero_and_logs_in_once(self):
        steps = self._steps_file("one\n\ntwo\n")
        fake = SimpleNamespace(log="DONE-1=0\nDONE-2=0\n", send=lambda *a: None,
                               expect=lambda *a, **k: None, read=lambda *a: "")
        with patch("calangovm.driver.Console") as MockConsole, \
             patch("calangovm.driver.login") as mock_login, \
             patch("calangovm.driver.time.sleep"):
            MockConsole.connect.return_value = fake
            rc = driver.drive(self._cfg(), steps, "someone", out=io.StringIO())
        self.assertEqual(rc, 0)
        mock_login.assert_called_once_with(fake, "someone", "rehearsal")

    def test_a_nonzero_exit_stops_the_run_and_returns_one(self):
        steps = self._steps_file("one\n\ntwo\n")
        sent = []
        fake = SimpleNamespace(log="DONE-1=1\n", send=lambda cmd: sent.append(cmd),
                               expect=lambda *a, **k: None, read=lambda *a: "")
        with patch("calangovm.driver.Console") as MockConsole, \
             patch("calangovm.driver.login"), \
             patch("calangovm.driver.time.sleep"):
            MockConsole.connect.return_value = fake
            rc = driver.drive(self._cfg(), steps, "someone", out=io.StringIO())
        self.assertEqual(rc, 1)
        # Two sends for the one failing step (the wrapped command, then the
        # tail); none at all for the second step -- the loop must not continue
        # past a failure.
        self.assertEqual(sum(1 for c in sent if "DONE-2" in c), 0)

    def test_a_timeout_stops_the_run_and_returns_one(self):
        steps = self._steps_file("one\n")

        def raise_timeout(*a, **k):
            raise TimeoutError("no marker")

        fake = SimpleNamespace(log="", send=lambda *a: None, expect=raise_timeout,
                               read=lambda *a: "")
        with patch("calangovm.driver.Console") as MockConsole, \
             patch("calangovm.driver.login"), \
             patch("calangovm.driver.time.sleep"):
            MockConsole.connect.return_value = fake
            out = io.StringIO()
            rc = driver.drive(self._cfg(), steps, "someone", out=out)
        self.assertEqual(rc, 1)
        self.assertIn("timed out", out.getvalue())
