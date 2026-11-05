"""CLI contracts that must work without Full Disk Access or a Notes store."""
import json
import os
import shlex
import subprocess

import pytest

from conftest import ROOT


COMMANDS = {
    "find": 1, "search": 1, "read": 1, "backlinks": 1, "folders": 0, "tags": 0,
    "create": 1, "append": 1, "create-folder": 1, "pin": 1, "set-style": 3,
    "format": 2, "check": 2, "add-todo": 2, "add-tag": 2, "link": 2,
    "add-table": 1, "add-url": 2, "attach": 2, "draw": 1, "help": 1, "version": 0,
}


@pytest.fixture
def cli(binary):
    def run(*args):
        return subprocess.run(
            [str(binary), *args], capture_output=True, text=True, timeout=20,
            env={**os.environ, "INKNOTES_CONTAINER": "inknotes-cli-must-not-open"},
        )
    return run


def error(p, *, code="usage", exit_code=2, status="action_required"):
    assert p.returncode == exit_code, p.stderr
    assert p.stdout == ""
    assert len(p.stderr.splitlines()) == 1, p.stderr
    assert p.stderr.startswith('{"error"')
    doc = json.loads(p.stderr)
    assert doc["error"] == code
    assert doc["message"]
    assert doc["status"] == status
    assert doc["retryable"] is False
    return doc


@pytest.mark.parametrize("args", [[], ["help"], ["--help"], ["-h"]])
def test_root_help(cli, args):
    p = cli(*args)
    assert p.returncode == 0 and p.stderr == ""
    assert "Usage: inknotes" in p.stdout
    assert "--apply" in p.stdout
    for command in COMMANDS:
        assert command in p.stdout


@pytest.mark.parametrize("command", COMMANDS)
def test_help_at_every_depth(cli, command):
    pages = [cli(command, "--help"), cli(command, "-h"), cli("help", command), cli("--help", command)]
    for p in pages:
        assert p.returncode == 0 and p.stderr == ""
        assert f"Usage: inknotes {command}" in p.stdout
        for section in ["Options:", "Example:"]:
            assert section in p.stdout
    assert len({p.stdout for p in pages}) == 1


def test_discovery_skips_other_validation(cli):
    p = cli("draw", "--width", "abc", "--aply", "--help")
    assert p.returncode == 0 and p.stderr == ""
    assert "Usage: inknotes draw" in p.stdout
    p = cli("read", "--help", "--version")
    assert "Usage: inknotes read" in p.stdout
    assert p.returncode == 0 and p.stderr == ""


@pytest.mark.parametrize("args", [["version"], ["--version"], ["read", "--version"], ["--version", "read"]])
def test_version(cli, args):
    p = cli(*args)
    assert p.returncode == 0 and p.stderr == ""
    assert json.loads(p.stdout) == {"version": "0.4.0"}


@pytest.mark.parametrize("command", COMMANDS)
def test_unknown_options_rejected_per_command(cli, command):
    doc = error(cli(command, "--aply", "swallowed-before"))
    assert "--aply" in doc["message"]
    assert f"inknotes {command} --help" in doc["message"]


@pytest.mark.parametrize("command,max_args", COMMANDS.items())
def test_extra_positionals_rejected(cli, command, max_args):
    error(cli(command, *(["extra"] * (max_args + 1))))


@pytest.mark.parametrize("args", [
    ["frobnicate"], ["help", "frobnicate"], ["frobnicate", "--help"],
    ["read"], ["search"], ["draw", "note"], ["append", "note"],
    ["add-table", "note"], ["create"], ["check", "note"],
    ["find", "--apply"], ["read", "note", "--limit", "5"],
    ["pin", "note", "--bold"], ["find", "--limit"],
    ["pin", "note", "--aply", "swallowed-before"],
    ["find", "--limit", "--pinned"], ["find", "--pinned=0"],
    ["pin", "note", "--apply=false"], ["read", "--format=", "note"],
])
def test_usage_errors_before_store_open(cli, args):
    error(cli(*args))


@pytest.mark.parametrize("args", [
    ["find", "--limit", "abc"], ["search", "query", "--limit=abc"],
    ["find", "--limit", "0"], ["find", "--limit", "-1"],
    ["find", "--limit", "99999999999999999999999"],
    ["set-style", "note", "item", "body", "--indent", "abc"],
    ["set-style", "note", "item", "body", "--indent=-1"],
    *[["draw", "note", "--svg", "missing.svg", "--width", v] for v in ["abc", "0", "-1", "nan", "inf"]],
    ["read", "note", "--format", "xml"],
])
def test_invalid_values_fail_before_store_open(cli, args):
    error(cli(*args))


@pytest.mark.parametrize("args", [
    ["read", "--", "--help", "extra"],
    ["find", "--", "--limit=5", "extra"],
])
def test_double_dash_keeps_options_literal(cli, args):
    assert "Unexpected argument" in error(cli(*args))["message"]


