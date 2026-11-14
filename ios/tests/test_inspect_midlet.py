import importlib.util
from pathlib import Path
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location("inspect_midlet", Path(__file__).resolve().parents[1] / "tools/inspect_midlet.py")
inspection = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inspection)


class ManifestInspectionTests(unittest.TestCase):
    def inspect_archive(self, entries):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.jar"
            with zipfile.ZipFile(path, "w") as jar:
                for name, content in entries.items():
                    jar.writestr(name, content)
            return inspection.inspect(path)

    def test_manifest_free_jar_remains_inspectable(self):
        report = self.inspect_archive({"icon.png": b"placeholder"})
        self.assertEqual({}, report["manifest"])
        self.assertIsNone(report["manifest_entry"])
        self.assertEqual(1, report["entry_count"])

    def test_manifest_paths_bom_and_folded_lines(self):
        report = self.inspect_archive({"meta-inf/manifest.mf":
            "\ufeffMIDlet-Name: Tiếng Việt\r\r\nMIDlet-1: Demo,,game.\r\r\n Main\r\r\n"})
        self.assertEqual("meta-inf/manifest.mf", report["manifest_entry"])
        self.assertEqual("Tiếng Việt", report["manifest"]["MIDlet-Name"])
        self.assertEqual("Demo,,game.Main", report["manifest"]["MIDlet-1"])

    def test_colon_does_not_require_a_space(self):
        report = self.inspect_archive({"MANIFEST.MF": "MIDlet-Name:Demo\nMIDlet-1:Demo,,game.Main\n"})
        self.assertEqual("Demo", report["manifest"]["MIDlet-Name"])


if __name__ == "__main__":
    unittest.main()
