"""Regex-level readers for SwiftPM, Xcode, XcodeGen and Gradle manifests.

Each reader strips comments first, so a URL in a comment can never become a dependency.
Anything a reader cannot account for makes the manifest `unknown` (never a silent pass).
Standard library only.
"""
from __future__ import annotations

import json
import posixpath
import re

MANIFEST_RE = re.compile(
    r"(^|/)(Package\.swift|Package\.resolved|project\.yml|project\.pbxproj|"
    r"settings\.gradle(\.kts)?|build\.gradle(\.kts)?|libs\.versions\.toml)$"
)
# ponytail: path-prefix skip list; extend if a repo grows other vendored trees.
SKIP_RE = re.compile(r"(^|/)(node_modules|\.build|build|vendor|reference|ref|DerivedData)/")


def is_manifest(path):
    return bool(MANIFEST_RE.search(path)) and not SKIP_RE.search(path)


def strip_comments(text, line="//", block=True):
    """Blank out comments (keeping newlines) while respecting string literals."""
    out, i, n = [], 0, len(text)
    quote = None
    while i < n:
        c = text[i]
        if quote:
            if c == "\n" and line == "#" and quote != '"""':
                quote = None  # YAML/TOML scalars do not span lines
                continue
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if text.startswith(quote, i):
                out.append(text[i + 1:i + len(quote)])
                i += len(quote)
                quote = None
                continue
            i += 1
            continue
        if text.startswith('"""', i):
            quote = '"""'
            out.append('"""')
            i += 3
            continue
        if c in "\"'" and (line != "#" or i == 0 or text[i - 1] in " \t\n:=[,{"):
            quote = c
            out.append(c)
            i += 1
            continue
        if block and text.startswith("/*", i):
            end = text.find("*/", i + 2)
            end = n if end < 0 else end + 2
            out.append(re.sub(r"[^\n]", " ", text[i:end]))
            i = end
            continue
        at_line_comment = bool(line) and text.startswith(line, i)
        if line == "#" and at_line_comment and i > 0 and not text[i - 1].isspace():
            at_line_comment = False  # YAML/TOML: '#' only starts a comment after whitespace
        if at_line_comment:
            end = text.find("\n", i)
            end = n if end < 0 else end
            out.append(" " * (end - i))
            i = end
            continue
        out.append(c)
        i += 1
    return "".join(out)


def _line(text, pos):
    return text.count("\n", 0, pos) + 1


def _call_args(text, start):
    """Text inside the balanced parentheses that open at text[start]."""
    depth = 0
    for j in range(start, len(text)):
        if text[j] == "(":
            depth += 1
        elif text[j] == ")":
            depth -= 1
            if depth == 0:
                return text[start + 1:j]
    return None


def _result(path, kind):
    return {"path": path, "kind": kind, "status": "parsed", "deps": [], "products": [], "problems": []}


def _split_top(s):
    """Top-level comma-separated items of `s` (brackets and string literals respected)."""
    items, depth, quote, start, i = [], 0, False, 0, 0
    while i < len(s):
        c = s[i]
        if quote:
            if c == "\\":
                i += 1
            elif c == '"':
                quote = False
        elif c == '"':
            quote = True
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == "," and depth == 0:
            items.append(s[start:i].strip())
            start = i + 1
        i += 1
    items.append(s[start:].strip())
    return [x for x in items if x]


def _argument(args, key):
    """Value text of the top-level `key:` argument in a call's argument text, or None."""
    return next((a.split(":", 1)[1].strip() for a in _split_top(args) if re.match(rf"{key}\s*:", a)), None)


_TARGET_KINDS = "target|testTarget|executableTarget|binaryTarget|systemLibrary|macro|plugin"


def _package_targets(t):
    """([{name, kind, path, deps: [{name, package?}]}], problems) from a literal `targets:` array.

    A dependency is a string literal, `.target(name:)`, `.byName(name:)` or `.product(name:,
    package:)`; anything else is a problem (never silently dropped)."""
    m = re.search(r"\bPackage\s*\(", t)
    arr = _argument(_call_args(t, m.end() - 1) or "", "targets") if m else None
    if arr is None:
        return [], []
    if not (arr.startswith("[") and arr.endswith("]")):
        return [], ["targets: is not a literal array"]
    out, problems = [], []
    for item in _split_top(arr[1:-1]):
        km = re.match(rf"\.({_TARGET_KINDS})\s*\(", item)
        args = item[km.end():item.rfind(")")] if km else ""
        name = re.match(r'"([^"]+)"$', _argument(args, "name") or "")
        if not km or not name:
            problems.append(f"target entry not understood: {item[:60]}")
            continue
        target = {"name": name.group(1), "kind": km.group(1), "path": (re.match(r'"([^"]+)"$', _argument(args, "path") or "") or [None, None])[1], "deps": []}
        deps = _argument(args, "dependencies") or "[]"
        for dep in _split_top(deps[1:-1]) if deps.startswith("[") else [deps]:
            lit = re.match(r'"([^"]+)"$', dep)
            call = re.match(r'\.(target|byName|product)\s*\(', dep)
            dname = re.search(r'\bname\s*:\s*"([^"]+)"', dep)
            if lit:
                target["deps"].append({"name": lit.group(1)})
            elif call and dname:
                pkg = re.search(r'\bpackage\s*:\s*"([^"]+)"', dep)
                target["deps"].append({"name": dname.group(1), **({"package": pkg.group(1)} if call.group(1) == "product" and pkg else {})})
            else:
                problems.append(f"{name.group(1)}: dependency not understood: {dep[:60]}")
        out.append(target)
    return out, problems


