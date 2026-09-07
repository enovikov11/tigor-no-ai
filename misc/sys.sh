python3 - <<'PY' > /tmp/sysfs.txt
import os
import sys
import time
import signal

ROOT = "/sys"
MAX = 64 * 1024

LOG_EVERY = 1000
READ_TIMEOUT = 0.2
SLOW_READ = 0.1

count = 0
kept = 0
errors = 0
binary = 0
oversize = 0
timeouts = 0

def log(s):
    print(s, file=sys.stderr, flush=True)

class ReadTimeout(Exception):
    pass

def alarm_handler(signum, frame):
    raise ReadTimeout

signal.signal(signal.SIGALRM, alarm_handler)

def is_text(data):
    if b"\0" in data:
        return False

    try:
        s = data.decode("utf-8")
    except UnicodeDecodeError:
        return False

    return all(c in "\t\n\r" or ord(c) >= 0x20 for c in s)

start = time.monotonic()

for root, dirs, files in os.walk(ROOT, followlinks=False):
    # Explicitly remove symlinked directories.
    # os.walk(followlinks=False) shouldn't descend into them anyway,
    # but this makes the intended behavior obvious.
    dirs[:] = [
        d for d in dirs
        if not os.path.islink(os.path.join(root, d))
    ]

    for name in files:
        path = os.path.join(root, name)
        count += 1

        if count % LOG_EVERY == 0:
            elapsed = time.monotonic() - start
            log(
                f"[progress] scanned={count} kept={kept} "
                f"errors={errors} binary={binary} oversize={oversize} "
                f"timeouts={timeouts} elapsed={elapsed:.1f}s "
                f"current={path}"
            )

        t0 = time.monotonic()

        try:
            signal.setitimer(signal.ITIMER_REAL, READ_TIMEOUT)

            with open(path, "rb", buffering=0) as f:
                data = f.read(MAX + 1)

        except ReadTimeout:
            timeouts += 1
            log(f"[timeout] {path}")
            continue

        except (OSError, ValueError) as e:
            errors += 1
            # Comment this out if permission errors are too noisy.
            log(f"[error] {path}: {e}")
            continue

        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)

        dt = time.monotonic() - t0

        if dt >= SLOW_READ:
            log(f"[slow {dt:.3f}s] {path}")

        if len(data) > MAX:
            oversize += 1
            continue

        if not data:
            continue

        if not is_text(data):
            binary += 1
            continue

        kept += 1

        text = data.decode("utf-8")

        print(f"===== {path} =====")
        print(text, end="" if text.endswith("\n") else "\n")
        print()

elapsed = time.monotonic() - start
log(
    f"[done] scanned={count} kept={kept} errors={errors} "
    f"binary={binary} oversize={oversize} timeouts={timeouts} "
    f"elapsed={elapsed:.1f}s"
)
PY