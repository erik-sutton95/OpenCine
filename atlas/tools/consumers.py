"""Consumer index: what of OpenCine each thin app adopts (B). Standard library and git only.

  atlas consumers                       one line per app from the committed index
  atlas consumers <symbol|module|path>  which apps use it, how much and in which files
  atlas consumers --write               regenerate atlas/consumers/<app>.{json,md} at each app's ref tip
  atlas consumers --check               regenerate at the commits the files record; fail on a difference
  atlas consumers --stale               regenerate at the current ref tips; fail when the content would change
  atlas pins                            each app's OpenCine pin, commits behind, changed API it uses

The public symbol set comes from the committed API snapshots (atlas/api/swift/*.txt and
Android/<module>/api/<module>.api). An app file uses a symbol when it imports the module that
declares it (Swift `import`, following `@_exported` re-exports; Kotlin `import pkg.Name` or
`pkg.*`) and names it. Apps are read from git objects at an identified commit, never a working
tree. Numbers that move with every OpenCine commit (commits behind, API changed since the pin) are
computed by `atlas pins` at query time and never committed.
"""
from __future__ import annotations

import json
import re
import sys
from collections import defaultdict
from pathlib import Path

import api
import atlas
import dupes
import hub
import resolver

OK, FAIL, USAGE, INCOMPLETE = atlas.OK, atlas.FAIL, atlas.USAGE, atlas.INCOMPLETE
GENERATOR = 2
OUT_DIR = Path("atlas/consumers")
# Bytes per committed file. Agents read the Markdown; the JSON is the complete index the CLI and
# the MCP server query (about 30 bytes per used symbol; the largest app uses about 1000).
BUDGET = {".md": 15 * 1024, ".json": 64 * 1024}
SAMPLE_FILES = 2    # files kept per symbol in the JSON; `atlas impact` lists every call site
UPDATE = "python3 atlas/tools/atlas.py consumers --write, then commit atlas/consumers"
# Android variant source sets count too: testDebug, androidTestRelease, testFixturesDebug.
TEST_PATH = re.compile(r"(^|/)(Tests?|tests?|test[A-Z]\w*|androidTest\w*|[A-Za-z0-9]*(UI)?Tests)/")
SWIFT_DECL = re.compile(r"^(?:struct|enum|class|protocol|actor|typealias|extension) ([A-Za-z_]\w*)(?=[<:\s=]|$)")
SWIFT_FREE = re.compile(r"^(?:func|var|let) ([A-Za-z_]\w*)[(:<]")
SWIFT_EXTERNAL = re.compile(r"^extension (?:\w+\.)*(\w+)$")
SWIFT_MEMBER = re.compile(r"^(?:static )?(?:func|var|let) (\w+)\.(\w+)[(:<]")
KOTLIN_CLASS = re.compile(r"^public (?:[a-z]+ )*class ([\w/]+?)(?:\$[\w$]+)? ")
KOTLIN_FUN = re.compile(r"^\tpublic (?:[a-z]+ )*fun ([A-Za-z_]\w*) \(")
IMPORT_SWIFT = re.compile(r"^\s*(@_exported\s+)?(?:@\w+\s+)*import\s+(?:(?:struct|class|enum|protocol|func|var|typealias)\s+)?(\w+)", re.M)
IMPORT_KOTLIN = re.compile(r"^\s*import\s+([\w.]+?)(\.\*)?(?:\s+as\s+\w+)?\s*$", re.M)
IDENT = re.compile(r"[A-Za-z_]\w*")
COMMENT = re.compile(r"//[^\n]*|/\*.*?\*/", re.S)
APP_VIEW = re.compile(r"^(?:public\s+|internal\s+|private\s+|fileprivate\s+)?(?:struct|final class|class)\s+(\w+(?:View|Screen|Sheet|Page))\b[^{\n]*\bView\b"
                      r"|^@Composable\s*\n(?:internal |private |public )?fun\s+([A-Z]\w*)\s*\(", re.M)
# A camera integration product names the capability fixture the app's camera family declares.
INTEGRATION_OF = {"OpenCineDJI": "dji", "OpenCineNikon": "nikon", "Insta360Apple": "luna", "Insta360Protocol": "luna"}


