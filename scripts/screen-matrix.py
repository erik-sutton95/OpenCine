#!/usr/bin/env python3
"""Run the shared screenshot matrix (the kit's ScreenMatrix scenario) for every app on one platform.

    scripts/screen-matrix.py ios --out DIR [--apps pocket insta z] [--devices phone tablet]
    scripts/screen-matrix.py android --out DIR [--apps pocket insta z] [--devices phone tablet]

Each app runs its own ScreenMatrix subclass on a private phone and a private tablet (iOS: iPhone 16 Pro
and iPad Pro 11-inch (M4) simulators; Android: Pixel 7 and Pixel Tablet emulators), created through
`ios-private-simulator.py` / `android-private-emulator.py` and deleted afterwards. A cell is one key screen
(cameras, pairing, live, gallery, player, settings) in light or dark, portrait or landscape: its
screenshot plus the checkpoint invariants (controls inside the window and safe area, no overlapping
operable controls). DIR receives `<app>/<device>/` run output, `cells/<cell>.png` and the report:
`report.json`, `report.md` and `index.html` (a contact sheet). The apps are this checkout's siblings
(`--workspace` overrides). Z Android stages its Swift core: export SWIFT_EXECUTABLE where the default
toolchain cannot build it. A run whose log stops growing for four minutes is killed and its class
restarted once; every test has a time allowance. Exits 1 when any cell breaks an invariant or is
not captured.
"""
from __future__ import annotations

import argparse
import html
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
SCREENS = ["cameras", "pairing", "live", "gallery", "player", "settings"]
APPS = {
    "pocket": {"repo": "OpenPocketCine", "generate": True, "project": "ios/OpenPocketCine.xcodeproj",
               "scheme": "OpenPocketCineUIReview", "bundle": "OpenPocketCineUITests",
               "package": "com.opencapture.openpocketcine.conformance"},
    "insta": {"repo": "OpenInstaCine", "generate": True, "project": "ios/OpenInstaCine.xcodeproj",
              "scheme": "OpenInstaCineUIReview", "bundle": "OpenInstaCineUITests",
              "package": "com.opencapture.openinstacine.conformance"},
    "z": {"repo": "OpenZCine", "generate": False, "project": "ios/Runner.xcodeproj",
          "scheme": "RunnerUIReview", "bundle": "RunnerUITests", "package": "com.opencapture.openzcine.conformance"},
}
DEVICES = {
    "ios": {"phone": "iPhone 16 Pro", "tablet": "iPad Pro 11-inch (M4)"},
    "android": {"phone": "pixel_7", "tablet": "pixel_tablet"},
}
# <app>-<device>-<orientation>-ScreenMatrix-<screen>-<appearance>, as the kit's checkpoint names a cell.
CELL = re.compile(r"^(?P<app>[^-]+)-(?P<device>.+)-(?P<orientation>portrait|landscape)-ScreenMatrix-"
                  r"(?P<screen>[a-z]+)-(?P<appearance>light|dark)$")


# A run whose log stops growing this long is stuck (a hung launch, boot or connect): it is killed.
STALL_SECONDS = 240


def run(command: list[str], log: Path, cwd: Path, env: dict | None = None) -> int:
    """Runs `command` into `log`; kills it and returns 124 when the log stalls for STALL_SECONDS."""
    with log.open("w") as output:
        output.write("$ " + " ".join(command) + "\n")
        output.flush()
        process = subprocess.Popen(command, cwd=cwd, env=env, stdout=output, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        size, quiet = -1, 0.0
        while process.poll() is None:
            time.sleep(5)
            grown = log.stat().st_size
            quiet = 0.0 if grown != size else quiet + 5
            size = grown
            if quiet >= STALL_SECONDS:
                os.killpg(process.pid, 15)
                try:
                    process.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, 9)
                output.write(f"\nscreen-matrix: no progress for {STALL_SECONDS} s, killed\n")
                return 124
        return process.returncode


