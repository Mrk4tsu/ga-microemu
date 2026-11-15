#!/usr/bin/env python3
"""Regress reflection and cancellation through hostile MIDlets on the interpreter."""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import time
import zipfile

IOS = Path(__file__).resolve().parents[1]
CASES = ("reflection", "constructor", "clinit", "start", "destroy", "cpu", "wait", "thread", "flood", "queue", "nested", "nested-route", "exit", "failure", "resources", "paint-stop")


def main(executable, javac, selected=None):
    with tempfile.TemporaryDirectory(prefix="microemu-session-") as temp:
        root = Path(temp)
        classes = root / "classes"
        classes.mkdir()
        runtime = IOS / "Runtime"
        subprocess.run([javac, "-source", "8", "-target", "8", "-encoding", "UTF-8",
                        "-bootclasspath", str(runtime / "minijvm_rt.jar"),
                        "-cp", str(runtime / "microemu-ios.jar"), "-d", str(classes),
                        *map(str, sorted((IOS / "tests/java/session").glob("*.java")))], check=True)
        # Compare reflection semantics with the installed Java VM as well.
        subprocess.run([str(Path(javac).with_name("java.exe" if os.name == "nt" else "java")),
                        "-cp", str(classes), "session.ReflectionChecks"], check=True)
        for mode in (selected,) if selected else CASES:
            game = root / (mode + ".jar")
            with zipfile.ZipFile(game, "w", zipfile.ZIP_DEFLATED) as jar:
                for file in classes.rglob("*.class"):
                    jar.write(file, file.relative_to(classes).as_posix())
                jar.writestr("META-INF/MANIFEST.MF", "Manifest-Version: 1.0\r\nMIDlet-Name: SessionTest\r\n"
                    "MIDlet-Vendor: MicroEmu\r\nMIDlet-1: Session,,session." +
                    ({"clinit": "StaticBlockMIDlet", "nested-route": "NestedRoutingMIDlet"}.get(mode, "SessionMIDlet")) + "\r\nTest-Mode: " + mode + "\r\n\r\n")
            events = root / "events.txt"
            events.write_text("", encoding="utf-8")
            control = root / "control.txt"
            control.write_text("", encoding="utf-8")
            env = os.environ.copy()
            env.update(MICROEMU_HOST_MODE="1", MICROEMU_ALLOW_NO_FRAME="1", MICROEMU_CONTROL_FILE=str(control))
            if mode != "resources": env["MICROEMU_STOP_ON_STATUS"] = "1"
            if mode == "flood": env["MICROEMU_LONG_INPUT"] = "1"
            if mode == "queue": env["MICROEMU_QUEUE_FLOOD"] = "1"
            if mode == "nested-route": env["MICROEMU_NESTED_ROUTING"] = "1"
            repeats = 30 if mode in ("resources","paint-stop") else 1
            if repeats > 1: env["MICROEMU_SESSION_REPEATS"] = str(repeats)
            started = time.monotonic()
            try:
                result = subprocess.run([str(executable), str(runtime / "minijvm_rt.jar"),
                    str(runtime / "microemu-ios.jar"), str(game), str(root / (mode + "-rms")), "40" if repeats > 1 else "4",
                    str(root / "frame.png"), str(events)], env=env, capture_output=True,
                    text=True, encoding="utf-8", errors="replace", timeout=45 if repeats > 1 else 6)
            except subprocess.TimeoutExpired as error:
                for stream in (error.stdout, error.stderr):
                    text = stream.decode("utf-8", "replace") if isinstance(stream, bytes) else (stream or "")
                    print("\n".join(text.splitlines()[-50:]))
                raise SystemExit(mode + ": TIMEOUT (Stop blocked)") from error
            output = result.stdout + result.stderr
            elapsed = time.monotonic() - started
            if mode == "failure":
                if (not result.returncode or "state=FAILED" not in output or "[TAB_FINISHED tab=1 result=-1]" not in output
                    or "SESSION_BLOCK error-toString" in output or "[RESOURCES tab=1" not in output):
                    print(output); raise SystemExit("Failure callback escaped the worker")
                print("PASS: failure (overridden Throwable callbacks stay cancellable)")
                continue
            marker = {"reflection": "SESSION_REFLECTION_PASS", "nested": "SESSION_CONTEXT_PASS",
                      "constructor": "SESSION_BLOCK constructor", "start": "SESSION_BLOCK start",
                      "clinit": "SESSION_BLOCK clinit", "resources": "SESSION_RESOURCES_READY",
                      "exit": "SESSION_EXIT",
                      "queue": "SESSION_QUEUE_PASS",
                      "wait": "SESSION_BLOCK wait",
                      "nested-route": "SESSION_NESTED_ROUTING_PASS",
                      "cpu": "SESSION_BLOCK cpu", "destroy": "SESSION_BLOCK destroy",
                      "thread": "SESSION_BLOCK child-thread", "flood": "SESSION_TEXT_STARTED", "paint-stop":"SESSION_PAINT_STOP_READY"}[mode]
            if mode=="paint-stop" and output.count("[SESSION] first-frame")!=repeats:
                print(output);raise SystemExit("Rendering did not start for every Stop stress session")
            if (result.returncode or output.count(marker) != repeats or
                output.count("[TAB_FINISHED tab=1 result=0]") != repeats or
                (repeats == 1 and (elapsed > 6 or (mode != "exit" and "[STOP_REQUEST" not in output))) or
                (mode != "clinit" and hashlib.sha256(game.read_bytes()).hexdigest() not in output)):
                print(output)
                raise SystemExit(mode + ": FAIL, status=" + str(result.returncode))
            print("PASS: %s (%.2fs, %d sessions)" % (mode, elapsed, repeats))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--javac", default="javac")
    parser.add_argument("--case", choices=CASES)
    args = parser.parse_args()
    main(args.executable.resolve(), args.javac, args.case)
