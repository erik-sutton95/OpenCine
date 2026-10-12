#!/usr/bin/env python3
"""Create or delete a private Android emulator for conformance and UI tests.

`create NAME` makes a new AVD (pixel_7 by default, `--device pixel_tablet` for a tablet) from the
newest installed `default` arm64 image unless `--image` names one, boots it headless on a free
console port, waits for boot and prints its serial (`emulator-<port>`). `delete NAME SERIAL` kills
that emulator and deletes the AVD. Every app's CI and local `conformance-android` recipe calls this
one script; it never touches an emulator or AVD it did not create.
"""
from pathlib import Path
import argparse
import os
import socket
import subprocess
import sys
import time

SDK = Path(os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT") or "")


def tool(*parts: str) -> str:
    path = SDK.joinpath(*parts)
    return str(path) if path.exists() else parts[-1]


def adb(serial: str, *args: str, timeout: float = 30) -> str:
    result = subprocess.run([tool("platform-tools", "adb"), "-s", serial, *args],
                            capture_output=True, text=True, timeout=timeout)
    return result.stdout.strip()


def free_port(first: int) -> int:
    # The console and adb ports (port, port + 1) must both be free on this host.
    for port in range(first, 5682, 2):
        try:
            for candidate in (port, port + 1):
                with socket.socket() as probe:
                    probe.bind(("127.0.0.1", candidate))
            return port
        except OSError:
            continue
    raise SystemExit("No free emulator console port")


def newest_image() -> str:
    images = sorted(SDK.glob("system-images/android-*/default/arm64-v8a"),
                    key=lambda path: int(path.parent.parent.name.split("-")[1]) if path.parent.parent.name.split("-")[1].isdigit() else 0)
    if not images:
        raise SystemExit("No default arm64-v8a system image is installed")
    api = images[-1].parent.parent.name
    return f"system-images;{api};default;arm64-v8a"


def create(name: str, device: str, image: str | None, first_port: int, gpu: str, log: Path | None) -> str:
    avd = tool("cmdline-tools", "latest", "bin", "avdmanager")
    subprocess.run([avd, "create", "avd", "-n", name, "-k", image or newest_image(), "-d", device, "--force"],
                   input="no\n", text=True, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    home = Path(os.environ.get("ANDROID_AVD_HOME") or Path.home() / ".android" / "avd")
    with (home / f"{name}.avd" / "config.ini").open("a") as config:
        config.write("hw.ramSize=3072\ndisk.dataPartition.size=6G\nhw.keyboard=no\n")
    port = free_port(first_port)
    serial = f"emulator-{port}"
    output = log.open("w") if log else subprocess.DEVNULL
    subprocess.Popen([tool("emulator", "emulator"), "-avd", name, "-port", str(port), "-no-window", "-no-audio",
                      "-no-boot-anim", "-no-snapshot", "-gpu", gpu],
                     stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
    deadline = time.time() + 600
    while time.time() < deadline:
        try:
            if adb(serial, "shell", "getprop", "sys.boot_completed", timeout=10) == "1":
                # The launcher's first-run hints and the keyguard would cover the app under test.
                adb(serial, "shell", "wm", "dismiss-keyguard")
                adb(serial, "shell", "settings", "put", "secure", "immersive_mode_confirmations", "confirmed")
                return serial
        except subprocess.TimeoutExpired:
            pass
        time.sleep(3)
    raise SystemExit(f"{name} did not boot on {serial}")


def delete(name: str, serial: str) -> None:
    subprocess.run([tool("platform-tools", "adb"), "-s", serial, "emu", "kill"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
    for _ in range(30):
        if serial not in subprocess.run([tool("platform-tools", "adb"), "devices"], capture_output=True, text=True).stdout:
            break
        time.sleep(1)
    subprocess.run([tool("cmdline-tools", "latest", "bin", "avdmanager"), "delete", "avd", "-n", name],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    make = commands.add_parser("create")
    make.add_argument("name")
    make.add_argument("--device", default="pixel_7")
    make.add_argument("--image")
    make.add_argument("--port", type=int, default=5600, help="the first console port to try")
    make.add_argument("--gpu", default="host", help="swiftshader_indirect where the host has no GPU (CI)")
    make.add_argument("--log", type=Path)
    remove = commands.add_parser("delete")
    remove.add_argument("name")
    remove.add_argument("serial")
    args = parser.parse_args()
    if args.command == "create":
        print(create(args.name, args.device, args.image, args.port, args.gpu, args.log))
    else:
        delete(args.name, args.serial)


if __name__ == "__main__":
    sys.exit(main())