def ios(app: dict, device: str, model: str, repo: Path, out: Path, scratch: Path) -> tuple[list[Path], str, int]:
    if app["generate"]:
        subprocess.run(["xcodegen", "generate"], cwd=repo / "ios", check=True, stdout=subprocess.DEVNULL)
    simulator = [sys.executable, str(SCRIPTS / "ios-private-simulator.py")]
    udid = subprocess.check_output([*simulator, "create", f"matrix-{app['repo']}-{device}", "--device", model,
                                    "--report", str(out / "simulator-setup.json")], text=True, timeout=600).strip()
    result = out / "result.xcresult"
    try:
        derived = ["-derivedDataPath", str(scratch / f"dd-{app['repo']}"),
                   "-clonedSourcePackagesDirPath", str(scratch / f"spm-{app['repo']}")]
        scheme = ["-project", app["project"], "-scheme", app["scheme"]]
        run(["xcodebuild", "-resolvePackageDependencies", *scheme, *derived], out / "resolve.log", repo)
        test = ["xcodebuild", *scheme, "-destination", f"platform=iOS Simulator,id={udid}", *derived,
                "-disableAutomaticPackageResolution", "-parallel-testing-enabled", "NO",
                "-test-timeouts-enabled", "YES", "-maximum-test-execution-time-allowance", "900",
                "-default-test-execution-time-allowance", "900",
                f"-only-testing:{app['bundle']}/ScreenMatrix", "-resultBundlePath", str(result), "test"]
        code = run(test, out / "xcodebuild.log", repo)
        if code == 124:  # stuck: restart the class once, keeping the stalled log
            (out / "xcodebuild.log").rename(out / "xcodebuild-stalled.log")
            shutil.rmtree(result, ignore_errors=True)
            code = run(test, out / "xcodebuild.log", repo)
    finally:
        subprocess.run([*simulator, "delete", udid], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    shots = out / "attachments"
    shots.mkdir(exist_ok=True)
    pngs: list[Path] = []
    if result.exists():
        subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result), "--output-path",
                        str(shots)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        manifest = shots / "manifest.json"
        for test in json.loads(manifest.read_text()) if manifest.exists() else []:
            for attachment in test["attachments"]:
                # XCTest suggests "<attachment name>_<index>_<uuid>.png".
                name = re.sub(r"_\d+_[0-9A-F-]{36}\.png$", "", attachment["suggestedHumanReadableName"])
                source = shots / attachment["exportedFileName"]
                if CELL.match(name) and source.exists():
                    pngs.append(source.rename(shots / f"{name}.png"))
    return pngs, (out / "xcodebuild.log").read_text(errors="replace"), code


