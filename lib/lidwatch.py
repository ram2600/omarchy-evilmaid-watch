"""Watch the laptop lid switch and fire the incident handler when it opens.

Runs as root. /dev/input/event* is root:input 0640 and the target user is not
in the `input` group, so there is no unprivileged path to these events.

We parse the raw `struct input_event` stream rather than shelling out to
evtest or `libinput debug-events`: neither is installed on this machine, and
the design goal is to add no new packages.
"""

import glob
import os
import select
import struct
import subprocess
import sys
import time

# struct input_event on 64-bit Linux:
#   struct timeval { long tv_sec; long tv_usec; }  __u16 type  __u16 code  __s32 value
# Verified as 24 bytes on this aarch64 kernel via struct.calcsize.
EVENT_FORMAT = "llHHi"
EVENT_SIZE = struct.calcsize(EVENT_FORMAT)

# Refuse to run rather than silently decode garbage. On a 32-bit target, or one
# with a time64 mismatch, this struct is not 24 bytes and every field we unpack
# would be misaligned - we would read a lid event that never happened, or miss
# one that did. For a security watcher, failing loudly is the only safe option.
if EVENT_SIZE != 24:
    raise SystemExit(
        "unexpected struct input_event size %d (expected 24); "
        "this build of the watcher only supports 64-bit kernels" % EVENT_SIZE
    )

EV_SW = 0x05
SW_LID = 0x00

# SW_LID semantics are inverted from what you would guess: the switch reads 1
# when the lid is CLOSED and 0 when it is OPEN. We fire on 0.
LID_OPEN = 0

RESCAN_MAX_BACKOFF = 30


def log(message):
    """Write to stderr; systemd captures it into the journal."""
    print(message, file=sys.stderr, flush=True)


def lid_devices():
    """Return every /dev/input/eventN whose switch capabilities include SW_LID.

    The lid device number is not stable across boots or driver reloads, so we
    discover by capability instead of hardcoding event0.

    Each capabilities/sw file holds space-separated hex words, printed most
    significant group first, so bit 0 (SW_LID) always lives in the LAST word.
    On this machine event0 reads "1" (matches) and event3, the headphone jack,
    reads "e" - bits 1-3 set, bit 0 clear - so it is correctly skipped.
    """
    found = []
    for cap_path in sorted(glob.glob("/sys/class/input/event*/device/capabilities/sw")):
        try:
            with open(cap_path) as handle:
                words = handle.read().split()
        except OSError:
            continue
        if not words:
            continue
        try:
            low_word = int(words[-1], 16)
        except ValueError:
            continue
        if low_word & (1 << SW_LID):
            # .../sys/class/input/eventN/device/capabilities/sw -> eventN
            event_dir = cap_path.split("/device/")[0]
            found.append("/dev/input/" + os.path.basename(event_dir))
    return found


def fire(trigger, source):
    """Launch the incident handler without blocking the event loop.

    The handler sleeps through a grace period of a minute or more, so it must
    never run inline - we would miss a second lid event while waiting.
    """
    try:
        subprocess.Popen(
            [trigger, source],
            stdin=subprocess.DEVNULL,
            start_new_session=True,
        )
        log("fired %s %s" % (trigger, source))
    except OSError as error:
        log("could not run %s: %s" % (trigger, error))


def drain(fd):
    """Read whole input_events from fd. Returns False if the device died."""
    lid_opened = False
    while True:
        try:
            data = os.read(fd, EVENT_SIZE * 64)
        except BlockingIOError:
            return lid_opened
        except OSError as error:
            log("read error on fd %d: %s" % (fd, error))
            return None
        if not data:
            return None
        for offset in range(0, len(data) - EVENT_SIZE + 1, EVENT_SIZE):
            _sec, _usec, etype, code, value = struct.unpack(
                EVENT_FORMAT, data[offset:offset + EVENT_SIZE]
            )
            if etype == EV_SW and code == SW_LID:
                log("SW_LID value=%d (%s)" % (value, "open" if value == LID_OPEN else "closed"))
                if value == LID_OPEN:
                    lid_opened = True


def main():
    trigger = sys.argv[1] if len(sys.argv) > 1 else "/usr/local/bin/omarchy-sentry-trigger"

    poller = select.poll()
    watched = {}
    backoff = 1

    while True:
        if not watched:
            for path in lid_devices():
                try:
                    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
                except OSError as error:
                    log("cannot open %s: %s" % (path, error))
                    continue
                watched[fd] = path
                poller.register(fd, select.POLLIN)
                log("watching %s" % path)

            if not watched:
                # The lid device can disappear briefly across a suspend cycle.
                # Rescanning here keeps one process alive across that gap;
                # relying on systemd Restart= instead would tear down the
                # process every time and widen the window where we are deaf.
                log("no SW_LID device found; rescanning in %ds" % backoff)
                time.sleep(backoff)
                backoff = min(backoff * 2, RESCAN_MAX_BACKOFF)
                continue
            backoff = 1

        for fd, flags in poller.poll(1000):
            if flags & (select.POLLERR | select.POLLHUP | select.POLLNVAL):
                log("device %s went away" % watched.get(fd, fd))
                poller.unregister(fd)
                os.close(fd)
                watched.pop(fd, None)
                continue

            result = drain(fd)
            if result is None:
                poller.unregister(fd)
                try:
                    os.close(fd)
                except OSError:
                    pass
                watched.pop(fd, None)
                continue
            if result:
                fire(trigger, "lid")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
