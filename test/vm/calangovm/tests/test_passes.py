import unittest
from unittest import mock
from pathlib import Path
from tempfile import TemporaryDirectory

from calangovm import config, passes

CFG = config.resolve(overrides={"dir": "/tmp/vmdir"}, environ={},
                     repo=Path("/nowhere/repo"))


class StepsFiles(unittest.TestCase):
    def test_the_real_steps_are_found_and_sorted(self):
        names = [p.name for p in passes.steps_files()]
        self.assertEqual(names, sorted(names))
        self.assertIn("05-gate-a.txt", names)
        self.assertIn("50-stage-d.txt", names)

    def test_an_empty_steps_directory_is_a_precondition(self):
        # run-all.sh had no anchor here. Its shell glob happened to fail loudly
        # because an unmatched pattern was passed to drive.py as a filename; a
        # Python glob returns [] and would print "0 passed, 0 failed" and exit
        # 0 -- a pass that asserted nothing.
        with TemporaryDirectory() as d:
            (Path(d) / "steps").mkdir()
            with self.assertRaises(config.Precondition):
                passes.steps_files(Path(d))


class RunAll(unittest.TestCase):
    def _fake_drive(self, results):
        calls = []

        def drive(cfg, path, user, out=None):
            calls.append(Path(path).name)
            return results.pop(0)

        return drive, calls

    def test_it_stops_at_the_first_failure(self):
        drive, calls = self._fake_drive([0, 1, 0, 0, 0, 0])
        with TemporaryDirectory() as d:
            cfg = config.resolve(overrides={"dir": d}, environ={},
                                 repo=Path("/nowhere/repo"))
            rc = passes.run_all(cfg, drive=drive, user="someone")
        self.assertEqual(rc, 1)
        self.assertEqual(len(calls), 2, "run_all kept going after a failure")

    def test_every_file_runs_when_all_pass(self):
        count = len(passes.steps_files())
        drive, calls = self._fake_drive([0] * count)
        with TemporaryDirectory() as d:
            cfg = config.resolve(overrides={"dir": d}, environ={},
                                 repo=Path("/nowhere/repo"))
            rc = passes.run_all(cfg, drive=drive, user="someone")
        self.assertEqual(rc, 0)
        self.assertEqual(len(calls), count)


class BootArgs(unittest.TestCase):
    def test_the_console_is_a_unix_socket_server(self):
        args = passes.BOOT_ARGS(CFG)
        self.assertIn(f"unix:{CFG.console_sock},server=on,wait=off", args)

    def test_it_boots_from_the_disk_not_the_cdrom(self):
        self.assertIn("order=c", passes.BOOT_ARGS(CFG))


class DriveRaises(unittest.TestCase):
    """run-all.sh ran drive.py as a subprocess; run_all calls it in-process.

    That boundary change is invisible until a live VM goes wrong, which is the
    only time it matters. Without a handler the exception escapes the loop and
    the FAIL line, the log tail and the summary are all lost.
    """

    def test_an_exception_is_reported_as_a_failed_stage(self):
        def drive(cfg, path, user, out=None):
            raise TimeoutError("no prompt in 420s; tail: 'grub> '")

        with TemporaryDirectory() as d:
            cfg = config.resolve(overrides={"dir": d}, environ={},
                                 repo=Path("/nowhere/repo"))
            rc = passes.run_all(cfg, drive=drive, user="someone")
        self.assertEqual(rc, 1)

    def test_the_exception_text_reaches_the_stage_log(self):
        def drive(cfg, path, user, out=None):
            raise ConnectionRefusedError("[Errno 111] Connection refused")

        with TemporaryDirectory() as d:
            cfg = config.resolve(overrides={"dir": d}, environ={},
                                 repo=Path("/nowhere/repo"))
            passes.run_all(cfg, drive=drive, user="someone")
            logs = sorted(Path(d).glob("out-*.log"))
            self.assertTrue(logs, "no stage log was written at all")
            self.assertIn("ConnectionRefusedError", logs[0].read_text())

    def test_it_still_stops_at_the_first_raising_stage(self):
        calls = []

        def drive(cfg, path, user, out=None):
            calls.append(Path(path).name)
            raise TimeoutError("boom")

        with TemporaryDirectory() as d:
            cfg = config.resolve(overrides={"dir": d}, environ={},
                                 repo=Path("/nowhere/repo"))
            passes.run_all(cfg, drive=drive, user="someone")
        self.assertEqual(len(calls), 1, "run_all kept going after an exception")


class Stop(unittest.TestCase):
    def test_it_reports_when_nothing_is_running(self):
        with mock.patch.object(passes.qemu, "running_vm_pids", return_value=[]), \
             mock.patch.object(passes.qemu, "terminate_running_vms") as term:
            self.assertEqual(passes.stop(CFG), 0)
            term.assert_not_called()

    def test_it_terminates_what_is_running(self):
        with mock.patch.object(passes.qemu, "running_vm_pids", return_value=[7, 9]), \
             mock.patch.object(passes.qemu, "terminate_running_vms") as term:
            self.assertEqual(passes.stop(CFG), 0)
            term.assert_called_once()
