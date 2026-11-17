#!/usr/bin/env python3
"""Package an unsigned iphoneos .app for signing with Sideloadly."""
import argparse
from pathlib import Path
import plistlib
import stat
import struct
import sys
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from runtime_crypto import encrypt_blob

ENCRYPTED_RUNTIME_FILES = frozenset({"Runtime/minijvm_rt.jar", "Runtime/microemu-ios.jar"})


def device_executable(bundle):
    info = plistlib.loads((bundle / "Info.plist").read_bytes())
    binary = bundle / info["CFBundleExecutable"]
    with binary.open("rb") as source:
        header = source.read(32)
        data = source.read(struct.unpack_from("<I", header, 20)[0]) if len(header) == 32 else b""
    if len(header) < 32 or struct.unpack_from("<II", header) != (0xFEEDFACF, 0x0100000C):
        raise ValueError("Expected a 64-bit ARM device executable")
    # LC_BUILD_VERSION platform=2 is iphoneos; platform=7 is the simulator.
    commands, size = struct.unpack_from("<II", header, 16)
    offset, device = 0, False
    for _ in range(commands):
        if offset + 8 > len(data):
            raise ValueError("Truncated Mach-O load commands")
        command, length = struct.unpack_from("<II", data, offset)
        if length < 8 or offset + length > len(data):
            raise ValueError("Invalid Mach-O load command size")
        if command == 0x32:
            device = struct.unpack_from("<I", data, offset + 8)[0] == 2
        elif command == 0x25:  # LC_VERSION_MIN_IPHONEOS
            device = True
        elif command == 0xC and info.get("NSSupportsLiveActivities") and length >= 24:  # LC_LOAD_DYLIB
            name_offset = struct.unpack_from("<I", data, offset + 8)[0]
            dependency = data[offset + name_offset:offset + length].split(b"\0", 1)[0]
            if any(name in dependency for name in (b"GaEmulatorLiveBridge.framework/", b"ActivityKit.framework/", b"libswift_Concurrency")):
                raise ValueError("Live Activity frameworks must be loaded conditionally to support iOS 12")
        offset += length
    if not device:
        raise ValueError("IPA requires an iphoneos build, not a Simulator app")
    return binary, info


def package(app, output):
    binary, info = device_executable(app)
    executables = {binary}
    has_widget = False
    for bundle in sorted([*app.rglob("*.appex"), *app.rglob("*.framework")]):
        executable, bundle_info = device_executable(bundle)
        executables.add(executable)
        if bundle_info.get("NSExtension", {}).get("NSExtensionPointIdentifier") == "com.apple.widgetkit-extension":
            has_widget = True
    if info.get("NSSupportsLiveActivities"):
        if not has_widget:
            raise ValueError("Live Activity extension is missing from PlugIns")
        if app / "Frameworks/GaEmulatorLiveBridge.framework/GaEmulatorLiveBridge" not in executables:
            raise ValueError("Live Activity bridge framework is missing")
    output.parent.mkdir(parents=True, exist_ok=True)

    def _dir_entry(name):
        entry = zipfile.ZipInfo(name if name.endswith("/") else name + "/")
        entry.create_system = 3
        entry.external_attr = ((stat.S_IFDIR | 0o755) << 16) | 0x10
        entry.compress_type = zipfile.ZIP_STORED
        return entry

    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(_dir_entry("Payload/"), b"")
        archive.writestr(_dir_entry("Payload/" + app.name + "/"), b"")
        for item in sorted(app.rglob("*")):
            rel = item.relative_to(app).as_posix()
            name = "Payload/" + app.name + "/" + rel
            if item.is_dir():
                archive.writestr(_dir_entry(name), b"")
                continue
            if not item.is_file():
                continue
            entry = zipfile.ZipInfo.from_file(item, name)
            entry.create_system = 3
            entry.compress_type = zipfile.ZIP_DEFLATED
            payload = item.read_bytes()
            # Preserve executables for nested app extensions/frameworks and Swift
            # runtime dylibs too. Marking only the main binary breaks sideloading.
            macho = payload[:4] in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca")
            executable = item in executables or (rel.startswith("Frameworks/") and macho)
            entry.external_attr = (stat.S_IFREG | (0o755 if executable else 0o644)) << 16
            if rel in ENCRYPTED_RUNTIME_FILES:
                payload = encrypt_blob(payload)
            archive.writestr(entry, payload)
    print(output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    package(args.app.resolve(), args.output.resolve())
