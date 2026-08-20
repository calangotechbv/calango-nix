import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from calangovm import config, install

DATA = Path(__file__).resolve().parent / "data"
HUMAN_ANSWERS = Path(__file__).resolve().parent.parent.parent / "human-answers.cfg"

ANSWERS = (
    "# a comment line\n"
    "d-i netcfg/get_hostname string calango-vm   # CALANGO_VM_HOST\n"
    "d-i netcfg/get_domain string\n"
    "d-i netcfg/hostname string calango-vm       # CALANGO_VM_HOST\n"
    "d-i passwd/root-password password rehearsal\n"
    "d-i passwd/root-password-again password rehearsal\n"
    "d-i passwd/user-password password rehearsal\n"
    "d-i passwd/user-password-again password rehearsal\n"
)


class RenderAnswers(unittest.TestCase):
    def test_both_hostname_lines_are_rewritten(self):
        out = install.render_answers(ANSWERS, "othervm", "pw")
        self.assertIn("d-i netcfg/get_hostname string othervm\n", out)
        self.assertIn("d-i netcfg/hostname string othervm\n", out)

    def test_the_trailing_comment_goes_with_the_value(self):
        # The sed in install.sh replaced everything after the key, comment
        # included. A rewrite that kept the comment would leave the marker
        # CALANGO_VM_HOST in a file the installer reads.
        out = install.render_answers(ANSWERS, "othervm", "pw")
        self.assertNotIn("CALANGO_VM_HOST", out)

    def test_all_four_password_lines_are_rewritten(self):
        out = install.render_answers(ANSWERS, "h", "s3cr3t")
        self.assertEqual(out.count("password s3cr3t"), 4)

    def test_unrelated_lines_are_untouched(self):
        out = install.render_answers(ANSWERS, "h", "p")
        self.assertIn("d-i netcfg/get_domain string\n", out)
        self.assertIn("# a comment line\n", out)


class CheckAnswers(unittest.TestCase):
    def test_a_rendered_file_passes(self):
        out = install.render_answers(ANSWERS, "othervm", "s3cr3t")
        self.assertIsNone(install.check_answers(out, "othervm", "s3cr3t"))

    def test_a_missed_hostname_is_a_precondition(self):
        # A stale hostname installs a machine the steps cannot find.
        out = install.render_answers(ANSWERS, "othervm", "s3cr3t")
        broken = out.replace("d-i netcfg/hostname string othervm",
                             "d-i netcfg/hostname string stale")
        with self.assertRaises(config.Precondition):
            install.check_answers(broken, "othervm", "s3cr3t")

    def test_three_password_lines_is_a_precondition(self):
        # A stale password locks the driver out of the machine it just built.
        out = install.render_answers(ANSWERS, "h", "s3cr3t")
        broken = out.replace("d-i passwd/user-password-again password s3cr3t",
                             "d-i passwd/user-password-again password stale", 1)
        with self.assertRaises(config.Precondition):
            install.check_answers(broken, "h", "s3cr3t")

    def test_an_unrendered_real_file_against_the_defaults_is_a_precondition(self):
        # human-answers.cfg's own placeholders ARE config.DEFAULTS' values, so
        # under the default configuration an untouched file's six lines are
        # byte-identical to the wanted ones. Part 1 (exact-line matching) alone
        # cannot catch this -- it is the vacuity gap Part 2 (the marker check)
        # exists to close. This is the case that passed before this fix.
        text = HUMAN_ANSWERS.read_text()
        with self.assertRaises(config.Precondition):
            install.check_answers(text, "calango-vm", "rehearsal")

    def test_an_unrendered_real_file_against_a_prefix_password_is_a_precondition(self):
        # The harmful false pass: pw="reh" is a PREFIX of the unrendered
        # placeholder "rehearsal". A substring count
        # (rendered.count("password " + pw)) matched all four unrendered lines,
        # the guard reported success, the installed machine got "rehearsal",
        # and the driver -- which types "reh" -- could not log in.
        text = HUMAN_ANSWERS.read_text()
        with self.assertRaises(config.Precondition):
            install.check_answers(text, "calango-vm", "reh")