def android(app: dict, device: str, profile: str, repo: Path, out: Path, scratch: Path) -> tuple[list[Path], str, int]:
    emulator = [sys.executable, str(SCRIPTS / "android-private-emulator.py")]
    name = f"matrix-{app['repo']}-{device}"
    serial = subprocess.check_output([*emulator, "create", name, "--device", profile, "--log",
                                      str(out / "emulator.log")], text=True, timeout=900).strip()
    project = repo / "Apps" / "Android"
    try:
        env = dict(os.environ, ANDROID_SERIAL=serial)
        test = ["./gradlew", "--no-daemon", ":app:connectedDebugAndroidTest",
                f"-Pandroid.testInstrumentationRunnerArguments.class={app['package']}.ScreenMatrix"]
        code = run(test, out / "gradle.log", project, env)
        if code == 124:  # stuck: restart the class once, keeping the stalled log
            (out / "gradle.log").rename(out / "gradle-stalled.log")
            code = run(test, out / "gradle.log", project, env)
    finally:
        subprocess.run([*emulator, "delete", name, serial], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    outputs = project / "app" / "build" / "outputs"
    pngs = []
    shots = out / "attachments"
    shots.mkdir(exist_ok=True)
    for png in outputs.glob("connected_android_test_additional_output/**/*ScreenMatrix-*.png"):
        if CELL.match(png.stem):
            pngs.append(Path(shutil.copy2(png, shots / png.name)))
    text = (out / "gradle.log").read_text(errors="replace")
    for report in outputs.glob("androidTest-results/connected/**/*.xml"):
        shutil.copy2(report, out / report.name)
        text += "\n" + report.read_text(errors="replace")
    return pngs, text, code


def violations(text: str, cell: str) -> list[str]:
    # Every checkpoint failure message starts with its cell's name (the kit's checkpoint).
    found = []
    for match in re.finditer(re.escape(cell) + r": [^\n<\"]+", html.unescape(text)):
        if match.group(0) not in found:
            found.append(match.group(0))
    return found


def report(platform: str, cells: list[dict], runs: list[dict], out: Path) -> None:
    (out / "report.json").write_text(json.dumps({"platform": platform, "runs": runs, "cells": cells}, indent=2) + "\n")
    broken = [cell for cell in cells if cell["status"] != "pass"]
    lines = [f"# Screen matrix ({platform})", "",
             f"{len(cells)} cells, {len(cells) - len(broken)} pass, {len(broken)} broken.", "",
             "| App | Device | Exit | Cells captured |", "| --- | --- | --- | --- |"]
    lines += [f"| {r['app']} | {r['device']} | {r['exit']} | {r['captured']} |" for r in runs]
    lines += ["", "| Cell | Status | Violations |", "| --- | --- | --- |"]
    for cell in cells:
        lines.append(f"| `{cell['cell']}` | {cell['status']} | {'<br>'.join(cell['violations'])} |")
    (out / "report.md").write_text("\n".join(lines) + "\n")
    rows = []
    for cell in cells:
        image = f'<img src="{html.escape(cell["screenshot"])}" loading="lazy">' if cell["screenshot"] else "not captured"
        notes = "".join(f"<li>{html.escape(v)}</li>" for v in cell["violations"])
        rows.append(f'<figure class="{cell["status"]}">{image}<figcaption><b>{html.escape(cell["cell"])}</b>'
                    f'<ul>{notes}</ul></figcaption></figure>')
    (out / "index.html").write_text(
        "<!doctype html><meta charset=utf-8><title>Screen matrix</title><style>"
        "body{font:13px system-ui;margin:16px;background:#fff;color:#111}"
        "figure{display:inline-block;vertical-align:top;width:260px;margin:6px;padding:6px;border:2px solid #9c9}"
        "figure.broken,figure.missing{border-color:#d33}img{max-width:100%;max-height:420px}ul{padding-left:16px}"
        f"</style><h1>Screen matrix ({platform})</h1><p>{len(cells)} cells, {len(broken)} broken.</p>"
        + "".join(rows))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("platform", choices=["ios", "android"])
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--apps", nargs="+", choices=list(APPS), default=list(APPS))
    parser.add_argument("--devices", nargs="+", choices=["phone", "tablet"], default=["phone", "tablet"])
    parser.add_argument("--workspace", type=Path, default=SCRIPTS.parent.parent, help="the directory holding the apps")
    parser.add_argument("--scratch", type=Path, help="build caches (default: OUT/.build)")
    args = parser.parse_args()
    out = args.out.resolve()
    scratch = (args.scratch or out / ".build").resolve()
    cells_dir = out / "cells"
    cells_dir.mkdir(parents=True, exist_ok=True)
    cells, runs = [], []
    for key in args.apps:
        app = APPS[key]
        for device in args.devices:
            run_dir = out / key / device
            if run_dir.exists():
                shutil.rmtree(run_dir)
            run_dir.mkdir(parents=True)
            target = DEVICES[args.platform][device]
            runner = ios if args.platform == "ios" else android
            pngs, text, code = runner(app, device, target, args.workspace / app["repo"], run_dir, scratch / args.platform)
            captured = {}
            for png in pngs:
                captured[png.stem] = Path(shutil.copy2(png, cells_dir / png.name)).relative_to(out).as_posix()
            # One cell per screen, appearance and orientation, whether or not it was captured.
            # The device as the kit names it (iOS model identifier, Android class and width), else the cell class.
            device_name = next((CELL.match(name)["device"] for name in captured), device)
            for screen in SCREENS:
                for appearance in ["light", "dark"]:
                    for orientation in ["portrait", "landscape"]:
                        cell = f"{app['repo']}-{device_name}-{orientation}-ScreenMatrix-{screen}-{appearance}"
                        found = violations(text, cell)
                        shot = captured.get(cell)
                        status = "missing" if shot is None else ("broken" if found else "pass")
                        cells.append({"app": key, "device": device, "orientation": orientation, "screen": screen,
                                      "appearance": appearance, "cell": cell, "screenshot": shot,
                                      "status": status, "violations": found})
            runs.append({"app": key, "device": device, "target": target, "exit": code, "captured": len(captured)})
    report(args.platform, cells, runs, out)
    print(out / "report.md")
    return 0 if all(cell["status"] == "pass" for cell in cells) else 1


if __name__ == "__main__":
    sys.exit(main())
