"""The qemu command line, its environment, and whether one is already running.

Ported from lib-qemu.sh. One device list for every caller, so PCI enumeration --
and therefore the predictable interface name -- cannot differ between the
install and the boot.
"""

import os
import signal
import subprocess
import time
from pathlib import Path

from .config import Config, Precondition

QEMU = "qemu-system-x86_64"

# comm is truncated at 15 characters by the kernel, so `qemu-system-x86_64` --
# 18 characters -- never appears there. This is the name to match, and matching
# it is safe: the process doing the matching is python3.
QEMU_COMM = "qemu-system-x86"

# These five must not reach qemu. It is Debian's binary and a calango session
# exports Nix's mesa paths, which makes Debian's GTK load a Nix libEGL and abort
# in epoxy:
#   qemu: GtkGLArea console lacks DMABUF support.
#   epoxy_get_proc_address: Assertion `0 && "Couldn't find current GLX or EGL
#   context."' failed.
# lib-qemu.sh had to express this as a string prefix (`env -u ... -u ...`)
# because `exec` cannot run a shell function. A dict has no such constraint.
NIXGL_VARS = (
    "LD_LIBRARY_PATH",
    "LIBGL_DRIVERS_PATH",
    "GBM_BACKENDS_PATH",
    "LIBVA_DRIVERS_PATH",
    "__EGL_VENDOR_LIBRARY_FILENAMES",
)


def strip_nixgl(environ=None) -> dict:
    environ = os.environ if environ is None else environ
    return {k: v for k, v in environ.items() if k not in NIXGL_VARS}


def common_args(cfg: Config) -> list[str]:
    """The device list, as a list. lib-qemu.sh's qemu_common.

    -vga none is load-bearing: with qemu's default VGA present as well, Hyprland
    opens the bochs device (pci id 1234:1111, driver (null)) and crashes in
    pixman -- a convincing false failure.
    """
    return [
        "-enable-kvm", "-machine", "q35", "-cpu", "host", "-m", "6G", "-smp", "4",
        "-drive", f"file={cfg.disk},if=virtio,cache=writeback",
        "-cdrom", str(cfg.iso),
        "-vga", "none", "-device", "virtio-gpu-gl-pci",
        "-netdev", f"user,id=n0,hostfwd=tcp:127.0.0.1:{cfg.port}-:22",
        "-device", "virtio-net-pci,netdev=n0",
    ]


def running_vm_pids(proc=Path("/proc")) -> list[int]:
    """Every pid whose comm is qemu's.

    lib-qemu.sh asked pgrep. pgrep -f matches the searching process's own
    command line -- a wait loop written that way never exits, and a pkill -f
    written that way kills the shell that issued it. Reading comm cannot
    self-match: this process's comm is python3.
    """
    pids = []
    for entry in sorted(proc.iterdir(), key=lambda p: p.name):
        if not entry.name.isdigit():
            continue
        try:
            comm = (entry / "comm").read_text().strip()
        except OSError:
            continue          # the process exited between iterdir and read
        if comm == QEMU_COMM:
            pids.append(int(entry.name))
    return sorted(pids)


def require_no_running_vm(cfg: Config, proc=Path("/proc")) -> None:
    """qemu holds a write lock on the image, so a leftover headless run makes the
    next command fail with `Failed to get "write" lock`, which reads like a
    corrupt disk and is really two VMs for one file.

    This stays machine-wide -- it matches any qemu, not one holding this disk.
    A narrower check would have to read /proc/<pid>/fd, which is unreadable for
    another user's process; here a false positive is safe and a false negative
    is the write-lock failure.
    """
    pids = running_vm_pids(proc)
    if pids:
        raise Precondition(
            f"a VM is already running (pid {', '.join(map(str, pids))}) and holds "
            f"{cfg.disk}.\n  Shut it down first:  vm stop")


def terminate_running_vms(proc=Path("/proc"), timeout: float = 60.0) -> None:
    """SIGTERM every qemu, then wait for them to go. final-pass.sh's first step."""
    for pid in running_vm_pids(proc):
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    end = time.monotonic() + timeout
    while running_vm_pids(proc) and time.monotonic() < end:
        time.sleep(2.0)
    if running_vm_pids(proc):
        raise Precondition(f"a qemu is still running after {timeout:.0f}s")


def exec_qemu(cfg: Config, extra: list[str]) -> None:
    """Replace this process with qemu, so the window belongs to the process the
    caller started. Never returns.
    """
    argv = [QEMU, *common_args(cfg), *extra]
    os.execvpe(QEMU, argv, strip_nixgl())


def spawn_qemu(cfg: Config, extra: list[str], stdout) -> subprocess.Popen:
    return subprocess.Popen([QEMU, *common_args(cfg), *extra],
                            env=strip_nixgl(), stdout=stdout,
                            stderr=subprocess.STDOUT)


def run_qemu(cfg: Config, extra: list[str]) -> int:
    return subprocess.run([QEMU, *common_args(cfg), *extra],
                          env=strip_nixgl()).returncode
