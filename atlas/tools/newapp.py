"""atlas new-app: a thin app from atlas/templates/app (SHELL-05). Standard library only.

The template is the whole app: every file under atlas/templates/app ends in `.tmpl` (so no build
tool, indexer or `atlas dupes` reads it as code), and `__NAME__`, `__APP_ID__`,
`__PACKAGE_PATH__` and `__OPENCINE_SHA__` are filled in paths and text. The Gradle wrapper is
copied from OpenCine/Android, and the pin is the OpenCine commit this atlas sits in. Nothing is
copied from shared code: the app composes OpenCine's shell and lists its integrations.

Only the new directory is written; an existing one is never touched. Nothing builds against
this tool or the template.
"""
from __future__ import annotations

import re
import shutil
import base64
from pathlib import Path

import atlas
import resolver

OK, USAGE = atlas.OK, atlas.USAGE
TEMPLATE = Path(__file__).resolve().parent.parent / "templates" / "app"
WRAPPER = ("gradlew", "gradlew.bat", "gradle/wrapper/gradle-wrapper.jar", "gradle/wrapper/gradle-wrapper.properties")
NAME_RE = re.compile(r"^[A-Z][A-Za-z0-9]{2,40}$")
ID_RE = re.compile(r"^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$")


def generate(name, app_id, dest, opencine, *, dry_run=False):
    """Writes <dest>/<name> from the template; returns its path. `opencine` is the OpenCine
    checkout whose commit is pinned and whose Gradle wrapper is copied."""
    if not NAME_RE.fullmatch(name) or not ID_RE.fullmatch(app_id):
        raise ValueError("invalid app name or bundle/application id; nothing written")
    out = Path(dest) / name
    if out.exists():
        raise ValueError(f"{out} already exists; nothing written")
    values = {"__NAME__": name, "__APP_ID__": app_id, "__PACKAGE_PATH__": app_id.replace(".", "/"),
              "__OPENCINE_SHA__": resolver.git(opencine, "rev-parse", "HEAD"), "__ATLAS_ID__": name.lower()}

    def fill(text):
        for key, value in values.items():
            text = text.replace(key, value)
        return text

    # Validate every template and prerequisite before creating the destination. Binary sample
    # resources are decoded only for SIMULATED source sets.
    outputs = []
    for src in sorted(TEMPLATE.rglob("*.tmpl")):
        relative = fill(str(src.relative_to(TEMPLATE)))[:-len(".tmpl")]
        if relative.endswith(".base64"):
            relative = relative[:-len(".base64")]
            payload = base64.b64decode(src.read_text().strip(), validate=True)
        else:
            payload = fill(src.read_text()).encode()
        outputs.append((out / relative, payload))
    for rel in WRAPPER:
        source = Path(opencine) / "Android" / rel
        if not source.is_file():
            raise ValueError(f"missing OpenCine prerequisite {source}; nothing written")
    if dry_run:
        return out, [path for path, _ in outputs] + [out / "Android" / rel for rel in WRAPPER]
    for target, payload in outputs:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(payload)
    for rel in WRAPPER:
        (out / "Android" / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(Path(opencine) / "Android" / rel, out / "Android" / rel)
    for script in (out / "scripts/checkout-opencine.sh", out / "scripts/check-simulated.sh", out / "Android/gradlew"):
        script.chmod(0o755)
    return out


def run(args, reg, root):
    pid, top = atlas.enclosing_platform(root, reg)
    if not pid:
        print("new-app runs from the atlas inside an OpenCine checkout")
        return USAGE
    app_id = args.id or f"com.opencapture.{args.name.lower()}"
    if not NAME_RE.match(args.name) or not ID_RE.match(app_id):
        print(f"name must be a type name (OpenFooCine), id a lowercase reverse domain; got {args.name!r}, {app_id!r}")
        return USAGE
    dest = Path(args.dest) if args.dest else top.parent
    try:
        result = generate(args.name, app_id, dest, top, dry_run=args.dry_run)
    except ValueError as exc:
        print(exc)
        return USAGE
    if args.dry_run:
        out, outputs = result
        print(f"would write {out} ({app_id}, integration {args.integration}); nothing written")
        for path in outputs:
            print(path)
        return OK
    out = result
    print(f"wrote {out} ({app_id}, integration {args.integration}, OpenCine pinned at {resolver.git(top, 'rev-parse', 'HEAD')[:12]})")
    for path in sorted(path for path in out.rglob("*") if path.is_file()):
        print(path)
    if not (dest / "OpenCine").is_dir():
        print(f"note: it builds against {dest / 'OpenCine'}; run scripts/checkout-opencine.sh there first")
    print("next: README.md in the new app (build, SIMULATED variants, adding a real integration)")
    return OK
