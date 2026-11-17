"""Reject simulator payloads and preserve the executable bit for sideload signing."""
import importlib.util
from pathlib import Path
import plistlib
import stat
import struct
import sys
import tempfile
import unittest
import zipfile

TOOLS = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))
import runtime_crypto

module = importlib.util.spec_from_file_location("package_ipa", TOOLS / "package_ipa.py")
packaging = importlib.util.module_from_spec(module)
module.loader.exec_module(packaging)


class PackagingTests(unittest.TestCase):
    def live_bundles(self, app, widget_platform=2, bridge_platform=2, include_bridge=True):
        info = plistlib.loads((app / "Info.plist").read_bytes())
        info.update(NSSupportsLiveActivities=True, MinimumOSVersion="12.0")
        (app / "Info.plist").write_bytes(plistlib.dumps(info))
        for path, executable, platform in (
            ("PlugIns/GaEmulatorStatus.appex", "GaEmulatorStatus", widget_platform),
            ("Frameworks/GaEmulatorLiveBridge.framework", "GaEmulatorLiveBridge", bridge_platform),
        ):
            if path.startswith("Frameworks/") and not include_bridge:
                continue
            bundle = app / path
            bundle.mkdir(parents=True)
            metadata = {"CFBundleExecutable": executable, "MinimumOSVersion": "16.1"}
            if path.startswith("PlugIns/"):
                metadata["NSExtension"] = {"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"}
            (bundle / "Info.plist").write_bytes(plistlib.dumps(metadata))
            header = struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 6 if path.startswith("Frameworks/") else 2, 1, 24, 0, 0)
            command = struct.pack("<6I", 0x32, 24, platform, 0x100100, 0x120000, 0)
            (bundle / executable).write_bytes(header + command)

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
            (app / "Runtime").mkdir()
            (app / "Runtime/minijvm_rt.jar").write_bytes(b"jar")
            packaging.package(app, root / "app.ipa")
            with zipfile.ZipFile(root / "app.ipa") as archive:
                binary = archive.getinfo("Payload/MicroEmu.app/MicroEmu")
                self.assertTrue(binary.external_attr >> 16 & stat.S_IXUSR)
                self.assertIn("Payload/", archive.namelist())
                self.assertIn("Payload/MicroEmu.app/", archive.namelist())
                self.assertIn("Payload/MicroEmu.app/Runtime/", archive.namelist())
                self.assertTrue(stat.S_ISDIR(archive.getinfo("Payload/").external_attr >> 16))
                self.assertIn("Payload/MicroEmu.app/Info.plist", archive.namelist())
                rt_blob = archive.read("Payload/MicroEmu.app/Runtime/minijvm_rt.jar")
                self.assertTrue(rt_blob.startswith(runtime_crypto.MAGIC))
                self.assertEqual(runtime_crypto.decrypt_blob(rt_blob), b"jar")

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

    def test_live_activity_embeds_executables_and_keeps_host_minimum(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            app = self.fixture(root)
            self.live_bundles(app)
            dylib = app / "Frameworks/libswift_Concurrency.dylib"
            dylib.write_bytes((app / "MicroEmu").read_bytes())
            packaging.package(app, root / "live.ipa")
            with zipfile.ZipFile(root / "live.ipa") as archive:
                for rel in ("MicroEmu", "PlugIns/GaEmulatorStatus.appex/GaEmulatorStatus",
                            "Frameworks/GaEmulatorLiveBridge.framework/GaEmulatorLiveBridge",
                            "Frameworks/libswift_Concurrency.dylib"):
                    self.assertTrue(archive.getinfo("Payload/MicroEmu.app/" + rel).external_attr >> 16 & stat.S_IXUSR)
                for rel, minimum in (("Info.plist", "12.0"), ("PlugIns/GaEmulatorStatus.appex/Info.plist", "16.1")):
                    content = archive.read("Payload/MicroEmu.app/" + rel)
                    self.assertEqual(plistlib.loads(content)["MinimumOSVersion"], minimum)
                    self.assertFalse(archive.getinfo("Payload/MicroEmu.app/" + rel).external_attr >> 16 & stat.S_IXUSR)

    def test_live_activity_missing_extension_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            app = self.fixture(root)
            (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "MicroEmu", "NSSupportsLiveActivities": True}))
            with self.assertRaisesRegex(ValueError, "extension is missing"):
                packaging.package(app, root / "missing.ipa")

    def test_live_activity_missing_bridge_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            app = self.fixture(root)
            self.live_bundles(app, include_bridge=False)
            with self.assertRaisesRegex(ValueError, "bridge framework is missing"):
                packaging.package(app, root / "missing.ipa")

    def test_embedded_simulator_extension_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            app = self.fixture(root)
            self.live_bundles(app, widget_platform=7)
            with self.assertRaisesRegex(ValueError, "iphoneos"):
                packaging.package(app, root / "wrong.ipa")

    def test_embedded_simulator_framework_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            app = self.fixture(root)
            self.live_bundles(app, bridge_platform=7)
            with self.assertRaisesRegex(ValueError, "iphoneos"):
                packaging.package(app, root / "wrong.ipa")

    def test_host_cannot_eagerly_link_new_ios_runtime(self):
        for dependency in ("@rpath/GaEmulatorLiveBridge.framework/GaEmulatorLiveBridge",
                           "/System/Library/Frameworks/ActivityKit.framework/ActivityKit",
                           "@rpath/libswift_Concurrency.dylib"):
            with self.subTest(dependency=dependency), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                app = self.fixture(root)
                self.live_bundles(app)
                binary = (app / "MicroEmu").read_bytes()
                name = dependency.encode() + b"\0"
                length = (24 + len(name) + 7) // 8 * 8
                command = struct.pack("<6I", 0xC, length, 24, 0, 0, 0) + name
                command += b"\0" * (length - len(command))
                header = bytearray(binary[:32])
                struct.pack_into("<II", header, 16, 2, 24 + length)
                (app / "MicroEmu").write_bytes(header + binary[32:] + command)
                with self.assertRaisesRegex(ValueError, "conditionally"):
                    packaging.package(app, root / "wrong.ipa")


if __name__ == "__main__":
    unittest.main()
