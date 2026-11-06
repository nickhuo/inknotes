"""Without Full Disk Access, every command that opens the store reports no_access.

These tests need a process that cannot read the Notes store, the opposite of the
end-to-end tests, so they skip when it is readable. They do not use the `inknotes`
fixture, whose setup reads the real store.
"""

import json
import os

import pytest

from conftest import REAL_STORE, InkNotes

# Every open targets this container, so even the --apply case can't reach the real store.
CONTAINER = "inknotes-no-access"
NOTE_ID = "00000000-0000-0000-0000-000000000000"


@pytest.mark.parametrize(
    "args",
    [
        pytest.param(("find", "x"), id="find"),
        pytest.param(("search", "foo"), id="search"),
        pytest.param(("folders",), id="folders"),
        pytest.param(("tags",), id="tags"),
        pytest.param(("read", NOTE_ID), id="read"),
        pytest.param(("backlinks", NOTE_ID), id="backlinks"),
        pytest.param(("create-folder", "X"), id="create-folder-dry-run"),
        pytest.param(("create-folder", "X", "--apply"), id="create-folder-apply"),
    ],
)
def test_no_access_without_full_disk_access(binary, args):
    if os.access(REAL_STORE, os.R_OK):
        pytest.skip("The Notes store is readable; this needs a process without Full Disk Access.")
    result = InkNotes(binary).raw(*args, env={"INKNOTES_CONTAINER": CONTAINER})
    assert result.returncode == 1, result.stderr[-3000:]
    assert result.stdout == ""
    assert json.loads(result.stderr.splitlines()[-1])["error"] == "no_access"
