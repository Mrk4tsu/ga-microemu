"""Verify XcodeGen spec paths and CLI root match the ios directory."""
import importlib.util
import json
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
        for rel in ("App/MicroEmuApp.m", "native/bridge.c"):
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
            deps = [d["sdk"] for d in spec["targets"]["MicroEmu"]["dependencies"]]
            self.assertNotIn("UniformTypeIdentifiers.framework", deps)
            sources = spec["targets"]["MicroEmu"]["sources"]
            self.assertIn({"path": "App/Assets.xcassets"}, sources)
            self.assertIn({"path": "Runtime", "buildPhase": "resources", "type": "folder"}, sources)
            self.assertIn({"path": "App/MicroEmuApp.m"}, sources)
            self.assertIn({"path": "native/bridge.c"}, sources)

            run_mock.assert_called_once()
            cmd = run_mock.call_args[0][0]
            self.assertEqual(cmd[cmd.index("--project") + 1], str(ios))
            self.assertEqual(cmd[cmd.index("--project-root") + 1], str(ios))


if __name__ == "__main__":
    unittest.main()
