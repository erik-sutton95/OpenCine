#!/usr/bin/env python3
"""Read-only atlas MCP server (stdio, JSON-RPC 2.0). Standard library only, no network.

Registered in the repository's .mcp.json. Each tool runs the matching atlas command in process
and returns its text, capped at MAX_LINES lines and MAX_CHARS characters, so an agent gets the
contract and the consumers of an OpenCine symbol from the committed API snapshots and consumer
index without reading app trees:

  consumers(target)  which apps use a symbol, module or OpenCine path (atlas consumers)
  api(module, grep)  one module's public API, optionally filtered (atlas api)
  pins()             each app's OpenCine pin, commits behind and changed API it uses (atlas pins)
  impact(target)     owner, linking apps and call sites from source search (atlas impact)
"""
from __future__ import annotations

import contextlib
import io
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import atlas  # noqa: E402

PROTOCOL = "2025-06-18"
MAX_LINES, MAX_CHARS = 80, 6000
STRING = {"type": "string"}
TOOLS = [
    {"name": "consumers", "description": "Which apps use an OpenCine public symbol, module (OpenCineCore, :core) or path, "
                                         "and in which files. From the committed consumer index.",
     "inputSchema": {"type": "object", "properties": {"target": STRING}, "required": ["target"]}},
    {"name": "api", "description": "Public API of one OpenCine Swift product or Gradle module, one declaration per line; "
                                   "grep filters lines.",
     "inputSchema": {"type": "object", "properties": {"module": STRING, "grep": STRING}, "required": ["module"]}},
    {"name": "pins", "description": "Each app's pinned OpenCine commit, how far behind HEAD it is and changed public API it uses.",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "impact", "description": "For a symbol or OpenCine path: owning target, products that ship it, apps that link "
                                      "it and their call sites (live source search of local checkouts).",
     "inputSchema": {"type": "object", "properties": {"target": STRING}, "required": ["target"]}},
]
NAMES = {t["name"] for t in TOOLS}


def argv_for(name, args):
    # Keep client values separate from the command's options, including option-looking names.
    if name == "consumers":
        return ["consumers", "--limit", "8", "--", args["target"]]
    if name == "api":
        grep = [f"--grep={args['grep']}"] if args.get("grep") else []
        return ["api", "--limit", str(MAX_LINES - 2), *grep, "--", args["module"]]
    if name == "pins":
        return ["pins", "--limit", "6"]
    return ["impact", "--limit", "5", "--", args["target"]]


def cap(text):
    lines = text.rstrip("\n").splitlines()
    out = "\n".join(lines[:MAX_LINES])
    if len(out) > MAX_CHARS:
        out = out[:MAX_CHARS].rsplit("\n", 1)[0]
    shown = out.count("\n") + 1 if out else 0
    return out + (f"\n... {len(lines) - shown} more line(s) not shown" if shown < len(lines) else "")


def call(name, args):
    """(text, is_error) for one tool call; never raises."""
    missing = [k for k in next(t for t in TOOLS if t["name"] == name)["inputSchema"].get("required", []) if not args.get(k)]
    if missing:
        return f"missing argument: {', '.join(missing)}", True
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        try:
            code = atlas.main(argv_for(name, args))
        except SystemExit as exc:
            code = exc.code
        except Exception as exc:  # noqa: BLE001 - a tool error is an answer, not a server crash
            print(f"{type(exc).__name__}: {exc}")
            code = None
    text = cap(out.getvalue())
    if code == atlas.INCOMPLETE:
        text += "\n(incomplete: something requested could not be read)"
    # A failed check or "nothing found" (FAIL) is still an answer; bad input or a crash is an error.
    return text or "(no output)", code in (atlas.USAGE, None)


def handle(msg):
    """The response object for one request, or None for a notification."""
    method, rid = msg.get("method"), msg.get("id")
    if rid is None:
        return None
    if method == "initialize":
        result = {"protocolVersion": PROTOCOL, "capabilities": {"tools": {}},
                  "serverInfo": {"name": "opencine-atlas", "version": atlas.ATLAS_VERSION}}
    elif method == "ping":
        result = {}
    elif method == "tools/list":
        result = {"tools": TOOLS}
    elif method == "tools/call":
        params = msg.get("params") or {}
        if not isinstance(params, dict) or not isinstance(params.get("arguments") or {}, dict):
            return {"jsonrpc": "2.0", "id": rid, "error": {"code": -32602, "message": "params and arguments must be objects"}}
        if params.get("name") not in NAMES:
            return {"jsonrpc": "2.0", "id": rid, "error": {"code": -32602, "message": f"unknown tool {params.get('name')!r}"}}
        text, is_error = call(params["name"], params.get("arguments") or {})
        result = {"content": [{"type": "text", "text": text}], "isError": is_error}
    else:
        return {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": f"method not found: {method}"}}
    return {"jsonrpc": "2.0", "id": rid, "result": result}


def main(stdin=sys.stdin, stdout=sys.stdout):
    for line in stdin:
        if not line.strip():
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            reply = {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "parse error"}}
        else:
            # Valid JSON that is not a request object (`[]`, `1`) gets an error, not a crash.
            reply = handle(msg) if isinstance(msg, dict) else {
                "jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "invalid request: not an object"}}
        if reply is not None:
            stdout.write(json.dumps(reply) + "\n")
            stdout.flush()


if __name__ == "__main__":
    main()
