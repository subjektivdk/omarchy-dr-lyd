#!/usr/bin/env python3
"""Reads and writes the plugin's state file (dr-lyd.json) defensively.

The state directory is user-writable, so the shell must not trust what it
finds there: a FIFO would stall a plain read, an oversized file would
exhaust memory, and a path swapped between check and use would redirect the
write. This helper opens the directory once, checks it is owned by the
current user, and does every file operation relative to that descriptor.

    state.py read  <dir>          prints the file (nothing if missing/unsafe)
    state.py write <dir> <json>   replaces the file atomically
"""
import os
import stat
import sys

NAME = "dr-lyd.json"
MAX_BYTES = 64 * 1024


def open_dir(path, create):
    if create:
        os.makedirs(path, mode=0o700, exist_ok=True)
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    if os.fstat(fd).st_uid != os.getuid():
        os.close(fd)
        raise PermissionError("state directory is not owned by the current user")
    return fd


def read_state(path):
    dir_fd = open_dir(path, False)
    # O_NONBLOCK: opening a FIFO must not wait for a writer. O_NOFOLLOW: the
    # file itself must not be a symlink.
    fd = os.open(NAME, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dir_fd)
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_BYTES:
        raise ValueError("state file is not a regular file of sensible size")
    data = os.read(fd, MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise ValueError("state file is too large")
    sys.stdout.write(data.decode("utf-8", "replace"))


def write_state(path, text):
    data = text.encode("utf-8")
    if len(data) > MAX_BYTES:
        raise ValueError("state is too large")
    dir_fd = open_dir(path, True)
    tmp = ".%s.%d.tmp" % (NAME, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dir_fd)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, NAME, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
    except BaseException:
        try:
            os.unlink(tmp, dir_fd=dir_fd)
        except OSError:
            pass
        raise


def main(argv):
    try:
        if len(argv) == 3 and argv[1] == "read":
            read_state(argv[2])
        elif len(argv) == 4 and argv[1] == "write":
            write_state(argv[2], argv[3])
        else:
            print(__doc__, file=sys.stderr)
            return 2
    except FileNotFoundError:
        return 0 if argv[1] == "read" else 1
    except (OSError, ValueError) as e:
        print("state.py: %s" % e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
