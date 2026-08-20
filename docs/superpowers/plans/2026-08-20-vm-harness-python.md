# VM Harness in Python — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `test/vm/`'s seven shell scripts and `drive.py` with one importable Python package and one executable, so the harness's rules can be held by unit tests that run under `nix flake check`.

**Architecture:** A package `test/vm/calangovm/` holds six modules, split so each has one job and none needs a VM to test. One executable, `test/vm/vm`, is argparse and dispatch and nothing else. A new flake check runs the standard-library test suite in the Nix sandbox. The old files stay untouched until a green `final-pass` on a fresh disk, then go in one commit.

**Tech Stack:** Python 3.13 standard library only. `unittest`, `argparse`, `socket`, `http.server`, `subprocess`, `gzip`. No third-party package, no `pytest`. Nix (`pkgs.runCommand`, `pkgs.python3`) for the check.

**Spec:** `docs/superpowers/specs/2026-08-20-vm-harness-python-design.md`

## Global Constraints

- **Standard library only.** No `pytest`, no third-party import, anywhere.
- **Every comment in a shell source travels** to the Python that replaces it. The comments are the expensive part of these files; each records a debugging session. Where a step says "carry the comment from `X:NN-MM`", copy that comment across and adapt only its references.
- **Transliteration**, except at the three points the spec names: argv as a list, environment as a dict, `/proc/*/comm` instead of `pgrep`.
- **Nothing under `test/vm/steps/` or `test/vm/human-answers.cfg` changes.** They are the transcription of the document under test, guarded by `vm-step-lines-verbatim`.
- **Every test is proven able to fail by mutation, and the step records the mutation.** Three checks in this project's history passed while the property they stood for was false.
- **New files must be `git add`ed before `nix flake check`.** A flake evaluates only tracked paths; an untracked `calangovm/` makes the new check pass against a directory missing most of what it tests.
- **Wrap every `nix` invocation:** `sg nix-users -c '...'`.
- **`/usr/bin/grep` when a count is load-bearing.** The interactive shell's `grep` is ugrep and returns 0 for a pattern containing `${`. This does not apply inside a Nix builder or inside Python.
- **Do not edit `docs/2026-08-19-results-suffer-generated-preseed.md`.** It is a record of a run that happened.
- The five nixGL variables are `LD_LIBRARY_PATH`, `LIBGL_DRIVERS_PATH`, `GBM_BACKENDS_PATH`, `LIBVA_DRIVERS_PATH`, `__EGL_VENDOR_LIBRARY_FILENAMES`. Exactly five, no more and no fewer.

## File Structure

| file | responsibility |
|---|---|
| `test/vm/vm` | argparse, subcommand dispatch, exit-code mapping. No logic. |
| `test/vm/calangovm/__init__.py` | empty; makes the package importable |
| `test/vm/calangovm/config.py` | the five values, the two derived, the store path, the account name |
| `test/vm/calangovm/qemu.py` | argv list, environment strip, the running-VM check, exec and run |
| `test/vm/calangovm/console.py` | the unix socket: read, send, expect, login |
| `test/vm/calangovm/driver.py` | step files: parse, substitute, wrap, send and wait |
| `test/vm/calangovm/install.py` | initrd, the newc read-back guard, the preseed server, Stage 0 |
| `test/vm/calangovm/passes.py` | boot, display, run-all, final-pass |
| `test/vm/calangovm/tests/` | the unit suite, one module per module above |
| `flake.nix` | gains `checks.vm-harness-tests` |

## Correction to the spec, made before Task 1

The spec's `driver.py` test row lists *"a step file that spells an account name literally fails"*. **That guard cannot be written and is dropped.** Measured:

```sh
/usr/bin/grep -n 'isutton' test/vm/steps/*.txt
# steps/10-stage-b.txt:32:cd ~/Projects/calango-nix && sed -i 's|^      suffer = mkHome "isutton" "suffer";|…
```

**Two subcommands beyond the spec's six**, both small and both worth stating
rather than smuggling in. `vm config` prints the resolved configuration, the
store path and the account name; it is what makes Task 1 independently testable
and it is the first thing to run when a value looks wrong. `vm stop` sends
SIGTERM to every running qemu — `qemu.require_no_running_vm`'s error message
has to name a command a reader can type, and `pkill -x qemu-system-x86` is the
form this project has twice killed its own shell with.

That line is legitimate: it is a `sed` whose pattern must match `flake.nix`'s existing `suffer` entry, so it spells the account on purpose. The configured account name for the VM *is* `isutton` — `home.username` — so a guard on the configured name matches this line too. A guard on the hostname fails the same way as soon as `--host suffer` is passed, because that string also appears in the same `sed`. The needle has another answer in the haystack; do not write the guard. Task 4 carries the remaining four `driver.py` cases.

---

### Task 1: the package, `config.py`, and the flake check

**Files:**
- Create: `test/vm/calangovm/__init__.py`
- Create: `test/vm/calangovm/config.py`
- Create: `test/vm/calangovm/tests/__init__.py`
- Create: `test/vm/calangovm/tests/test_config.py`
- Create: `test/vm/vm`
- Modify: `flake.nix` (add `checks.vm-harness-tests`)

**Interfaces:**
- Consumes: nothing.
- Produces: `config.Config` (frozen dataclass with `dir: Path`, `iso: Path`, `host: str`, `pw: str`, `port: int`, `repo: Path`, and properties `http_port: int`, `disk: Path`, `console_sock: Path`); `config.Precondition(Exception)`; `config.DEFAULTS: dict[str,str]`; `config.ENV: dict[str,str]`; `config.resolve(overrides=None, environ=None, repo=None) -> Config`; `config.find_repo() -> Path`; `config.bootstrap_path(cfg) -> Path`; `config.username(store: Path) -> str`.

- [ ] **Step 1: Create the package directories**

```bash
mkdir -p test/vm/calangovm/tests
touch test/vm/calangovm/__init__.py test/vm/calangovm/tests/__init__.py
```

- [ ] **Step 2: Write the failing tests**

Create `test/vm/calangovm/tests/test_config.py`:

```python
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
```

- [ ] **Step 3: Run the tests and verify they fail**

Run: `cd test/vm && python3 -m unittest discover -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'calangovm.config'`, exit 1.

- [ ] **Step 4: Write `config.py`**

Create `test/vm/calangovm/config.py`. Carry the per-variable comment block from `lib-qemu.sh:1-20` into the module docstring, and the "the ACCOUNT NAME is deliberately not configurable" comment from `lib-qemu.sh:19-20,61-63` onto `username`.

