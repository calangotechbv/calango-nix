import socket
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


class Boot(unittest.TestCase):
    """boot() had no test and no execution: final_pass re-implemented its body.

    So the green pass exercised a COPY of this code, and the copy had already
    drifted -- it omitted require_no_running_vm. Both paths now share
    _prepare_boot, and both are tested here.
    """

    def _cfg(self, d):
        return config.resolve(overrides={"dir": d}, environ={},
                              repo=Path("/nowhere/repo"))

    def test_it_execs_qemu_with_the_boot_args(self):
        seen = []
        with TemporaryDirectory() as d, \
             mock.patch.object(passes.qemu, "require_no_running_vm"):
            cfg = self._cfg(d)
            passes.boot(cfg, exec_qemu=lambda c, a: seen.append(a))
        self.assertEqual(seen, [passes.BOOT_ARGS(cfg)])

    def test_it_refuses_while_another_vm_holds_the_disk(self):
        with TemporaryDirectory() as d, \
             mock.patch.object(passes.qemu, "running_vm_pids", return_value=[11]):
            with self.assertRaises(config.Precondition):
                passes.boot(self._cfg(d), exec_qemu=lambda c, a: None)

    def test_a_stale_socket_file_is_removed_before_qemu_starts(self):
        # qemu creates the socket, and refuses to if the path is taken. A
        # leftover from a killed run is otherwise read as a live console.
        order = []
        with TemporaryDirectory() as d, \
             mock.patch.object(passes.qemu, "require_no_running_vm"):
            cfg = self._cfg(d)
            cfg.console_sock.write_text("stale")
            passes.boot(cfg, exec_qemu=lambda c, a: order.append(cfg.console_sock.exists()))
        self.assertEqual(order, [False])

    def test_detached_returns_once_the_console_socket_exists(self):
        with TemporaryDirectory() as d, \
             mock.patch.object(passes.qemu, "require_no_running_vm"):
            cfg = self._cfg(d)

            def spawn(c, argv, out):
                sock = socket.socket(socket.AF_UNIX)
                self.addCleanup(sock.close)
                sock.bind(str(c.console_sock))
                return "popen"

            self.assertEqual(passes.boot_detached(cfg, spawn=spawn), "popen")
            self.assertTrue((cfg.dir / "qemu-boot.out").is_file())

    def test_detached_is_a_precondition_when_the_socket_never_appears(self):
        # The shape this catches is a qemu that died at once -- a bad argument,
        # a held disk. Without it the next thing to run is Console.connect
        # against nothing, whose ConnectionRefusedError names neither.
        with TemporaryDirectory() as d, \
             mock.patch.object(passes.qemu, "require_no_running_vm"):
            cfg = self._cfg(d)
            with self.assertRaises(config.Precondition) as caught:
                passes.boot_detached(cfg, timeout=0, spawn=lambda c, a, o: None)
            self.assertIn("qemu-boot.out", str(caught.exception))

    def test_detached_refuses_while_another_vm_holds_the_disk(self):
        # final_pass's own copy of this body had no such guard.
        #
        # The message is asserted because this test PASSED VACUOUSLY without
        # it: with timeout=0 and a spawn that starts nothing, the socket check
        # below raises a Precondition of its own, so deleting the guard under
        # test left the assertRaises satisfied by the wrong exception. Found by
        # mutating _prepare_boot, which failed the boot() test beside this one
        # and not this one.
        with TemporaryDirectory() as d, \
             mock.patch.object(passes.qemu, "running_vm_pids", return_value=[11]):
            with self.assertRaises(config.Precondition) as caught:
                passes.boot_detached(self._cfg(d), timeout=0,
                                     spawn=lambda c, a, o: None)
            self.assertIn("already running", str(caught.exception))
