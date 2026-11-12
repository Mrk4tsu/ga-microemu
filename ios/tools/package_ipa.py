#!/usr/bin/env python3
"""Package an unsigned iphoneos .app for signing with Sideloadly."""
import argparse
from pathlib import Path
import plistlib
import stat
import struct
import zipfile


def package(app, output):
    info = plistlib.loads((app / "Info.plist").read_bytes())
    binary = app / info["CFBundleExecutable"]
    header = binary.read_bytes()[:32]
    if len(header) < 32 or struct.unpack_from("<II", header) != (0xFEEDFACF, 0x0100000C):
        raise ValueError("Expected a 64-bit ARM device executable")
    # LC_BUILD_VERSION platform=2 is iphoneos; platform=7 is the simulator.
    commands, size = struct.unpack_from("<II", header, 16)
    data = binary.read_bytes()[32:32 + size]
    offset, device = 0, False
    for _ in range(commands):
        command, length = struct.unpack_from("<II", data, offset)
        if command == 0x32:
            device = struct.unpack_from("<I", data, offset + 8)[0] == 2
        elif command == 0x25:  # LC_VERSION_MIN_IPHONEOS
            device = True
        offset += length
    if not device:
        raise ValueError("IPA requires an iphoneos build, not a Simulator app")
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        for file in sorted(app.rglob("*")):
            if not file.is_file():
                continue
            name = "Payload/" + app.name + "/" + file.relative_to(app).as_posix()
            entry = zipfile.ZipInfo.from_file(file, name)
            if file == binary:
                entry.external_attr = (stat.S_IFREG | 0o755) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry, file.read_bytes())
    print(output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    package(args.app.resolve(), args.output.resolve())