```python
"""Configuration for the VM harness: five values, two derived, two read.

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


def find_repo() -> Path:
    """The repository this harness tests, found from the harness's own location
    rather than hard-coded, so a clone anywhere works. lib-qemu.sh:29-30.
    """
    repo = Path(__file__).resolve().parents[3]
    if not (repo / "flake.nix").is_file():
        raise Precondition(
            f"no flake.nix at {repo} -- is calangovm/ still at test/vm/calangovm/?")
    return repo


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
        port=int(pick("port")),
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
```

- [ ] **Step 5: Run the tests and verify they pass**

Run: `cd test/vm && python3 -m unittest discover -v`
Expected: PASS, 11 tests.

- [ ] **Step 6: Prove three of the tests can fail**

Mutate, run, revert, re-read the file. Record each result in the task report.

| mutation | test that must fail |
|---|---|
| `return environ.get(ENV[name]) or DEFAULTS[name]` → `return environ.get(ENV[name], DEFAULTS[name])` | `test_an_empty_variable_is_not_a_value` |
| `"8" + str(self.port)[-3:]` → `"8" + str(self.port)` | `test_2622_gives_8622` |
| `raise Precondition(...)` in `username` → `return "isutton"` | `test_an_absent_username_is_a_precondition` |

Revert with `git restore --worktree <path>` after staging the good content — never `--staged --worktree`, which restores from HEAD and would delete a file new to this branch.

- [ ] **Step 7: Write the `vm` executable**

Create `test/vm/vm`, mode 755:

```python
#!/usr/bin/env python3
"""One entry point for the VM harness. See test/vm/README.md.

Subcommands are added by the module that implements them; this file is
argparse, dispatch and the exit-code mapping, and holds no logic of its own.
"""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from calangovm import config


def build_parser():
    ap = argparse.ArgumentParser(prog="vm", description="Drive RUNBOOK.md in qemu.")
    for name in sorted(config.ENV):
        ap.add_argument(f"--{name}", default=None,
                        help=f"{config.ENV[name]} (default: {config.DEFAULTS[name]})")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("config", help="print the resolved configuration")
    p.set_defaults(func=cmd_config)

    return ap


def cmd_config(cfg, args):
    for field in ("dir", "iso", "host", "pw", "port", "repo"):
        print(f"{field:<12} {getattr(cfg, field)}")
    print(f"{'http_port':<12} {cfg.http_port}")
    store = config.bootstrap_path(cfg)
    print(f"{'bootstrap':<12} {store}")
    print(f"{'account':<12} {config.username(store)}")
    return 0


def main(argv=None):
    # Line-buffer both streams. Python block-buffers whenever the stream is not
    # a tty, so `vm final-pass > log` or a pipe into tee shows nothing for
    # minutes and a healthy run reads as a hung one. drive.py needed `python3 -u`
    # from every caller for exactly this; now a caller cannot get it wrong.
    sys.stdout.reconfigure(line_buffering=True)
    sys.stderr.reconfigure(line_buffering=True)

    args = build_parser().parse_args(argv)
    try:
        cfg = config.resolve(overrides={name: getattr(args, name) for name in config.ENV})
        return args.func(cfg, args)
    except config.Precondition as exc:
        print(f"vm: {exc}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("\ninterrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
```

```bash
chmod 755 test/vm/vm
```

- [ ] **Step 8: Add the flake check**

In `flake.nix`, inside the same `checks.${system}` attrset that holds `vm-step-lines-verbatim`, add:

```nix
        # The harness's own unit tests. No VM, no network, no kvm: everything
        # under test is argv construction, string handling, a socketpair and a
        # fake /proc tree.
        #
        # No vacuity anchor, and that is measured rather than assumed --
        # `unittest discover` is the one guard shape in this flake that cannot
        # pass having asserted nothing. Python 3.13.5:
        #
        #   empty directory              -> exit 5, "NO TESTS RAN"
        #   a file with no test methods  -> exit 5, "NO TESTS RAN"
        #   a missing start directory    -> exit 1, ImportError
        #   an unimportable test module  -> exit 1, reported as a failing test
        #
        # Re-measure if the sandbox python ever moves major version.
        vm-harness-tests =
          pkgs.runCommand "vm-harness-tests"
            { nativeBuildInputs = [ pkgs.python3 ]; } ''
              cp -r ${./test/vm} harness
              chmod -R +w harness
              cd harness
              python3 -m unittest discover -v
              touch "$out"
            '';
```

- [ ] **Step 9: Track the new files, then run the check**

A flake evaluates only tracked paths. Without this the check builds against a `test/vm` missing `calangovm/` entirely and passes having tested nothing.

```bash
git add test/vm/calangovm test/vm/vm flake.nix
sg nix-users -c 'nix flake check' 2>&1 | grep -c '^checking derivation checks\.'
sg nix-users -c 'nix flake check' 2>&1 | grep -o 'running [0-9]* flake checks'
```

Expected: both agree, and both read one higher than before this task. Record the number; do not assume it.

- [ ] **Step 10: Prove the check can fail**

```bash
sed -i 's/self.assertEqual(c.http_port, 8622)/self.assertEqual(c.http_port, 9999)/' \
  test/vm/calangovm/tests/test_config.py
/usr/bin/grep -c 9999 test/vm/calangovm/tests/test_config.py   # must read 1
sg nix-users -c 'nix build --no-link .#checks.x86_64-linux.vm-harness-tests'
# must FAIL, naming test_2622_gives_8622
git restore --worktree test/vm/calangovm/tests/test_config.py
/usr/bin/grep -c 9999 test/vm/calangovm/tests/test_config.py   # must read 0
```

- [ ] **Step 11: Commit**

```bash
git add test/vm/calangovm test/vm/vm flake.nix
git commit -m "test/vm: the harness config, importable, with a check that runs its tests"
```

---

### Task 2: `qemu.py`

**Files:**
- Create: `test/vm/calangovm/qemu.py`
- Create: `test/vm/calangovm/tests/test_qemu.py`

**Interfaces:**
- Consumes: `config.Config`, `config.Precondition`.
- Produces: `qemu.NIXGL_VARS: tuple[str,...]`; `qemu.QEMU_COMM: str`; `qemu.strip_nixgl(environ=None) -> dict`; `qemu.common_args(cfg) -> list[str]`; `qemu.running_vm_pids(proc=Path("/proc")) -> list[int]`; `qemu.require_no_running_vm(cfg, proc=Path("/proc")) -> None`; `qemu.terminate_running_vms(proc=Path("/proc"), timeout=60.0) -> None`; `qemu.exec_qemu(cfg, extra: list[str]) -> None`; `qemu.spawn_qemu(cfg, extra, stdout) -> subprocess.Popen`; `qemu.run_qemu(cfg, extra) -> int`.

