"""B: the consumer index (atlas consumers, atlas pins) and the read-only MCP server over it."""
import io
import json
import unittest
from unittest import mock

from support import AtlasCase, commit, make_repo, meta, sh, tree_digest, write_registry

import consumers  # noqa: E402
import mcp_server  # noqa: E402

PACKAGE = '''let package = Package(name: "OpenCine", products: [
    .library(name: "Core", targets: ["Core"]),
    .library(name: "Media", targets: ["Media"]),
    .library(name: "OpenCineDJI", targets: ["OpenCineDJI"]),
], targets: [.target(name: "Core"), .target(name: "Media", dependencies: ["Core"]), .target(name: "OpenCineDJI")])
'''
CORE_API = "# header\nstruct Thing: Sendable\nfunc Thing.go() -> ()\nfunc hostSleep(for: Swift.Duration) throws -> ()\n"
MEDIA_API = "# header\nstruct CubeLUT\nextension SwiftUI.View\nfunc View.monitorGlass() -> some View\nvar View.tint: Color\n"
KOTLIN_API = ("public final class com/x/core/Thing {\n\tpublic fun <init> ()V\n}\n\n"
              "public final class com/x/core/ThingsKt {\n\tpublic static final fun makeThing ()Lcom/x/core/Thing;\n}\n")
APP_PACKAGE = '''let package = Package(name: "App", dependencies: [.package(path: "../OpenCine")],
    targets: [.target(name: "App", dependencies: [.product(name: "Media", package: "OpenCine"),
                                                  .product(name: "OpenCineDJI", package: "OpenCine")])])
'''
SETTINGS = 'includeBuild("../OpenCine/Android")\n'
GRADLE = 'dependencies { implementation("com.opencapture.opencine:core") }\n'


class Fixture(AtlasCase):
    def setUp(self):
        super().setUp()
        self.top = self.ws / "OpenCine"
        self.plat = make_repo(self.top, {
            "Package.swift": PACKAGE,
            "Sources/Core/Thing.swift": "public struct Thing {}\n",
            "Sources/Media/Exports.swift": "@_exported import Core\npublic struct CubeLUT {}\n",
            "atlas/api/swift/Core.txt": CORE_API, "atlas/api/swift/Media.txt": MEDIA_API,
            "Android/core/api/core.api": KOTLIN_API,
            "Fixtures/control-capabilities-dji.tsv": "# h\n# integration\tbody\tfamily\tstate\ndji\tPocket 3\tiso\toffered\n"
                                                     "dji\tPocket 3\tgimbal\toffered\ndji\tPocket 4\tiso\toffered\ndji\tPocket 4\tgimbal\toffered\n",
        })
        app = self.ws / "App"
        self.app_main = make_repo(app, {
            "Package.swift": APP_PACKAGE, "settings.gradle.kts": SETTINGS, "app/build.gradle.kts": GRADLE,
            "opencine-pins.txt": f"# pin\nOpenCine {self.plat}\n",
            # Media re-exports Core, so Thing is visible through `import Media`; the comment is ignored.
            "Sources/App/A.swift": "import Media\n// CubeLUT in a comment\nstruct Panel: View { var body: some View { Thing().monitorGlass() } }\n",
            "Sources/App/B.swift": "import Foundation\nlet t = Thing()\n",  # no OpenCine import: not a use
            "Sources/App/Thing.swift": "struct CubeLUT {}\n",  # an app copy of a public name
            "app/src/main/kotlin/K.kt": "import com.x.core.Thing\nimport com.x.core.makeThing\nval k: Thing = makeThing()\n",
            "Tests/AppTests/T.swift": "import Media\nlet t = CubeLUT()\n",  # tests are not adoption
        }, url="https://github.com/o/App")
        products = [{"name": n, "kind": "swift-library", "manifest": "Package.swift"} for n in ("Core", "Media", "OpenCineDJI")] + [
            {"name": ":core", "kind": "gradle-module", "manifest": "Android/settings.gradle.kts", "coordinates": "com.opencapture.opencine:core"}]
        plat = meta("opencine", "platform", "OpenCine", products=products, refs=[{"name": "main", "commit": self.plat, "role": "baseline"}])
        plat["layers"] = {"core": ["Core", "Media", "OpenCineDJI", ":core"]}
        edge = {"to": "opencine", "kind": "library", "status": "live", "confidence": "inferred", "ref": "main"}
        write_registry(self.root, [plat, meta("app", "app", "App", url="https://github.com/o/App", edges=[edge],
                                              refs=[{"name": "main", "commit": self.app_main, "role": "baseline"}])])

    def write(self):
        code, out = self.run_atlas("consumers", "--write")
        self.assertEqual(code, 0, out)
        return json.loads((self.top / "atlas/consumers/app.json").read_text())


