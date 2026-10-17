#!/usr/bin/env python3
"""Hash nonignored build inputs, including dirty/untracked source, without logging them.

Shared by the OpenCine apps. Each app lists what its build compiles in tools/build-identity.json:
{"ios": {"app": [paths], "OpenCine": [paths]}, "android": {...}}, its own paths and those of the
sibling OpenCine checkout it builds against by path.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

INPUTS = "tools/build-identity.json"


def identity(root: Path, platform: str, configuration: str) -> str:
    spec = json.loads((root / INPUTS).read_text())[platform]
    digest = hashlib.sha256()
    digest.update(("opc-build-v1\0" + platform + "\0" + configuration + "\0").encode())
    add_files(digest, root, [INPUTS, *spec["app"]])
    # ponytail: each app build compiles the shared OpenCine package from a sibling checkout
    # named by path (ios project, Package.swift, Apps/Android/settings.gradle.kts). Hash the
    # parts this app uses while that path dependency exists; a url + version pin moves into the
    # lockfiles instead.
    sibling = root.resolve().parent / "OpenCine"
    if (sibling / ".git").exists():
        add_files(digest, sibling, spec.get("OpenCine", []), prefix=b"OpenCine/")
    return platform + "-" + digest.hexdigest()[:32]


def add_files(digest, root: Path, paths: list[str], prefix: bytes = b"") -> None:
    if not paths:
        return
    listed = subprocess.check_output(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", *paths], cwd=root
    )
    for name in sorted(set(listed.split(b"\0")) - {b""}):
        path = root / name.decode()
        if not path.is_file() or path.is_symlink():
            continue
        digest.update(prefix + name + b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).digest())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True, help="The app repository")
    parser.add_argument("--platform", choices=["ios", "android"], required=True)
    parser.add_argument("--configuration", required=True)
    args = parser.parse_args()
    print(identity(args.root, args.platform, args.configuration))
