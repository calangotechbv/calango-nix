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