def read_package_swift(path, text):
    r = _result(path, "swiftpm")
    t = strip_comments(text)
    if "Package(" not in t:
        r["status"] = "unknown"
        r["problems"].append("no Package( declaration")
        return r
    r["products"] = re.findall(r"\.(?:library|executable|plugin)\(\s*name:\s*\"([^\"]+)\"", t)
    # Only the target-direction check reads these; a target problem never hides a package edge.
    r["targets"], r["target_problems"] = _package_targets(t)
    for m in re.finditer(r"\.package\s*\(", t):
        args = _call_args(t, m.end() - 1)
        url = re.search(r"\burl:\s*\"([^\"]+)\"", args or "")
        loc = re.search(r"\bpath:\s*\"([^\"]+)\"", args or "")
        if url:
            r["deps"].append({"type": "url", "value": url.group(1), "line": _line(t, m.start())})
        elif loc:
            r["deps"].append({"type": "path", "value": loc.group(1), "line": _line(t, m.start())})
        else:
            r["status"] = "unknown"
            r["problems"].append(f"line {_line(t, m.start())}: .package( without a literal url or path")
    return r


def read_package_resolved(path, text):
    r = _result(path, "swiftpm-lock")
    try:
        data = json.loads(text)
    except ValueError:
        r["status"] = "unknown"
        r["problems"].append("invalid JSON")
        return r
    pins = data.get("pins") or (data.get("object") or {}).get("pins")
    if pins is None:
        r["status"] = "unknown"
        r["problems"].append("no pins")
        return r
    for p in pins:
        loc = p.get("location") or p.get("repositoryURL")
        state = p.get("state") or {}
        r["deps"].append({"type": "url", "value": loc, "version": state.get("version"), "revision": state.get("revision"), "lock": True})
    return r


def _yaml_block(lines, key):
    """Lines of a top-level YAML mapping `key:` (indentation-based, regex-level)."""
    out, inside = [], False
    for no, raw in enumerate(lines, 1):
        if re.match(rf"^{re.escape(key)}:\s*$", raw):
            inside = True
            continue
        if inside:
            if raw.strip() and not raw.startswith((" ", "\t")):
                break
            out.append((no, raw))
    return out


def read_xcodegen(path, text):
    r = _result(path, "xcodegen")
    lines = strip_comments(text, line="#", block=False).splitlines()
    if any(re.match(r"^include:", line) for line in lines):
        r["status"] = "unknown"
        r["problems"].append("include: specs are not read")
    entry = None
    for no, raw in _yaml_block(lines, "packages"):
        m = re.match(r"^  ([^\s:][^:]*):\s*$", raw)
        if m:
            if entry and not entry.get("value"):
                r["status"] = "unknown"
                r["problems"].append(f"line {entry['line']}: package {entry['name']} has no url or path")
            entry = {"name": m.group(1), "line": no}
            r["deps"].append(entry)
            continue
        m = re.match(r"^\s{4,}(url|path):\s*[\"']?([^\"'\s]+)[\"']?\s*$", raw)
        if m and entry is not None:
            entry["type"], entry["value"] = m.group(1), m.group(2)
    if entry and not entry.get("value"):
        r["status"] = "unknown"
        r["problems"].append(f"line {entry['line']}: package {entry['name']} has no url or path")
    r["products"] = [m.group(1) for _, raw in _yaml_block(lines, "targets") if (m := re.match(r"^  ([^\s:][^:]*):\s*$", raw))]
    return r


def read_pbxproj(path, text):
    r = _result(path, "xcodeproj")
    t = strip_comments(text, line=None)
    refs = re.findall(r"isa = XC(?:Remote|Local)SwiftPackageReference;", t)
    for m in re.finditer(r"isa = XCRemoteSwiftPackageReference;\s*repositoryURL = \"?([^\";\s]+)\"?;", t):
        r["deps"].append({"type": "url", "value": m.group(1), "line": _line(t, m.start())})
    for m in re.finditer(r"isa = XCLocalSwiftPackageReference;\s*relativePath = \"?([^\";]+?)\"?;", t):
        r["deps"].append({"type": "path", "value": m.group(1), "line": _line(t, m.start())})
    if len(refs) != len(r["deps"]):
        r["status"] = "unknown"
        r["problems"].append(f"{len(refs)} package references, {len(r['deps'])} understood")
    r["products"] = re.findall(r"isa = PBXNativeTarget;.*?\bname = \"?([^\";]+)\"?;", t, re.S)
    return r