@pytest.fixture(scope="session")
def harness(tmp_path_factory):
    """Exercise parser values, errors and unreadable search bodies without Notes."""
    folder = tmp_path_factory.mktemp("cli-contracts")
    main = folder / "main.swift"
    main.write_text('''
import Foundation
let args = Array(CommandLine.arguments.dropFirst())
switch args[0] {
case "parse":
    let parsed = Args(Array(args.dropFirst()))
    emit(["command": parsed.command ?? "", "positional": parsed.positional, "options": parsed.options, "apply": parsed.apply])
case "fail": fail(args[1], "Fixture failure.")
case "search":
    let bodies: [String?] = ["Café needle", nil, "unmatched", "another NEEDLE", nil]
    emit(searchResults(bodies, query: args[1], limit: Int(args[2])!, body: { $0 }, summary: { ["body": $0!] }))
default: fatalError("unknown fixture")
}
''')
    binary = folder / "contracts"
    sources = [ROOT / "Sources/inknotes" / name for name in ["CLI.swift", "Core.swift", "Search.swift"]]
    subprocess.run(["swiftc", *map(str, sources), str(main), "-o", str(binary)], check=True, capture_output=True, text=True)

    def run(*args):
        return subprocess.run([str(binary), *args], capture_output=True, text=True, timeout=20)
    return run


def test_parser_values_and_safety_default(harness):
    p = harness("parse", "find", "--limit=5", "--pinned", "--", "--help")
    assert p.returncode == 0 and p.stderr == ""
    assert json.loads(p.stdout) == {"command": "find", "positional": ["--help"], "options": {"limit": "5", "pinned": "1"}, "apply": False}
    for pinned in [["--pinned"], ["--pinned", "1"], ["--pinned=1"]]:
        assert json.loads(harness("parse", "find", *pinned).stdout)["options"] == {"pinned": "1"}
    p = harness("parse", "add-todo", "note", "--apply", "--", "--literal-text")
    assert json.loads(p.stdout)["apply"] is True
    assert json.loads(p.stdout)["positional"] == ["note", "--literal-text"]
    p = harness("parse", "draw", "note", "--svg=test.svg", "--width=12.5")
    assert json.loads(p.stdout)["options"]["width"] == "12.5"
    p = harness("parse", "set-style", "note", "--index=0", "--style=body", "--indent=0")
    assert p.returncode == 0 and json.loads(p.stdout)["apply"] is False


@pytest.mark.parametrize("code,exit_code,status", [
    ("usage", 2, "action_required"), ("file_not_found", 2, "action_required"),
    ("note_not_found", 2, "action_required"), ("bad_index", 2, "action_required"),
    ("no_access", 1, "action_required"), ("account_not_writable", 1, "action_required"),
    ("framework_unavailable", 1, "error"), ("save_failed", 1, "error"),
    ("fetch_failed", 1, "error"),
])
def test_error_classification(harness, code, exit_code, status):
    error(harness("fail", code), code=code, exit_code=exit_code, status=status)


@pytest.mark.parametrize("query,limit,count,truncated", [
    ("needle", "1", 1, True), ("needle", "2", 2, False),
    ("needle", "5", 2, False), ("absent", "1", 0, False),
    ("cafe", "1", 1, False),
])
def test_search_reports_unreadable_bodies_and_exact_truncation(harness, query, limit, count, truncated):
    p = harness("search", query, limit)
    assert p.returncode == 0 and p.stderr == ""
    doc = json.loads(p.stdout)
    assert doc["count"] == count == len(doc["notes"])
    assert doc["skipped"] == 2  # Includes unreadable bodies beyond the result limit.
    assert doc["truncated"] is truncated
    assert all("snippet" in note for note in doc["notes"])


def test_build_failure_does_not_copy_a_stale_binary(tmp_path):
    """A compiler failure must stay a failure even when a product already exists."""
    script = tmp_path / "build.sh"
    script.write_text((ROOT / "build.sh").read_text())
    product = tmp_path / "product"
    product.mkdir()
    stale = product / "inknotes"
    stale.write_text("stale compiler product")
    stale.chmod(0o755)
    output = tmp_path / "build" / "inknotes"
    output.parent.mkdir()
    output.write_text("previous build")
    tools = tmp_path / "tools"
    tools.mkdir()
    swift = tools / "swift"
    swift.write_text(f'''#!/bin/sh
case "$*" in
  *--show-bin-path*) printf '%s\\n' {shlex.quote(str(product))} ;;
  *) echo 'fixture compile failure' >&2; exit 37 ;;
esac
''')
    swift.chmod(0o755)
    p = subprocess.run(["zsh", str(script)], capture_output=True, text=True, timeout=20,
                       env={**os.environ, "PATH": f"{tools}:{os.environ['PATH']}"})
    assert p.returncode == 37
    assert "fixture compile failure" in p.stdout
    assert "built " not in p.stdout
    assert output.read_text() == "previous build"
