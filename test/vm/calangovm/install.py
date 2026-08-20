"""Stage 0 of RUNBOOK.md, for real: the GENERATED preseed, served verbatim out
of the store, against a Debian netinst.

Ported from install.sh. Two things stay deliberate:

  * no priority=critical on the boot line. RUNBOOK.md's Stage 0 does not carry
    it, and the point of this code is to boot the line the document prints.
  * the served directory is the STORE PATH, not a copy. A copy can drift from
    what .#calangoBootstrap ships, and then this rehearses a file nobody
    installs.

What a person would answer at the remaining prompts comes from
human-answers.cfg, which rides in the initrd. See that file's own header for
why it is not on the kernel command line.
"""

import gzip
import hashlib
import shutil
import subprocess
import sys
import threading
import urllib.request
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from . import qemu
from .config import Config, Precondition, bootstrap_path, username

NEWC_MAGIC = b"070701"

# The hostname and the throwaway password come from the configuration rather
# than from the file, so one copy of this harness cannot hard-code the machine
# it was written on. Everything else in human-answers.cfg is a real answer a
# person gives at the installer.
HOST_KEYS = (
    "d-i netcfg/get_hostname string ",
    "d-i netcfg/hostname string ",
)
PW_KEYS = (
    "d-i passwd/root-password password ",
    "d-i passwd/root-password-again password ",
    "d-i passwd/user-password password ",
    "d-i passwd/user-password-again password ",
)


def render_answers(text: str, host: str, pw: str) -> str:
    def rewrite(line: str) -> str:
        for key in HOST_KEYS:
            if line.startswith(key):
                return key + host      # the trailing comment goes with the value
        for key in PW_KEYS:
            if line.startswith(key):
                return key + pw
        return line

    return "\n".join(rewrite(l) for l in text.splitlines()) + "\n"


def check_answers(rendered: str, host: str, pw: str) -> None:
    """Prove the substitution took. A stale hostname installs a machine the
    steps cannot find, and a stale password locks the driver out of it."""
    for key in HOST_KEYS:
        if key + host not in rendered:
            raise Precondition(f"hostname substitution failed: no '{key}{host}'")
    found = rendered.count("password " + pw)
    if found != len(PW_KEYS):
        raise Precondition(
            f"password substitution failed: {found} of {len(PW_KEYS)} lines")


def read_newc(blob: bytes) -> list[tuple[str, int]]:
    """The members of a cpio newc archive, as [(name, size), ...].

    Written here rather than shelled out to `cpio -t` on purpose: the archive is
    WRITTEN by cpio, so verifying it with cpio would let one bug hide inside the
    other. Two implementations, one property.

    newc: a 110-byte ASCII header (a 6-byte magic and thirteen 8-hex fields),
    then the NUL-terminated name, then the data, each padded to a 4-byte
    boundary of the whole archive.
    """
    members, off = [], 0
    while off + 110 <= len(blob):
        if blob[off:off + 6] != NEWC_MAGIC:
            raise ValueError(f"not a newc header at offset {off}")
        fields = [int(blob[off + 6 + i * 8: off + 14 + i * 8], 16) for i in range(13)]
        filesize, namesize = fields[6], fields[11]
        name = blob[off + 110: off + 110 + namesize - 1].decode()
        off += 110 + namesize
        off += -off % 4
        if name == "TRAILER!!!":
            return members
        members.append((name, filesize))
        off += filesize
        off += -off % 4
    raise ValueError("no TRAILER!!! member; the archive is truncated")


def build_extra_cpio(preseed_text: str, workdir: Path) -> Path:
    """The human's answers, as a gzipped cpio to append to the installer initrd.

    The kernel command line was tried first and panicked at 30 answers:
      Kernel panic - not syncing: Too many boot env vars at
      `apt-setup/cdrom/set-first=false'
    d-i loads /preseed.cfg from the initrd root before it asks anything, then
    still fetches url= and applies that too. The two files answer disjoint
    questions, which is the property under test.
    """
    staging = workdir / "initrd-extra"
    shutil.rmtree(staging, ignore_errors=True)
    staging.mkdir(parents=True)
    (staging / "preseed.cfg").write_text(preseed_text)

    proc = subprocess.run(["cpio", "-H", "newc", "-o", "--quiet"],
                          cwd=staging, input=b"preseed.cfg\n", capture_output=True)
    if proc.returncode != 0:
        raise Precondition("cpio failed: " + proc.stderr.decode()[-400:])

    expected = len(preseed_text.encode())
    members = read_newc(proc.stdout)
    if members != [("preseed.cfg", expected)]:
        raise Precondition(
            f"the appended cpio is not one preseed.cfg of {expected} bytes: {members}")

    out = workdir / "extra.cpio.gz"
    out.write_bytes(gzip.compress(proc.stdout, 9))
    return out