- [ ] **Step 1: Write the failing tests**

Create `test/vm/calangovm/tests/test_qemu.py`:

```python
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
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `cd test/vm && python3 -m unittest discover -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'calangovm.qemu'`.

- [ ] **Step 3: Write `qemu.py`**

Carry `lib-qemu.sh:33-43`'s device comments and `lib-qemu.sh:45-53`'s nixGL comment verbatim, and `lib-qemu.sh:69-72`'s write-lock comment onto `require_no_running_vm`.

```python
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
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `cd test/vm && python3 -m unittest discover -v`
Expected: PASS.

- [ ] **Step 5: Prove three tests can fail**

| mutation | test that must fail |
|---|---|
| delete `"-vga", "none",` from `common_args` | `test_vga_none_is_present` |
| add `"XDG_SESSION_TYPE"` to `NIXGL_VARS` | `test_exactly_five_are_removed` and `test_the_five_are_the_right_five` |
| `QEMU_COMM = "qemu-system-x86"` → `"qemu-system-x86_64"` | `test_a_running_qemu_is_found` and `test_the_name_is_the_truncated_one` |

- [ ] **Step 6: Commit**

```bash
git add test/vm/calangovm/qemu.py test/vm/calangovm/tests/test_qemu.py
git commit -m "test/vm: the qemu argv as a list, and a running-VM check that cannot self-match"
```

---

### Task 3: `console.py`

**Files:**
- Create: `test/vm/calangovm/console.py`
- Create: `test/vm/calangovm/tests/test_console.py`

**Interfaces:**
- Consumes: nothing from the package.
- Produces: `console.Console` with `__init__(sock, timeout=1.0)`, classmethod `connect(path, timeout=1.0)`, `read(seconds=1.0) -> str`, `send(line: str) -> None`, `expect(pattern: str, seconds=120.0, poll=3.0) -> str`, attribute `log: str`; `console.login(c, user, pw, timeout=420.0, poll=3.0) -> None`.

- [ ] **Step 1: Write the failing tests**

Create `test/vm/calangovm/tests/test_console.py`:

```python
import socket
import threading
import unittest

from calangovm import console


def pair():
    """Two connected sockets: one for the Console, one standing in for the VM."""
    a, b = socket.socketpair()
    return console.Console(a, timeout=0.05), b


class ReadSendExpect(unittest.TestCase):
    def test_send_appends_a_newline(self):
        c, vm = pair()
        c.send("hello")
        self.assertEqual(vm.recv(64), b"hello\n")

    def test_expect_returns_when_the_pattern_arrives(self):
        c, vm = pair()
        vm.sendall(b"noise\nDONE-3=0\n")
        self.assertIn("DONE-3=0", c.expect(r"DONE-3=(\d+)", 5.0, poll=0.05))

    def test_expect_raises_and_names_the_tail(self):
        c, vm = pair()
        vm.sendall(b"this is not it\n")
        with self.assertRaises(TimeoutError) as caught:
            c.expect(r"NEVER-APPEARS", 0.4, poll=0.05)
        self.assertIn("this is not it", str(caught.exception))

    def test_the_log_accumulates_across_reads(self):
        c, vm = pair()
        vm.sendall(b"one\n")
        c.read(0.2)
        vm.sendall(b"two\n")
        c.read(0.2)
        self.assertIn("one", c.log)
        self.assertIn("two", c.log)


class Login(unittest.TestCase):
    def test_nothing_but_newlines_is_sent_before_a_prompt(self):
        """The rule that cost a whole final pass.

        login used to probe with `echo PROBE-OK-42`. On a machine that had just
        booted, those characters went to GRUB, whose serial console was still
        up -- and `e`, the first letter of `echo`, is GRUB's "edit this entry"
        key. A bare newline is the only safe blind keystroke.
        """
        c, vm = pair()
        seen = bytearray()
        stop = threading.Event()

        def collect():
            vm.settimeout(0.05)
            while not stop.is_set():
                try:
                    seen.extend(vm.recv(4096))
                except OSError:
                    pass

        t = threading.Thread(target=collect, daemon=True)
        t.start()
        with self.assertRaises(TimeoutError):
            console.login(c, "someone", "secret", timeout=0.6, poll=0.05)
        stop.set()
        t.join(2.0)
        self.assertGreater(len(seen), 0, "login sent nothing at all; it must poke")
        self.assertEqual(set(seen), {ord("\n")},
                         f"login sent something other than a newline: {bytes(seen)!r}")

    def test_a_login_prompt_gets_the_account_and_the_password(self):
        c, vm = pair()
        got = []

        def next_real_line():
            # Ignore the bare newlines login pokes with. Reading raw here races:
            # the poke can arrive before the account does, and the assertion
            # then fails on a healthy login.
            buf = b""
            while True:
                buf += vm.recv(4096)
                line = buf.replace(b"\n", b"")
                if line:
                    return line

        def guest():
            vm.settimeout(5.0)
            vm.sendall(b"\ncalango-vm login: ")
            got.append(next_real_line())        # the account
            vm.sendall(b"\nPassword: ")
            got.append(next_real_line())        # the password
            vm.sendall(b"\nsomeone@calango-vm:~$ ")

        t = threading.Thread(target=guest, daemon=True)
        t.start()
        console.login(c, "someone", "secret", timeout=20.0, poll=0.05)
        t.join(10.0)
        self.assertEqual(got, [b"someone", b"secret"])

    def test_the_password_reaches_the_guest_as_an_exported_variable(self):
        # The step files' sudo wrapper needs the password and must not spell it.
        c, vm = pair()
        vm.sendall(b"someone@calango-vm:~$ ")
        console.login(c, "someone", "s3cr3t", timeout=20.0, poll=0.05)
        vm.settimeout(1.0)
        got = b""
        try:
            while True:
                chunk = vm.recv(4096)
                if not chunk:
                    break
                got += chunk
        except OSError:
            pass
        self.assertIn(b"export CALANGO_PW='s3cr3t'", got)
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `cd test/vm && python3 -m unittest discover -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'calangovm.console'`.

- [ ] **Step 3: Write `console.py`**

Transliterate `drive.py:28-78`. Carry the whole docstring of `login` (`drive.py:51-60`) verbatim — it is the GRUB lesson.

```python
"""The VM's serial console: a unix socket, and the login that must not type.

Ported from drive.py's Console class and login(). The socket is a parameter
rather than read from the environment at import time, which is what makes any of
this testable against a socketpair.
"""

import re
import socket
import time


