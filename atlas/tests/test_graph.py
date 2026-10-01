"""ATLAS-04: Graphify builds are local-only, exclude sensitive classes and keep provenance."""
import json
import unittest
from unittest import mock

import support  # noqa: F401  (puts tools/ on sys.path)
import graph  # noqa: E402
from support import AtlasCase, commit, make_repo, meta, tree_digest, write_registry

CAN_BUILD = not graph.local_only_problems()


class Exclusions(unittest.TestCase):
    def test_classes(self):
        cases = {
            "ios/App/Signing.mobileprovision": "credentials", "Apps/Android/.env": "credentials",
            "ios/App/Frameio.local.xcconfig": "credentials", "Apps/Android/app/build/out.so": "build-products",
            "handbook/node_modules/x/index.js": "build-products", "fixtures/capture.pcapng": "binary-captures",
            "Resources/Look.cube": "binary-captures", "reference/sdk/header.h": "vendor-reference-copies",
            "Sources/Core/Thing.swift": None, "Sources/Core/CredentialStore.swift": None,
        }
        for path, cls in cases.items():
            self.assertEqual(graph.excluded_class(path), cls, path)


class Build(AtlasCase):
    def setUp(self):
        super().setUp()
        self.repo = self.ws / "App"
        self.sha = make_repo(self.repo, {
            "Sources/App/A.swift": "struct A { func f() { B().g() } }\nstruct B { func g() {} }\n",
            "Sources/App/K.kt": "class K { fun x() = 1 }\n",
            "Apps/Android/.env": "TOKEN=not-a-real-token\n",
            "Apps/Android/app/build/libx.so": "binary",
            "fixtures/frame.h265": "binary",
        })
        self.write(self.sha)

    def write(self, *shas, names=("main", "feature")):
        refs = [{"name": n, "commit": s, "role": "baseline" if i == 0 else "candidate"} for i, (n, s) in enumerate(zip(names, shas))]
        write_registry(self.root, [meta("app", "app", "App", refs=refs)])

    def test_refuses_when_local_only_cannot_be_verified(self):
        before = tree_digest(self.ws)
        with mock.patch.object(graph, "local_only_problems", return_value=["sandbox missing"]):
            code, out = self.run_atlas("graph", "build", "app", "--local-only")
            self.assertEqual(code, 1)
            self.assertIn("refused", out)
            code, out = self.run_atlas("graph", "plan")
            self.assertIn("REFUSED", out)
        self.assertEqual(tree_digest(self.ws), before)

    def test_build_requires_local_only_flag(self):
        self.assertEqual(self.run_atlas("graph", "build", "app")[0], 2)

    @unittest.skipUnless(CAN_BUILD, "pinned graphify and sandbox-exec are not both available")
    def test_build_provenance_exclusions_labels_and_namespacing(self):
        checkout_before = tree_digest(self.repo)
        code, out = self.run_atlas("graph", "build", "app@main", "--local-only")
        self.assertEqual(code, 0, out)
        self.assertEqual(tree_digest(self.repo), checkout_before, "the source checkout must not change")
        snap_dir = self.root / "repos" / "app" / "snapshots" / self.sha
        snap = json.loads((snap_dir / "snapshot.json").read_text())
        self.assertEqual((snap["source_commit"], snap["dirty"], snap["scope"]), (self.sha, False, "baseline"))
        self.assertEqual(snap["coverage"]["excluded"], {"binary-captures": 1, "build-products": 1, "credentials": 1})
        self.assertGreaterEqual(snap["coverage"]["parsed"], 2)
        self.assertTrue((snap_dir / "GRAPH_REPORT.md").is_file())
        self.assertTrue((self.root / "graphify-out" / f"app@{self.sha[:12]}" / "graph" / "graph.json").is_file())
        self.assertNotIn("not-a-real-token", (snap_dir / "GRAPH_REPORT.md").read_text())

        labels_path = snap_dir / "graphify_labels.json"
        labels = json.loads(labels_path.read_text())
        first = sorted(labels)[0]
        labels[first] = "Edited by a maintainer"
        labels_path.write_text(json.dumps(labels))
        self.assertEqual(self.run_atlas("graph", "build", "app@main", "--local-only")[0], 0)
        self.assertEqual(json.loads(labels_path.read_text())[first], "Edited by a maintainer")

        second = commit(self.repo, {"Sources/App/C.swift": "struct C {}\n"}, "same-day change")
        self.write(self.sha, second)
        self.assertEqual(self.run_atlas("graph", "build", "app@feature", "--local-only")[0], 0)
        self.assertTrue((snap_dir / "snapshot.json").is_file(), "a second ref must not replace the first snapshot")
        self.assertTrue((self.root / "repos" / "app" / "snapshots" / second / "snapshot.json").is_file())

        code, out = self.run_atlas("graph", "merge")
        self.assertEqual(code, 0, out)
        inputs = json.loads((self.root / "graphify-out" / "merged-inputs.json").read_text())
        self.assertEqual(sorted(i["snapshot"] for i in inputs["inputs"]), sorted([f"app@{self.sha}", f"app@{second}"]))
        self.assertIn("does not discover cross-repo dependencies", inputs["note"])
        self.assertEqual(self.run_atlas("check")[0], 0)


if __name__ == "__main__":
    unittest.main()
