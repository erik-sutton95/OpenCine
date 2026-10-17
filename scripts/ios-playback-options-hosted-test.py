#!/usr/bin/env python3
"""Run the original developer-only21 playback, status and media-opening hosted cases.

The richer owner's native popover needs real outside input from the accepted
read-only proof machinery. The caller supplies that checkout, a private simulator
and external owned output/cache storage. All original named methods stay enrolled.
The adapter shuts down the private simulator after owned readers exit and retains
userdata, Products and every raw result. Invoke through the program heavy wrapper.
"""
from pathlib import Path
from uuid import UUID
import argparse
import re
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--project-spec", type=Path, required=True)
parser.add_argument("--host-target", required=True)
parser.add_argument("--host-entitlements", type=Path, required=True)
parser.add_argument("--simulator-id", required=True)
parser.add_argument("--derived-data", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--native-proof-root", type=Path, required=True,
    help="Read-only checkout containing the accepted three native proof templates and adapter")
parser.add_argument("--jobs", type=int, choices=range(1, 5), default=4)
args = parser.parse_args()
assert re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*Simulated", args.host_target)
UUID(args.simulator_id)
command = [sys.executable, str(Path(__file__).with_name("ios-playback-options-native-input.py")),
    "--jobs", str(args.jobs), "--proof-root", str(args.native_proof_root), "--project-spec", str(args.project_spec),
    "--host-target", args.host_target, "--host-entitlements", str(args.host_entitlements),
    "--simulator-id", args.simulator_id, "--derived-data", str(args.derived_data),
    "--output", str(args.output)]
raise SystemExit(subprocess.run(command, check=False).returncode)
