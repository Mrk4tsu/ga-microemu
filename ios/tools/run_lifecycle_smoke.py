#!/usr/bin/env python3
"""Exercise render locks, Stop with an idle TCP reader, and text input during GC."""
import argparse
import os
from pathlib import Path
import socketserver
import subprocess
import tempfile
import threading
import zipfile

IOS = Path(__file__).resolve().parents[1]

class IdleHandler(socketserver.BaseRequestHandler):
    def handle(self):
        self.server.release.wait(20)

def main(executable, javac, selected=None):
    with tempfile.TemporaryDirectory(prefix="microemu-lifecycle-") as temp:
        root = Path(temp)
        classes = root / "classes"
        classes.mkdir()
        runtime = IOS / "Runtime"
        fixtures = IOS / "tests/java/lifecycle"
        subprocess.run([javac, "-source", "8", "-target", "8", "-encoding", "UTF-8",
                        "-bootclasspath", str(runtime / "minijvm_rt.jar"),
                        "-cp", str(runtime / "microemu-ios.jar"), "-d", str(classes),
                        *[str(p) for p in sorted(fixtures.glob("*.java"))]], check=True)
        with socketserver.ThreadingTCPServer(("127.0.0.1", 0), IdleHandler) as server:
            server.daemon_threads = True
            server.release = threading.Event()
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                for name in ((selected,) if selected else ("RenderLockMIDlet", "SocketStopMIDlet", "InputPressureMIDlet", "TextBoxMIDlet", "TextBoxStop")):
                    game = root / (name + ".jar")
                    with zipfile.ZipFile(game, "w", zipfile.ZIP_DEFLATED) as jar:
                        for file in classes.rglob("*.class"):
                            jar.write(file, file.relative_to(classes).as_posix())
                        jar.writestr("META-INF/MANIFEST.MF",
                            "Manifest-Version: 1.0\r\nMIDlet-Name: " + name +
                            "\r\nMIDlet-Vendor: MicroEmu\r\nMIDlet-1: Test,,lifecycle." + ("TextBoxMIDlet" if name == "TextBoxStop" else name) +
                            ("\r\nTest-Stop: true" if name == "TextBoxStop" else "") +
                            "\r\nTest-Port: %d\r\n\r\n" % server.server_address[1])
                    args = [str(executable), str(runtime / "minijvm_rt.jar"), str(runtime / "microemu-ios.jar"),
                            str(game), str(root / ("rms-" + name)), "4", str(root / (name + ".png"))]
                    if name == "SocketStopMIDlet":
                        events = root / "stop.txt"
                        events.write_text("1200 10 0 0\n", encoding="utf-8")
                        args.append(str(events))
                    if name.startswith("TextBox"):
                        events = root / (name + "-events.txt")
                        events.write_text("1200 4 40 40\n1400 6 40 40\n" +
                                          ("2500 10 0 0\n" if name == "TextBoxStop" else ""), encoding="utf-8")
                        args.append(str(events))
                    environment = os.environ.copy()
                    if name == "SocketStopMIDlet":
                        environment["MICROEMU_ALLOW_NO_FRAME"] = "1"
                    elif name == "InputPressureMIDlet":
                        environment["MICROEMU_MULTI_TAB"] = "1"
                        environment["MICROEMU_INPUT_STRESS"] = "1"
                    if name.startswith("TextBox"):
                        environment["MICROEMU_HOST_MODE"] = "1"
                        if name == "TextBoxMIDlet": environment["MICROEMU_TEST_TEXT_INPUT"] = "1"
                    try:
                        result = subprocess.run(args, capture_output=True, text=True, encoding="utf-8",
                                                errors="replace", timeout=10, env=environment,
                                                input="inputtest\ntestpass\n" if name == "TextBoxMIDlet" else None)
                    except subprocess.TimeoutExpired as error:
                        print(name + ": TIMEOUT")
                        print(error.stdout.decode("utf-8", "replace") if isinstance(error.stdout, bytes) else (error.stdout or ""))
                        print(error.stderr.decode("utf-8", "replace") if isinstance(error.stderr, bytes) else (error.stderr or ""))
                        raise SystemExit("Lifecycle regression: blocked renderer or VM shutdown")
                    print(result.stdout)
                    print(result.stderr)
                    marker = {"RenderLockMIDlet": "RENDER_LOCK_PASS", "SocketStopMIDlet": "SOCKET_READER_READY", "InputPressureMIDlet": "INPUT_PRESSURE_PASS", "TextBoxMIDlet": "TEXTBOX_PASS", "TextBoxStop": "TEXTBOX_OPEN"}[name]
                    expected = 2 if name == "InputPressureMIDlet" else 1
                    if result.returncode or result.stdout.count(marker) != expected or "RENDER_LOCK_FAIL" in result.stdout or "INPUT_PRESSURE_FAIL" in result.stdout or "TEXTBOX_FAIL" in result.stdout:
                        raise SystemExit(name + " failed: status " + str(result.returncode))
                    print("PASS: " + name)
            finally:
                server.release.set()
                server.shutdown()

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--javac", default="javac")
    parser.add_argument("--case", choices=("RenderLockMIDlet", "SocketStopMIDlet", "InputPressureMIDlet", "TextBoxMIDlet", "TextBoxStop"))
    args = parser.parse_args()
    main(args.executable.resolve(), args.javac, args.case)