class Consumers(Fixture):
    def test_symbols_come_from_the_api_snapshots(self):
        syms = consumers.core_symbols(self.top)
        self.assertEqual(set(syms["Core"]["symbols"]), {"Thing", "hostSleep"})
        self.assertEqual(set(syms["Media"]["symbols"]), {"CubeLUT", "monitorGlass"})  # `tint` is too generic
        self.assertEqual(syms[":core"]["symbols"], {"Thing": "com.x.core", "makeThing": "com.x.core"})

    def test_index_records_adoption_files_pins_copies_twins_and_capabilities(self):
        rec = consumers.unpack(self.write())
        self.assertEqual((rec["commit"], rec["opencine_pin"]), (self.app_main, self.plat))
        self.assertEqual(rec["links"], {"swift": ["Media", "OpenCineDJI"], "gradle": [":core"]})
        self.assertEqual(rec["files"], ["Sources/App/A.swift", "app/src/main/kotlin/K.kt"])
        self.assertEqual(rec["modules"]["Core"], {"Thing": [1, 0]})
        self.assertEqual(rec["modules"]["Media"], {"monitorGlass": [1, 0]})
        self.assertEqual(rec["modules"][":core"], {"Thing": [1, 1], "makeThing": [1, 1]})
        self.assertEqual(rec["shadows"], ["CubeLUT"])
        self.assertEqual(rec["twins"], {"used_both": 1, "swift_only": [], "kotlin_only": []})
        self.assertEqual(rec["capabilities"]["groups"], [{"bodies": ["Pocket 3", "Pocket 4"], "states": {"offered": ["gimbal", "iso"]}}])
        md = (self.top / "atlas/consumers/app.md").read_text()
        self.assertIn("| Core | 1 | Thing (1) |", md)
        self.assertNotIn(chr(0x2014), md)  # atlas style: no em dash

    def test_queries_by_symbol_module_and_path(self):
        self.write()
        code, out = self.run_atlas("consumers", "Thing")
        self.assertEqual(code, 0, out)
        self.assertIn("Thing: public in :core, Core", out)
        self.assertIn("Thing [Core] 1: Sources/App/A.swift", out)
        code, out = self.run_atlas("consumers", ":core")
        self.assertIn("app: links; 2 symbols used: Thing (1), makeThing (1)", out)
        code, out = self.run_atlas("consumers", "Sources/Core/Thing.swift")
        self.assertIn("Thing [:core] 1: app/src/main/kotlin/K.kt", out)
        code, out = self.run_atlas("consumers", "hostSleep")
        self.assertIn("app @ ", out)
        self.assertIn(": not used", out)

    def test_check_passes_then_fails_when_the_api_changes_and_writes_nothing(self):
        self.write()
        code, out = self.run_atlas("consumers", "--check")
        self.assertEqual(code, 0, out)
        (self.top / "atlas/api/swift/Media.txt").write_text(MEDIA_API.replace("func View.monitorGlass() -> some View\n", ""))
        before = tree_digest(self.ws)
        code, out = self.run_atlas("consumers", "--check")
        self.assertEqual(code, 1, out)
        self.assertIn("consumers --write", out)
        self.assertEqual(tree_digest(self.ws), before)

    def test_stale_reads_the_moved_ref_tip(self):
        self.write()
        self.assertEqual(self.run_atlas("consumers", "--stale")[0], 0)
        commit(self.ws / "App", {"Sources/App/C.swift": "import Core\nlet c = Thing()\n"}, "use more")
        code, out = self.run_atlas("consumers", "--stale")
        self.assertEqual(code, 1, out)
        self.assertIn("ref moved", out)

    def test_pins_counts_commits_and_changed_lines_the_app_uses(self):
        self.write()
        sh(self.top, "add", "-A")
        sh(self.top, "commit", "-qm", "index")
        commit(self.top, {"atlas/api/swift/Core.txt": CORE_API.replace("go()", "go(fast: Swift.Bool)")}, "change Thing")
        code, out = self.run_atlas("pins")
        self.assertEqual(code, 0, out)
        self.assertIn(f"app: pin {self.plat[:12]}, 2 commit(s) behind; 2 changed public line(s) it uses", out)
        self.assertIn("Core: + func Thing.go(fast: Swift.Bool) -> ()", out)

    def test_missing_app_checkout_is_incomplete_not_passed(self):
        self.write()
        (self.root / ".local").mkdir()
        (self.root / ".local/checkouts.json").write_text(json.dumps({"repos": {"app": str(self.ws / "Gone")}}))
        code, out = self.run_atlas("consumers", "--check")
        self.assertEqual(code, 3, out)
        self.assertIn("NOT CHECKED", out)

    def test_android_test_variant_source_sets_are_not_adoption(self):
        tip = commit(self.ws / "App", {
            "app/src/testDebug/kotlin/T.kt": "import com.x.core.Thing\nval t = Thing()\n",
            "app/src/androidTestRelease/kotlin/U.kt": "import com.x.core.makeThing\nval u = makeThing()\n",
            "app/src/testFixturesDebug/kotlin/V.kt": "import com.x.core.Thing\nval v = Thing()\n",
        }, "variant tests")
        code, out = self.run_atlas("consumers", "--write")
        self.assertEqual(code, 0, out)
        rec = consumers.unpack(json.loads((self.top / "atlas/consumers/app.json").read_text()))
        self.assertEqual(rec["commit"], tip)
        self.assertEqual(rec["files"], ["Sources/App/A.swift", "app/src/main/kotlin/K.kt"])

    def test_write_that_skips_an_app_is_incomplete(self):
        (self.root / ".local").mkdir()
        (self.root / ".local/checkouts.json").write_text(json.dumps({"repos": {"app": str(self.ws / "Gone")}}))
        code, out = self.run_atlas("consumers", "--write")
        self.assertEqual(code, 3, out)
        self.assertIn("NOT CHECKED", out)

    def test_reports_of_an_unregistered_app_are_stale_and_write_removes_them(self):
        self.write()
        for name in ("gone.json", "gone.md"):
            (self.top / "atlas/consumers" / name).write_text((self.top / "atlas/consumers" / name.replace("gone", "app")).read_text())
        code, out = self.run_atlas("consumers", "--check")
        self.assertEqual(code, 1, out)
        self.assertIn("gone.json", out)
        self.assertIn("no registered app", out)
        code, out = self.run_atlas("consumers", "--write")
        self.assertEqual(code, 0, out)
        self.assertFalse((self.top / "atlas/consumers/gone.json").exists())
        self.assertFalse((self.top / "atlas/consumers/gone.md").exists())
        self.assertEqual(self.run_atlas("consumers", "--check")[0], 0)

    def test_large_cross_platform_index_keeps_all_adoption_within_budget(self):
        # Android library snapshots add about 1500 symbols and long package paths to an app.
        rec = self.write()
        paths = [f"Apps/Android/app/src/main/kotlin/com/opencapture/camera/Screen{i:03d}.kt" for i in range(222)]
        rec["files"] = paths
        rec["modules"] = {":core": " ".join(f"CameraSettingDescriptor{i:04d}:2:0,221" for i in range(1560))}
        original = json.loads(json.dumps(rec))
        text = consumers.serialize(rec)
        self.assertLessEqual(len(text.encode()), consumers.BUDGET[".json"])
        self.assertEqual(rec, original)  # serializing must not change a later Markdown render
        self.assertEqual(consumers.serialize(rec), text)
        decoded = consumers.unpack(json.loads(text))
        self.assertEqual(decoded["files"], paths)
        self.assertEqual(len(decoded["modules"][":core"]), 1560)
        self.assertEqual(set(tuple(value) for value in decoded["modules"][":core"].values()), {(2, 0, 221)})
        # File IDs and both sample paths still reach the query result, including the last file.
        query = consumers.query({"app": decoded}, {":core": {"lang": "kotlin", "symbols": {"CameraSettingDescriptor1559": "com.x.core"}}},
                                "CameraSettingDescriptor1559", self.top, 10)
        self.assertEqual(query[-1], "    CameraSettingDescriptor1559 [:core] 2: " + paths[0] + ", " + paths[221])

    def test_path_roundtrip_preserves_root_names_colons_and_empty_files(self):
        rec = self.write()
        for paths in ([], ["Root.swift", "Sources/Camera:A.swift", "Sources/Caméra.kt"]):
            with self.subTest(paths=paths):
                rec["files"] = paths
                self.assertEqual(consumers.unpack(json.loads(consumers.serialize(rec)))["files"], paths)

    def test_existing_unpacked_paths_still_load_and_query(self):
        rec = self.write()
        rec["files"] = ["Sources/App/A.swift", "app/src/main/kotlin/K.kt"]
        rec.pop("directories", None)
        (self.top / "atlas/consumers/app.json").write_text(json.dumps(rec))
        code, out = self.run_atlas("consumers", "Thing")
        self.assertEqual(code, 0, out)
        self.assertIn("Thing [Core] 1: Sources/App/A.swift", out)
        self.assertIn("Thing [:core] 1: app/src/main/kotlin/K.kt", out)

    def test_budget_is_enforced(self):
        self.write()
        with mock.patch.dict(consumers.BUDGET, {".json": 10}):
            code, out = self.run_atlas("consumers", "--check")
        self.assertEqual(code, 1, out)
        self.assertIn("over the 10 byte budget", out)
        self.assertIn("consumers: over budget", out)


