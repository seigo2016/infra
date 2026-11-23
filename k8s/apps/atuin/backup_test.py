"""Run with python -m unittest discover -s k8s/apps/atuin -p '*_test.py' -v.
Requires sqlite3 CLI on PATH. All databases are disposable temporary fixtures.
"""
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import time
import unittest

SCRIPT = Path(__file__).with_name("backup.sh")


class BackupTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.backups = self.root / "backup"
        self.backups.mkdir()
        self.db = self.root / "atuin.db"
        self.create_db(self.db)
        self.env = dict(os.environ, DB_PATH=str(self.db), BACKUP_DIR=str(self.backups))

    def create_db(self, path):
        with sqlite3.connect(path) as db:
            db.execute("CREATE TABLE history (value TEXT)")
            db.execute("INSERT INTO history VALUES ('keep me')")

    def seed(self, n=4):
        paths = []
        for i in range(n):
            p = self.backups / f"atuin-2020-01-{i+1:02}.db"
            self.create_db(p)
            os.utime(p, (time.time() - 20*86400,) * 2)
            paths.append(p)
        return paths

    def run_backup(self):
        return subprocess.run(["sh", str(SCRIPT), "--once"], env=self.env,
                              capture_output=True, text=True, timeout=20)

    def test_success_retains_three_valid_generations(self):
        old = self.seed()
        result = self.run_backup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(list(self.backups.glob("atuin-*.db"))), 3)
        self.assertFalse(old[0].exists())
        self.assertTrue(old[-1].exists())
        for p in self.backups.glob("atuin-*.db"):
            with sqlite3.connect(p) as db:
                self.assertEqual(db.execute("SELECT value FROM history").fetchone(), ("keep me",))

    def test_wal_committed_rows_are_in_snapshot(self):
        with sqlite3.connect(self.db) as db:
            db.execute("PRAGMA journal_mode=WAL")
            db.execute("INSERT INTO history VALUES ('in WAL')")
            db.commit()
            self.assertEqual(self.run_backup().returncode, 0)
            snapshot = next(self.backups.glob("atuin-*.db"))
            with sqlite3.connect(snapshot) as copy:
                self.assertEqual(copy.execute("SELECT COUNT(*) FROM history").fetchone()[0], 2)

    def test_unrelated_files_and_symlinks_are_preserved(self):
        self.seed()
        unrelated = self.backups / "manual.db"
        unrelated.write_text("keep")
        link = self.backups / "atuin-2019-01-01.db"
        link.symlink_to(self.db)
        self.assertEqual(self.run_backup().returncode, 0)
        self.assertTrue(link.is_symlink())
        self.assertEqual(unrelated.read_text(), "keep")

    def test_failure_never_prunes(self):
        old = self.seed()
        self.db.write_bytes(b"not a database")
        result = self.run_backup()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(all(p.exists() for p in old))
        self.assertIn("ERROR", result.stderr)
        self.assertEqual(len(list(self.backups.iterdir())), 4)

    def test_missing_source_is_not_created(self):
        old = self.seed()
        self.db.unlink()
        result = self.run_backup()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.db.exists())
        self.assertTrue(all(p.exists() for p in old))

    def test_recent_snapshots_are_not_pruned(self):
        old = self.seed()
        for p in old:
            os.utime(p, None)
        self.assertEqual(self.run_backup().returncode, 0)
        self.assertTrue(all(p.exists() for p in old))

    def test_corrupt_snapshots_do_not_count_towards_minimum(self):
        old = self.seed(2)
        bad = self.backups / "atuin-2099-01-01.db"
        bad.write_bytes(b"broken")
        result = self.run_backup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all(p.exists() for p in old))
        self.assertTrue(bad.exists())

    def test_repeated_runs_have_unique_names(self):
        self.assertEqual(self.run_backup().returncode, 0)
        self.assertEqual(self.run_backup().returncode, 0)
        self.assertEqual(len(list(self.backups.glob("atuin-*.db"))), 2)

    def test_publish_failure_in_recurring_mode_never_prunes(self):
        old = self.seed()
        bindir = self.root / "bin"
        bindir.mkdir()
        for name, body in {
            "mv": "exit 1",
            "sleep": "exit 42",
        }.items():
            stub = bindir / name
            stub.write_text("#!/bin/sh\n" + body + "\n")
            stub.chmod(0o755)
        self.env["PATH"] = str(bindir) + ":" + self.env["PATH"]
        result = subprocess.run(["sh", str(SCRIPT)], env=self.env,
                                capture_output=True, text=True, timeout=20)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("publishing snapshot failed", result.stderr)
        self.assertNotIn("snapshot verified", result.stderr)
        self.assertTrue(all(p.exists() for p in old))
        self.assertEqual(len(list(self.backups.iterdir())), 4)

    def test_integrity_failure_does_not_publish_or_prune(self):
        old = self.seed()
        real = shutil.which("sqlite3")
        bindir = self.root / "bin"
        bindir.mkdir()
        stub = bindir / "sqlite3"
        stub.write_text('#!/bin/sh\ncase "$*" in *integrity_check*) echo corrupt; exit 0;; esac\nexec "' + real + '" "$@"\n')
        stub.chmod(0o755)
        self.env["PATH"] = str(bindir) + ":" + self.env["PATH"]
        result = self.run_backup()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(all(p.exists() for p in old))
        self.assertEqual(len(list(self.backups.iterdir())), 4)

if __name__ == "__main__":
    unittest.main()