# ---------------------------------------------------------------- OpenCine side

def core_symbols(top):
    """{module: {"lang", "symbols": {name: package or None}}} from the committed API snapshots."""
    out = {}
    for name, path in api.snapshot_files(top).items():
        syms, current = {}, ("", "")
        if name.startswith(":"):
            for line in Path(path).read_text().splitlines():
                cls = KOTLIN_CLASS.match(line)
                if cls:
                    pkg, _, simple = cls.group(1).rpartition("/")
                    current = (pkg.replace("/", "."), simple)
                    if not simple.endswith("Kt"):
                        syms[simple] = current[0]
                    continue
                fun = KOTLIN_FUN.match(line)
                if fun and current[1].endswith("Kt") and "$" not in fun.group(1):
                    syms[fun.group(1)] = current[0]
            out[name] = {"lang": "kotlin", "symbols": syms}
        else:
            lines = api.public_lines(path)
            # Members added to another module's type (SwiftUI.View modifiers) are named directly.
            external = {m.group(1) for ln in lines if (m := SWIFT_EXTERNAL.match(ln))}
            for line in lines:
                m = SWIFT_DECL.match(line) or SWIFT_FREE.match(line)
                if m and not line.startswith("extension"):
                    syms[m.group(1)] = None
                member = SWIFT_MEMBER.match(line)
                # camelCase only: a lower-case single word (center, tint) matches too much SwiftUI code.
                if member and member.group(1) in external and re.search(r"[a-z][A-Z]", member.group(2)):
                    syms[member.group(2)] = None
            out[name] = {"lang": "swift", "symbols": syms}
    return out


def core_reexports(top):
    """{module: {modules it @_exported-imports}} from the OpenCine working tree."""
    out = defaultdict(set)
    for f in sorted((Path(top) / "Sources").glob("*/**/*.swift")):
        module = f.relative_to(Path(top) / "Sources").parts[0]
        for exported, name in IMPORT_SWIFT.findall(f.read_text(errors="replace")):
            if exported:
                out[module].add(name)
    return out


def _visible(modules, reexports):
    seen, todo = set(), list(modules)
    while todo:
        m = todo.pop()
        if m not in seen:
            seen.add(m)
            todo += reexports.get(m, ())
    return seen


# ---------------------------------------------------------------- one app

def capabilities(top, links):
    """{"integration", "bodies": {[bodies]: {state: [families]}}} grouped by identical declarations."""
    integration = next((INTEGRATION_OF[p] for p in sorted(links) if p in INTEGRATION_OF), None)
    path = Path(top) / "Fixtures" / f"control-capabilities-{integration}.tsv"
    if not integration or not path.is_file():
        return None
    by_body = defaultdict(lambda: defaultdict(list))
    for line in path.read_text().splitlines():
        if line.startswith("#") or not line.strip():
            continue
        _, body, family, state = line.split("\t")
        by_body[body][state].append(family)
    groups = defaultdict(list)
    for body, states in sorted(by_body.items()):
        groups[json.dumps({s: sorted(f) for s, f in sorted(states.items())}, sort_keys=True)].append(body)
    return {"integration": integration, "groups": [{"bodies": b, "states": json.loads(k)} for k, b in sorted(groups.items(), key=lambda kv: kv[1])]}


