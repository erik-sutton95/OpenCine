"""C-API: public API snapshots. The digester itself is not run here (macOS + a Swift build);
render_dump is fed a recorded dump shape and generate() is replaced."""
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from support import AtlasCase, make_repo, meta, tree_digest, write_registry

import api  # noqa: E402


def nominal(printed):
    return {"kind": "TypeNominal", "name": printed.rsplit(".", 1)[-1], "printedName": printed}


DUMP = {"ABIRoot": {"kind": "Root", "name": "NO_MODULE", "printedName": "NO_MODULE", "tool_arguments": ["/private/x"], "children": [
    {"kind": "Import", "name": "Foundation", "printedName": "Foundation", "declKind": "Import"},
    {"kind": "TypeDecl", "name": "Reading", "printedName": "Reading", "declKind": "Enum",
     "conformances": [{"printedName": "Copyable"}, {"printedName": "Sendable"}, {"printedName": "Equatable"}],
     "children": [
         {"kind": "Var", "name": "steps", "printedName": "steps", "declKind": "EnumElement", "children": [
             {"kind": "TypeFunc", "printedName": "(Mod.Reading.Type) -> (Swift.Int, Swift.Int) -> Mod.Reading", "children": [
                 {"kind": "TypeFunc", "printedName": "(Swift.Int, Swift.Int) -> Mod.Reading", "children": []}]}]},
         {"kind": "Var", "name": "none", "printedName": "none", "declKind": "EnumElement", "children": [
             {"kind": "TypeFunc", "printedName": "(Mod.Reading.Type) -> Mod.Reading", "children": [nominal("Mod.Reading")]}]},
         {"kind": "Var", "name": "hashValue", "printedName": "hashValue", "declKind": "Var", "implicit": True,
          "children": [nominal("Swift.Int")]},
     ]},
    {"kind": "TypeDecl", "name": "Session", "printedName": "Session", "declKind": "Protocol", "children": [
        {"kind": "Function", "name": "submit", "printedName": "submit(_:deadline:)", "declKind": "Func", "throwing": True,
         "mangledName": "$s3Mod7SessionP6submityAA7ReceiptVAA7CommandV_s8DurationVtYaKF",
         "genericSig": "<Self where Self : Mod.Session>",
         "children": [nominal("Mod.Receipt"), nominal("Mod.Command"), nominal("Swift.Duration")]},
        {"kind": "Var", "name": "level", "printedName": "level", "declKind": "Var", "children": [nominal("Swift.Double")],
         "accessors": [{"kind": "Accessor", "name": "Get"}, {"kind": "Accessor", "name": "Set"}]},
    ]},
    {"kind": "Constructor", "name": "init", "printedName": "init(level:)", "declKind": "Constructor",
     "children": [nominal("Mod.Meter"), nominal("Swift.Double")]},
    {"kind": "TypeDecl", "name": "View", "printedName": "View", "declKind": "Protocol", "isExternal": True, "moduleName": "SwiftUI",
     "children": [{"kind": "Function", "name": "glass", "printedName": "glass()", "declKind": "Func",
                   "children": [nominal("some SwiftUI.View")]}]},
    {"kind": "TypeAlias", "name": "Level", "printedName": "Level", "declKind": "TypeAlias", "children": [nominal("Swift.Double")]},
]}}


