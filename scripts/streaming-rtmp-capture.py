#!/usr/bin/env python3
"""Record what a reference RTMP sender puts on the wire, for the streaming golden tests.

FFmpeg publishes one second of a test pattern and a tone to an FFmpeg receiver through a TCP
proxy in this script. The proxy records the sender-to-receiver bytes after the handshake (C0, C1
and C2) and writes them as hex to Fixtures/rtmp-ffmpeg-publish.hex, 32 bytes per line. FFmpeg is
a developer tool here only; nothing links it. Standard library only; every wait has a timeout.

Usage: python3 scripts/streaming-rtmp-capture.py [--output PATH]
"""
import argparse
import selectors
import socket
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / "Fixtures" / "rtmp-ffmpeg-publish.hex"
HANDSHAKE_BYTES = 1 + 1536 + 1536
MAX_FIXTURE_BYTES = 64 * 1024
TIMEOUT_SECONDS = 30


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def wait_for_listener(port, deadline):
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.05)
    raise SystemExit(f"receiver never listened on {port}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()

    receiver_port = free_port()
    proxy_port = free_port()
    deadline = time.monotonic() + TIMEOUT_SECONDS
    receiver = subprocess.Popen(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-listen", "1", "-f", "flv",
         "-i", f"rtmp://127.0.0.1:{receiver_port}/live/fixturekey", "-c", "copy", "-f", "null", "-"],
        stdin=subprocess.DEVNULL)
    sender = None
    try:
        # FFmpeg's listener accepts one connection, so the readiness probe would use it up.
        # Give it a moment instead, then connect the proxy once.
        time.sleep(0.5)
        proxy = socket.socket()
        proxy.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        proxy.bind(("127.0.0.1", proxy_port))
        proxy.listen(1)
        proxy.settimeout(TIMEOUT_SECONDS)
        sender = subprocess.Popen(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-re",
             "-f", "lavfi", "-i", "testsrc=s=64x36:r=10:d=1",
             "-f", "lavfi", "-i", "sine=d=1:sample_rate=48000",
             "-c:v", "libx264", "-g", "10", "-bf", "0",
             "-c:a", "aac", "-b:a", "32k", "-ac", "2",
             "-f", "flv", f"rtmp://127.0.0.1:{proxy_port}/live/fixturekey"],
            stdin=subprocess.DEVNULL)
        client, _ = proxy.accept()
        upstream = socket.create_connection(("127.0.0.1", receiver_port), timeout=TIMEOUT_SECONDS)
        recorded = bytearray()
        selector = selectors.DefaultSelector()
        selector.register(client, selectors.EVENT_READ, upstream)
        selector.register(upstream, selectors.EVENT_READ, client)
        open_sides = 2
        while open_sides and time.monotonic() < deadline:
            for key, _ in selector.select(timeout=1):
                data = key.fileobj.recv(65536)
                if not data:
                    selector.unregister(key.fileobj)
                    open_sides -= 1
                    try:
                        key.data.shutdown(socket.SHUT_WR)
                    except OSError:
                        pass
                    continue
                if key.fileobj is client:
                    recorded += data
                key.data.sendall(data)
        if open_sides:
            raise SystemExit("the publish did not finish in time")
        sender.wait(timeout=TIMEOUT_SECONDS)
        receiver.wait(timeout=TIMEOUT_SECONDS)
        if sender.returncode != 0 or receiver.returncode != 0:
            raise SystemExit(f"ffmpeg failed: sender {sender.returncode}, receiver {receiver.returncode}")
    finally:
        for process in (sender, receiver):
            if process and process.poll() is None:
                process.kill()

    payload = bytes(recorded[HANDSHAKE_BYTES:])
    lines = [payload[i:i + 32].hex() for i in range(0, len(payload), 32)]
    text = "\n".join(lines) + "\n"
    if len(text) > MAX_FIXTURE_BYTES:
        raise SystemExit(f"fixture is {len(text)} bytes, over the {MAX_FIXTURE_BYTES} byte limit")
    args.output.write_text(text)
    print(f"wrote {args.output.relative_to(ROOT) if args.output.is_relative_to(ROOT) else args.output}: "
          f"{len(payload)} bytes after the handshake, {len(text)} bytes of hex")


if __name__ == "__main__":
    sys.exit(main())