def build(rid, m, plat_meta, top, path, ref_name, commit, symbols, reexports, units):
    """The index record of one app at one commit."""
    links = sorted(hub.linked_products(path, commit, plat_meta))
    pin_text = resolver.git(path, "show", f"{commit}:opencine-pins.txt", check=False) or ""
    pin = next(iter(re.findall(r"^OpenCine\s+([0-9a-f]{40})\s*$", pin_text, re.M)), None)
    files = [(n, COMMENT.sub("", t)) for n, t in dupes.commit_files(path, commit)
             if Path(n).suffix in (".swift", ".kt", ".java") and not TEST_PATH.search(n) and Path(n).name != "Package.swift"]
    linked = set(links)
    # A linked product carries every target it reaches (Media brings Core).
    targets, products, modules = units
    reached = hub._closure(targets, [t for p in linked for t in products.get(p, [])]) | hub._closure(modules, linked)
    swift_mods = {k for k, v in symbols.items() if v["lang"] == "swift" and k in reached | linked}
    kotlin_by_pkg = defaultdict(dict)  # package -> {symbol: module}
    for k, v in symbols.items():
        if v["lang"] == "kotlin" and k in reached | linked:
            for s, pkg in v["symbols"].items():
                kotlin_by_pkg[pkg][s] = k
    app_reexports = {name for _, t in files if t and "@_exported" in t for exp, name in IMPORT_SWIFT.findall(t) if exp}
    uses = defaultdict(lambda: defaultdict(list))  # module -> symbol -> [file]
    owned, views = set(), set()
    for rel, text in files:
        idents = set(IDENT.findall(text))
        if rel.endswith(".swift"):
            imported = {n for _, n in IMPORT_SWIFT.findall(text)} | app_reexports
            for mod in sorted(_visible(imported, reexports) & swift_mods):
                for s in sorted(idents & symbols[mod]["symbols"].keys()):
                    uses[mod][s].append(rel)
            owned.update(re.findall(r"^(?:public |internal |final |open )*(?:struct|class|enum|protocol|actor) ([A-Z]\w*)", text, re.M))
        else:
            for name, star in IMPORT_KOTLIN.findall(text):
                pkg, _, simple = name.rpartition(".")
                cands = kotlin_by_pkg.get(name, {}) if star else {simple: kotlin_by_pkg.get(pkg, {}).get(simple)}
                for s, mod in cands.items():
                    if mod and s in idents:
                        uses[mod][s].append(rel)
            owned.update(re.findall(r"^(?:(?:public|internal|private|data|sealed|abstract|open|enum|value|annotation)\s+)*(?:class|interface|object) ([A-Z]\w*)", text, re.M))
        views.update(a or b for a, b in APP_VIEW.findall(text))
    used_files = sorted({f for mod in uses.values() for fs in mod.values() for f in fs})
    fid = {f: i for i, f in enumerate(used_files)}
    all_core = {s for v in symbols.values() for s in v["symbols"]}
    swift_names = {s for v in symbols.values() if v["lang"] == "swift" for s in v["symbols"]}
    kotlin_names = {s for v in symbols.values() if v["lang"] == "kotlin" for s in v["symbols"]}
    used = defaultdict(set)
    for mod, syms in uses.items():
        used[symbols[mod]["lang"]].update(syms)
    twins = swift_names & kotlin_names
    return {
        "generator": GENERATOR, "app": rid, "ref": ref_name, "commit": commit, "opencine_pin": pin,
        "links": {"swift": [p for p in links if not p.startswith(":")], "gradle": [p for p in links if p.startswith(":")]},
        "files": used_files,
        "modules": {mod: " ".join(f"{s}:{len(fs)}:{','.join(str(fid[f]) for f in fs[:SAMPLE_FILES])}" for s, fs in sorted(syms.items()))
                    for mod, syms in sorted(uses.items())},
        "unused_links": sorted(p for p in links if p in symbols and p not in uses),
        "owned": {"types": len(owned - all_core), "views": sorted(views - all_core)},
        "shadows": sorted((owned | views) & all_core),
        "twins": {"used_both": len(twins & used["swift"] & used["kotlin"]),
                  "swift_only": sorted(twins & used["swift"] - used["kotlin"]),
                  "kotlin_only": sorted(twins & used["kotlin"] - used["swift"])},
        "capabilities": capabilities(top, links),
    }


def _cap(items, n):
    items = list(items)
    return ", ".join(items[:n]) + (f", ... (+{len(items) - n})" if len(items) > n else "")


