#!/usr/bin/env python3
# pylint: disable=duplicate-code
# The generator copies this helper beside each deployed shared library.
"""Run a gate and retain passes only for unchanged clean trees."""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def output(*args: str) -> bytes:
    """Read a command without accepting partial output on failure."""
    return subprocess.check_output(args, stderr=subprocess.DEVNULL)  # noqa: S603 # Fixed Git/mise readers.


def fingerprint(name: str, draft: str, command: list[str]) -> tuple[str, str] | None:
    """Include selected tool versions and gate inputs, including ignored config."""
    if output("git", "status", "--porcelain", "--untracked-files=all"):
        return None
    tree = output("git", "rev-parse", "HEAD^{tree}").decode().strip()
    digest = hashlib.sha256()
    for value in (
        tree,
        name,
        command,
        output("mise", "--version").decode(),
        output("mise", "ls", "--current", "--json").decode(),
    ):
        digest.update(json.dumps(value, sort_keys=True).encode())
    paths = [
        Path(p)
        for p in (
            "mise.toml",
            ".agents/agent-skills.conf",
            ".config/mise/conf.d",
            ".devtools/tasks",
            ".pre-commit-config.yaml",
            ".pre-commit-hooks.yaml",
            "prek.toml",
            ".config/prek.toml",
            ".mise.toml",
            "mise.lock",
        )
    ]
    hooks = (
        output("git", "config", "--default", "", "--get", "core.hooksPath")
        .decode()
        .strip()
    )
    if not hooks:
        hooks = output("git", "rev-parse", "--git-path", "hooks").decode().strip()
    paths.append(Path(hooks))
    if draft:
        paths.append(Path(draft))
    for path in paths:
        files = sorted(path.rglob("*")) if path.is_dir() else [path]
        for file in files:
            digest.update(str(file).encode())
            if file.is_file():
                digest.update(str(file.stat().st_mode).encode())
                digest.update(file.read_bytes())
    return tree, digest.hexdigest()


def main() -> int:
    name, draft, rerun, *command = sys.argv[1:]
    root = output("git", "rev-parse", "--show-toplevel").decode().strip()
    os.chdir(root)
    state = (
        Path(output("git", "rev-parse", "--absolute-git-dir").decode().strip())
        / "agent-skills"
        / "gates"
    )
    state.mkdir(parents=True, exist_ok=True)
    record = state / (hashlib.sha256(name.encode()).hexdigest() + ".json")
    before = fingerprint(name, draft, command)
    saved: dict[str, object]
    try:
        saved = json.loads(record.read_text())
    except (FileNotFoundError, ValueError) as _error:
        saved = {"key": [], "passed": 0.0}
    if rerun != "true" and before and saved.get("key") == list(before):
        sys.stdout.write(f"gates: {' '.join(command)} passed at {before[0]} (reused)\n")
        sys.stdout.flush()
        return 0
    # Invalidate before attempting the command, including a forced failed retry.
    record.unlink(missing_ok=True)
    sys.stdout.write(f"gates: {' '.join(command)}\n")
    sys.stdout.flush()
    log = state / (hashlib.sha256(name.encode()).hexdigest() + ".log")
    with log.open("wb") as stream:
        result = subprocess.Popen(  # noqa: S603 # argv supplied by the workflow, never a shell.
            command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
        )
        assert result.stdout is not None  # noqa: S101 # PIPE guarantees this stream.
        for line in result.stdout:
            stream.write(line)
            sys.stdout.buffer.write(line)
            sys.stdout.buffer.flush()
        result.wait()
    after = fingerprint(name, draft, command)
    if result.returncode == 0 and before and before == after:
        with tempfile.NamedTemporaryFile(mode="w", dir=state, delete=False) as stream:
            json.dump({"key": before, "passed": time.time()}, stream)
        Path(stream.name).replace(record)
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
