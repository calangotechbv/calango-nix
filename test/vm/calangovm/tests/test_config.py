import shutil
import tempfile
import unittest
from pathlib import Path

from calangovm import config

FAKE_REPO = Path("/nowhere/repo")


class Fallback(unittest.TestCase):
    def test_default_when_nothing_is_set(self):
        c = config.resolve(environ={}, repo=FAKE_REPO)
        self.assertEqual(c.host, "calango-vm")
        self.assertEqual(c.port, 2622)
        self.assertEqual(c.pw, "rehearsal")

    def test_environment_beats_the_default(self):
        c = config.resolve(environ={"CALANGO_VM_HOST": "other"}, repo=FAKE_REPO)
        self.assertEqual(c.host, "other")

    def test_an_empty_variable_is_not_a_value(self):
        # lib-qemu.sh spelled this `: "${CALANGO_VM_HOST:=calango-vm}"`, and the
        # := form treats an empty value as unset. A plain `in environ` test does
        # not, and would hand the harness an empty hostname.
        c = config.resolve(environ={"CALANGO_VM_HOST": ""}, repo=FAKE_REPO)
        self.assertEqual(c.host, "calango-vm")

    def test_flag_beats_the_environment(self):
        c = config.resolve(overrides={"host": "flagged"},
                           environ={"CALANGO_VM_HOST": "envd"}, repo=FAKE_REPO)
        self.assertEqual(c.host, "flagged")

    def test_every_value_has_an_environment_variable(self):
        # The vm executable builds its flags from config.ENV, so a value with no
        # entry here silently gets no flag.
        self.assertEqual(set(config.ENV), set(config.DEFAULTS))
        self.assertEqual(sorted(config.ENV.values()), [
            "CALANGO_VM_DIR", "CALANGO_VM_HOST", "CALANGO_VM_ISO",
            "CALANGO_VM_PORT", "CALANGO_VM_PW"])


class HttpPort(unittest.TestCase):
    def test_2622_gives_8622(self):
        c = config.resolve(environ={"CALANGO_VM_PORT": "2622"}, repo=FAKE_REPO)
        self.assertEqual(c.http_port, 8622)

    def test_only_the_last_three_digits_carry(self):
        # install.sh spelled this PORT=8${CALANGO_VM_PORT: -3}.
        c = config.resolve(environ={"CALANGO_VM_PORT": "2700"}, repo=FAKE_REPO)
        self.assertEqual(c.http_port, 8700)


class Username(unittest.TestCase):
    def test_read_from_the_rendered_preseed(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "preseed.cfg").write_text(
                "d-i passwd/user-fullname string Someone\n"
                "d-i passwd/username string isutton\n")
            self.assertEqual(config.username(Path(d)), "isutton")

    def test_an_absent_username_is_a_precondition(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "preseed.cfg").write_text("d-i passwd/user-fullname string x\n")
            with self.assertRaises(config.Precondition):
                config.username(Path(d))


class Paths(unittest.TestCase):
    def test_the_disk_and_socket_hang_off_the_state_directory(self):
        c = config.resolve(overrides={"dir": "/tmp/vmdir"}, environ={}, repo=FAKE_REPO)
        self.assertEqual(c.disk, Path("/tmp/vmdir/disk.qcow2"))
        self.assertEqual(c.console_sock, Path("/tmp/vmdir/console.sock"))

    def test_a_tilde_is_expanded(self):
        c = config.resolve(overrides={"dir": "~/vm/x"}, environ={}, repo=FAKE_REPO)
        self.assertFalse(str(c.dir).startswith("~"))


def _harness_tree(harness: Path) -> Path:
    """A test/vm laid out the way harness_dir insists on, returning it."""
    (harness / "calangovm").mkdir(parents=True)
    (harness / "steps").mkdir()
    (harness / "human-answers.cfg").write_text("")
    return harness


class FindRepo(unittest.TestCase):
    """find_repo had no coverage: every other test passes repo= and skips it."""

    def test_it_climbs_three_levels_to_the_flake(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d).resolve()
            (root / "flake.nix").write_text("{}\n")
            here = _harness_tree(root / "test" / "vm") / "calangovm" / "config.py"
            here.write_text("")
            self.assertEqual(config.find_repo(here), root)

    def test_no_flake_above_it_is_a_precondition(self):
        with tempfile.TemporaryDirectory() as d:
            here = (_harness_tree(Path(d).resolve() / "a" / "b")
                    / "calangovm" / "config.py")
            here.write_text("")
            with self.assertRaises(config.Precondition) as caught:
                config.find_repo(here)
            # Named, because find_repo now climbs through harness_dir and that
            # raises a Precondition of its own. Without this the test passes on
            # a tree that never reached the flake check at all.
            self.assertIn("flake.nix", str(caught.exception))


class HarnessDir(unittest.TestCase):
    """The arithmetic install(), steps_files() and find_repo() each had a copy of."""

    def test_the_real_one_holds_the_harness(self):
        # Asserted by CONTENT, not by name. An earlier version of this test read
        # `harness.name == "vm"` and failed only inside
        # checks.vm-harness-tests, which copies test/vm to harness/ -- the trap
        # find_repo's docstring names, met by a test written to cover it.
        harness = config.harness_dir()
        self.assertTrue((harness / "human-answers.cfg").is_file())
        self.assertTrue((harness / "steps").is_dir())
        self.assertTrue((harness / "calangovm" / "config.py").is_file())

    def test_it_is_the_directory_holding_the_package(self):
        with tempfile.TemporaryDirectory() as d:
            harness = _harness_tree(Path(d).resolve() / "test" / "vm")
            self.assertEqual(config.harness_dir(harness / "calangovm" / "x.py"),
                             harness)

    def test_a_missing_marker_is_a_precondition_not_a_traceback(self):
        # install() reads human-answers.cfg straight off this path. Unguarded,
        # a calangovm/ moved one level down gives a bare FileNotFoundError --
        # exit 3, "the harness broke" -- for a tree that is merely laid out
        # wrong. Each marker is dropped in turn: a guard naming two properties
        # and enforcing one is the shape this project keeps paying for.
        for drop in ("human-answers.cfg", "steps"):
            with self.subTest(drop=drop), tempfile.TemporaryDirectory() as d:
                harness = _harness_tree(Path(d).resolve() / "test" / "vm")
                target = harness / drop
                shutil.rmtree(target) if target.is_dir() else target.unlink()
                with self.assertRaises(config.Precondition) as caught:
                    config.harness_dir(harness / "calangovm" / "x.py")
                self.assertIn(drop, str(caught.exception))
