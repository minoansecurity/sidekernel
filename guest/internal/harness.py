"""Shared launcher for harness wrappers in guest/: run the CLI, and in a terminal relay it
so Ctrl+V attaches the host clipboard image as a pasted file path.

A wrapper keeps only its harness's policy (proxy settings, refused commands) and ends with
`return launch(BINARY, argv)`. Nothing here knows about a particular harness.
"""
import errno
import fcntl
import os
from pathlib import Path
import pty
import re
import select
import signal
import subprocess
import sys
import tempfile
import termios
import time
import tty


# Match legacy Ctrl+V and the encodings requested by modern terminal keyboard modes.
# Keep these in sync with ClipboardGrant in Host/Clipboard.swift. Releases do not paste again.
PASTE_KEYS = (
    b"\x16", b"\x1b[118;5u", b"\x1b[118;5:1u", b"\x1b[118;5:2u",
    b"\x1b[27;5;118~",
)
# The terminal wraps text the user pastes in these markers ("bracketed paste").
PASTE_START, PASTE_END = b"\x1b[200~", b"\x1b[201~"
ESCAPE = b"\x1b"

# Every key and marker above starts with Escape or Ctrl+V. Any other byte is plain text.
KEY_START = re.compile(rb"([\x1b\x16])")

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
MAX_IMAGE_BYTES = 64 * 1024 * 1024

# How long a lone Escape waits for more bytes before it counts as the Escape key.
ESCAPE_DELAY = 0.03


# MARK: - Clipboard images

class PasteInput:
    """Find image-paste keys in keyboard input and replace them with an attachment.

    A key is several bytes and a read can end halfway through one, so bytes that might
    start a key wait in `pending` until the next read decides. Inside a bracketed
    paste, the text is the user's own: nothing in it is a key until PASTE_END.
    """

    def __init__(self):
        self.pending = b""      # bytes that may still become a key
        self.bracketed = False  # inside a bracketed paste

    def feed(self, data, image):
        """Return the input to pass on. `image()` gives the attachment for a paste key."""
        output = b""
        # Split into runs of plain text and single Escape / Ctrl+V bytes.
        for piece in KEY_START.split(data):
            output += self.feed_piece(piece, image)
        return output

    def flush(self):
        """After a pause, a lone Escape is the Escape key, so pass it on.

        A partial paste marker is never released: the rest may arrive in a later read.
        """
        if not self.waiting_on_escape():
            return b""
        self.pending = b""
        return ESCAPE

    def waiting_on_escape(self):
        return self.pending == ESCAPE and not self.bracketed

    def feed_piece(self, piece, image):
        output = b""
        # A key start, or text that may finish a waiting key: take one byte at a time.
        while piece and (self.pending or KEY_START.fullmatch(piece)):
            self.pending += piece[:1]
            piece = piece[1:]
            output += self.take_pending(image)
        # Whatever is left is plain text.
        return output + piece

    def take_pending(self, image):
        """Replace a completed key, and release bytes that can no longer start one."""
        output = b""
        while self.pending:
            keys = self.keys_to_watch()
            if self.pending in keys:
                key, self.pending = self.pending, b""
                return output + self.replace(key, image)
            if any(key.startswith(self.pending) for key in keys):
                return output  # could still become a key; wait for more bytes
            # Not a key. Pass the first byte on and check the rest again.
            output += self.pending[:1]
            self.pending = self.pending[1:]
        return output

    def keys_to_watch(self):
        if self.bracketed:
            return (PASTE_END,)
        return (PASTE_START,) + PASTE_KEYS

    def replace(self, key, image):
        if key == PASTE_START:
            self.bracketed = True
            return key
        if key == PASTE_END:
            self.bracketed = False
            return key
        # Without an image, the harness gets the key itself.
        return image() or key


def clipboard_image():
    """Read only through the host's keystroke grant, never through a desktop server."""
    root = Path(os.environ.get("SK_ROOT", "") + "/run/sidekernel")
    # /run is VM-local and excluded from save; retain successful images until VM shutdown.
    directory = root / "clipboard"
    try:
        directory.mkdir(mode=0o700, exist_ok=True)
        fd, path = tempfile.mkstemp(prefix="paste-", suffix=".png", dir=directory)
    except OSError:
        return None
    try:
        with os.fdopen(fd, "w+b") as image:
            fetched = fetch_png(root / "libexec/sk-agent", image)
    except (OSError, subprocess.SubprocessError):
        fetched = False
    if not fetched:
        Path(path).unlink(missing_ok=True)
        return None
    # The path is generated locally, not taken from clipboard text. No Enter is injected.
    return PASTE_START + os.fsencode(path) + PASTE_END


def fetch_png(agent, image):
    """Write the host clipboard into `image`. True if it holds a PNG of a sane size."""
    result = subprocess.run(
        [str(agent), "ctl", "clip"],
        stdin=subprocess.DEVNULL, stdout=image, stderr=subprocess.DEVNULL, timeout=5,
    )
    if result.returncode != 0:
        return False
    size = os.fstat(image.fileno()).st_size
    if size <= len(PNG_SIGNATURE) or size > MAX_IMAGE_BYTES:
        return False
    image.seek(0)
    return image.read(len(PNG_SIGNATURE)) == PNG_SIGNATURE


# MARK: - Terminal helpers

def write_all(fd, data):
    while data:
        written = os.write(fd, data)
        data = data[written:]


def window_size(fd):
    return fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\0" * 8)


def set_window_size(fd, size):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, size)


def kill_group(group, signum):
    if group <= 0:
        return
    try:
        os.killpg(group, signum)
    except OSError:
        pass  # already gone