def markdown(rec, display):
    lines = [f"# {display}: what it adopts from OpenCine",
             "",
             f"Generated by `atlas consumers --write` from {rec['ref']} `{rec['commit'][:12]}`; do not edit. "
             f"Complete data: `{rec['app']}.json`; query with `atlas consumers <symbol|module|path>`.",
             "",
             f"- OpenCine pin: `{(rec['opencine_pin'] or 'none')[:12]}` (`atlas pins` for drift)",
             f"- Swift products: {_cap(rec['links']['swift'], 40) or 'none'}",
             f"- Gradle modules: {_cap(rec['links']['gradle'], 40) or 'none'}",
             f"- Linked but no symbol use found: {_cap(rec['unused_links'], 20) or 'none'}",
             "",
             "## Modules",
             "",
             "| Module | Symbols used | Most used |",
             "|---|---:|---|"]
    for mod, syms in rec["modules"].items():
        top = sorted(syms.items(), key=lambda kv: (-kv[1][0], kv[0]))
        lines.append(f"| {mod} | {len(syms)} | {_cap((f'{s} ({v[0]})' for s, v in top), 6)} |")
    per_file = defaultdict(int)
    for syms in rec["modules"].values():
        for v in syms.values():
            for i in v[1:]:
                per_file[i] += 1
    lines += ["", "## Adapter files (most Core symbols first)", ""]
    for i, n in sorted(per_file.items(), key=lambda kv: (-kv[1], rec["files"][kv[0]]))[:15]:
        lines.append(f"- `{rec['files'][i]}` ({n})")
    lines += ["", "## App-owned", "",
              f"- Top-level types not in OpenCine: {rec['owned']['types']}",
              f"- Views: {_cap(rec['owned']['views'], 40) or 'none'}",
              f"- Same name as an OpenCine public symbol (copy or shadow): {_cap(rec['shadows'], 30) or 'none'}",
              "", "## Platform twins", "",
              f"Names public in both the Swift and Kotlin API: {rec['twins']['used_both']} used on both sides.",
              "",
              f"- Swift side only: {_cap(rec['twins']['swift_only'], 25) or 'none'}",
              f"- Kotlin side only: {_cap(rec['twins']['kotlin_only'], 25) or 'none'}"]
    cap = rec["capabilities"]
    if cap:
        lines += ["", f"## Capabilities ({cap['integration']}, Fixtures/control-capabilities-{cap['integration']}.tsv)", ""]
        for g in cap["groups"]:
            states = "; ".join(f"{s}: {', '.join(f)}" for s, f in g["states"].items())
            lines.append(f"- {_cap(g['bodies'], 6)}: {states}")
    return "\n".join(lines) + "\n"


def serialize(rec):
    # Android package paths repeat across many files. Keep their directory once without reducing
    # adoption or sample coverage; unpack restores the full paths for every reader.
    directories = sorted({p.rpartition("/")[0] for p in rec["files"]})
    ids = {directory: i for i, directory in enumerate(directories)}
    packed = dict(rec, directories=directories)
    packed["files"] = [f"{ids[parent]}:{name}" for parent, _, name in (p.rpartition("/") for p in rec["files"])]
    return json.dumps(packed, sort_keys=True, separators=(",", ":")) + "\n"


def unpack(rec):
    """The record with each module's packed `Name:files:sample,ids` string as {name: [files, ids...]}."""
    out = dict(rec)
    directories = out.pop("directories", None)
    if directories is not None:
        out["files"] = [f"{directories[int(i)]}/{name}" if directories[int(i)] else name
                        for i, name in (p.split(":", 1) for p in rec["files"])]
    out["modules"] = {mod: {s: [int(n)] + [int(i) for i in ids.split(",") if i]
                            for s, n, ids in (e.split(":") for e in packed.split())}
                      for mod, packed in rec["modules"].items()}
    return out


# ---------------------------------------------------------------- reading the index

def load(top):
    d = Path(top) / OUT_DIR
    return {p.stem: unpack(json.loads(p.read_text())) for p in sorted(d.glob("*.json"))} if d.is_dir() else {}


def _apps(reg, pid):
    return {rid: m for rid, m in sorted(reg.items()) if rid != pid and m["layer"] == "app" and m.get("status") != "retired"}


def regenerate(reg, root, at):
    """{rid: (record or None, reason)} with `at(rid, m, path)` -> (ref name, commit) choosing the source."""
    pid, top = hub.platform(reg, root)
    symbols, reexports = core_symbols(top), core_reexports(top)
    files = atlas.platform_files_at(top)
    units = (*hub._swift_units(files), hub._gradle_units(files))
    out = {}
    for rid, m in _apps(reg, pid).items():
        res = resolver.resolve(m, root)
        if res["status"] != "ok":
            out[rid] = (None, f"checkout {res['status']}")
            continue
        ref_name, commit = at(rid, m, res["path"])
        if not commit or not resolver.rev(res["path"], commit):
            out[rid] = (None, f"{ref_name} not available locally")
            continue
        out[rid] = (build(rid, m, reg[pid], top, res["path"], ref_name, commit, symbols, reexports, units), None)
    return out


