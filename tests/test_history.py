#!/usr/bin/env python3
"""Tests for claude-skill/bin/history.py. Each test runs the script as a
subprocess with HOME pointed at a temporary directory holding a scratch
database, and with a PATH that has no omarchy-shell, so neither the real
history nor the running shell is touched."""
import datetime
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "claude-skill", "bin", "history.py")


class HistoryScriptTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = self.tmp.name
        self.db = os.path.join(self.home, ".local/state/omarchy/dr-lyd/history.sqlite")

    def tearDown(self):
        self.tmp.cleanup()

    def run_script(self, *args):
        env = {"HOME": self.home, "PATH": self.home, "PYTHONDONTWRITEBYTECODE": "1", "TZ": "Europe/Copenhagen"}
        return subprocess.run([sys.executable, SCRIPT, *args], env=env,
                              capture_output=True, text=True, timeout=30)

    def make_db(self, rows):
        os.makedirs(os.path.dirname(self.db))
        con = sqlite3.connect(self.db)
        con.execute("CREATE TABLE plays(id INTEGER PRIMARY KEY, channel TEXT NOT NULL, played_at INTEGER NOT NULL,"
                    " duration_ms INTEGER, artist TEXT, title TEXT NOT NULL, track_urn TEXT, programme TEXT,"
                    " UNIQUE(channel, played_at, title))")
        con.executemany("INSERT INTO plays(channel, played_at, artist, title, programme) VALUES (?,?,?,?,?)", rows)
        con.commit()
        con.close()

    def read(self, path):
        with open(path, encoding="utf-8") as f:
            return f.read()

    def count(self):
        con = sqlite3.connect(self.db)
        try:
            return con.execute("SELECT COUNT(*) FROM plays").fetchone()[0]
        finally:
            con.close()

    def ago(self, **delta):
        return int((datetime.datetime.now() - datetime.timedelta(**delta)).timestamp())

    def sample(self):
        self.make_db([
            ("p6beat", self.ago(minutes=30), "Sort Sol", "Let Your Fingers Do The Walking", "Morgenbeatet"),
            ("p6beat", self.ago(minutes=20), "Massive Attack", "Teardrop", "Morgenbeatet"),
            ("p3", self.ago(minutes=10), "", "100% Talk_Show | Live", ""),
            ("p6beat", self.ago(days=3), "O'Brien", "Old Song", "Aften"),
        ])

    def test_no_database(self):
        out = self.run_script("list")
        self.assertEqual(out.returncode, 0)
        self.assertIn("no listening history yet", out.stdout)
        self.assertNotEqual(self.run_script("export").returncode, 0)

    def test_list_filters_by_days_and_channel(self):
        self.sample()
        lines = self.run_script("list").stdout.splitlines()
        self.assertEqual(len(lines), 3, "default is the last day")
        self.assertTrue(lines[0].endswith("\tp6beat\tSort Sol – Let Your Fingers Do The Walking\tMorgenbeatet"))
        self.assertEqual(len(self.run_script("list", "0").stdout.splitlines()), 4)
        self.assertEqual(len(self.run_script("list", "1", "p3").stdout.splitlines()), 1)
        self.assertNotEqual(self.run_script("list", "x").returncode, 0)

    def test_search_is_case_insensitive_and_literal(self):
        self.sample()
        self.assertIn("Teardrop", self.run_script("search", "massive").stdout)
        self.assertIn("Old Song", self.run_script("search", "o'brien").stdout)
        self.assertIn("Morgenbeatet", self.run_script("search", "MORGEN").stdout)
        self.assertIn("100% Talk_Show", self.run_script("search", "100%").stdout)
        self.assertIn("no tracks", self.run_script("search", "0% Talk_S_").stdout, "% and _ are literal")
        self.assertNotEqual(self.run_script("search").returncode, 0)

    def test_export_markdown_newest_first_and_escaped(self):
        self.sample()
        path = os.path.join(self.home, "out.md")
        out = self.run_script("export", path)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("exported 4 tracks", out.stdout)
        text = self.read(path)
        self.assertIn("· 4 tracks · all history", text)
        self.assertIn("100% Talk_Show \\| Live", text, "pipes are escaped in table cells")
        today = text.index("Teardrop")
        self.assertLess(today, text.index("Let Your Fingers"), "newest first within a day")
        self.assertLess(today, text.index("Old Song"), "newest day first")
        self.assertIn("| p6beat |", text, "slug when the shell can't name the channel")

    def test_export_dates_limits_days(self):
        self.sample()
        path = os.path.join(self.home, "out.md")
        today = datetime.date.today().isoformat()
        out = self.run_script("export", path, "", "", "--dates", today)
        self.assertEqual(out.returncode, 0, out.stderr)
        text = self.read(path)
        self.assertIn("· 3 tracks ·", text)
        self.assertNotIn("Old Song", text)
        self.assertNotEqual(self.run_script("export", path, "", "", "--dates", "2001-01-01").returncode, 0)
        self.assertNotEqual(self.run_script("export", path, "", "", "--dates", "junk").returncode, 0)

    def test_clear_needs_yes(self):
        self.sample()
        refused = self.run_script("clear")
        self.assertNotEqual(refused.returncode, 0)
        self.assertEqual(self.count(), 4)
        out = self.run_script("clear", "--yes")
        self.assertIn("deleted 4 tracks", out.stdout)
        self.assertEqual(self.count(), 0)


if __name__ == "__main__":
    unittest.main()