def extract_kernel(cfg: Config) -> tuple[Path, Path]:
    """The installer's kernel and initrd come out of the ISO itself, so no
    netboot download is needed and the kernel matches the image being installed.
    """
    vmlinuz, initrd = cfg.dir / "vmlinuz", cfg.dir / "initrd.gz"
    if vmlinuz.is_file() and initrd.is_file():
        return vmlinuz, initrd
    if shutil.which("bsdtar") is None:
        raise Precondition(
            "need bsdtar (libarchive-tools) to read the ISO, or drop vmlinuz "
            f"and initrd.gz into {cfg.dir} by hand")
    print("extracting the installer kernel and initrd from the ISO")
    for member, dest in (("install.amd/vmlinuz", vmlinuz),
                         ("install.amd/initrd.gz", initrd)):
        proc = subprocess.run(["bsdtar", "-xOf", str(cfg.iso), member],
                              capture_output=True)
        if proc.returncode != 0 or not proc.stdout:
            raise Precondition(f"could not read {member} out of {cfg.iso}")
        dest.write_bytes(proc.stdout)
    return vmlinuz, initrd


def make_server(store: Path, port: int, fetches: list) -> ThreadingHTTPServer:
    class Handler(SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw):
            super().__init__(*a, directory=str(store), **kw)

        def do_GET(self):
            if self.path == "/preseed.cfg":
                fetches.append(self.client_address[0])
            super().do_GET()

        def log_message(self, fmt, *args):
            sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    return ThreadingHTTPServer(("127.0.0.1", port), Handler)


def install(cfg: Config) -> int:
    qemu.require_no_running_vm(cfg)
    cfg.dir.mkdir(parents=True, exist_ok=True)
    if not cfg.iso.is_file():
        raise Precondition(f"no ISO at {cfg.iso}")

    vmlinuz, initrd = extract_kernel(cfg)

    print("building the preseeded initrd")
    harness = Path(__file__).resolve().parent.parent
    answers = render_answers((harness / "human-answers.cfg").read_text(),
                             cfg.host, cfg.pw)
    check_answers(answers, cfg.host, cfg.pw)
    extra = build_extra_cpio(answers, cfg.dir)
    preseeded = cfg.dir / "initrd-preseeded.gz"
    preseeded.write_bytes(initrd.read_bytes() + extra.read_bytes())

    store = bootstrap_path(cfg)
    digest = hashlib.sha256((store / "preseed.cfg").read_bytes()).hexdigest()
    print(f"serving {store}")
    print(f"sha256  {digest}  preseed.cfg")
    print(f"account the preseed will create: {username(store)}")

    fetches: list[str] = []
    httpd = make_server(store, cfg.http_port, fetches)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    serial = cfg.dir / "install-serial.log"
    try:
        url = f"http://127.0.0.1:{cfg.http_port}/preseed.cfg"
        with urllib.request.urlopen(url, timeout=10) as response:
            print(f"preseed reachable on the host: HTTP {response.status}")

        cfg.disk.unlink(missing_ok=True)
        subprocess.run(["qemu-img", "create", "-f", "qcow2", str(cfg.disk), "30G"],
                       check=True, stdout=subprocess.DEVNULL)

        # The boot line is the one RUNBOOK.md prints, plus a serial console.
        # 10.0.2.2 is the host as seen through qemu's user-mode networking.
        append = (f"auto=true url=http://10.0.2.2:{cfg.http_port}/preseed.cfg"
                  " console=ttyS0,115200n8 --- console=ttyS0,115200n8")
        qemu.run_qemu(cfg, [
            "-kernel", str(vmlinuz), "-initrd", str(preseeded),
            "-append", append,
            "-display", "egl-headless,gl=on",
            "-serial", f"file:{serial}", "-no-reboot",
        ])
    finally:
        httpd.shutdown()

    text = serial.read_bytes().decode("utf-8", "replace")
    if "Installation step failed" in text or "Kernel panic" in text:
        print(f"STAGE 0 FAILED -- see {serial}", file=sys.stderr)
        return 1

    # Two fetches are expected: the host probe above, then the installer's. One
    # means the installer never fetched it. The host cannot tell them apart by
    # address -- slirp presents the guest as 127.0.0.1, the same as a local
    # probe -- so the count is the whole evidence. install.sh only PRINTED this
    # number; here it is an assertion.
    if len(fetches) < 2:
        print(f"STAGE 0 FAILED -- {len(fetches)} preseed fetch(es) logged; the "
              "installer never fetched it", file=sys.stderr)
        return 1
    print(f"Stage 0 OK: {len(fetches)} preseed fetches logged")
    return 0
