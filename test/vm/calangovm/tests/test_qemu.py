import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

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
