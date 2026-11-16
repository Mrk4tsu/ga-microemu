#!/usr/bin/env python3
"""Generate a small Xcode project without upstream mobile SDK integrations."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess

IOS = Path(__file__).resolve().parents[1]


def _relative_source(path):
    """Return a POSIX path relative to IOS when possible for XcodeGen."""
    try:
        return Path(os.path.relpath(path, IOS)).as_posix()
    except ValueError:
        return str(path)


def generate(runtime, spec_only=False):
    core = runtime / "minijvm/c"
    paths = list((IOS / "App").glob("*.m")) + list((IOS / "native").glob("*.c"))
    for directory in ("jvm", "utils", "utils/https", "utils/https/mbedtls/library"):
        paths.extend((core / directory).glob("*.c"))
    paths += [core / "utils/mimalloc/src/static.c"]
    includes = [IOS / "native", IOS / "App", core / "jvm", core / "utils", core / "utils/sljit",
                core / "utils/https", core / "utils/https/mbedtls/include", core / "utils/mimalloc/include",
                runtime / "mobile/c/gui/stb"]
    spec = {
        "name": "MicroEmu", "options": {"deploymentTarget": {"iOS": "12.0"}, "createIntermediateGroups": True},
        "settings": {
            "base": {
                "PRODUCT_BUNDLE_IDENTIFIER": "com.gamod.microemu", "CODE_SIGNING_ALLOWED": "NO",
                "CODE_SIGNING_REQUIRED": "NO", "CLANG_ENABLE_OBJC_ARC": "YES", "GCC_C_LANGUAGE_STANDARD": "gnu11",
                "HEADER_SEARCH_PATHS": ["$(inherited)", *[str(p) for p in includes]],
                "TARGETED_DEVICE_FAMILY": "1,2", "ENABLE_BITCODE": "NO", "GENERATE_INFOPLIST_FILE": "NO",
                "INFOPLIST_FILE": "App/Info.plist", "IPHONEOS_DEPLOYMENT_TARGET": "12.0",
                "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
            },
            "configs": {
                "Release": {
                    "DEPLOYMENT_POSTPROCESSING": "YES",
                    "STRIP_INSTALLED_PRODUCT": "YES",
                    "STRIP_STYLE": "all",
                    "COPY_PHASE_STRIP": "YES",
                    "DEAD_CODE_STRIPPING": "YES",
                    "GCC_SYMBOLS_PRIVATE_EXTERN": "YES",
                    "GCC_GENERATE_DEBUGGING_SYMBOLS": "NO",
                    "ENABLE_NS_ASSERTIONS": "NO",
                }
            },
        },
        "targets": {"MicroEmu": {"type": "application", "platform": "iOS",
            "sources": [{"path": _relative_source(p)} for p in sorted(paths)] + [
                {"path": _relative_source(IOS / "App/Assets.xcassets")},
                {"path": _relative_source(IOS / "Runtime"), "buildPhase": "resources", "type": "folder"}],
            "dependencies": [{"sdk": name + ".framework"} for name in
                ("UIKit", "Foundation", "CoreGraphics", "CoreText", "QuartzCore", "AudioToolbox", "AVFoundation", "MediaPlayer", "UserNotifications", "Security")],
            "scheme": {"gatherCoverageData": False}}},
    }
    # Use Runtime (not Resources) at the .app root so iOS CFBundle does not
    # treat the shallow app bundle as a legacy Version-1 bundle layout.
    licenses = IOS / "Runtime/ThirdParty"
    licenses.mkdir(parents=True, exist_ok=True)
    for source, target in [(runtime / "LICENSE", "miniJVM-MIT.txt"),
                            (runtime / "minijvm/java/LICENSE", "Runtime-GPL2.txt"),
                            (runtime / "minijvm/java/CLASSPATH_EXCEPTION", "Classpath-Exception.txt"),
                            (IOS.parent / "microemulator/COPYING-AL-2.0", "MicroEmulator-Apache2.txt")]:
        shutil.copyfile(source, licenses / target)
    # This pinned checkout vendors dependency source without standalone LICENSE
    # files. Preserve its source notices and include the applicable full texts.
    mit = (runtime / "LICENSE").read_text(encoding="utf-8")
    (licenses / "mimalloc-MIT.txt").write_text(
        "Copyright (c) 2018-2026, Microsoft Research, Daan Leijen\n\n" + mit, encoding="utf-8")
    import re
    notices = []
    for path in sorted((core / "utils").rglob("*")):
        if path.suffix in (".c", ".h"):
            text = path.read_text(encoding="utf-8", errors="replace")
            header = re.search(r"/\*.*?\*/", text, re.S)
            if header:
                notices.append(str(path.relative_to(runtime)) + "\n" + header.group(0))
    (licenses / "Native-dependency-notices.txt").write_text("\n\n".join(notices), encoding="utf-8")
    # STB's dual-license notice is in the source headers; distribute them intact.
    shutil.copyfile(runtime / "mobile/c/gui/stb/stb_image.h", licenses / "stb_image-notice-and-source.txt")
    shutil.copyfile(core / "utils/tinycthread.h", licenses / "tinycthread-notice-and-source.txt")
    spec_path = IOS / "build/project.json"
    spec_path.parent.mkdir(parents=True, exist_ok=True)
    spec_path.write_text(json.dumps(spec, indent=2), encoding="utf-8")
    if not spec_only:
        subprocess.run(
            ["xcodegen", "generate", "--spec", str(spec_path), "--project", str(IOS), "--project-root", str(IOS)],
            check=True,
            cwd=IOS,
        )
    print(spec_path)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path, default=IOS / ".deps/miniJVM")
    parser.add_argument("--spec-only", action="store_true")
    args = parser.parse_args()
    generate(args.runtime.resolve(), args.spec_only)