class HumanAnswersCfgMarkers(unittest.TestCase):
    """check_answers' Part 2 relies on human-answers.cfg carrying the
    CALANGO_VM_HOST / CALANGO_VM_PW markers on exactly the six substituted
    lines. This anchors that count: without it, someone tidying a comment out
    of that data file would silently weaken the guard, with nothing to say so.
    """

    def test_the_marker_counts_are_two_and_four(self):
        text = HUMAN_ANSWERS.read_text()
        self.assertEqual(text.count("# CALANGO_VM_HOST"), 2)
        self.assertEqual(text.count("# CALANGO_VM_PW"), 4)


class ReadNewc(unittest.TestCase):
    """The parser is ours; the archive it reads was written by cpio. Two
    implementations, so a bug in one cannot hide inside the other."""

    def test_the_real_archive_holds_one_preseed(self):
        blob = (DATA / "one-member.cpio").read_bytes()
        self.assertEqual(install.read_newc(blob), [("preseed.cfg", 42)])

    def test_a_truncated_archive_raises(self):
        blob = (DATA / "one-member.cpio").read_bytes()
        with self.assertRaises(ValueError):
            install.read_newc(blob[:200])

    def test_something_that_is_not_cpio_raises(self):
        with self.assertRaises(ValueError):
            install.read_newc(b"x" * 400)


class BuildExtraCpio(unittest.TestCase):
    def test_the_archive_holds_exactly_the_preseed_written(self):
        text = "d-i netcfg/get_hostname string calango-vm\n"
        with TemporaryDirectory() as d:
            out = install.build_extra_cpio(text, Path(d))
            self.assertTrue(out.is_file())
            self.assertGreater(out.stat().st_size, 0)

    def test_a_wrong_size_is_caught(self):
        # The guard compares the member's size against the text it was handed.
        # Nothing verified this before: an empty appended archive gives an
        # installer that asks every question by hand over a serial console,
        # which reads as a hang.
        with TemporaryDirectory() as d:
            real = install.read_newc
            install.read_newc = lambda blob: [("preseed.cfg", 0)]
            try:
                with self.assertRaises(config.Precondition):
                    install.build_extra_cpio("some text\n", Path(d))
            finally:
                install.read_newc = real


class Verdict(unittest.TestCase):
    """Stage 0's outcome, decided in one place so it can be tested without qemu.

    The ordering is the defect this exists for: the first port dropped
    run_qemu's status and read the serial log regardless, so a qemu that never
    started was reported by the fetch counter as "the installer never fetched
    it" -- a networking diagnosis for an emulator that did not run.
    """

    def test_a_healthy_run(self):
        code, message = install.verdict(0, "Finishing the installation", 2)
        self.assertEqual(code, 0)
        self.assertIn("Stage 0 OK", message)

    def test_a_failed_install_step(self):
        code, message = install.verdict(0, "…\nInstallation step failed\n…", 2)
        self.assertEqual(code, 1)
        self.assertIn("failed step", message)

    def test_a_kernel_panic(self):
        code, _ = install.verdict(
            0, "Kernel panic - not syncing: Too many boot env vars", 2)
        self.assertEqual(code, 1)

    def test_one_fetch_means_the_installer_never_asked(self):
        code, message = install.verdict(0, "", 1)
        self.assertEqual(code, 1)
        self.assertIn("never fetched", message)

    def test_qemu_failing_is_a_precondition_not_a_stage_failure(self):
        # qemu exits 0 for a guest that panics under -no-reboot, so a nonzero
        # status here is the emulator itself failing: the harness did not run.
        code, message = install.verdict(1, "", 0)
        self.assertEqual(code, 2)
        self.assertIn("qemu exited 1", message)

    def test_qemu_failing_is_reported_before_the_fetch_count(self):
        # The exact misdiagnosis. With qemu dead, the fetch count is 1 (the
        # host probe only) and the serial log is empty or stale -- so every
        # later check has a story to tell, and all of them are wrong.
        code, message = install.verdict(1, "Installation step failed", 1)
        self.assertEqual(code, 2, "a dead qemu was diagnosed as something else")
        self.assertIn("qemu", message)
        self.assertNotIn("fetch", message)