def exit_code(status):
    """Turn a wait status into a shell exit code: 128 + N for a signal."""
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return os.WEXITSTATUS(status)


# MARK: - Terminal relay

class Relay:
    """Run the harness in its own PTY and copy bytes between it and our terminal.

    Output goes through unchanged. Input goes through PasteInput, which swaps
    image-paste keys for an attachment.
    """

    def __init__(self, binary, argv):
        self.saved = termios.tcgetattr(0)  # our terminal's modes, restored in close()
        size = window_size(0)
        self.pid, self.master = pty.fork()
        if self.pid == 0:
            self.start_harness(binary, argv, size)
        self.parser = PasteInput()
        self.escape_since = None  # when a lone Escape started waiting
        self.status = None        # the harness's wait status, once it exits
        self.handlers = {}        # signal handlers to put back in close()

    @staticmethod
    def start_harness(binary, argv, size):
        """In the child: take the window size, then become the harness. Never returns."""
        try:
            set_window_size(0, size)
            os.execv(binary, argv)
        except OSError as error:
            print(f"{os.path.basename(binary)}: {error}", file=sys.stderr)
            os._exit(127)

    def run(self):
        try:
            tty.setraw(0)
            self.install_signal_handlers()
            self.resize()
            self.pump()
        finally:
            self.close()
        return exit_code(self.status)

    def install_signal_handlers(self):
        self.handlers[signal.SIGWINCH] = signal.signal(signal.SIGWINCH, self.resize)
        for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
            self.handlers[signum] = signal.signal(signum, self.forward)

    def pump(self):
        """Relay until the terminal or the harness goes away."""
        while True:
            ready, _, _ = select.select([0, self.master], [], [], self.timeout())
            if self.master in ready and not self.copy_output():
                return
            if 0 in ready and not self.copy_input():
                return
            self.release_escape_if_due()
            if self.harness_exited():
                self.drain_output()
                return

    def timeout(self):
        """How long to wait for input: until a waiting Escape is due, or a quarter second."""
        if self.escape_since is None:
            return 0.25
        waited = time.monotonic() - self.escape_since
        return max(0, ESCAPE_DELAY - waited)

    def copy_output(self):
        """Copy the harness's output to the terminal. False once the PTY is closed."""
        try:
            output = os.read(self.master, 65536)
        except OSError as error:
            if error.errno != errno.EIO:
                raise
            return False
        write_all(1, output)
        return bool(output)

    def drain_output(self):
        """The harness exited, but the PTY may still hold its last output. Copy it."""
        deadline = time.monotonic() + 1
        while time.monotonic() < deadline:
            ready, _, _ = select.select([self.master], [], [], 0.03)
            if not ready or not self.copy_output():
                return

    def copy_input(self):
        """Copy keystrokes to the harness, replacing image-paste keys. False at EOF."""
        data = os.read(0, 4096)
        if not data:
            return False
        write_all(self.master, self.parser.feed(data, self.paste_image))
        if self.parser.waiting_on_escape():
            self.escape_since = time.monotonic()
        else:
            self.escape_since = None
        return True

    def release_escape_if_due(self):
        if self.escape_since is None:
            return
        if time.monotonic() - self.escape_since >= ESCAPE_DELAY:
            write_all(self.master, self.parser.flush())
            self.escape_since = None

    def paste_image(self):
        # An editor or tool the harness started may own the terminal right now.
        # Its Ctrl+V means something else, so leave the key alone.
        if os.tcgetpgrp(self.master) != self.pid:
            return None
        # A line-by-line (canonical) prompt cannot accept a bracketed attachment.
        local_modes = termios.tcgetattr(self.master)[3]
        if local_modes & termios.ICANON:
            return None
        return clipboard_image()

    def harness_exited(self):
        reaped, status = os.waitpid(self.pid, os.WNOHANG)
        if reaped:
            self.status = status
        return bool(reaped)

    def resize(self, _signum=None, _frame=None):
        try:
            set_window_size(self.master, window_size(0))
        except OSError:
            pass

    def forward(self, signum, _frame):
        try:
            # The foreground group includes any editor or tool the harness started.
            kill_group(os.tcgetpgrp(self.master), signum)
        except OSError:
            pass

    def close(self):
        try:
            foreground = os.tcgetpgrp(self.master)
        except OSError:
            foreground = self.pid
        os.close(self.master)  # Hang up the child on input EOF or a relay failure.
        try:
            termios.tcsetattr(0, termios.TCSANOW, self.saved)
        except OSError:
            pass  # The outer terminal may already have disconnected.
        for signum, handler in self.handlers.items():
            signal.signal(signum, handler)
        if self.status is None:
            self.status = self.reap({self.pid, foreground})

    def reap(self, groups):
        """Wait for the harness to exit.

        A child can ignore the hangup, and the shell must not wait forever. So give it
        a second, then send SIGTERM, then a second later SIGKILL.
        """
        for signum in (signal.SIGTERM, signal.SIGKILL):
            status = self.wait(timeout=1)
            if status is not None:
                return status
            for group in groups:
                kill_group(group, signum)
        return os.waitpid(self.pid, 0)[1]

    def wait(self, timeout):
        """The harness's wait status, or None if it is still running after `timeout`."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            reaped, status = os.waitpid(self.pid, os.WNOHANG)
            if reaped:
                return status
            time.sleep(0.01)
        return None


# MARK: - Entry

def launch(binary, argv, paste_images=True):
    """Exec the harness; in a terminal, relay it so Ctrl+V attaches clipboard images.

    Only a terminal session needs the relay; redirected streams stay exactly as given.
    """
    if paste_images and all(os.isatty(fd) for fd in (0, 1, 2)):
        return Relay(binary, argv).run()
    os.execv(binary, argv)
