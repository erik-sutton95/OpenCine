#!/usr/bin/env python3
"""Stage legal texts as bundle resources, byte for byte from the repository files.

SwiftPM bundles only files inside a target, so OpenCine checks in generated copies of its
THIRD-PARTY-NOTICES.md and LICENSE for MonitorUI. Never edit those copies: edit the repository
files and run this script; `--check` changes nothing and fails when a copy has drifted.

    stage-legal-resources.py [--check]
        OpenCine: THIRD-PARTY-NOTICES.md and LICENSE into Sources/MonitorUI/Resources/Legal/.
    stage-legal-resources.py [--check] --app <app repository root> <directory>
        An app: NOTICE, LICENSE and THIRD-PARTY-NOTICES.md into <directory> (absolute, or relative
        to the app root) as NOTICE.txt, LICENSE.txt and THIRD-PARTY-NOTICES.txt. The iOS apps run
        this as a build phase into their bundle's Legal folder, so no app copy is checked in.

Android stages the same files at build time with Gradle Copy tasks.
"""
from pathlib import Path
import sys

CORE = Path(__file__).resolve().parent.parent


def pairs(argv: list[str]) -> list[tuple[Path, Path]]:
    if "--app" in argv:
        index = argv.index("--app")
        root = Path(argv[index + 1]).resolve()
        destination = root / argv[index + 2]
        return [(root / name, destination / f"{Path(name).stem}.txt")
                for name in ("NOTICE", "LICENSE", "THIRD-PARTY-NOTICES.md")]
    return [
        (CORE / "THIRD-PARTY-NOTICES.md", CORE / "Sources/MonitorUI/Resources/Legal/THIRD-PARTY-NOTICES.md"),
        (CORE / "LICENSE", CORE / "Sources/MonitorUI/Resources/Legal/LICENSE"),
    ]


def main(argv: list[str]) -> int:
    drifted = []
    for source, copy in pairs(argv):
        data = source.read_bytes()
        if "--check" in argv:
            if not copy.is_file() or copy.read_bytes() != data:
                drifted.append(f"{copy} differs from {source}")
            continue
        copy.parent.mkdir(parents=True, exist_ok=True)
        copy.write_bytes(data)
    for line in drifted:
        print(line, file=sys.stderr)
    if drifted:
        print("Run scripts/stage-legal-resources.py with the same arguments, without --check.", file=sys.stderr)
    return 1 if drifted else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