class Console:
    def __init__(self, sock, timeout: float = 1.0):
        self.s = sock
        self.s.settimeout(timeout)
        self.log = ""

    @classmethod
    def connect(cls, path, timeout: float = 1.0) -> "Console":
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(str(path))
        return cls(s, timeout)

    def read(self, seconds: float = 1.0) -> str:
        end, out = time.monotonic() + seconds, ""
        while time.monotonic() < end:
            try:
                data = self.s.recv(65536)
                if not data:
                    break
                out += data.decode("utf-8", "replace")
            except socket.timeout:
                pass
        self.log += out
        return out

    def send(self, line: str) -> None:
        self.s.sendall((line + "\n").encode())

    def expect(self, pattern: str, seconds: float = 120.0,
               poll: float = 3.0) -> str:
        end, acc, rx = time.monotonic() + seconds, "", re.compile(pattern)
        while time.monotonic() < end:
            acc += self.read(min(poll, seconds))
            if rx.search(acc):
                return acc
        raise TimeoutError(f"{pattern} after {seconds}s; tail: {acc[-500:]!r}")


def login(c: Console, user: str, pw: str, timeout: float = 420.0,
          poll: float = 3.0) -> None:
    """Wait for a prompt, then log in. Sends NOTHING until one appears.

    This used to probe with `echo PROBE-OK-42`. On a machine that had just
    booted, those characters went to GRUB, whose serial console was still up --
    and `e`, the first letter of `echo`, is GRUB's "edit this entry" key. The
    final pass sat in GRUB's editor until it timed out, and the traceback showed
    grub.cfg being echoed back. A bare newline is the only safe thing to send
    blind: in GRUB it boots the highlighted entry, at a login prompt it reprints
    it, and in a shell it prints the prompt again.
    """
    acc, state = "", None
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        acc += c.read(poll)
        tail = acc[-3000:]
        if re.search(r"login:\s*$", tail) or "login:" in acc[-300:]:
            state = "login"
            break
        if re.search(r"(RDY> |\$ ?)$", tail):
            state = "shell"
            break
        c.send("")            # safe in GRUB, at a getty, and in a shell alike
    if state is None:
        raise TimeoutError(f"no prompt in {timeout}s; tail: {acc[-400:]!r}")
    if state == "login":
        c.send(user)
        c.expect(r"[Pp]assword:", 60, poll)
        c.send(pw)
        c.expect(r"\$", 90, poll)
    c.send("stty -echo 2>/dev/null; PS1='RDY> '")
    # The step files' sudo wrapper needs the password, and must not spell it.
    c.send("export CALANGO_PW='" + pw + "'")
    c.read(2.0)
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `cd test/vm && python3 -m unittest discover -v`
Expected: PASS. The suite must stay under ten seconds; if `test_nothing_but_newlines_is_sent_before_a_prompt` is slow, lower its `timeout`, never its assertions.

- [ ] **Step 5: Prove three tests can fail**

| mutation | test that must fail |
|---|---|
| `c.send("")` → `c.send("echo PROBE-OK-42")` in the wait loop | `test_nothing_but_newlines_is_sent_before_a_prompt` |
| delete the `export CALANGO_PW=...` line | `test_the_password_reaches_the_guest_as_an_exported_variable` |
| `raise TimeoutError(...)` in `expect` → `return acc` | `test_expect_raises_and_names_the_tail` |

The first mutation is the one that matters: it is the exact regression this test exists to catch, and the test must name what was sent in its failure message.

- [ ] **Step 6: Commit**

```bash
git add test/vm/calangovm/console.py test/vm/calangovm/tests/test_console.py
git commit -m "test/vm: the serial console, and a test that it types nothing into GRUB"
```

---

### Task 4: `driver.py` and `vm drive`

**Files:**
- Create: `test/vm/calangovm/driver.py`
- Create: `test/vm/calangovm/tests/test_driver.py`
- Modify: `test/vm/vm` (register the `drive` subcommand)

**Interfaces:**
- Consumes: `config.Config`, `console.Console`, `console.login`.
- Produces: `driver.DEFAULT_TIMEOUT: int`; `driver.PROMPT_PATTERN: str`; `driver.parse(text) -> list[tuple[int,str]]`; `driver.command(body, user, host) -> str`; `driver.wrap(cmd, index) -> str`; `driver.drive(cfg, steps_path, user, out=sys.stdout) -> int` (0 green, 1 a step failed or timed out).

- [ ] **Step 1: Write the failing tests**

Create `test/vm/calangovm/tests/test_driver.py`:

```python
import unittest

from calangovm import driver


class Parse(unittest.TestCase):
    def test_a_timeout_block_sets_the_timeout_for_what_follows(self):
        self.assertEqual(driver.parse("#T 120\n\nfirst\n\n#T 45\n\nsecond\n"),
                         [(120, "first"), (45, "second")])

    def test_the_timeout_persists_until_it_is_changed(self):
        steps = driver.parse("#T 120\n\nfirst\n\nsecond\n")
        self.assertEqual([t for t, _ in steps], [120, 120])

    def test_a_file_with_no_timeout_block_uses_the_default(self):
        self.assertEqual(driver.parse("only\n"),
                         [(driver.DEFAULT_TIMEOUT, "only")])

    def test_blank_blocks_are_dropped(self):
        self.assertEqual(len(driver.parse("a\n\n\n\n\nb\n")), 2)

    def test_a_multi_line_block_stays_one_step(self):
        self.assertEqual(driver.parse("one\ntwo\n"), [(driver.DEFAULT_TIMEOUT, "one\ntwo")])


class Command(unittest.TestCase):
    def test_comment_lines_are_dropped(self):
        self.assertEqual(driver.command("#= runbook text\nreal --cmd", "u", "h"),
                         "real --cmd")

    def test_lines_are_joined_with_semicolons(self):
        self.assertEqual(driver.command("one\ntwo", "u", "h"), "one; two")

    def test_tokens_are_substituted(self):
        self.assertEqual(
            driver.command("id -nG @USER@ on @HOST@", "isutton", "calango-vm"),
            "id -nG isutton on calango-vm")

    def test_the_doubled_token_stage_b_uses_substitutes(self):
        # steps/10-stage-b.txt writes "@USER@@@HOST@" for "user@host".
        self.assertEqual(driver.command('"@USER@@@HOST@"', "isutton", "calango-vm"),
                         '"isutton@calango-vm"')


class Wrap(unittest.TestCase):
    def test_the_marker_reads_the_first_pipeline_status(self):
        # Not $? -- that is grep's status, and grep matches nothing on a healthy
        # step, so every passing step would report a failure.
        self.assertIn('echo "DONE-7=${PIPESTATUS[0]}"', driver.wrap("true", 7))

    def test_the_bulk_goes_under_rl_and_never_tmp(self):
        # /tmp is cleared on boot, so the reboot taken to investigate a stall
        # destroys the evidence of the stall.
        w = driver.wrap("true", 7)
        self.assertIn("~/rl/step-7.log", w)
        self.assertNotIn("/tmp/", w)

    def test_prompt_shaped_lines_come_back_line_buffered(self):
        # apt runs maintainer scripts under a pty, so redirecting apt does not
        # make them non-interactive -- only invisible and unanswerable.
        w = driver.wrap("true", 1)
        self.assertIn("Package configuration", w)
        self.assertIn("--line-buffered", w)
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `cd test/vm && python3 -m unittest discover -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'calangovm.driver'`.

- [ ] **Step 3: Write `driver.py`**

Transliterate `drive.py:80-131`. Carry the three-lesson comment (`drive.py:101-110`) onto `wrap`, and the token comment (`drive.py:95-98`) onto `command`.

```python
"""Step files: parse them, substitute the tokens, send them, wait for the marker.

Ported from drive.py's parse() and main(). The console is a parameter and the
output stream is a parameter, so run_all can drive several files in one process
and redirect each to its own log.
"""

