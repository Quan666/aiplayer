"""Verify the released amalgamation and exercise a library built from it."""

import ctypes
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "packages/sqlite3_flutter_libs"
LOCK = json.loads((PACKAGE / "sqlite-source.lock.json").read_text())


class SQLiteSourceIntegrityTest(unittest.TestCase):
    def test_official_amalgamation_hashes_and_version(self):
        for relative, expected in LOCK["files"].items():
            with self.subTest(file=relative):
                path = PACKAGE / relative
                self.assertFalse(path.is_symlink())
                self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), expected)
        source = PACKAGE / "darwin/sqlite3_flutter_libs/Sources/CSQLite/sqlite3.c"
        self.assertEqual(hashlib.sha3_256(source.read_bytes()).hexdigest(), LOCK["sqlite3_c_sha3_256"])
        self.assertIn(f'#define SQLITE_VERSION        "{LOCK["version"]}"', source.read_text())
        self.assertIn(LOCK["source_id"], source.read_text())


@unittest.skipUnless(shutil.which("cmake") and os.name != "nt", "Native CMake toolchain is required")
class SQLiteNativeRegressionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="aiplayer-sqlite-native-test-")
        cls.directory = Path(cls.temporary.name)
        cls.addClassCleanup(cls.temporary.cleanup)
        configured = os.environ.get("AIPLAYER_SQLITE_TEST_LIBRARY")
        if configured:
            library = Path(configured).resolve()
        else:
            source = cls.directory / "project"
            source.mkdir()
            (source / "CMakeLists.txt").write_text(
                'cmake_minimum_required(VERSION 3.14)\nproject(sqlite_regression LANGUAGES C)\n'
                f'include("{PACKAGE.as_posix()}/cmake/sqlite3_source.cmake")\n'
                'add_library(sqlite_under_test SHARED "${AIPLAYER_SQLITE_SOURCE}")\n'
                'aiplayer_configure_sqlite(sqlite_under_test)\n'
                'set_target_properties(sqlite_under_test PROPERTIES SUFFIX ".so")\n'
            )
            build = cls.directory / "build"
            for command in (["cmake", "-S", str(source), "-B", str(build), "-DCMAKE_BUILD_TYPE=Debug"],
                            ["cmake", "--build", str(build), "--parallel", "1"]):
                result = subprocess.run(command, capture_output=True, text=True, timeout=120)
                if result.returncode:
                    raise RuntimeError(result.stdout + result.stderr)
            library = build / "libsqlite_under_test.so"
        cls.library = ctypes.CDLL(str(library))
        cls.library.sqlite3_libversion.restype = ctypes.c_char_p
        cls.library.sqlite3_sourceid.restype = ctypes.c_char_p
        cls.library.sqlite3_threadsafe.restype = ctypes.c_int
        cls.library.sqlite3_open.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
        cls.library.sqlite3_open.restype = ctypes.c_int
        cls.library.sqlite3_close.argtypes = [ctypes.c_void_p]
        cls.library.sqlite3_close.restype = ctypes.c_int
        cls.callback_type = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_int,
                                            ctypes.POINTER(ctypes.c_char_p), ctypes.POINTER(ctypes.c_char_p))
        cls.library.sqlite3_exec.argtypes = [ctypes.c_void_p, ctypes.c_char_p, cls.callback_type,
                                            ctypes.c_void_p, ctypes.POINTER(ctypes.c_char_p)]
        cls.library.sqlite3_exec.restype = ctypes.c_int
        cls.library.sqlite3_free.argtypes = [ctypes.c_void_p]

    def open(self, path=":memory:"):
        database = ctypes.c_void_p()
        self.assertEqual(self.library.sqlite3_open(str(path).encode(), ctypes.byref(database)), 0)
        self.addCleanup(lambda: self.library.sqlite3_close(database))
        return database

    def sql(self, database, query):
        rows = []
        def collect(_, count, values, names):
            rows.append(tuple(values[index].decode() if values[index] is not None else None
                              for index in range(count)))
            return 0
        callback = self.callback_type(collect)
        error = ctypes.c_char_p()
        result = self.library.sqlite3_exec(database, query.encode(), callback, None, ctypes.byref(error))
        message = error.value.decode() if error.value else ""
        if error.value:
            self.library.sqlite3_free(error)
        self.assertEqual(result, 0, message)
        return rows

    def test_library_is_the_verified_release_with_threading(self):
        self.assertEqual(self.library.sqlite3_libversion().decode(), LOCK["version"])
        self.assertEqual(self.library.sqlite3_sourceid().decode(), LOCK["source_id"])
        self.assertEqual(self.library.sqlite3_threadsafe(), 1)

    def test_transactions_fts5_rtree_json_and_math(self):
        db = self.open()
        self.sql(db, "CREATE TABLE records(id INTEGER PRIMARY KEY, value TEXT);"
                     "BEGIN; INSERT INTO records(value) VALUES('discard'); ROLLBACK;"
                     "BEGIN; INSERT INTO records(value) VALUES('retained'); COMMIT;")
        self.assertEqual(self.sql(db, "SELECT value FROM records;"), [("retained",)])
        self.sql(db, "CREATE VIRTUAL TABLE search USING fts5(title);"
                     "INSERT INTO search VALUES('verified SQLite source');")
        self.assertEqual(self.sql(db, "SELECT title FROM search WHERE search MATCH 'verified';"),
                         [("verified SQLite source",)])
        self.sql(db, "CREATE VIRTUAL TABLE boxes USING rtree(id,x0,x1); INSERT INTO boxes VALUES(1,2,3);")
        self.assertEqual(self.sql(db, "SELECT id FROM boxes WHERE x0>=2;"), [("1",)])
        self.assertEqual(self.sql(db, "SELECT json_extract('{\"v\":7}','$.v'),sqrt(9);"), [("7", "3.0")])

    def test_wal_connections_checkpoint_and_reopen(self):
        with tempfile.TemporaryDirectory(dir=self.directory) as directory:
            path = Path(directory) / "library.sqlite"
            first, second = self.open(path), self.open(path)
            self.assertEqual(self.sql(first, "PRAGMA journal_mode=WAL;"), [("wal",)])
            self.sql(first, "CREATE TABLE records(id INTEGER PRIMARY KEY, value TEXT);"
                            "BEGIN IMMEDIATE; INSERT INTO records VALUES(1,'committed'); COMMIT;")
            self.assertEqual(self.sql(second, "SELECT value FROM records;"), [("committed",)])
            self.sql(second, "BEGIN IMMEDIATE; UPDATE records SET value='rolled back'; ROLLBACK;")
            self.sql(first, "PRAGMA wal_checkpoint(TRUNCATE);")
            self.assertEqual(self.sql(first, "PRAGMA integrity_check;"), [("ok",)])
            reopened = self.open(path)
            self.assertEqual(self.sql(reopened, "SELECT value FROM records;"), [("committed",)])


if __name__ == "__main__":
    unittest.main()