class Render(unittest.TestCase):
    def test_one_sorted_line_per_public_declaration(self):
        text = api.render_dump("Mod", DUMP)
        lines = [ln for ln in text.splitlines() if not ln.startswith("#")]
        self.assertEqual(lines, [
            "case Reading.none",
            "case Reading.steps(Swift.Int, Swift.Int)",
            "enum Reading: Equatable, Sendable",
            "extension SwiftUI.View",
            "func Session.submit(_: Command, deadline: Swift.Duration) async throws -> Receipt",
            "func View.glass() -> some SwiftUI.View",
            "init (level: Swift.Double)",
            "protocol Session",
            "typealias Level = Swift.Double",
            "var Session.level: Swift.Double { get set }",
        ])
        self.assertNotIn("/private", text)  # tool arguments (machine paths) never reach the file
        self.assertEqual(text, api.render_dump("Mod", DUMP), "deterministic")


    def test_the_snapshot_does_not_depend_on_the_xcode_version(self):
        # Xcode 26 prints a non-escaping closure parameter's typealias as the function type and
        # Xcode 27 keeps the alias; iOS 27 adds SDK protocols (CLBodyIdentifiable) to UIView.
        func = {"kind": "TypeFunc", "printedName": "(Foundation.Data) -> Foundation.Data", "children": []}
        alias = {"kind": "TypeNameAlias", "printedName": "Mod.PKCE.Digest", "children": [func], "typeAttributes": ["noescape"]}
        stored = dict(alias, typeAttributes=[])

        def view(conformances, parameter):
            return {"ABIRoot": {"children": [
                {"kind": "TypeDecl", "name": "Host", "printedName": "Host", "declKind": "Class",
                 "superclassNames": ["UIKit.UIView", "UIKit.UIResponder", "ObjectiveC.NSObject"],
                 "conformances": [{"printedName": n, "usr": u} for n, u in conformances]},
                {"kind": "TypeDecl", "name": "Live", "printedName": "Live", "declKind": "Class",
                 "superclassNames": ["Other.Host", "UIKit.UIView"],
                 "conformances": [{"printedName": "Feed", "usr": "s:5Other4FeedP"}, {"printedName": "UIAppearance", "usr": "c:objc(pl)UIAppearance"}]},
                {"kind": "TypeDecl", "name": "Codec", "printedName": "Codec", "declKind": "Class", "superclassNames": ["Other.Base"],
                 "conformances": [{"printedName": "Wire", "usr": "s:5Other4WireP"}]},
                {"kind": "Function", "name": "sign", "printedName": "sign(_:)", "declKind": "Func", "children": [nominal("Swift.Void"), parameter]},
                {"kind": "Var", "name": "digest", "printedName": "digest", "declKind": "Var", "isLet": True, "children": [stored]},
            ]}}
        base = [("Equatable", "s:SQ"), ("Sendable", "s:s8SendableP"), ("UIAppearance", "c:objc(pl)UIAppearance"),
                ("UITraitChangeObservable", "s:5UIKit23UITraitChangeObservableP"), ("Feed", "s:5Other4FeedP")]
        xcode26 = api.render_dump("Mod", view(base, func), {"Other"})
        xcode27 = api.render_dump("Mod", view(base + [("CLBodyIdentifiable", "c:objc(pl)CLBodyIdentifiable")], alias), {"Other"})
        self.assertEqual(xcode26, xcode27)
        lines = [ln for ln in xcode27.splitlines() if not ln.startswith("#")]
        self.assertIn("class Host: UIKit.UIView, Equatable, Feed, Sendable", lines)
        self.assertIn("class Live: Other.Host, Feed", lines)  # an SDK class up the chain still counts
        self.assertIn("class Codec: Other.Base, Wire", lines)  # package superclass: nothing dropped
        self.assertIn("func sign(_: (Foundation.Data) -> Foundation.Data) -> Swift.Void", lines)
        self.assertIn("let digest: PKCE.Digest", lines)  # a stored alias reads the same on both


class Digest(unittest.TestCase):
    def test_a_module_that_fails_to_load_is_an_error_not_an_empty_snapshot(self):
        def fake(cmd, **_):
            if "swift-api-digester" in cmd:
                Path(cmd[cmd.index("-o") + 1]).write_text('{"ABIRoot": {"children": []}}')
                return subprocess.CompletedProcess(cmd, 0, "", "error: redefinition of module 'X'\nFailed to load module: Core\n")
            return subprocess.CompletedProcess(cmd, 0, "/sdk\n", "")
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(api.subprocess, "run", side_effect=fake):
            with self.assertRaisesRegex(RuntimeError, "Core: Failed to load module"):
                api.digest(tmp, "Core", tmp, tmp)

    def test_the_digester_is_asked_to_abort_when_a_module_fails_to_load(self):
        # Any load failure, whatever its message, must fail the digester rather than leave an empty
        # dump: the fake behaves like the real tool, aborting only when given the flag.
        def fake(cmd, **_):
            if "swift-api-digester" in cmd:
                Path(cmd[cmd.index("-o") + 1]).write_text('{"ABIRoot": {"children": []}}')
                code = 1 if "-abort-on-module-fail" in cmd else 0
                return subprocess.CompletedProcess(cmd, code, "", "error: could not build module 'Core'\n")
            return subprocess.CompletedProcess(cmd, 0, "/sdk\n", "")
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(api.subprocess, "run", side_effect=fake):
            with self.assertRaisesRegex(RuntimeError, "Core: error: could not build module"):
                api.digest(tmp, "Core", tmp, tmp)


