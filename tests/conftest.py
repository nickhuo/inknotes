"""Shared setup for the end-to-end tests.

The tests drive the real `nnote` binary against a separate Notes store
(NNOTE_CONTAINER, Notes' own test-container mechanism), so they never touch
your notes. Run them from a process with Full Disk Access:

    uv run pytest

Set NNOTE_BIN to test an existing binary instead of building one, and
NNOTE_E2E_KEEP=1 to keep the test store for inspection.
"""

import hashlib
import json
import os
import shutil
import sqlite3
import struct
import subprocess
import zlib
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "tests" / "fixtures"
GROUP = Path.home() / "Library/Group Containers/group.com.apple.notes"
REAL_STORE = GROUP / "NoteStore.sqlite"
CONTAINER = "nnote-e2e"
TEST_STORE_DIR = GROUP / "Containers" / CONTAINER
FOLDER = "E2E"


class NNoteError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(f"{code}: {message}")
        self.code = code


class NNote:
    """Runs the nnote binary inside the test container."""

    def __init__(self, binary: Path):
        self.binary = binary

    def raw(self, *args: str, stdin: str | None = None, env: dict | None = None) -> subprocess.CompletedProcess:
        # The caller's NNOTE_WRITABLE_ACCOUNTS must not leak in; tests set it explicitly.
        full_env = {k: v for k, v in os.environ.items() if k != "NNOTE_WRITABLE_ACCOUNTS"}
        full_env.update({"NNOTE_CONTAINER": CONTAINER, **(env or {})})
        return subprocess.run([str(self.binary), *args], input=stdin, capture_output=True, text=True, env=full_env, timeout=120)

    def __call__(self, *args: str, stdin: str | None = None, env: dict | None = None):
        """Runs a command and returns its JSON, or raises NNoteError."""
        p = self.raw(*args, stdin=stdin, env=env)
        if p.returncode != 0:
            err = next((json.loads(l) for l in reversed(p.stderr.splitlines()) if l.startswith('{"error"')), None)
            if err is None:
                raise AssertionError(f"nnote {' '.join(args)} failed without a JSON error:\n{p.stderr[-3000:]}")
            raise NNoteError(err["error"], err["message"])
        return json.loads(p.stdout)

    def markdown(self, note: str) -> str:
        p = self.raw("read", note, "--format", "markdown")
        assert p.returncode == 0, p.stderr[-2000:]
        return p.stdout

    def create(self, markdown: str, *, folder: str = FOLDER) -> dict:
        """Creates a note from Markdown (its first line is the title) and returns it."""
        return self("create", "--folder", folder, "--markdown", "-", "--apply", stdin=markdown)["note"]

    def read(self, note: dict | str) -> dict:
        return self("read", note["id"] if isinstance(note, dict) else note)


def paragraph(note: dict, text: str) -> dict:
    hits = [p for p in note["paragraphs"] if p["text"] == text]
    assert len(hits) == 1, f"expected one paragraph {text!r}, found {len(hits)}"
    return hits[0]


def attachments(note: dict, kind: str | None = None) -> list[dict]:
    found = [a for p in note["paragraphs"] for a in p.get("attachments", [])]
    return [a for a in found if kind is None or a["type"] == kind]


def real_store_fingerprint() -> tuple[frozenset, str]:
    """Which objects exist and what every note body holds, in the real store.

    Notes.app bumps change counters on its own, so those are not compared.
    """
    db = sqlite3.connect(f"file:{REAL_STORE}?mode=ro", uri=True)
    try:
        objects = frozenset(r[0] for r in db.execute("SELECT Z_PK FROM ZICCLOUDSYNCINGOBJECT"))
        bodies = hashlib.sha256()
        for pk, data in db.execute("SELECT Z_PK, ZDATA FROM ZICNOTEDATA ORDER BY Z_PK"):
            bodies.update(str(pk).encode() + (data or b""))
        return objects, bodies.hexdigest()
    finally:
        db.close()


def write_png(path: Path) -> Path:
    w, h = 64, 32
    rows = b"".join(b"\x00" + bytes(v for x in range(w) for v in (x * 4, y * 8, 160)) for y in range(h))

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
    return path


@pytest.fixture(scope="session")
def binary() -> Path:
    if os.environ.get("NNOTE_BIN"):
        return Path(os.environ["NNOTE_BIN"]).resolve()
    subprocess.run(["zsh", str(ROOT / "build.sh")], check=True, capture_output=True)
    return ROOT / "build" / "nnote"


@pytest.fixture(scope="session")
def nnote(binary: Path):
    """A fresh test store with one folder, E2E; the real store must stay untouched."""
    try:
        before = real_store_fingerprint()
    except sqlite3.OperationalError as e:
        pytest.exit(f"Cannot read the Notes database ({e}). Run the tests from a process with Full Disk Access.", 2)
    shutil.rmtree(TEST_STORE_DIR, ignore_errors=True)
    nn = NNote(binary)
    nn("create-folder", FOLDER, "--apply")
    # Guard against the container seam silently falling back to the real store.
    paths = sorted(f["path"] for f in nn("folders")["folders"])
    if paths != ["E2E", "Notes"]:
        pytest.exit(f"The test store is not empty (folders: {paths}); refusing to continue.", 2)
    yield nn
    assert real_store_fingerprint() == before, "the real Notes store changed during the tests"
    if not os.environ.get("NNOTE_E2E_KEEP"):
        shutil.rmtree(TEST_STORE_DIR, ignore_errors=True)
