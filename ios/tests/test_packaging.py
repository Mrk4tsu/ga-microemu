"""Reject simulator payloads and preserve the executable bit for sideload signing."""
import importlib.util
from pathlib import Path
import plistlib
import stat
import struct
import tempfile
import unittest
import zipfile

module = importlib.util.spec_from_file_location("package_ipa", Path(__file__).resolve().parents[1] / "tools/package_ipa.py")
packaging = importlib.util.module_from_spec(module)
module.loader.exec_module(packaging)


class PackagingTests(unittest.TestCase):
    def fixture(self, root, cpu=0x0100000C, platform=2):
        app = root / "MicroEmu.app"
        app.mkdir()
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "MicroEmu"}))
        header = struct.pack("<8I", 0xFEEDFACF, cpu, 0, 2, 1, 24, 0, 0)
        command = struct.pack("<6I", 0x32, 24, platform, 0xF0000, 0x120000, 0)
        (app / "MicroEmu").write_bytes(header + command)
        return app

    def test_device_payload_has_executable_permission(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            app = self.fixture(root)
            (app / "Resources").mkdir()
            (app / "Resources/minijvm_rt.jar").write_bytes(b"jar")
            packaging.package(app, root / "app.ipa")
            with zipfile.ZipFile(root / "app.ipa") as archive:
                binary = archive.getinfo("Payload/MicroEmu.app/MicroEmu")
                self.assertTrue(binary.external_attr >> 16 & stat.S_IXUSR)
                self.assertIn("Payload/", archive.namelist())
                self.assertIn("Payload/MicroEmu.app/", archive.namelist())
                self.assertIn("Payload/MicroEmu.app/Resources/", archive.namelist())
                self.assertTrue(stat.S_ISDIR(archive.getinfo("Payload/").external_attr >> 16))
                self.assertIn("Payload/MicroEmu.app/Info.plist", archive.namelist())

    def test_arm_simulator_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with self.assertRaisesRegex(ValueError, "iphoneos"):
                packaging.package(self.fixture(root, platform=7), root / "wrong.ipa")

    def test_intel_simulator_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with self.assertRaisesRegex(ValueError, "ARM"):
                packaging.package(self.fixture(root, cpu=0x01000007, platform=7), root / "wrong.ipa")


if __name__ == "__main__":
    unittest.main()