import re
import sys
import time
from pathlib import Path

from .console import Console, login

DEFAULT_TIMEOUT = 300

# What a maintainer script's prompt looks like on the console. apt runs
# maintainer scripts under a pty, so redirecting apt's own output does NOT make
# them non-interactive -- it makes them invisible AND unanswerable. These lines
# come back while the bulk still goes to a file inside the guest.
PROMPT_PATTERN = r"Package configuration|Configuring |<Yes>|\[Y/n\]|\[y/N\]|\?$"


def parse(text: str) -> list[tuple[int, str]]:
    """Blank-line-separated blocks. A block starting with '#T ' sets the timeout
    for every block after it."""
    steps, timeout = [], DEFAULT_TIMEOUT
    for block in text.split("\n\n"):
        block = block.strip()
        if not block:
            continue
        if block.startswith("#T "):
            timeout = int(block.split()[1])
            continue
        steps.append((timeout, block))
    return steps


def command(body: str, user: str, host: str) -> str:
    """The one line a block becomes.

    @USER@ and @HOST@ are the harness's own tokens, the same shape the flake
    uses in bootstrap/runbook.md.in. A step file must not spell the account or
    the hostname, so one copy of this harness cannot quietly hard-code the
    machine it was written on.
    """
    one = "; ".join(l for l in body.splitlines() if not l.startswith("#"))
    return one.replace("@USER@", user).replace("@HOST@", host)


def wrap(cmd: str, index: int) -> str:
    """Three lessons from the run that stalled, all of them paid for:

      * /tmp is cleared on boot, so a reboot to investigate destroyed the
        evidence. Logs go to ~/rl.
      * a redirected step makes an interactive prompt invisible AND
        unanswerable -- code's postinst asked a debconf question and the VM sat
        idle for ten minutes with a silent console. tee forwards prompt-shaped
        lines to the console while the bulk still goes to the file.
      * PIPESTATUS[0], not $?. $? is grep's status, and grep matches nothing on
        a healthy step.
    """
    return (
        f"mkdir -p ~/rl; ( {cmd} ) 2>&1 | tee ~/rl/step-{index}.log"
        f" | grep -aE --line-buffered '{PROMPT_PATTERN}'"
        f' ; echo "DONE-{index}=${{PIPESTATUS[0]}}"'
    )


def drive(cfg, steps_path, user: str, out=sys.stdout) -> int:
    steps = parse(Path(steps_path).read_text())
    c = Console.connect(cfg.console_sock)
    login(c, user, cfg.pw)
    for index, (timeout, body) in enumerate(steps, 1):
        print(f"\n===== step {index} (timeout {timeout}s) =====\n{body}\n"
              "----- output -----", file=out)
        c.send(wrap(command(body, user, cfg.host), index))
        try:
            c.expect(rf"DONE-{index}=(\d+)", timeout)
        except TimeoutError as exc:
            print(f"TIMEOUT: {exc}", file=out)
            c.send(f"tail -25 ~/rl/step-{index}.log")
            time.sleep(4)
            print(c.read(6.0), file=out)
            print(f"step {index} timed out", file=out)
            return 1
        rc = re.search(rf"DONE-{index}=(\d+)", c.log).group(1)
        c.send(f"echo '--- tail of step {index} ---'; tail -18 ~/rl/step-{index}.log")
        time.sleep(4)
        print(c.read(8.0), file=out)
        print(f"exit={rc}", file=out)
        if rc != "0":
            print(f"step {index} exited {rc}", file=out)
            return 1
    print("\nALL STEPS OK", file=out)
    return 0
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `cd test/vm && python3 -m unittest discover -v`
Expected: PASS.

- [ ] **Step 5: Register the `drive` subcommand**

In `test/vm/vm`, add to `build_parser()` after the `config` parser:

```python
    p = sub.add_parser("drive", help="run one steps file against a booted VM")
    p.add_argument("steps", help="path to a steps/*.txt file")
    p.set_defaults(func=cmd_drive)
```

and the handler, beside `cmd_config`:

```python
def cmd_drive(cfg, args):
    from calangovm import driver
    store = config.bootstrap_path(cfg)
    return driver.drive(cfg, args.steps, config.username(store))
```

- [ ] **Step 6: Prove three tests can fail**

| mutation | test that must fail |
|---|---|
| `${PIPESTATUS[0]}` → `$?` in `wrap` | `test_the_marker_reads_the_first_pipeline_status` |
| `~/rl/step-{index}.log` → `/tmp/step-{index}.log` | `test_the_bulk_goes_under_rl_and_never_tmp` |
| delete `.replace("@HOST@", host)` from `command` | `test_tokens_are_substituted` and `test_the_doubled_token_stage_b_uses_substitutes` |

- [ ] **Step 7: Commit**

```bash
git add test/vm/calangovm/driver.py test/vm/calangovm/tests/test_driver.py test/vm/vm
git commit -m "test/vm: the step driver, split from the console and testable"
```

---

### Task 5: `install.py` and `vm install`

**Files:**
- Create: `test/vm/calangovm/install.py`
- Create: `test/vm/calangovm/tests/test_install.py`
- Create: `test/vm/calangovm/tests/data/one-member.cpio` (a real `cpio` archive, generated in Step 1)
- Modify: `test/vm/vm` (register the `install` subcommand)

