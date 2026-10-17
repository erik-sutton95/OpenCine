#!/usr/bin/env python3
"""Create or delete a private iOS simulator with real accessibility for UI and hosted tests.

`create NAME` makes a new device (iPhone 16 Pro by default, newest available iOS runtime unless
`--runtime` names one), boots it once so it owns its preference store, enables accessibility in
that store only, boots it again and prints its UDID. `delete UDID` shuts it down and deletes it.
Every app's CI and local `conformance-ios` recipe calls this one script; it never touches a
simulator it did not create.
"""
from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import subprocess


def simctl(*args: str) -> str:
    return subprocess.check_output(["xcrun", "simctl", *args], text=True)


def create(name: str, device: str, runtime: str | None, report: Path | None) -> str:
    device_types = json.loads(simctl("list", "devicetypes", "--json"))["devicetypes"]
    device_type = next((item for item in device_types if item["name"] == device), None)
    if device_type is None:
        raise SystemExit(f"The {device} simulator device type is unavailable")
    runtimes = [item for item in json.loads(simctl("list", "runtimes", "--json"))["runtimes"]
                if item.get("isAvailable") and item["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")]
    if runtime:
        runtimes = [item for item in runtimes if item["version"] == runtime]
    if not runtimes:
        raise SystemExit(f"No available iOS simulator runtime{' ' + runtime if runtime else ''}")
    selected = max(runtimes, key=lambda item: tuple(int(part) for part in item["version"].split(".")))
    udid = simctl("create", name, device_type["identifier"], selected["identifier"]).strip()
    # The first boot creates this device's own preference store.
    subprocess.run(["xcrun", "simctl", "bootstatus", udid, "-b"], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["xcrun", "simctl", "shutdown", udid], check=True)
    preference = (Path.home() / "Library/Developer/CoreSimulator/Devices" / udid
                / "data/Library/Preferences/com.apple.Accessibility.plist")
    before = preference.read_bytes()
    original = plistlib.loads(before)
    enabled = dict(original, ApplicationAccessibilityEnabled=True, AccessibilityEnabled=True)
    preference.write_bytes(plistlib.dumps(enabled, fmt=plistlib.FMT_BINARY))
    if report:
        report.parent.mkdir(parents=True, exist_ok=True)
        report.write_text(json.dumps({
            "deviceID": udid, "deviceName": device, "runtime": selected["identifier"],
            "runtimeVersion": selected["version"],
            "preferenceBeforeSHA256": hashlib.sha256(before).hexdigest(),
            "preferenceAfterSHA256": hashlib.sha256(preference.read_bytes()).hexdigest(),
            "originalValues": {key: original.get(key) for key in ["ApplicationAccessibilityEnabled", "AccessibilityEnabled"]},
            "enabledOnlyForPrivateDevice": True,
        }, indent=2) + "\n")
    subprocess.run(["xcrun", "simctl", "bootstatus", udid, "-b"], check=True, stdout=subprocess.DEVNULL)
    return udid


def delete(udid: str) -> None:
    # A finished test run may already have shut its destination down.
    subprocess.run(["xcrun", "simctl", "shutdown", udid], stderr=subprocess.DEVNULL)
    subprocess.run(["xcrun", "simctl", "delete", udid], check=True)


parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
commands = parser.add_subparsers(dest="command", required=True)
create_command = commands.add_parser("create")
create_command.add_argument("name")
create_command.add_argument("--device", default="iPhone 16 Pro")
create_command.add_argument("--runtime", help="iOS version, for example 26.2; default newest available")
create_command.add_argument("--report", type=Path, help="write the accessibility setup record here")
delete_command = commands.add_parser("delete")
delete_command.add_argument("udid")
args = parser.parse_args()
if args.command == "create":
    print(create(args.name, args.device, args.runtime, args.report))
else:
    delete(args.udid)
