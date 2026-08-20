"""The `vm` executable itself, which had no test, no import and no syntax check.

The whole-branch review found this: `checks.vm-harness-tests` runs
`unittest discover`, which never touches a file with no `.py` extension, and
nothing else in the tree imported it. So the one file holding the branch's only
stated behavioural promise -- the exit-code contract -- was the one file with no
coverage at all. Importing it here is also the syntax check
`bin/calango-serve-bootstrap` gets from its own builder.
"""

import contextlib
import importlib.machinery
import importlib.util
import io
import unittest
from pathlib import Path
from unittest import mock

from calangovm import config

VM = Path(__file__).resolve().parents[2] / "vm"


class Stream(io.StringIO):
    """A StringIO main() can line-buffer.

    `main()` calls `sys.stdout.reconfigure(line_buffering=True)`, which a plain
    StringIO does not have. Adding the no-op here rather than making main()
    check for the attribute: the line-buffering is load-bearing -- it is what
    replaced the `python3 -u` every caller had to remember -- and softening it
    so a test can run is how a guard quietly stops guarding.
    """

    def reconfigure(self, **kwargs):
        pass


def load_vm():
    """Import `test/vm/vm`, which has no .py extension so nothing finds it.

    The module name is deliberately not "vm": exec_module runs the file, and
    its `if __name__ == "__main__"` guard must not fire.
    """
    loader = importlib.machinery.SourceFileLoader("vmcli", str(VM))
    spec = importlib.util.spec_from_loader("vmcli", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


# A Config that needs neither the real repository nor a running nix. main()
# otherwise calls find_repo(), which cannot succeed inside the check's sandbox
# -- test/vm is copied to harness/ with no flake.nix three levels above it.
FAKE = config.resolve(overrides={"dir": "/tmp/vm-entrypoint-test"}, environ={},
                      repo=Path("/nowhere/repo"))


class Loads(unittest.TestCase):
    def test_the_file_parses_and_imports(self):
        self.assertTrue(hasattr(load_vm(), "main"))

    def test_every_subcommand_is_registered(self):
        parser = load_vm().build_parser()
        actions = [a for a in parser._actions if a.choices and hasattr(a, "dest")
                   and a.dest == "cmd"]
        self.assertEqual(len(actions), 1, "no subparser group found")
        self.assertEqual(sorted(actions[0].choices), sorted([
            "boot", "config", "display", "drive", "final-pass", "install",
            "run-all", "stop"]))


class ExitCodes(unittest.TestCase):
    """0 green, 1 a stage failed, 2 the harness did not run, 3 the harness broke."""

    def _run(self, argv, handler=None):
        module = load_vm()
        err = Stream()
        with contextlib.ExitStack() as stack:
            if handler is not None:
                stack.enter_context(mock.patch.object(module, "cmd_config", handler))
                stack.enter_context(mock.patch.object(config, "resolve",
                                                      lambda **kw: FAKE))
            stack.enter_context(contextlib.redirect_stderr(err))
            stack.enter_context(contextlib.redirect_stdout(Stream()))
            code = module.main(argv)
        return code, err.getvalue()

    def test_zero_when_the_handler_says_zero(self):
        code, _ = self._run(["config"], lambda cfg, args: 0)
        self.assertEqual(code, 0)

    def test_one_when_a_stage_failed(self):
        code, _ = self._run(["config"], lambda cfg, args: 1)
        self.assertEqual(code, 1)

    def test_two_for_a_precondition(self):
        code, err = self._run(["config"], mock.Mock(
            side_effect=config.Precondition("a VM is already running")))
        self.assertEqual(code, 2)
        self.assertIn("a VM is already running", err)

    def test_two_for_a_bad_port_rather_than_a_traceback(self):
        # This one deliberately does NOT patch config.resolve: the point is that
        # a non-numeric port is caught inside it. Config's arguments evaluate in
        # order, so the port is parsed before find_repo() runs -- which is why
        # this test gives the same answer here and in the sandbox.
        code, err = self._run(["--port", "abc", "config"])
        self.assertEqual(code, 2)
        self.assertIn("must be a number", err)
        self.assertNotIn("Traceback", err)

    def test_three_when_the_harness_itself_breaks(self):
        # The defect this contract fix exists for: an unmapped exception used to
        # exit 1, which is the code for "a stage failed" -- so a bug in vm and a
        # real defect in what it tests were indistinguishable.
        code, err = self._run(["config"], mock.Mock(
            side_effect=RuntimeError("dict changed size during iteration")))
        self.assertEqual(code, 3)
        self.assertIn("bug in vm", err)
        self.assertIn("dict changed size", err)   # the traceback still prints

    def test_a_usage_error_exits_two_and_does_not_reach_a_handler(self):
        module = load_vm()
        with contextlib.redirect_stderr(Stream()):
            with self.assertRaises(SystemExit) as caught:
                module.main([])
        self.assertEqual(caught.exception.code, 2)