**Interfaces:**
- Consumes: `config.Config`, `config.Precondition`, `config.bootstrap_path`, `config.username`, `qemu.require_no_running_vm`, `qemu.run_qemu`.
- Produces: `install.HOST_KEYS: tuple[str,...]`; `install.PW_KEYS: tuple[str,...]`; `install.render_answers(text, host, pw) -> str`; `install.check_answers(rendered, host, pw) -> None`; `install.read_newc(blob: bytes) -> list[tuple[str,int]]`; `install.build_extra_cpio(preseed_text, workdir) -> Path`; `install.extract_kernel(cfg) -> tuple[Path,Path]`; `install.make_server(store, port, fetches) -> ThreadingHTTPServer`; `install.install(cfg) -> int`.

- [ ] **Step 1: Generate the cpio fixture with a real `cpio`**

The fixture must come from `cpio` itself. `read_newc` is verified *against* it, so a fixture hand-written from the same understanding as the parser would let one bug hide inside the other.

```bash
mkdir -p test/vm/calangovm/tests/data
T=$(mktemp -d)
printf 'd-i netcfg/get_hostname string calango-vm\n' > "$T/preseed.cfg"
( cd "$T" && printf 'preseed.cfg\n' | cpio -H newc -o --quiet ) \
  > test/vm/calangovm/tests/data/one-member.cpio
rm -rf "$T"
ls -l test/vm/calangovm/tests/data/one-member.cpio     # 512 bytes
```

- [ ] **Step 2: Write the failing tests**

Create `test/vm/calangovm/tests/test_install.py`:

```python
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
```

- [ ] **Step 3: Run the tests and verify they fail**

Run: `cd test/vm && python3 -m unittest discover -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'calangovm.install'`.

- [ ] **Step 4: Write `install.py`**

Carry `install.sh:1-15` into the module docstring, `install.sh:39-45` onto `build_extra_cpio`, `install.sh:49-51` onto `render_answers`, `install.sh:59-60` onto `check_answers`, and `install.sh:97-99` onto the fetch count.

```python
"""Stage 0 of RUNBOOK.md, for real: the GENERATED preseed, served verbatim out
of the store, against a Debian netinst.

Ported from install.sh. Two things stay deliberate:

  * no priority=critical on the boot line. RUNBOOK.md's Stage 0 does not carry
    it, and the point of this code is to boot the line the document prints.
  * the served directory is the STORE PATH, not a copy. A copy can drift from
    what .#calangoBootstrap ships, and then this rehearses a file nobody
    installs.

What a person would answer at the remaining prompts comes from
human-answers.cfg, which rides in the initrd.
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
```

- [ ] **Step 5: Run the tests and verify they pass**

Run: `cd test/vm && python3 -m unittest discover -v`
Expected: PASS.

- [ ] **Step 6: Register the `install` subcommand**

In `test/vm/vm`:

```python
    p = sub.add_parser("install", help="Stage 0: install from the generated preseed")
    p.set_defaults(func=cmd_install)
```

```python
def cmd_install(cfg, args):
    from calangovm import install
    return install.install(cfg)
```

- [ ] **Step 7: Prove three tests can fail**

| mutation | test that must fail |
|---|---|
| `return key + host` → `return line` in `render_answers` | `test_both_hostname_lines_are_rewritten` |
| `if found != len(PW_KEYS)` → `if found < 1` in `check_answers` | `test_three_password_lines_is_a_precondition` |
| delete the `if members != [...]` block in `build_extra_cpio` | `test_a_wrong_size_is_caught` |

- [ ] **Step 8: Commit**

```bash
git add test/vm/calangovm/install.py test/vm/calangovm/tests/test_install.py \
        test/vm/calangovm/tests/data/one-member.cpio test/vm/vm
git commit -m "test/vm: Stage 0, with the appended cpio verified by an independent reader"
```

---

### Task 6: `passes.py` and the remaining subcommands

**Files:**
- Create: `test/vm/calangovm/passes.py`
- Create: `test/vm/calangovm/tests/test_passes.py`
- Modify: `test/vm/vm` (register `boot`, `display`, `run-all`, `final-pass`, `stop`)

**Interfaces:**
- Consumes: everything above.
- Produces: `passes.BOOT_ARGS(cfg) -> list[str]`; `passes.boot(cfg) -> None` (never returns); `passes.display(cfg) -> None` (never returns); `passes.stop(cfg) -> int`; `passes.steps_files(harness=None) -> list[Path]`; `passes.run_all(cfg, drive=None, user=None) -> int`; `passes.final_pass(cfg) -> int`.

- [ ] **Step 1: Write the failing tests**

Create `test/vm/calangovm/tests/test_passes.py`:

```python
import unittest
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
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `cd test/vm && python3 -m unittest discover -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'calangovm.passes'`.

- [ ] **Step 3: Write `passes.py`**

Carry `boot-headless.sh:1-10` onto `boot`, `run-with-display.sh:1-6` onto `display`, `run-all.sh:1-7` onto `run_all`, and `final-pass.sh:1-11` onto `final_pass`.

```python
"""The stages, and the one command that runs all of them.

Ported from boot-headless.sh, run-with-display.sh, run-all.sh and final-pass.sh.
"""

import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

from . import driver, install, qemu
from .config import Config, Precondition, bootstrap_path, username


def BOOT_ARGS(cfg: Config) -> list[str]:
    """The console on a unix socket, which is how driver.py talks to it.

    There is no ssh here on purpose: the generated preseed's tasksel line is
    `standard` only, so this machine has no sshd. Spec 18's rehearsal added
    ssh-server as a harness deviation, and a 9p share as well -- and the share
    is why its Stage B passed while the `git clone` in the document was broken.
    If the harness supplies something, the runbook is not being tested on it.
    """
    return ["-boot", "order=c",
            "-display", "egl-headless,gl=on",
            "-serial", f"unix:{cfg.console_sock},server=on,wait=off"]


def boot(cfg: Config) -> None:
    qemu.require_no_running_vm(cfg)
    cfg.console_sock.unlink(missing_ok=True)
    qemu.exec_qemu(cfg, BOOT_ARGS(cfg))          # never returns


def display(cfg: Config) -> None:
    """The same machine in a window. Run it from a graphical session, not a tty.

    Log in with the account the preseed created and pick "Hyprland (Nix)" at
    tuigreet. This is the only way to answer Gate D's last two lines and the
    only way to see whether the desktop is right: no harness can do either.
    """
    qemu.require_no_running_vm(cfg)
    store = bootstrap_path(cfg)
    print(f"account: {username(store)}   password: {cfg.pw}")
    qemu.exec_qemu(cfg, ["-boot", "order=c", "-display", "gtk,gl=on"])


