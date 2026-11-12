#!/usr/bin/env python3
"""Build the bootstrap library and the MicroEmulator iOS Java layer."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import zipfile

IOS = Path(__file__).resolve().parents[1]
REPO = IOS.parent


def compile_jar(javac, sources, classes, output, boot=None, resources=()):
    # Only remove this builder's verified output directories.
    classes.resolve().relative_to((IOS / "build/java").resolve())
    if classes.exists():
        shutil.rmtree(classes)
    classes.mkdir(parents=True, exist_ok=True)
    args = ["-encoding", "UTF-8", "-source", "8", "-target", "8", "-Xlint:-options", "-d", str(classes)]
    if boot:
        args += ["-bootclasspath", str(boot)]
    # Quote every path in the javac argument file, also on Windows.
    argfile = classes.parent / (classes.name + "-sources.txt")
    argfile.write_text("\n".join('"' + str(s).replace("\\", "/") + '"' for s in sources), encoding="utf-8")
    subprocess.run([javac, *args, "@" + str(argfile)], check=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as jar:
        for file in sorted(classes.rglob("*.class")):
            jar.write(file, file.relative_to(classes).as_posix())
        for root in resources:
            if root.exists():
                for file in sorted(root.rglob("*")):
                    if file.is_file():
                        jar.write(file, file.relative_to(root).as_posix())


def build(runtime, javac="javac", runtime_only=False, skip_runtime=False):
    build_dir = IOS / "build/java"
    resources = IOS / "Resources"
    runtime_main = runtime / "minijvm/java/src/main"
    rtjar = resources / "minijvm_rt.jar"
    if not skip_runtime:
        compile_jar(javac, sorted((runtime_main / "java").rglob("*.java")),
                    build_dir / "runtime", rtjar, resources=[runtime_main / "resource"])
    if runtime_only:
        return
    sources = []
    for module in ("microemu-cldc", "microemu-midp"):
        sources.extend(sorted((REPO / "microemulator" / module / "src/main/java").rglob("*.java")))
    # miniJVM already owns the CLDC connection API and its native protocols.
    # Do not ship a second javax.microedition.io.Connector implementation.
    sources = [s for s in sources if not (runtime_main / "java" / s.relative_to(
        REPO / "microemulator" / ("microemu-cldc" if "microemu-cldc" in s.parts else "microemu-midp") / "src/main/java")).exists()]
    # miniJVM's CLDC Calendar has set/get, but no Calendar.add. Preserve
    # DateField's calendar-day arithmetic in a generated source overlay.
    date_field = REPO / "microemulator/microemu-midp/src/main/java/javax/microedition/lcdui/DateField.java"
    import re
    adapted, count = re.subn(r"cal\.add\(Calendar.DAY_OF_MONTH, (\d+)\)",
        r"cal.set(Calendar.DAY_OF_MONTH, cal.get(Calendar.DAY_OF_MONTH) + \1)",
        date_field.read_text(encoding="utf-8"))
    if count != 4:
        raise RuntimeError("DateField compatibility overlay no longer matches")
    overlay = build_dir / "generated/DateField.java"
    overlay.parent.mkdir(parents=True, exist_ok=True)
    overlay.write_text(adapted, encoding="utf-8")
    sources[sources.index(date_field)] = overlay
    sources.extend(sorted((IOS / "java").rglob("*.java")))
    compile_jar(javac, sources, build_dir / "emulator", resources / "microemu-ios.jar", rtjar)
    print("Built", rtjar, "and", resources / "microemu-ios.jar")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path, default=IOS / ".deps/miniJVM")
    parser.add_argument("--javac", default="javac")
    parser.add_argument("--runtime-only", action="store_true")
    parser.add_argument("--skip-runtime", action="store_true")
    args = parser.parse_args()
    build(args.runtime.resolve(), args.javac, args.runtime_only, args.skip_runtime)
