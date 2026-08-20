import signal
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

from calangovm import config, qemu

CFG = config.resolve(overrides={"dir": "/tmp/vmdir", "iso": "/tmp/d.iso"},
                     environ={}, repo=Path("/nowhere/repo"))


class Argv(unittest.TestCase):
    def test_vga_none_is_present(self):
        # -vga none is load-bearing: with qemu's default VGA also present,
        # Hyprland opens the bochs device and crashes in pixman.
        args = qemu.common_args(CFG)
        self.assertIn("-vga", args)
        self.assertEqual([args[i + 1] for i, a in enumerate(args) if a == "-vga"],
                         ["none"])

    def test_the_gl_device_is_present(self):
        self.assertIn("virtio-gpu-gl-pci", qemu.common_args(CFG))

    def test_the_disk_and_iso_come_from_the_config(self):
        args = qemu.common_args(CFG)
        self.assertIn("file=/tmp/vmdir/disk.qcow2,if=virtio,cache=writeback", args)
        self.assertIn("/tmp/d.iso", args)

    def test_the_forward_uses_the_configured_port(self):
        self.assertIn("user,id=n0,hostfwd=tcp:127.0.0.1:2622-:22", qemu.common_args(CFG))

    def test_every_element_is_a_separate_argument(self):
        # The shell version echoed one string and relied on word splitting. A
        # list element containing a space would be passed to qemu as one
        # argument and rejected.
        for a in qemu.common_args(CFG):
            self.assertNotIn(" ", a)

    def test_the_whole_list_is_this_exact_order(self):
        # One device list for every caller, so PCI enumeration -- and therefore
        # the predictable interface name -- cannot differ between the install
        # and the boot. Every other test in this class is assertIn, which a
        # reorder (e.g. swapping the two -device entries) sails straight
        # through. This one pins the full sequence.
        self.assertEqual(qemu.common_args(CFG), [
            "-enable-kvm", "-machine", "q35", "-cpu", "host", "-m", "6G", "-smp", "4",
            "-drive", "file=/tmp/vmdir/disk.qcow2,if=virtio,cache=writeback",
            "-cdrom", "/tmp/d.iso",
            "-vga", "none", "-device", "virtio-gpu-gl-pci",
            "-netdev", "user,id=n0,hostfwd=tcp:127.0.0.1:2622-:22",
            "-device", "virtio-net-pci,netdev=n0",
        ])


class NixglStrip(unittest.TestCase):
    def test_exactly_five_are_removed(self):
        self.assertEqual(len(qemu.NIXGL_VARS), 5)
        source = {v: "x" for v in qemu.NIXGL_VARS}
        source["PATH"] = "/usr/bin"
        source["HOME"] = "/home/someone"
        out = qemu.strip_nixgl(source)
        self.assertEqual(set(out), {"PATH", "HOME"})

    def test_the_five_are_the_right_five(self):
        self.assertEqual(sorted(qemu.NIXGL_VARS), [
            "GBM_BACKENDS_PATH", "LD_LIBRARY_PATH", "LIBGL_DRIVERS_PATH",
            "LIBVA_DRIVERS_PATH", "__EGL_VENDOR_LIBRARY_FILENAMES"])

    def test_nothing_else_is_touched(self):
        out = qemu.strip_nixgl({"XDG_RUNTIME_DIR": "/run/user/1000"})
        self.assertEqual(out, {"XDG_RUNTIME_DIR": "/run/user/1000"})


def fake_proc(entries):
    """A /proc-shaped directory: {pid: comm}. Returns a context manager."""
    d = TemporaryDirectory()
    root = Path(d.name)
    for pid, comm in entries.items():
        (root / str(pid)).mkdir()
        (root / str(pid) / "comm").write_text(comm + "\n")
    (root / "self").mkdir()          # a non-numeric entry, as /proc really has
    return d, root


class RunningVm(unittest.TestCase):
    def test_a_running_qemu_is_found(self):
        d, root = fake_proc({101: "bash", 202: "qemu-system-x86"})
        with d:
            self.assertEqual(qemu.running_vm_pids(root), [202])

    def test_no_qemu_is_an_empty_list(self):
        d, root = fake_proc({101: "bash", 202: "python3"})
        with d:
            self.assertEqual(qemu.running_vm_pids(root), [])

    def test_the_name_is_the_truncated_one(self):
        # comm is truncated at 15 characters by the kernel, so the full
        # qemu-system-x86_64 never appears there and must never be matched for.
        self.assertEqual(qemu.QEMU_COMM, "qemu-system-x86")
        self.assertEqual(len(qemu.QEMU_COMM), 15)

    def test_require_raises_when_one_is_running(self):
        d, root = fake_proc({202: "qemu-system-x86"})
        with d, self.assertRaises(config.Precondition):
            qemu.require_no_running_vm(CFG, root)

    def test_require_is_silent_when_none_is(self):
        d, root = fake_proc({101: "bash"})
        with d:
            self.assertIsNone(qemu.require_no_running_vm(CFG, root))


