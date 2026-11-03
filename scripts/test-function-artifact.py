"""Offline regressions for the deployment archive gate."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from zipfile import ZipFile, ZipInfo

spec = importlib.util.spec_from_file_location("artifact", Path(__file__).with_name("check-function-artifact.py"))
artifact = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artifact)


class ArtifactChecks(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.base = {"index.js": "before", "package.json": "{}", "scf_bootstrap": "#!/bin/sh\nnode index.js", "node_modules/dependency.js": "locked"}

    def archive(self, name, files):
        path = Path(self.directory.name) / name
        with ZipFile(path, "w") as archive:
            for key, value in files.items():
                entry = ZipInfo(key)
                entry.filename = key  # preserve hostile names even on Windows
                archive.writestr(entry, value)
        return path

    def compare(self, values, allowed=()):
        return artifact.compare(self.archive("before.zip", self.base), self.archive("after.zip", values), set(allowed))

    def test_reviewed_business_change_allowed(self):
        result = self.compare({**self.base, "index.js": "after"}, ["index.js"])
        self.assertTrue(result["ok"])
        self.assertNotIn("after", str(result))

    def test_unplanned_dependency_update_denied(self):
        result = self.compare({**self.base, "node_modules/dependency.js": "unexpected"})
        self.assertFalse(result["ok"])
        self.assertEqual(result["dependencyChanges"], ["node_modules/dependency.js"])

    def test_missing_bootstrap_denied_even_when_allowed(self):
        result = self.compare({k: v for k, v in self.base.items() if k != "scf_bootstrap"}, ["scf_bootstrap"])
        self.assertFalse(result["ok"])
        self.assertEqual(result["missingRuntimeFiles"], ["scf_bootstrap"])

    def test_unexpected_added_or_removed_file_denied(self):
        self.assertFalse(self.compare({**self.base, "debug.js": "extra"})["ok"])
        self.assertFalse(self.compare({k: v for k, v in self.base.items() if k != "node_modules/dependency.js"})["ok"])

    def test_safe_new_module_allowed(self):
        self.assertTrue(self.compare({**self.base, "scene.js": "module"}, ["scene.js"])["ok"])

    def test_traversal_paths_denied_without_extraction(self):
        for name in ["../escape.js", "/root.js", "C:/escape.js", "nested\\escape.js"]:
            with self.subTest(name=name), self.assertRaises(ValueError):
                artifact.inventory(self.archive("unsafe.zip", {name: "text"}))


if __name__ == "__main__":
    unittest.main()