def _tip(pid):
    def at(rid, m, path):
        ref = hub.primary_ref(m, pid)
        return (ref["name"], hub.ref_tip(path, ref)) if ref else ("no registered ref", None)
    return at


def query(index, symbols, target, top, limit):
    """Text lines answering which apps use a symbol, module or OpenCine path."""
    target = target.strip()
    mods = {k: v for k, v in symbols.items()}
    if target in mods or f":{target.lstrip(':')}" in mods:
        mod = target if target in mods else f":{target.lstrip(':')}"
        lines = [f"{mod} ({mods[mod]['lang']}, {len(mods[mod]['symbols'])} public symbols)"]
        for rid, rec in index.items():
            syms = rec["modules"].get(mod, {})
            linked = mod in rec["links"]["swift"] + rec["links"]["gradle"]
            top_syms = sorted(syms.items(), key=lambda kv: (-kv[1][0], kv[0]))
            lines.append(f"  {rid}: {'links' if linked else 'does not link'}; {len(syms)} symbols used"
                         + (f": {_cap((f'{s} ({v[0]})' for s, v in top_syms), limit)}" if syms else ""))
        return lines
    names = [target]
    if "/" in target:
        f = Path(top) / target
        if not f.exists():
            return [f"{target}: no such path in OpenCine"]
        src = [f] if f.is_file() else sorted(p for p in f.rglob("*") if p.suffix in (".swift", ".kt"))
        declared = {s for p in src for s in hub.TYPE_DECL.findall(p.read_text(errors="replace"))}
        public = {s for v in symbols.values() for s in v["symbols"]}
        names = sorted(declared & public)
        if not names:
            return [f"{target}: declares no public OpenCine symbol"]
    lines = []
    owners = sorted(k for k, v in symbols.items() for n in names if n in v["symbols"])
    head = f"{', '.join(names[:8])}{' ...' if len(names) > 8 else ''}"
    lines.append(f"{head}: public in {', '.join(sorted(set(owners))) or 'no OpenCine API snapshot'}")
    for rid, rec in index.items():
        hits = [(mod, n, rec["modules"][mod][n]) for mod in rec["modules"] for n in names if n in rec["modules"][mod]]
        if not hits:
            lines.append(f"  {rid} @ {rec['commit'][:12]}: not used")
            continue
        total = sum(h[2][0] for h in hits)
        lines.append(f"  {rid} @ {rec['commit'][:12]}: {total} file(s)")
        for mod, n, v in hits[:limit]:
            sample = ", ".join(rec["files"][i] for i in v[1:])
            lines.append(f"    {n} [{mod}] {v[0]}: {sample}{' ...' if v[0] > len(v) - 1 else ''}")
    return lines


def pins(index, symbols, top, limit):
    """Text lines: pin, commits behind OpenCine HEAD and changed public lines among used symbols."""
    head = resolver.git(top, "rev-parse", "HEAD")
    lines = [f"OpenCine HEAD {head[:12]}"]
    for rid, rec in index.items():
        pin = rec.get("opencine_pin")
        if not pin:
            lines.append(f"  {rid}: no opencine-pins.txt at {rec['commit'][:12]}")
            continue
        if not resolver.rev(top, pin):
            lines.append(f"  {rid}: pin {pin[:12]} is not in this checkout (git fetch)")
            continue
        behind = resolver.git(top, "rev-list", "--count", f"{pin}..HEAD", check=False) or "?"
        changed, missing = [], []
        for mod, syms in rec["modules"].items():
            _, path = api.find_snapshot(top, mod)
            if not path:
                continue
            rel = str(path.relative_to(top))
            old = resolver.git(top, "show", f"{pin}:{rel}", check=False)
            if not old:
                missing.append(mod)
                continue
            a, b = set(api.public_lines_text(old)), set(api.public_lines(path))
            for line in sorted(a ^ b):
                words = set(IDENT.findall(line.replace("/", " ").replace("$", " ")))
                if words & syms.keys():
                    changed.append(f"{mod}: {'+' if line in b else '-'} {line.strip()}")
        lines.append(f"  {rid}: pin {pin[:12]}, {behind} commit(s) behind; {len(changed)} changed public line(s) it uses")
        if missing:
            lines.append(f"    not compared (no API snapshot at the pin): {_cap(missing, 6)}")
        lines += [f"    {c}" for c in changed[:limit]]
        if len(changed) > limit:
            lines.append(f"    ... {len(changed) - limit} more (--limit)")
    return lines