PACKAGE = '''let package = Package(name: "OpenCine", products: [
    .library(name: "Core", targets: ["Core"]),
    .library(name: "UI", targets: ["UI"]),
], targets: [.target(name: "Core"), .target(name: "UI")])
'''


class Command(AtlasCase):
    def setUp(self):
        super().setUp()
        self.top = self.ws / "OpenCine"
        sha = make_repo(self.top, {
            "Package.swift": PACKAGE,
            "atlas/api/swift/Core.txt": "# header\nstruct Thing\nfunc Thing.go() -> ()\n",
            "atlas/api/swift/Gone.txt": "# header\nstruct Old\n",
            "Android/core/api/core.api": "public final class com/x/Thing {\n\tpublic fun go ()V\n}\n",
        })
        plat = meta("opencine", "platform", "OpenCine", refs=[{"name": "main", "commit": sha, "role": "baseline"}])
        plat["layers"] = {"core": ["Core", "UI", ":core"]}
        write_registry(self.root, [plat])

    def test_products_come_from_the_package_manifest(self):
        self.assertEqual(api.swift_products(self.top), ["Core", "UI"])
        self.assertEqual(api.package_modules(self.top), {"Core", "UI"})

    def test_lists_and_prints_swift_and_kotlin_snapshots(self):
        code, out = self.run_atlas("api")
        self.assertEqual(code, 0, out)
        self.assertIn("Core ", out)
        self.assertIn(":core ", out)
        code, out = self.run_atlas("api", "core", "--grep", "go")
        self.assertEqual(code, 0, out)
        self.assertIn("func Thing.go() -> ()", out)
        code, out = self.run_atlas("api", ":core")
        self.assertIn("public final class com/x/Thing", out)
        code, out = self.run_atlas("api", "Nope")
        self.assertEqual(code, 2, out)

    def test_check_names_the_change_and_the_update_command_and_writes_nothing(self):
        fresh = {"Core": "# header\nstruct Thing\nfunc Thing.go() -> ()\nfunc Thing.stop() -> ()\n", "UI": "# header\nstruct Panel\n"}
        before = tree_digest(self.top)
        with mock.patch.object(api, "generate", return_value=fresh):
            code, out = self.run_atlas("api", "--check")
        self.assertEqual(code, 1, out)
        self.assertIn("Core: public API changed (+1 -0)", out)
        self.assertIn("  + func Thing.stop() -> ()", out)
        self.assertIn("Gone: public API changed (+0 -1)", out)
        self.assertIn("api --write", out)
        self.assertEqual(tree_digest(self.top), before)

    def test_write_records_the_build_and_then_check_passes(self):
        fresh = {"Core": "# header\nstruct Thing\n", "UI": "# header\nstruct Panel\n"}
        with mock.patch.object(api, "generate", return_value=fresh):
            self.assertEqual(self.run_atlas("api", "--write")[0], 0)
            code, out = self.run_atlas("api", "--check")
        self.assertEqual(code, 0, out)
        self.assertEqual(sorted(p.name for p in (self.top / "atlas/api/swift").iterdir()), ["Core.txt", "UI.txt"])

    def test_check_without_a_build_is_incomplete_not_passed(self):
        with mock.patch.object(api, "generate", side_effect=RuntimeError("no SwiftPM build found")):
            code, out = self.run_atlas("api", "--check")
        self.assertEqual(code, 3, out)
        self.assertIn("no SwiftPM build found", out)


if __name__ == "__main__":
    unittest.main()