class McpServer(Fixture):
    def ask(self, *messages):
        out = io.StringIO()
        mcp_server.main(io.StringIO("".join(json.dumps(m) + "\n" for m in messages)), out)
        return [json.loads(line) for line in out.getvalue().splitlines()]

    def test_lists_four_tools_and_answers_from_the_index(self):
        self.write()
        init, tools, used, api, bad = self.ask(
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "consumers", "arguments": {"target": "Thing"}}},
            {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "api", "arguments": {"module": "core", "grep": "go"}}},
            {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "consumers", "arguments": {}}},
        )
        self.assertEqual(init["result"]["serverInfo"]["name"], "opencine-atlas")
        self.assertEqual([t["name"] for t in tools["result"]["tools"]], ["consumers", "api", "pins", "impact"])
        self.assertIn("Thing [Core] 1: Sources/App/A.swift", used["result"]["content"][0]["text"])
        self.assertIn("func Thing.go() -> ()", api["result"]["content"][0]["text"])
        self.assertTrue(bad["result"]["isError"])

    def test_output_is_capped_and_unknown_methods_are_errors(self):
        self.assertIn("more line(s) not shown", mcp_server.cap("\n".join(str(i) for i in range(500))))
        self.assertLessEqual(len(mcp_server.cap("x" * 90 + "\n") * 1), mcp_server.MAX_CHARS)
        reply, = self.ask({"jsonrpc": "2.0", "id": 9, "method": "resources/list"})
        self.assertEqual(reply["error"]["code"], -32601)
        reply, = self.ask({"jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": {"name": "write", "arguments": {}}})
        self.assertEqual(reply["error"]["code"], -32602)

    def test_non_object_requests_and_params_are_errors_and_the_server_keeps_answering(self):
        lines = "[]\n" + "".join(json.dumps(m) + "\n" for m in (
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["consumers"]},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "consumers", "arguments": ["Thing"]}},
            {"jsonrpc": "2.0", "id": 3, "method": "ping"},
        ))
        out = io.StringIO()
        mcp_server.main(io.StringIO(lines), out)
        array, params, arguments, ping = [json.loads(line) for line in out.getvalue().splitlines()]
        self.assertEqual((array["id"], array["error"]["code"]), (None, -32600))
        self.assertEqual((params["id"], params["error"]["code"]), (1, -32602))
        self.assertEqual((arguments["id"], arguments["error"]["code"]), (2, -32602))
        self.assertEqual(ping, {"jsonrpc": "2.0", "id": 3, "result": {}})

    def test_a_consumer_target_cannot_rewrite_a_stale_index(self):
        self.write()
        commit(self.ws / "App", {"Sources/App/New.swift": "import Media\nlet value = Thing()\n"}, "new adoption")
        before = tree_digest(self.ws)
        reply, = self.ask({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                          "params": {"name": "consumers", "arguments": {"target": "--write"}}})
        self.assertEqual(tree_digest(self.ws), before)
        self.assertIn("--write: public in", reply["result"]["content"][0]["text"])
        self.assertFalse(reply["result"]["isError"])

    def test_option_looking_modules_targets_and_filters_are_literal_values(self):
        self.write()
        before = tree_digest(self.ws)
        for name, args, expected in (
            ("api", {"module": "--write"}, "--write: no API snapshot"),
            ("impact", {"target": "--write"}, "nothing found: not declared in OpenCine"),
            ("api", {"module": "Core", "grep": "--write"}, "Core: 0 line(s)"),
        ):
            with self.subTest(name=name, args=args):
                reply, = self.ask({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                  "params": {"name": name, "arguments": args}})
                self.assertEqual(tree_digest(self.ws), before)
                self.assertIn(expected, reply["result"]["content"][0]["text"])

    def test_tools_write_nothing(self):
        self.write()
        before = tree_digest(self.ws)
        for name, args in (("consumers", {"target": "Thing"}), ("api", {"module": "Core"}), ("pins", {}), ("impact", {"target": "Thing"})):
            self.ask({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": name, "arguments": args}})
        self.assertEqual(tree_digest(self.ws), before)


if __name__ == "__main__":
    unittest.main()
