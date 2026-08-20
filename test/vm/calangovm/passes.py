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
    only way to see whether the desktop is right: no harness here can do either.
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
        # buffering=1. main()'s line_buffering covers sys.stdout and
        # sys.stderr and does not reach this file, and this file is the one
        # stream `python3 -u` was used for in run-all.sh -- it only ever ran
        # drive.py in the redirected form. Block-buffered, `tail -f` on a stage
        # log shows nothing for the twenty minutes Stage C takes, which is the
        # exact "healthy run reads as a hung one" this harness keeps paying for,
        # and a killed run leaves the log empty rather than truncated.
        with log.open("w", buffering=1) as out:
            try:
                rc = drive(cfg, path, user, out=out)
            except Exception as exc:
                # run-all.sh ran drive.py as a SUBPROCESS, so anything it raised
                # arrived here as a nonzero exit and got the ordinary FAIL line,
                # log tail and summary. Here drive() runs in-process, so without
                # this the same conditions -- Console.connect against a qemu that
                # has died, login's 420s TimeoutError when a stage left the VM at
                # an unexpected prompt -- escape the loop as a raw traceback and
                # take the diagnostic shape of this harness with them, at exactly
                # the moment a live VM has gone wrong. Report it as a failure.
                print(f"{type(exc).__name__}: {exc}", file=out)
                rc = 1
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
