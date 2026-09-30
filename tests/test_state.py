#!/usr/bin/env python3
"""Tests for scripts/state.py: FIFOs, symlinks, oversized files, atomic write."""
import os
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts", "state.py")


def run(*args):
    return subprocess.run([sys.executable, SCRIPT, *args], capture_output=True, text=True, timeout=10)


class StateTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name
        self.file = os.path.join(self.dir, "dr-lyd.json")

    def tearDown(self):
        self.tmp.cleanup()

    def test_roundtrip(self):
        self.assertEqual(run("write", self.dir, '{"favorites":["p1"]}').returncode, 0)
        r = run("read", self.dir)
        self.assertEqual((r.returncode, r.stdout), (0, '{"favorites":["p1"]}'))
        self.assertEqual(os.listdir(self.dir), ["dr-lyd.json"])

    def test_missing_file_reads_empty(self):
        r = run("read", self.dir)
        self.assertEqual((r.returncode, r.stdout), (0, ""))

    def test_fifo_does_not_hang(self):
        os.mkfifo(self.file)
        r = run("read", self.dir)
        self.assertEqual(r.stdout, "")
        self.assertNotEqual(r.returncode, 0)

    def test_symlink_is_refused(self):
        target = os.path.join(self.dir, "elsewhere")
        with open(target, "w") as f:
            f.write("{}")
        os.symlink(target, self.file)
        r = run("read", self.dir)
        self.assertEqual(r.stdout, "")
        self.assertNotEqual(r.returncode, 0)

    def test_oversized_file_is_refused(self):
        with open(self.file, "w") as f:
            f.write("x" * (64 * 1024 + 1))
        r = run("read", self.dir)
        self.assertEqual(r.stdout, "")
        self.assertNotEqual(r.returncode, 0)

    def test_oversized_write_is_refused(self):
        self.assertNotEqual(run("write", self.dir, "x" * (64 * 1024 + 1)).returncode, 0)
        self.assertFalse(os.path.exists(self.file))

    def test_write_replaces_a_symlink_instead_of_following_it(self):
        target = os.path.join(self.dir, "elsewhere")
        with open(target, "w") as f:
            f.write("keep")
        os.symlink(target, self.file)
        self.assertEqual(run("write", self.dir, "{}").returncode, 0)
        self.assertFalse(os.path.islink(self.file))
        with open(target) as f:
            self.assertEqual(f.read(), "keep")


if __name__ == "__main__":
    unittest.main()
