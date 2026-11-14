#!/usr/bin/env python3
"""Drive raster Form/Items, native TextField input and List focus/commands."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import zipfile

IOS = Path(__file__).resolve().parents[1]


def main(executable, javac):
    with tempfile.TemporaryDirectory(prefix="microemu-ui-") as temp:
        root = Path(temp)
        classes = root / "classes"
        classes.mkdir()
        rt = IOS / "Runtime"
        subprocess.run([javac, "-source", "8", "-target", "8", "-encoding", "UTF-8",
            "-bootclasspath", str(rt / "minijvm_rt.jar"), "-cp", str(rt / "microemu-ios.jar"),
            "-d", str(classes), str(IOS / "tests/java/session/UIAdaptersMIDlet.java")], check=True)
        game = root / "ui.jar"
        with zipfile.ZipFile(game, "w") as jar:
            for file in classes.rglob("*.class"): jar.write(file, file.relative_to(classes).as_posix())
            jar.writestr("META-INF/MANIFEST.MF", "MIDlet-Name: UIAdapters\r\nMIDlet-Vendor: MicroEmu\r\nMIDlet-1: UI,,session.UIAdaptersMIDlet\r\n")
        events = root / "events.txt"
        events.write_text("250 13 -5 0\n750 13 -6 0\n1100 13 -2 0\n1400 13 -5 0\n", encoding="utf-8")
        env = os.environ.copy()
        env.update(MICROEMU_HOST_MODE="1", MICROEMU_TEST_TEXT_INPUT="1", MICROEMU_SCHEDULE_ON_STATUS="1")
        result = subprocess.run([str(executable), str(rt / "minijvm_rt.jar"), str(rt / "microemu-ios.jar"),
            str(game), str(root / "rms"), "8", str(root / "frame.png"), str(events)],
            env=env, input="adapter text\n", capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=10)
        if result.returncode or not all(tag in result.stdout for tag in ("UI_FIELD_PASS", "UI_LIST_READY", "UI_CUSTOM_PAINT", "UI_ADAPTERS_PASS")):
            print(result.stdout); print(result.stderr)
            raise SystemExit("UI adapter regression")
        print("PASS: Form/Items/Gauge/ChoiceGroup + native TextField commit + List focus/commands")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--javac", default="javac")
    args = parser.parse_args()
    main(args.executable.resolve(), args.javac)