class TerminateRunningVms(unittest.TestCase):
    def test_it_signals_every_matching_pid(self):
        d, root = fake_proc(
            {101: "bash", 202: "qemu-system-x86", 303: "qemu-system-x86"})

        def die(pid, sig):
            # Simulate the process actually going away, the way a real SIGTERM
            # eventually does -- otherwise the wait loop below would spin for
            # the full timeout even though the signal was sent correctly.
            (root / str(pid) / "comm").unlink()
            (root / str(pid)).rmdir()

        with d, patch("calangovm.qemu.os.kill", side_effect=die) as mock_kill:
            qemu.terminate_running_vms(root, timeout=5.0)
        self.assertEqual(
            sorted(c.args for c in mock_kill.call_args_list),
            [(202, signal.SIGTERM), (303, signal.SIGTERM)])

    def test_it_signals_none_when_there_are_none(self):
        d, root = fake_proc({101: "bash"})
        with d, patch("calangovm.qemu.os.kill") as mock_kill:
            qemu.terminate_running_vms(root, timeout=5.0)
        mock_kill.assert_not_called()

    def test_it_raises_when_a_pid_persists_past_the_timeout(self):
        d, root = fake_proc({202: "qemu-system-x86"})
        # timeout=0.0 keeps this test fast: the wait loop's first check already
        # finds time.monotonic() past `end`, so it never sleeps before raising.
        with d, patch("calangovm.qemu.os.kill") as mock_kill:
            with self.assertRaises(config.Precondition):
                qemu.terminate_running_vms(root, timeout=0.0)
        mock_kill.assert_called_once_with(202, signal.SIGTERM)


def source_environ():
    """The five nixGL variables plus one unrelated one, for the strip to prove
    itself against. If the strip were ever dropped from exec_qemu/spawn_qemu/
    run_qemu, this is what would make each of the tests below fail.
    """
    source = {v: "x" for v in qemu.NIXGL_VARS}
    source["PATH"] = "/usr/bin"
    return source


class SubprocessInvocations(unittest.TestCase):
    """A missed `env=` on any of these three lets Nix's mesa reach Debian's
    qemu, which aborts in epoxy -- see qemu.NIXGL_VARS's comment. Each test
    below patches the subprocess entry point and checks the environment it was
    actually given, with all five variables present in the source environment
    so the assertion would fail if the strip were ever dropped.
    """

    def test_exec_qemu_strips_nixgl_and_passes_common_args(self):
        with patch("calangovm.qemu.os.execvpe") as mock_execvpe, \
             patch.dict("os.environ", source_environ(), clear=True):
            qemu.exec_qemu(CFG, ["-nographic"])
        prog, argv, env = mock_execvpe.call_args.args
        self.assertEqual(prog, qemu.QEMU)
        self.assertEqual(argv, [qemu.QEMU, *qemu.common_args(CFG), "-nographic"])
        for v in qemu.NIXGL_VARS:
            self.assertNotIn(v, env)
        self.assertEqual(env.get("PATH"), "/usr/bin")

    def test_spawn_qemu_strips_nixgl_and_passes_common_args(self):
        with patch("calangovm.qemu.subprocess.Popen") as mock_popen, \
             patch.dict("os.environ", source_environ(), clear=True):
            qemu.spawn_qemu(CFG, ["-nographic"], stdout=None)
        (argv,), kwargs = mock_popen.call_args
        self.assertEqual(argv, [qemu.QEMU, *qemu.common_args(CFG), "-nographic"])
        env = kwargs["env"]
        for v in qemu.NIXGL_VARS:
            self.assertNotIn(v, env)
        self.assertEqual(env.get("PATH"), "/usr/bin")

    def test_run_qemu_strips_nixgl_and_passes_common_args(self):
        with patch("calangovm.qemu.subprocess.run") as mock_run, \
             patch.dict("os.environ", source_environ(), clear=True):
            mock_run.return_value.returncode = 0
            qemu.run_qemu(CFG, ["-nographic"])
        (argv,), kwargs = mock_run.call_args
        self.assertEqual(argv, [qemu.QEMU, *qemu.common_args(CFG), "-nographic"])
        env = kwargs["env"]
        for v in qemu.NIXGL_VARS:
            self.assertNotIn(v, env)
        self.assertEqual(env.get("PATH"), "/usr/bin")
