"""Exercise the Codex wrapper's policy, without host credentials or clipboard access."""
import os
from pathlib import Path
import re
import runpy
import subprocess
import sys
import tempfile
import unittest

from test_harness import TerminalCase


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "guest/codex"
sys.path.insert(0, str(ROOT / "guest/internal"))
import harness  # noqa: E402  So the wrapper's import finds the repo copy.
CODEX = runpy.run_path(str(SOURCE), run_name="codex_wrapper_test")


class ArgumentTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="sidekernel-codex-arguments-")
        self.root = Path(self.temporary.name)
        self.binary = self.root / "codex-stub"
        self.binary.write_text("#!/bin/sh\nprintf '%s\\0' \"$@\"\n")
        self.binary.chmod(0o755)
        libexec = self.root / "run/sidekernel/libexec"
        libexec.mkdir(parents=True)
        (libexec / "harness.py").write_text((ROOT / "guest/internal/harness.py").read_text())
        self.wrapper = self.root / "wrapper"
        self.wrapper.write_text(SOURCE.read_text().replace("/usr/local/bin/codex", str(self.binary)))

    def tearDown(self):
        self.temporary.cleanup()

    def run_wrapper(self, *args):
        return subprocess.run([sys.executable, str(self.wrapper), *args], capture_output=True,
                              env=dict(os.environ, SK_ROOT=str(self.root)), timeout=5)

    def arguments(self, *args):
        result = self.run_wrapper(*args)
        self.assertEqual(result.returncode, 0, result.stderr)
        return [os.fsdecode(arg) for arg in result.stdout.split(b"\0")[:-1]]

    def test_overrides_move_ahead_of_subcommands_and_keep_the_proxy(self):
        self.assertEqual(self.arguments("-c", "root=true", "exec", "--config=child=true", "resume", "--last",
                                        "-cnested=true", "--disable", "shell_tool", "prompt"),
                         CODEX["PROXY"] + CODEX["NO_UPDATE_PROMPT"]
                         + ["-c", "root=true", "--config=child=true", "-cnested=true",
                            "--disable", "shell_tool", "exec", "resume", "--last", "prompt"])

    def test_everything_after_the_delimiter_is_literal(self):
        literal = ["exec", "--", "prompt with spaces; $(literal)", "--config", "literal=true", "login"]
        self.assertEqual(self.arguments(*literal), CODEX["PROXY"] + CODEX["NO_UPDATE_PROMPT"] + literal)

    def test_login_and_logout_are_managed_on_the_host(self):
        for args in [["login", "status"], ["-c", "x=true", "login", "status"], ["--model=other", "logout"],
                     ["-m", "other", "login"], ["--no-alt-screen", "--cd", "/workspace", "logout"],
                     ["--disable", "shell_tool", "login"]]:
            result = self.run_wrapper(*args)
            self.assertEqual(result.returncode, 1, args)
            self.assertEqual(result.stdout, b"", "native login must not run")
            self.assertIn(b"authentication is managed on the host", result.stderr)
        # An option value, an image path or a prompt is not the login command.
        for args in [["--", "login"], ["-m", "login", "exec", "prompt"], ["-i", "a.png", "login"],
                     ["exec", "logout"], ["help", "login"]]:
            self.assertEqual(self.run_wrapper(*args).returncode, 0, args)

    def test_missing_cli_is_reported(self):
        self.binary.unlink()
        result = self.run_wrapper("exec", "prompt")
        self.assertEqual(result.returncode, 127)
        self.assertIn(b"not installed in this microVM", result.stderr)


class CodexTerminalTests(TerminalCase):
    def wrapper_source(self):
        return SOURCE.read_text().replace("/usr/local/bin/codex", str(self.binary))

    def test_ctrl_v_attaches_an_image_through_the_wrapper(self):
        self.start()
        os.write(self.master, b"\x16")
        data = self.finish()
        path = re.fullmatch(rb"\x1b\[200~(.*)\x1b\[201~\x04", data).group(1)
        self.assertEqual(Path(os.fsdecode(path)).read_bytes(), self.fixture.read_bytes())


class SeedTests(unittest.TestCase):
    def test_codex_home_gets_the_host_guidance_before_every_command(self):
        with tempfile.TemporaryDirectory(prefix="sidekernel-seed-") as temporary:
            root = Path(temporary)
            guidance = root / "run/sk-seed/codex/AGENTS.md"
            guidance.parent.mkdir(parents=True)
            guidance.write_text("sandbox guidance\n")
            home = root / "project/codex"
            environment = {"PATH": os.environ["PATH"], "SK_ROOT": str(root), "CODEX_HOME": str(home)}
            seed = [str(ROOT / "guest/internal/seed"), "/bin/sh", "-c", 'cat "$CODEX_HOME/AGENTS.md"; exit 7']
            first = subprocess.run(seed, capture_output=True, env=environment, timeout=5)
            self.assertEqual((first.returncode, first.stdout), (7, b"sandbox guidance\n"))
            # The guidance is always the host's; a guest edit lasts until the next command.
            (home / "AGENTS.md").write_text("planted\n")
            second = subprocess.run(seed, capture_output=True, env=environment, timeout=5)
            self.assertEqual(second.stdout, b"sandbox guidance\n")


if __name__ == "__main__":
    unittest.main()