# ponytail: Kotlin-DSL call syntax only; Groovy `implementation 'g:a:v'` without parentheses is
# not read. None of the registered repos has a Groovy build file.
_GRADLE_CONFIGS = r"(?:implementation|api|compileOnly|runtimeOnly|\w+Implementation|\w+Api|kapt|ksp)"


def _dependency_blocks(t):
    """`t` with everything outside `dependencies { ... }` blocks blanked (offsets kept)."""
    keep = [" "] * len(t)
    for m in re.finditer(r"\bdependencies\s*\{", t):
        depth = 0
        for j in range(m.end() - 1, len(t)):
            depth += {"{": 1, "}": -1}.get(t[j], 0)
            if depth == 0:
                keep[m.end():j] = t[m.end():j]
                break
    return "".join(keep)


def read_gradle(path, text):
    settings = posixpath.basename(path).startswith("settings.")
    r = _result(path, "gradle-settings" if settings else "gradle-build")
    t = strip_comments(text)
    if settings:
        for m in re.finditer(r"^\s*include\b\s*(\()?(.*)$", t, re.M):
            args = _call_args(t, m.start(1)) if m.group(1) else m.group(2)
            r["products"] += re.findall(r"[\"'](:[^\"']+)[\"']", args or "")
    for m in re.finditer(r"\bincludeBuild\s*\(?\s*", t):
        lit = re.match(r"[\"']([^\"']+)[\"']", t[m.end():])
        if lit:
            r["deps"].append({"type": "path", "value": lit.group(1), "line": _line(t, m.start())})
        else:
            r["status"] = "unknown"
            r["problems"].append(f"line {_line(t, m.start())}: includeBuild without a literal path")
    blocks = _dependency_blocks(t)
    # Same-build module dependencies (`project(":x")`, also inside testFixtures/platform).
    r["projects"] = re.findall(r"\bproject\(\s*[\"'](:[^\"']+)[\"']\s*\)", blocks)
    for m in re.finditer(rf"(?<![\w.]){_GRADLE_CONFIGS}\s*\(\s*", blocks):
        arg = t[m.end():m.end() + 200]
        lit = re.match(r"[\"']([\w.-]+:[\w.-]+)(?::[^\"']*)?[\"']", arg)
        if lit:
            r["deps"].append({"type": "coordinates", "value": lit.group(1), "line": _line(t, m.start())})
        elif not re.match(r"(project|libs\.|platform|files|fileTree|kotlin|enforcedPlatform|testFixtures)\b", arg):
            r["status"] = "unknown"
            r["problems"].append(f"line {_line(t, m.start())}: dependency argument not understood")
    return r


def read_version_catalog(path, text):
    r = _result(path, "gradle-catalog")
    lines = strip_comments(text, line="#", block=False).splitlines()
    section = None
    for no, raw in enumerate(lines, 1):
        s = raw.strip()
        if s.startswith("["):
            section = s.strip("[]")
            continue
        if section != "libraries" or "=" not in s:
            continue
        mod = re.search(r"module\s*=\s*\"([^\"]+)\"", s)
        grp, name = re.search(r"group\s*=\s*\"([^\"]+)\"", s), re.search(r"\bname\s*=\s*\"([^\"]+)\"", s)
        short = re.match(r"[\w.-]+\s*=\s*\"([\w.-]+:[\w.-]+)(?::[^\"]*)?\"", s)
        value = mod.group(1) if mod else f"{grp.group(1)}:{name.group(1)}" if grp and name else short.group(1) if short else None
        if value:
            r["deps"].append({"type": "coordinates", "value": value, "line": no})
        else:
            r["status"] = "unknown"
            r["problems"].append(f"line {no}: library entry not understood")
    return r


def read(path, text):
    name = posixpath.basename(path)
    if name == "Package.swift":
        return read_package_swift(path, text)
    if name == "Package.resolved":
        return read_package_resolved(path, text)
    if name == "project.yml":
        return read_xcodegen(path, text)
    if name == "project.pbxproj":
        return read_pbxproj(path, text)
    if name == "libs.versions.toml":
        return read_version_catalog(path, text)
    return read_gradle(path, text)


def outside_dir(manifest_path, rel):
    """For a path dependency, the first folder name outside the repo root, else None."""
    joined = posixpath.normpath(posixpath.join(posixpath.dirname(manifest_path), rel))
    parts = joined.split("/")
    ups = 0
    while ups < len(parts) and parts[ups] == "..":
        ups += 1
    if ups == 0:
        return None
    return parts[ups] if ups < len(parts) else ".."
