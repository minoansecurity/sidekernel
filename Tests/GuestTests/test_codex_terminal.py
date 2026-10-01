"""Exercise the guest wrapper with real PTYs, without host credentials or clipboard access."""
import errno
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import runpy
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unittest
from unittest.mock import patch
import zlib


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "guest/codex"
CODEX = runpy.run_path(str(SOURCE), run_name="codex_wrapper_test")


def png():
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress((b"\0" + b"\xff\0\0" * 2) * 2))
            + chunk(b"IEND", b""))


class PasteInputTests(unittest.TestCase):
    def test_keys_and_markers_survive_every_read_boundary(self):
        start, end = CODEX["PASTE_START"], CODEX["PASTE_END"]
        for key in CODEX["PASTE_KEYS"]:
            # A Ctrl+V byte inside a bracketed text paste must stay literal.
            data = b"before" + key + start + b"literal\x16" + end + key + b"after"
            expected = b"beforeATTACH" + start + b"literal\x16" + end + b"ATTACHafter"
            for split in range(len(data) + 1):
                parser = CODEX["PasteInput"]()
                calls = []
                def image():
                    calls.append(True)
                    return b"ATTACH"
                actual = parser.feed(data[:split], image) + parser.feed(data[split:], image) + parser.flush()
                self.assertEqual(actual, expected)
                self.assertEqual(len(calls), 2)

    def test_other_keys_and_clipboard_failures_are_preserved(self):
        data = (b"\x1b[118;5:3u\x1b[118;1u\x1b[117;5u\x1b[27;1;118~"
                b"\x16\x1b[6n\x1b[1;2R\x03\x1b")
        parser = CODEX["PasteInput"]()
        self.assertEqual(parser.feed(data, lambda: None) + parser.flush(), data)

    def test_escape_flush_does_not_consume_next_key(self):
        parser = CODEX["PasteInput"]()
        self.assertEqual(parser.feed(b"\x1b", lambda: b"BAD"), b"")
        self.assertEqual(parser.flush(), b"\x1b")
        self.assertEqual(parser.feed(b"x", lambda: b"BAD"), b"x")

    def test_delayed_paste_end_marker_is_not_lost_on_escape_timeout(self):
        start, end = CODEX["PASTE_START"], CODEX["PASTE_END"]
        for split in range(1, len(end)):
            parser = CODEX["PasteInput"]()
            self.assertEqual(parser.feed(start + b"text", lambda: b"BAD"), start + b"text")
            self.assertEqual(parser.feed(end[:split], lambda: b"BAD"), b"")
            self.assertEqual(parser.flush(), b"")
            self.assertEqual(parser.feed(end[split:], lambda: b"BAD"), end)
            self.assertFalse(parser.bracketed)
            self.assertEqual(parser.feed(b"\x16", lambda: b"ATTACH"), b"ATTACH")

    def test_large_literal_paste_is_preserved(self):
        data = (b"plain text\r\n" * 100_000) + b"\x16"
        parser = CODEX["PasteInput"]()
        self.assertEqual(parser.feed(data, lambda: b"ATTACH"), data[:-1] + b"ATTACH")

    def test_only_interactive_invocations_use_the_relay(self):
        check = CODEX["interactive_terminal"]
        for args in [[], ["a prompt"], ["--", "exec"], ["resume", "--last"], ["fork", "id"],
                     ["-m", "review"], ["-i", "exec.png"], ["-c", 'x="exec"']]:
            self.assertTrue(check(args), args)
        for args in [["exec", "-"], ["--model", "x", "exec"], ["e", "prompt"], ["review"],
                     ["features", "list"], ["--help"], ["resume", "--help"], ["--version"]]:
            self.assertFalse(check(args), args)


class TerminalTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="sidekernel-codex-terminal-")
        self.root = Path(self.temporary.name)
        self.agent = self.root / "run/sidekernel/libexec/sk-agent"
        self.agent.parent.mkdir(parents=True)
        self.fixture = self.root / "fixture.png"
        self.fixture.write_bytes(png())
        self.requests = self.root / "requests"
        self.write_agent("""
import os, pathlib, sys
assert sys.argv[1:] == ['ctl', 'clip']
with open(os.environ['REQUESTS'], 'ab') as requests:
    requests.write(b'clip\\n')
sys.stdout.buffer.write(pathlib.Path(os.environ['FIXTURE']).read_bytes())
""")
        self.binary = self.root / "codex-stub"
        self.binary.write_text("#!" + sys.executable + "\n" + """
import fcntl, json, os, pathlib, signal, struct, sys, termios, tty
def size():
    return list(struct.unpack('HHHH', fcntl.ioctl(0, termios.TIOCGWINSZ, b'\\0' * 8))[:2])
def resized(*_):
    print('SIZE=' + json.dumps(size()), flush=True)
signal.signal(signal.SIGWINCH, resized)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(23))
tty.setraw(0)
print('CHILD_PID=' + str(os.getpid()), flush=True)
print('READY=' + json.dumps(size()), flush=True)
data = bytearray()
while True:
    chunk = os.read(0, 4096)
    data.extend(chunk)
    if b'\\x04' in chunk:
        break
pathlib.Path(os.environ['CAPTURE']).write_bytes(data)
print('FINAL_OUTPUT', flush=True)
sys.exit(7)
""")
        self.binary.chmod(0o755)
        self.wrapper = self.root / "wrapper"
        self.wrapper.write_text(SOURCE.read_text().replace("/usr/local/bin/codex", str(self.binary)))
        self.environment = dict(os.environ, SK_ROOT=str(self.root), CODEX_HOME=str(self.root / "config"),
                                FIXTURE=str(self.fixture), REQUESTS=str(self.requests),
                                CAPTURE=str(self.root / "capture"))
        self.process = None
        self.master = self.slave = None
        self.output = bytearray()

    def tearDown(self):
        if self.process is not None:
            if self.process.poll() is None:
                self.process.send_signal(signal.SIGCONT)
                self.process.terminate()
                try:
                    self.process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=3)
        for fd in (self.master, self.slave):
            if fd is not None:
                os.close(fd)
        self.temporary.cleanup()

    def write_agent(self, script):
        self.agent.write_text("#!" + sys.executable + "\n" + script)
        self.agent.chmod(0o755)

    def start(self, args=()):
        self.master, self.slave = pty.openpty()
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 100, 0, 0))
        self.saved_termios = termios.tcgetattr(self.slave)
        self.process = subprocess.Popen([sys.executable, str(self.wrapper), *args],
                                        stdin=self.slave, stdout=self.slave, stderr=self.slave,
                                        env=self.environment)
        self.read_until(b"READY=[32, 100]")

    def read_until(self, marker, timeout=5):
        deadline = time.monotonic() + timeout
        while marker not in self.output and time.monotonic() < deadline:
            if select.select([self.master], [], [], 0.05)[0]:
                try:
                    self.output.extend(os.read(self.master, 65536))
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    break
        self.assertIn(marker, self.output)

    def finish(self):
        os.write(self.master, b"\x04")
        self.read_until(b"FINAL_OUTPUT")
        self.assertEqual(self.process.wait(timeout=5), 7)
        self.assert_terminal_restored()
        return (self.root / "capture").read_bytes()

    def assert_terminal_restored(self):
        actual = termios.tcgetattr(self.slave)
        expected = self.saved_termios.copy()
        # macOS sets PENDIN when returning to canonical input; it is kernel state,
        # not an application-selected terminal mode.
        actual[3] &= ~getattr(termios, "PENDIN", 0)
        expected[3] &= ~getattr(termios, "PENDIN", 0)
        self.assertEqual(actual, expected)

    def test_multiple_images_attach_in_order_and_remain_private(self):
        self.start()
        os.write(self.master, b"draft\x16 between \x1b[118;5u after")
        data = self.finish()
        paths = re.findall(rb"\x1b\[200~(.*?)\x1b\[201~", data)
        self.assertEqual(len(paths), 2)
        self.assertNotEqual(paths[0], paths[1])
        self.assertEqual(data, b"draft\x1b[200~" + paths[0] + b"\x1b[201~ between \x1b[200~"
                         + paths[1] + b"\x1b[201~ after\x04")
        for raw_path in paths:
            path = Path(os.fsdecode(raw_path))
            self.assertEqual(path.read_bytes(), self.fixture.read_bytes())
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.requests.read_bytes(), b"clip\nclip\n")

    def test_text_paste_never_reads_clipboard(self):
        self.start()
        data = b"\x1b[200~literal\x16\x1b[118;5u\r\n\x1b[201~"
        # Feed one byte at a time to exercise split terminal markers.
        for byte in data:
            os.write(self.master, bytes((byte,)))
        self.assertEqual(self.finish(), data + b"\x04")
        self.assertFalse(self.requests.exists())

    def test_foreground_editor_receives_ctrl_v_without_a_clipboard_read(self):
        self.binary.write_text(self.binary.read_text().replace("tty.setraw(0)", """
tty.setraw(0)
ready_read, ready_write = os.pipe()
tool = os.fork()
if tool:
    os.setpgid(tool, tool)
    os.tcsetpgrp(0, tool)
    os.write(ready_write, b'ready')
    _, status = os.waitpid(tool, 0)
    sys.exit(os.WEXITSTATUS(status))
os.setpgid(0, 0)
os.read(ready_read, 5)
"""))
        self.start()
        os.write(self.master, b"\x16")
        self.assertEqual(self.finish(), b"\x16\x04")
        self.assertFalse(self.requests.exists())

    def test_denied_clipboard_preserves_native_key_and_leaves_no_image(self):
        self.write_agent("import sys; sys.exit(1)\n")
        self.start()
        os.write(self.master, b"\x16")
        self.assertEqual(self.finish(), b"\x16\x04")
        self.assertEqual(list((self.root / "run/sidekernel/clipboard").iterdir()), [])

    def test_invalid_clipboard_bytes_are_not_attached(self):
        self.fixture.write_bytes(b"not an image")
        self.start()
        os.write(self.master, b"\x16")
        self.assertEqual(self.finish(), b"\x16\x04")
        self.assertEqual(list((self.root / "run/sidekernel/clipboard").iterdir()), [])

    def test_resize_reaches_child_and_termination_restores_terminal(self):
        self.start()
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", 45, 120, 0, 0))
        self.process.send_signal(signal.SIGWINCH)
        self.read_until(b"SIZE=[45, 120]")
        self.process.terminate()
        self.assertEqual(self.process.wait(timeout=5), 23)
        self.assert_terminal_restored()

    def test_input_eof_reaps_a_child_that_ignores_hangup_and_termination(self):
        self.binary.write_text("#!" + sys.executable + "\n" + """
import signal, time, tty
signal.signal(signal.SIGHUP, signal.SIG_IGN)
signal.signal(signal.SIGTERM, signal.SIG_IGN)
tty.setraw(0)
print('READY=[32, 100]', flush=True)
while True:
    time.sleep(1)
""")
        # Exercise EOF while keeping the outer PTY open to inspect its restored modes.
        self.wrapper.write_text(self.wrapper.read_text().replace('data = os.read(0, 4096)', 'data = b""'))
        self.start()
        os.write(self.master, b"trigger EOF")
        self.assertEqual(self.process.wait(timeout=4), 128 + signal.SIGKILL)
        self.assert_terminal_restored()

    def test_child_suspend_and_resume_restore_the_outer_terminal(self):
        self.binary.write_text(self.binary.read_text().replace(
            "print('READY='", "signal.signal(signal.SIGUSR1, lambda *_: os.kill(os.getpid(), signal.SIGSTOP))\n"
            "signal.signal(signal.SIGCONT, lambda *_: print('CONTINUED', flush=True))\nprint('READY='"))
        self.start()
        child = int(re.search(rb"CHILD_PID=(\d+)", self.output).group(1))
        os.kill(child, signal.SIGUSR1)
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            waited, status = os.waitpid(self.process.pid, os.WNOHANG | os.WUNTRACED)
            if waited and os.WIFSTOPPED(status):
                break
            time.sleep(0.01)
        else:
            self.fail("relay did not suspend with Codex")
        self.assert_terminal_restored()
        self.process.send_signal(signal.SIGCONT)
        self.read_until(b"CONTINUED")
        os.write(self.master, b"after resume")
        self.assertEqual(self.finish(), b"after resume\x04")

    def test_noninteractive_streams_and_literal_bytes_are_unchanged(self):
        self.binary.write_text("#!" + sys.executable + "\n" + """
import sys
sys.stdout.buffer.write(sys.stdin.buffer.read())
sys.stderr.write('diagnostic')
sys.exit(9)
""")
        data = bytes(range(256)) * 256
        result = subprocess.run([sys.executable, str(self.wrapper), "exec", "-"], input=data,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env=self.environment, timeout=5)
        self.assertEqual(result.returncode, 9)
        self.assertEqual(result.stdout, data)
        self.assertEqual(result.stderr, b"diagnostic")
        self.assertFalse(self.requests.exists())

    def test_clipboard_timeout_removes_partial_file(self):
        with patch.dict(os.environ, self.environment), patch("subprocess.run", side_effect=
                subprocess.TimeoutExpired("sk-agent", 5)):
            self.assertIsNone(CODEX["clipboard_image"]())
        self.assertEqual(list((self.root / "run/sidekernel/clipboard").iterdir()), [])

    def test_claude_clipboard_commands_still_return_png_and_targets(self):
        # Run the unmodified Claude bridge through its real command names.
        script = (ROOT / "guest/internal/clip").read_text().replace(
            "/run/sidekernel/libexec/sk-agent", str(self.agent))
        clip = self.root / "clip"
        clip.write_text(script)
        clip.chmod(0o755)
        for name, args, expected in [
            ("xclip", ["-selection", "clipboard", "-o", "-t", "image/png"], png()),
            ("xclip", ["-selection", "clipboard", "-o", "-t", "TARGETS"], b"image/png\n"),
            ("wl-paste", ["--type", "image/png"], png()),
            ("wl-paste", ["--list-types"], b"image/png\n"),
        ]:
            command = self.root / name
            if not command.exists():
                command.symlink_to(clip)
            result = subprocess.run([str(command), *args], env=self.environment,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout, expected)
            self.assertEqual(result.stderr, b"")


if __name__ == "__main__":
    unittest.main()
