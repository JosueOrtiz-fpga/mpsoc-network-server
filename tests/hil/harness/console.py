"""The board's serial console: logs every byte and waits for patterns.

Standard library only (termios), so the host needs no pyserial. A reader thread
appends everything to the log file and to `text`, a copy with ANSI escapes and
carriage returns removed that the waits search. `expect()` moves a cursor through
`text`, so each wait only sees output that arrived after the previous match.
"""
import codecs
import errno
import fcntl
import os
import re
import select
import termios
import threading
import time
import tty

ANSI = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|[78]|[()][0-9A-Za-z])")


class ConsoleError(Exception):
    """The console is unusable, went away, timed out or showed a failure."""


class Console:
    def __init__(self, device, log_path, baud=termios.B115200):
        self.device = device
        try:
            self._fd = os.open(device, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        except OSError as e:
            raise ConsoleError(f"cannot open console {device}: {e.strerror} "
                               "(J16 connected? HIL_CONSOLE in hil.env)") from None
        try:
            # picocom takes the same lock, so a forgotten picocom shows up here
            # instead of as two readers splitting the output between them.
            fcntl.flock(self._fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(self._fd)
            raise ConsoleError(f"{device} is in use: close picocom or any other terminal on it") from None
        self._raw_115200_8n1(baud)
        self._log = open(log_path, "ab", buffering=0)
        self._decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
        self._carry = ""
        self.text = ""
        self.pos = 0
        self.error = None
        self._hooks = []
        self._cond = threading.Condition()
        self._wlock = threading.Lock()
        self._stop = False
        self._thread = threading.Thread(target=self._reader, name="console", daemon=True)
        self._thread.start()

    def _raw_115200_8n1(self, baud):
        tty.setraw(self._fd)
        a = termios.tcgetattr(self._fd)
        a[0] &= ~(termios.IXON | termios.IXOFF | termios.IXANY)
        a[2] &= ~(termios.CSIZE | termios.PARENB | termios.CSTOPB | termios.CRTSCTS)
        a[2] |= termios.CS8 | termios.CLOCAL | termios.CREAD
        a[4] = a[5] = baud
        termios.tcsetattr(self._fd, termios.TCSANOW, a)

    # ---- reader thread ---------------------------------------------------------------
    def _clean(self, text):
        # An escape sequence split across two reads is held back until it is complete.
        text, self._carry = self._carry + text, ""
        i = text.rfind("\x1b")
        if i != -1 and len(text) - i < 16 and not ANSI.match(text, i):
            text, self._carry = text[:i], text[i:]
        return ANSI.sub("", text).replace("\r", "")

    def _reader(self):
        while not self._stop:
            try:
                ready, _, _ = select.select([self._fd], [], [], 0.2)
                if not ready:
                    continue
                data = os.read(self._fd, 4096)
            except OSError as e:
                if e.errno in (errno.EAGAIN, errno.EINTR):
                    continue
                data, why = b"", e.strerror
            else:
                why = "end of file"
            if not data:
                # The FT2232H runs from board power: a board that switched itself off
                # takes the console with it.
                with self._cond:
                    self.error = f"console {self.device} lost ({why}): board powered off or J16 unplugged?"
                    self._cond.notify_all()
                return
            self._log.write(data)
            text = self._clean(self._decoder.decode(data))
            with self._cond:
                start = len(self.text)
                self.text += text
                for hook in list(self._hooks):
                    rx, reply, since = hook
                    if rx.search(self.text, max(since, start - 256)):
                        self._hooks.remove(hook)
                        self._write(reply)
                self._cond.notify_all()

    def _write(self, data):
        with self._wlock:
            while data:
                try:
                    data = data[os.write(self._fd, data):]
                except BlockingIOError:
                    select.select([], [self._fd], [], 0.5)

    # ---- API -------------------------------------------------------------------------
    def send(self, text):
        self._write(text.encode())

    def respond(self, pattern, reply):
        """Send `reply` as soon as `pattern` shows up in new output, once, from the
        reader thread: fast enough for U-Boot's two-second autoboot countdown."""
        with self._cond:
            self._hooks.append((re.compile(pattern), reply.encode(), len(self.text)))

    def expect(self, pattern, timeout, fail=()):
        """Wait for `pattern` after the cursor and move the cursor past it. Raises
        ConsoleError on timeout, on a lost console, or when a `fail` pattern shows up
        first."""
        rx = re.compile(pattern)
        bad = [re.compile(p) for p in fail]
        deadline = time.monotonic() + timeout
        with self._cond:
            while True:
                m = rx.search(self.text, self.pos)
                for b in bad:
                    hit = b.search(self.text, self.pos)
                    if hit and (m is None or hit.start() < m.end()):
                        raise ConsoleError(f"console shows {self._line(hit.start())!r} "
                                           f"while waiting for {pattern!r}")
                if m:
                    self.pos = m.end()
                    return m
                if self.error:
                    raise ConsoleError(f"{self.error} (while waiting for {pattern!r})")
                left = deadline - time.monotonic()
                if left <= 0:
                    raise ConsoleError(f"timeout after {timeout:g} s waiting for {pattern!r}")
                self._cond.wait(min(left, 0.5))

    def find_all(self, patterns, start=0, end=None):
        """Whole lines of `text[start:end]` that match any of `patterns`."""
        with self._cond:
            text = self.text[start:end]
        rx = re.compile("|".join(f"(?:{p})" for p in patterns))
        return [line for line in text.splitlines() if rx.search(line)]

    def _line(self, i):
        a = self.text.rfind("\n", 0, i) + 1
        b = self.text.find("\n", i)
        return self.text[a:None if b == -1 else b].strip()

    def tail(self, lines=40):
        with self._cond:
            return "\n".join(self.text.splitlines()[-lines:])

    def close(self):
        self._stop = True
        self._thread.join(timeout=2)
        os.close(self._fd)
        self._log.close()