# ---------------------------------------------------------------- command

def run(args, reg, root):
    pid, top = hub.platform(reg, root)
    if not top:
        print("the OpenCine platform checkout is not available", file=sys.stderr)
        return INCOMPLETE
    out_dir = Path(top) / OUT_DIR
    if args.cmd == "pins":
        print("\n".join(pins(load(top), core_symbols(top), top, args.limit)))
        return OK
    if args.write or args.check or args.stale:
        index = load(top) if args.check else {}
        if args.check:
            at = lambda rid, m, path: (index[rid]["ref"], index[rid]["commit"]) if rid in index else _tip(pid)(rid, m, path)  # noqa: E731
        else:
            at = _tip(pid)
        fresh, code, changed = regenerate(reg, root, at), OK, []
        for rid, (rec, why) in fresh.items():
            if rec is None:
                print(f"{rid}: NOT CHECKED ({why})")
                code = INCOMPLETE
                continue
            texts = {f"{rid}.json": serialize(rec), f"{rid}.md": markdown(unpack(rec), reg[rid]["display_name"])}
            for name, text in texts.items():
                size, budget = len(text.encode()), BUDGET[Path(name).suffix]
                if size > budget:
                    print(f"{rid}: {name} is {size} bytes, over the {budget} byte budget")
                    code = FAIL
                current = out_dir / name
                if not current.is_file() or current.read_text() != text:
                    changed.append(name)
                    if args.write:
                        out_dir.mkdir(parents=True, exist_ok=True)
                        current.write_text(text)
            print(f"{rid}: {rec['ref']} {rec['commit'][:12]}, {sum(len(s.split()) for s in rec['modules'].values())} symbols in "
                  f"{len(rec['files'])} files, {len(texts[f'{rid}.json'])} B json")
        # Reports of an app that is no longer registered would still answer queries (load()).
        expected = {f"{rid}{ext}" for rid in fresh for ext in BUDGET}
        surplus = sorted(p.name for p in out_dir.glob("*") if p.suffix in BUDGET and p.name not in expected) if out_dir.is_dir() else []
        for name in surplus:
            print(f"{name}: no registered app; {'removed' if args.write else 'remove it'}")
            changed.append(name)
            if args.write:
                (out_dir / name).unlink()
        if args.write:
            print(f"consumers: {len(changed)} file(s) written or removed")
            if code == INCOMPLETE:
                print("consumers: incomplete (an app was not written)")
            return code
        if changed:
            why = ("the committed index does not match a regeneration at its recorded commits (OpenCine API or generator changed)"
                   if args.check else "an app's ref moved and the index would change")
            print(f"stale: {', '.join(changed)}: {why}. Run {UPDATE}.")
            return FAIL
        print({OK: "consumers: index is current", FAIL: "consumers: over budget"}.get(code, "consumers: incomplete"))
        return code
    index = load(top)
    if not index:
        print(f"no consumer index committed yet ({UPDATE})")
        return INCOMPLETE
    if not args.target:
        for rid, rec in index.items():
            print(f"{rid} @ {rec['ref']} {rec['commit'][:12]}: pin {(rec['opencine_pin'] or 'none')[:12]}, "
                  f"{len(rec['links']['swift'])} Swift products, {len(rec['links']['gradle'])} Gradle modules, "
                  f"{sum(len(s) for s in rec['modules'].values())} symbols in {len(rec['files'])} files")
        return OK
    lines = query(index, core_symbols(top), args.target, top, args.limit)
    print("\n".join(lines))
    return OK
