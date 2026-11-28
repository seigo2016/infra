#!/usr/bin/env python3
"""Derive Control Plane bindings from the local, trusted observation service."""
from __future__ import annotations

import json
import subprocess
import sys
import tomllib
from pathlib import Path
from uuid import UUID

EXEC_START = [
    "busctl", "--user", "--json=short", "get-property", "org.freedesktop.systemd1",
    "/org/freedesktop/systemd1/unit/research_2dops_2dbridge_2eservice",
    "org.freedesktop.systemd1.Service", "ExecStart",
]


def monitored_roots(exec_start: dict) -> list[Path]:
    # ExecStart's D-Bus property exposes argv (not a shell command or escaped human display).
    [(_path, argv, *_)] = exec_start["data"]
    if not isinstance(argv, list) or len(argv) < 2 or not all(isinstance(a, str) for a in argv):
        raise ValueError("the installed Bridge has no argv")
    if not argv[1].endswith("/control-plane/bridge/observe.py"):
        raise ValueError("the installed Bridge does not launch observe.py directly")
    roots = []
    args = iter(argv[2:])
    for arg in args:
        if arg == "--project-root" or arg.startswith("--project-root="):
            value = next(args, "") if arg == "--project-root" else arg.partition("=")[2]
            root = Path(value)
            if not root.is_absolute():
                raise ValueError("the Bridge needs an absolute observation root")
            canonical = root.resolve(strict=True)
            if not canonical.is_dir() or len(str(canonical).encode()) > 1024:
                raise ValueError("invalid observation root")
            roots.append(canonical)
    if not roots:
        raise ValueError("no observation roots in the installed Bridge")
    return sorted(set(roots))


def bindings(exec_start: dict, expected_host: str) -> list[dict[str, str]]:
    out = []
    for root in monitored_roots(exec_start):
        try:
            with (root / ".claude/research-ops.toml").open("rb") as file:
                cp = tomllib.load(file).get("control_plane", {})
        except FileNotFoundError:
            continue  # A monitored project need not be registered in the Control Plane.
        if not isinstance(cp, dict):
            raise ValueError("invalid control_plane configuration")
        if "project" not in cp:
            continue
        project, host = cp["project"], cp.get("bridge")
        if not isinstance(project, str) or not isinstance(host, str) or host != expected_host:
            raise ValueError("configured Bridge id does not match the local reporter")
        out.append({"host": host, "root": str(root), "project_id": str(UUID(project))})
    if len(out) > 200:
        raise ValueError("too many overview bindings")
    return out


def main() -> int:
    try:
        expected_host = sys.argv[1]
        if not expected_host or len(expected_host.encode()) > 500:
            raise ValueError("invalid local reporter identity")
        dbus = subprocess.run(EXEC_START, check=True, capture_output=True, timeout=10)
        print(json.dumps(bindings(json.loads(dbus.stdout), expected_host)))
    except (OSError, ValueError, KeyError, TypeError, IndexError, subprocess.SubprocessError):
        # Never print argv, credentials, checkout content or tracebacks to provisioning output.
        print("Cannot derive overview bindings from the local Bridge and its project configuration.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
