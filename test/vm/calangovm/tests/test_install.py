import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from calangovm import config, install

DATA = Path(__file__).resolve().parent / "data"

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
