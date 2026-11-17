"""Verify XcodeGen spec paths and CLI root match the ios directory."""
import importlib.util
import json
import plistlib
from pathlib import Path
import tempfile
import unittest
from unittest import mock

module_spec = importlib.util.spec_from_file_location(
    "generate_project", Path(__file__).resolve().parents[1] / "tools/generate_project.py"
)
gen = importlib.util.module_from_spec(module_spec)
module_spec.loader.exec_module(gen)


class GenerateProjectTests(unittest.TestCase):
    def _create_fixture(self, root):
        ios = root / "ios"
        for rel in ("App/MicroEmuApp.m", "App/BackgroundRunController.m", "App/BackgroundStatusController.m", "native/bridge.c"):
            target = ios / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("", encoding="utf-8")
        (ios / "App/Assets.xcassets").mkdir(parents=True, exist_ok=True)
        (ios / "Runtime").mkdir(parents=True, exist_ok=True)
        (root / "microemulator").mkdir(parents=True, exist_ok=True)
        (root / "microemulator/COPYING-AL-2.0").write_text("Apache-2.0", encoding="utf-8")

        runtime = root / "miniJVM"
        for rel in (
            "LICENSE",
            "minijvm/java/LICENSE",
            "minijvm/java/CLASSPATH_EXCEPTION",
            "minijvm/c/jvm/vm.c",
            "minijvm/c/utils/utf8.c",
            "minijvm/c/utils/https/http.c",
            "minijvm/c/utils/https/mbedtls/library/aes.c",
            "minijvm/c/utils/mimalloc/src/static.c",
            "minijvm/c/utils/tinycthread.h",
            "mobile/c/gui/stb/stb_image.h",
        ):
            target = runtime / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("/* notice */", encoding="utf-8")
        return ios, runtime

    def test_xcodegen_uses_ios_as_project_root_and_relative_sources(self):
        with tempfile.TemporaryDirectory() as temp:
            ios, runtime = self._create_fixture(Path(temp))
            with mock.patch.object(gen, "IOS", ios), mock.patch.object(gen.subprocess, "run") as run_mock:
                gen.generate(runtime, spec_only=False)

            spec = json.loads((ios / "build/project.json").read_text(encoding="utf-8"))
            self.assertEqual(spec["options"]["deploymentTarget"]["iOS"], "12.0")
            self.assertEqual(spec["settings"]["base"]["IPHONEOS_DEPLOYMENT_TARGET"], "12.0")
            self.assertEqual(spec["settings"]["base"]["ASSETCATALOG_COMPILER_APPICON_NAME"], "AppIcon")
            release = spec["settings"]["configs"]["Release"]
            self.assertEqual(release["STRIP_INSTALLED_PRODUCT"], "YES")
            self.assertEqual(release["DEPLOYMENT_POSTPROCESSING"], "YES")
            self.assertEqual(release["GCC_SYMBOLS_PRIVATE_EXTERN"], "YES")
            app = spec["targets"]["MicroEmu"]
            deps = [d["sdk"] for d in app["dependencies"] if "sdk" in d]
            self.assertNotIn("UniformTypeIdentifiers.framework", deps)
            self.assertIn("AVFoundation.framework", deps)
            self.assertIn("MediaPlayer.framework", deps)
            self.assertIn("UserNotifications.framework", deps)
            sources = spec["targets"]["MicroEmu"]["sources"]
            self.assertIn({"path": "App/Assets.xcassets"}, sources)
            self.assertIn({"path": "Runtime", "buildPhase": "resources", "type": "folder"}, sources)
            self.assertIn({"path": "App/MicroEmuApp.m"}, sources)
            self.assertIn({"path": "App/BackgroundRunController.m"}, sources)
            self.assertIn({"path": "App/BackgroundStatusController.m"}, sources)
            self.assertIn({"path": "native/bridge.c"}, sources)

            run_mock.assert_called_once()
            cmd = run_mock.call_args[0][0]
            self.assertEqual(cmd[cmd.index("--project") + 1], str(ios))
            self.assertEqual(cmd[cmd.index("--project-root") + 1], str(ios))

            # The iOS 12 host must not link/load Swift or ActivityKit at startup.
            self.assertNotIn("ActivityKit.framework", deps)
            self.assertFalse(any(s["path"].endswith(".swift") for s in app["sources"]))
            self.assertIn({"target": "GaEmulatorLiveBridge", "embed": True, "link": False, "codeSign": False}, app["dependencies"])
            self.assertIn({"target": "GaEmulatorStatus", "embed": True, "link": False, "codeSign": False}, app["dependencies"])
            self.assertEqual(spec["settings"]["base"]["ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES"], "YES")
            for name in ("GaEmulatorLiveBridge", "GaEmulatorStatus"):
                target = spec["targets"][name]
                self.assertEqual(target["deploymentTarget"], "16.1")
                self.assertEqual(target["settings"]["base"]["IPHONEOS_DEPLOYMENT_TARGET"], "16.1")
                self.assertIn({"path": "LiveActivity/Shared/GaEmulatorActivityAttributes.swift"}, target["sources"])
            widget = spec["targets"]["GaEmulatorStatus"]
            self.assertEqual(widget["type"], "app-extension")
            self.assertEqual(widget["settings"]["base"]["APPLICATION_EXTENSION_API_ONLY"], "YES")

    def test_release_stripping_preserves_dynamic_framework_symbols(self):
        with tempfile.TemporaryDirectory() as temp:
            ios, runtime = self._create_fixture(Path(temp))
            with mock.patch.object(gen, "IOS", ios):
                gen.generate(runtime, spec_only=True)
            spec = json.loads((ios / "build/project.json").read_text(encoding="utf-8"))

        # The bridge is a dynamic library. Applying the app's "all" policy to
        # it fails in Apple's strip tool on imported Swift/ActivityKit symbols.
        project_release = spec["settings"]["configs"]["Release"]
        self.assertNotIn("STRIP_STYLE", project_release)
        for name, style in (("MicroEmu", "all"), ("GaEmulatorLiveBridge", "debugging"),
                            ("GaEmulatorStatus", "non-global")):
            with self.subTest(target=name):
                target_settings = spec["targets"][name].get("settings", {})
                effective = {**spec["settings"]["base"], **project_release,
                             **target_settings.get("base", {}),
                             **target_settings.get("configs", {}).get("Release", {})}
                self.assertEqual(effective["STRIP_STYLE"], style)
                self.assertEqual(effective["STRIP_INSTALLED_PRODUCT"], "YES")
                self.assertEqual(effective["DEPLOYMENT_POSTPROCESSING"], "YES")

    def test_background_audio_declared_in_shipped_plist(self):
        with (gen.IOS / "App/Info.plist").open("rb") as source:
            info = plistlib.load(source)
        self.assertIn("audio", info["UIBackgroundModes"])
        self.assertNotIn("NSMicrophoneUsageDescription", info)
        self.assertTrue(info["NSSupportsLiveActivities"])

    def test_live_activity_bundle_metadata_matches_host(self):
        host = plistlib.loads((gen.IOS / "App/Info.plist").read_bytes())
        widget = plistlib.loads((gen.IOS / "LiveActivity/Widget/Info.plist").read_bytes())
        bridge = plistlib.loads((gen.IOS / "LiveActivity/Bridge/Info.plist").read_bytes())
        self.assertEqual(widget["NSExtension"]["NSExtensionPointIdentifier"], "com.apple.widgetkit-extension")
        for info in (widget, bridge):
            self.assertEqual(info["CFBundleVersion"], host["CFBundleVersion"])
            self.assertEqual(info["CFBundleShortVersionString"], host["CFBundleShortVersionString"])


if __name__ == "__main__":
    unittest.main()
