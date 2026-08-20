"""Configuration for the VM harness: five values, three derived, two read.

Ported from lib-qemu.sh.

  CALANGO_VM_DIR   where the disk, logs and console socket live. NOT the repo:
                   the disk is 30G. Default ~/vm/calango-runbook.
  CALANGO_VM_ISO   a Debian netinst image.
  CALANGO_VM_HOST  the hostname the VM gets, and the flake host you add in
                   Stage B. Default calango-vm.
  CALANGO_VM_PW    the throwaway password for the VM account. It is typed into
                   a scratch VM over a serial console; it is not a secret and
                   must not be reused anywhere.
  CALANGO_VM_PORT  host port forwarded to the guest's 22. Nothing listens
                   there -- the generated preseed installs no sshd -- but a
                   distinct port keeps two harness copies from colliding.

The ACCOUNT NAME is deliberately not configurable. See username().
"""

import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

DEFAULTS = {
    "dir": "~/vm/calango-runbook",
    "iso": "~/Downloads/debian-13.6.0-amd64-netinst.iso",
    "host": "calango-vm",
    "pw": "rehearsal",
    "port": "2622",
}

ENV = {name: "CALANGO_VM_" + name.upper() for name in DEFAULTS}


class Precondition(Exception):
    """The machine was not ready, as against something failing.

    Mapped to exit code 2 by the vm executable. The shell version exited 1 for
    both, so a caller could not tell "no ISO downloaded" from "Stage C failed".
    """


@dataclass(frozen=True)
class Config:
    dir: Path
    iso: Path
    host: str
    pw: str
    port: int
    repo: Path

    @property
    def http_port(self) -> int:
        """8622 from 2622. install.sh spelled it PORT=8${CALANGO_VM_PORT: -3}."""
        return int("8" + str(self.port)[-3:])

    @property
    def disk(self) -> Path:
        return self.dir / "disk.qcow2"

    @property
    def console_sock(self) -> Path:
        return self.dir / "console.sock"


def find_repo(start=None) -> Path:
    """The repository this harness tests, found from the harness's own location
    rather than hard-coded, so a clone anywhere works. lib-qemu.sh:29-30.

    `start` exists so a test can build a tree and check the arithmetic. A test
    that instead called find_repo() bare and asserted against the real
    repository would pass here and FAIL inside the sandbox of
    checks.vm-harness-tests, which copies test/vm to harness/ with no flake.nix
    three levels above it.
    """
    repo = (Path(__file__) if start is None else Path(start)).resolve().parents[3]
    if not (repo / "flake.nix").is_file():
        raise Precondition(
            f"no flake.nix at {repo} -- is calangovm/ still at test/vm/calangovm/?")
    return repo


def _port(value: str) -> int:
    """A bad --port is a precondition, not a crash.

    `int()` on a non-numeric value raised a ValueError that main() did not map,
    so `vm --port abc config` exited 1 with a traceback -- the code the contract
    reserves for "a stage failed". A caller could not tell a typo in its own
    command line from the harness finding a real defect.
    """
    try:
        return int(value)
    except ValueError:
        raise Precondition(
            f"{ENV['port']} / --port must be a number, not {value!r}") from None


def resolve(overrides=None, environ=None, repo=None) -> Config:
    """flag, then environment, then default -- and an empty value is not a value.

    lib-qemu.sh used `: "${VAR:=default}"`, whose := form treats an empty string
    as unset. `environ.get(...) or default` reproduces that; `in environ` does
    not.
    """
    overrides = overrides or {}
    environ = os.environ if environ is None else environ

    def pick(name: str) -> str:
        value = overrides.get(name)
        if value:
            return str(value)
        return environ.get(ENV[name]) or DEFAULTS[name]

    return Config(
        dir=Path(pick("dir")).expanduser(),
        iso=Path(pick("iso")).expanduser(),
        host=pick("host"),
        pw=pick("pw"),
        port=_port(pick("port")),
        repo=find_repo() if repo is None else repo,
    )


def bootstrap_path(cfg: Config) -> Path:
    """Build .#calangoBootstrap and return its store path. lib-qemu.sh's vm_bootstrap.

    `sg nix-users` is this project's convention and is always correct: a plain
    `nix` fails on /nix/var/nix/daemon-socket/ from any shell that predates the
    usermod, with a message that reads as a broken Nix install.
    """
    if shutil.which("sg") is None:
        raise Precondition("no sg on PATH; it comes from Debian's passwd package")
    proc = subprocess.run(
        ["sg", "nix-users", "-c",
         "nix build --no-link --print-out-paths .#calangoBootstrap"],
        cwd=cfg.repo, capture_output=True, text=True)
    if proc.returncode != 0:
        tail = "\n  ".join(proc.stderr.strip().splitlines()[-6:] or ["(no output)"])
        raise Precondition(f".#calangoBootstrap did not build:\n  {tail}")
    # nix's progress goes to stderr, so stdout holds only paths. Take the last,
    # which is $out -- the same reason lib-qemu.sh piped through `tail -1`.
    paths = [line for line in proc.stdout.split() if line.startswith("/nix/store/")]
    if not paths:
        raise Precondition(".#calangoBootstrap built but printed no store path")
    return Path(paths[-1])


def username(store: Path) -> str:
    """The account the installer will create, read out of the artifact under test.

    Deliberately not configurable. The generated preseed answers
    `d-i passwd/username` from the flake's home.username, so this is the one
    true source and a mismatch between the harness and the installed machine is
    impossible.

    lib-qemu.sh took the LAST field of that line; this takes the first token
    after the prefix, which is the same answer for every line without a trailing
    comment and the right one for a line with it.
    """
    prefix = "d-i passwd/username string "
    for line in (store / "preseed.cfg").read_text().splitlines():
        if line.startswith(prefix):
            return line[len(prefix):].split()[0]
    raise Precondition(f"no '{prefix}' line in {store}/preseed.cfg")