def stop(cfg: Config) -> int:
    pids = qemu.running_vm_pids()
    if not pids:
        print("no VM is running")
        return 0
    qemu.terminate_running_vms()
    print(f"stopped {len(pids)} qemu process(es)")
    return 0


def steps_files(harness: Path | None = None) -> list[Path]:
    harness = Path(__file__).resolve().parent.parent if harness is None else harness
    files = sorted((harness / "steps").glob("*.txt"))
    if not files:
        raise Precondition(f"no steps/*.txt under {harness}/steps -- "
                           "run_all would report a pass having run nothing")
    return files


def run_all(cfg: Config, drive=None, user: str | None = None) -> int:
    """Drive RUNBOOK.md's stages in order, stopping at the first that fails.

    Stage 0 is install(), before this: it drives the installer, not a login.
    Gate D's last two lines are not here -- they read loginctl and Hyprland's
    own /proc/<pid>/environ, so they need a person at tuigreet.
    """
    drive = driver.drive if drive is None else drive
    if user is None:
        user = username(bootstrap_path(cfg))
    print(f"driving as {user}@{cfg.host} over {cfg.console_sock}")

    passed = failed = 0
    for path in steps_files():
        name = path.stem
        print(f"\n================ {name} ================")
        log = cfg.dir / f"out-{name}.log"
        with log.open("w") as out:
            rc = drive(cfg, path, user, out=out)
        if rc == 0:
            print(f"PASS  {name}")
            passed += 1
        else:
            print(f"FAIL  {name}   (see {log})")
            print("".join(log.read_text().splitlines(keepends=True)[-25:]))
            failed += 1
            break
    print(f"\n---- {passed} passed, {failed} failed ----")
    return 1 if failed else 0


def final_pass(cfg: Config) -> int:
    """THE final pass: one command, fresh disk, no fixes applied mid-run.

    Iterating against a live VM is how defects are found. This is the evidence:
    a machine that did not exist when the command started, taken through every
    stage of the PUSHED RUNBOOK.md. A sequence assembled out of fixes is not
    evidence that the sequence works.
    """
    def log(message: str) -> None:
        stamp = datetime.now(timezone.utc).strftime("%H:%M:%SZ")
        print(f"\n######## {message}  ({stamp}) ########")

    log("stop any running VM")
    qemu.terminate_running_vms()

    log("check the step files still match the document")
    check = subprocess.run(
        ["sg", "nix-users", "-c",
         "nix build --no-link .#checks.x86_64-linux.vm-step-lines-verbatim"],
        cwd=cfg.repo)
    if check.returncode != 0:
        return 1

    log("Stage 0 -- the generated preseed, served verbatim from the store")
    if install.install(cfg) != 0:
        return 1

    log("boot the installed machine")
    cfg.console_sock.unlink(missing_ok=True)
    with (cfg.dir / "qemu-boot.out").open("w") as out:
        qemu.spawn_qemu(cfg, BOOT_ARGS(cfg), out)
    end = time.monotonic() + 180
    while not cfg.console_sock.is_socket() and time.monotonic() < end:
        time.sleep(1)
    if not cfg.console_sock.is_socket():
        raise Precondition(f"{cfg.console_sock} never appeared; see {cfg.dir}/qemu-boot.out")

    log("Gate A through Stage D")
    rc = run_all(cfg)

    log("result")
    if rc == 0:
        print("GREEN: Stage 0 through Stage D, one uninterrupted pass.")
        print("Remaining: Gate D's last two lines, which need a login at tuigreet.")
    else:
        print("NOT GREEN -- see the FAIL line above.")
    return rc
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `cd test/vm && python3 -m unittest discover -v`
Expected: PASS.

- [ ] **Step 5: Register the five remaining subcommands**

In `test/vm/vm`'s `build_parser()`:

```python
    for name, help_text, handler in (
            ("boot", "boot the installed machine, console on a unix socket", cmd_boot),
            ("display", "boot it in a window, for a person", cmd_display),
            ("run-all", "Gate A through Stage D against a booted machine", cmd_run_all),
            ("final-pass", "fresh disk, Stage 0 through Stage D", cmd_final_pass),
            ("stop", "SIGTERM every running qemu and wait for it to go", cmd_stop)):
        p = sub.add_parser(name, help=help_text)
        p.set_defaults(func=handler)
```

and the handlers:

```python
def cmd_boot(cfg, args):
    from calangovm import passes
    passes.boot(cfg)          # execs; never returns


def cmd_display(cfg, args):
    from calangovm import passes
    passes.display(cfg)       # execs; never returns


def cmd_run_all(cfg, args):
    from calangovm import passes
    return passes.run_all(cfg)


def cmd_final_pass(cfg, args):
    from calangovm import passes
    return passes.final_pass(cfg)


def cmd_stop(cfg, args):
    from calangovm import passes
    return passes.stop(cfg)
```

- [ ] **Step 6: Check the CLI answers**

```bash
./test/vm/vm --help
./test/vm/vm config
```

Expected: `--help` lists eight subcommands. `vm config` prints the resolved values, the store path and the account name — which exercises `bootstrap_path` and `username` against the real flake.

- [ ] **Step 7: Prove two tests can fail**

| mutation | test that must fail |
|---|---|
| delete `break` from `run_all`'s failure branch | `test_it_stops_at_the_first_failure` |
| delete the `if not files: raise` in `steps_files` | `test_an_empty_steps_directory_is_a_precondition` |

- [ ] **Step 8: Commit**

```bash
git add test/vm/calangovm/passes.py test/vm/calangovm/tests/test_passes.py test/vm/vm
git commit -m "test/vm: the stages, with an anchor run-all.sh never had"
```

---

### Task 7: verification

No code. This task produces the evidence that licenses Task 8, and it is the
only task that cannot be hurried.

**Files:** none.

- [ ] **Step 1: Run the whole check set and record the count**

```bash
sg nix-users -c 'nix flake check' 2>&1 | grep -o 'running [0-9]* flake checks'
sg nix-users -c 'nix flake check' 2>&1 | grep -c '^checking derivation checks\.'
sg nix-users -c 'nix flake check' 2>&1 | grep -c '^checking derivation'
```

Expected: the first two agree; the third is two higher, because it also counts
`calangoDeb` and `calangoBootstrap`. Write all three numbers into the task
report — Task 8 rewrites `CLAUDE.md` from them.

- [ ] **Step 2: Run the final pass on a fresh disk**

```bash
./test/vm/vm final-pass 2>&1 | tee ~/vm/final-pass-python.log
echo "exit=${PIPESTATUS[0]}"
```

About forty minutes, unattended. `PIPESTATUS[0]`, not `$?` — `tee`'s status
would otherwise report success for a failed pass, which is the exact defect
`final-pass.sh`'s own header warns about.

Expected: `GREEN: Stage 0 through Stage D, one uninterrupted pass.` and
`exit=0`.

- [ ] **Step 3: If it is not green, fix and run again**

A defect found here is a defect in the port. Fix it, commit, and start Step 2
over from a fresh disk. **Do not report a pass assembled out of fixes.**
Iterating and passing are different claims: only a clean run with no edits after
it is evidence that the sequence works.

- [ ] **Step 4: One person confirms the desktop**

```bash
./test/vm/vm display
```

From a graphical session, not a tty. Log in with the account and password the
command prints, choose "Hyprland (Nix)" at tuigreet, and confirm the desktop
comes up. No harness can answer this.

- [ ] **Step 5: Record the evidence**

Write into the task report: the three check counts, the `final-pass` exit
status, the wall-clock time, and whether the desktop came up. Task 8 must not
start without all five.

---

### Task 8: delete the old harness and rewrite the documents

**Files:**
- Delete: `test/vm/lib-qemu.sh`, `test/vm/install.sh`, `test/vm/boot-headless.sh`, `test/vm/run-with-display.sh`, `test/vm/run-all.sh`, `test/vm/final-pass.sh`, `test/vm/check-steps.sh`, `test/vm/drive.py`
- Modify: `test/vm/README.md`
- Modify: `CLAUDE.md`
- Modify: `flake.nix` (one comment references `check-steps.sh`)

- [ ] **Step 1: Confirm the evidence exists**

Read Task 7's report. If `final-pass` was not green on a fresh disk, or the
desktop was not confirmed, **stop**. Nothing here is reversible cheaply: the
shell harness is the only fallback while the Python one is unproven.

- [ ] **Step 2: Delete the eight files**

```bash
git rm test/vm/lib-qemu.sh test/vm/install.sh test/vm/boot-headless.sh \
       test/vm/run-with-display.sh test/vm/run-all.sh test/vm/final-pass.sh \
       test/vm/check-steps.sh test/vm/drive.py
ls -1 test/vm
```

Expected afterwards: `README.md`, `calangovm`, `human-answers.cfg`, `steps`, `vm`.

- [ ] **Step 3: Rewrite `test/vm/README.md`**

Keep the document's four sections and its voice. What changes:

- **Run it** — `./test/vm/vm final-pass`, and the iteration recipe becomes
  `./test/vm/vm drive steps/30-stage-c.txt` with no exported variables.
- **Configuration** — the table gains a flag column; the paragraph on the
  account name is unchanged.
- **What keeps the harness honest** — `check-steps.sh` is gone; the assertion is
  `vm-step-lines-verbatim`, which `vm final-pass` builds as its first step and
  which `nix flake check` runs anyway. Add that `checks.vm-harness-tests` runs
  the unit suite, and that it needs no vacuity anchor because `unittest
  discover` exits 5 on an empty suite.
- **What is a deviation and what is not** — unchanged. The four accommodations
  and the `DEBIAN_FRONTEND` paragraph carry over verbatim.
- **Nine things not to undo** — becomes **seven**. Delete the `python3 -u` entry
  and the `exit "$rc"` entry, and add one sentence to the section's opening
  saying where they went: both are now properties of the code, not of the
  caller. Add a line to the three that are now unit tests naming the test.
- **A new short section, "What is not covered."** Stage 0 serves the preseed
  with its own `http.server`, while `RUNBOOK.md`'s Stage 0 tells the reader to
  run `calango-serve-bootstrap`. No check spans the difference, because
  `vm-step-lines-verbatim` reads only `steps/*.txt` and Stage 0 has no step
  file. Say so plainly; do not close it here.

- [ ] **Step 4: Edit `CLAUDE.md`, three passages, all re-measured**

Use the numbers Task 7 recorded. Do not compute any of them by arithmetic on
the numbers already in the file.

1. The `nix flake check` passage: the sentence naming the count, the list of
   branches that moved it (add one clause for `vm-harness-tests`), and the
   measured three-line table, whose `'^checking derivation'` figure moves with
   the check count.
2. The `bar-title-slot` sentence — "unlike four of the other six" — is stale
   with one more check. Recount which checks run this flake's own code against
   which inspect a built tree, and write the two numbers you measured.
3. The paragraph describing `test/vm/check-steps.sh` as a script that "only
   runs when someone remembers to". That script is gone; `vm-step-lines-verbatim`
   is now the only implementation, and `vm final-pass` builds it as its first
   step. Rewrite the passage around that, and keep the reason the check exists.
4. The list of paths whose change requires running `nix flake check`: add
   `test/vm/calangovm/`.

- [ ] **Step 5: Fix the one `flake.nix` comment**

```bash
/usr/bin/grep -n 'check-steps' flake.nix
```

The comment reads "same reasoning as check-steps.sh". Rewrite it to state the
reasoning rather than to point at a deleted file.

- [ ] **Step 6: Check that nothing else names a deleted file**

```bash
/usr/bin/grep -rn 'check-steps\.sh\|final-pass\.sh\|boot-headless\.sh\|run-all\.sh\|run-with-display\.sh\|lib-qemu\.sh\|drive\.py\|install\.sh' \
  --include='*.md' --include='*.nix' --include='*.in' . \
  | /usr/bin/grep -v '^\./docs/2026-08-19-results'
```

Expected: no output. `docs/2026-08-19-results-suffer-generated-preseed.md` is
excluded on purpose — it is a record of a run that happened, and its seven
references are correct about the past.

- [ ] **Step 7: Run the whole check set once more**

```bash
sg nix-users -c 'nix flake check' 2>&1 | grep -o 'running [0-9]* flake checks'
```

Expected: the same number Task 7 recorded. A change here means Step 4 edited
something load-bearing.

- [ ] **Step 8: Commit**

```bash
git add -A test/vm CLAUDE.md flake.nix
git commit -m "test/vm: the shell harness is gone; the Python one is proven"
```

---

## Notes for the executor

- **The one irreversible step is Task 8.** Everything before it leaves both
  harnesses working. If Task 7 cannot go green, the correct outcome is a branch
  with the Python harness added and the shell harness intact — not a deletion on
  faith.
- **`git restore --worktree <path>`, never `--staged --worktree`.** The second
  restores from HEAD, which deletes a file new to this branch and destroys
  uncommitted work. Commit each task's real work before its mutation tests, so
  every revert is recoverable.
- **After every mutation revert, re-read the file and confirm a count.** A
  revert that silently did nothing reads exactly like a guard that cannot fail.
