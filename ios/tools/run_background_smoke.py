#!/usr/bin/env python3
"""Test game/TCP progress and lifecycle transitions; does not emulate iOS audio or suspension."""
import argparse
import os
from pathlib import Path
import socketserver
import subprocess
import tempfile
import threading
import zipfile

IOS = Path(__file__).resolve().parents[1]


class EchoHandler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(12)
        try:
            while True:
                data = self.request.recv(1024)
                if not data:
                    break
                self.server.exchanges += len(data)
                self.request.sendall(data)
        except (OSError, TimeoutError):
            pass


def main(executable, javac):
    with tempfile.TemporaryDirectory(prefix="microemu-background-") as temp:
        root = Path(temp)
        classes = root / "classes"
        classes.mkdir()
        runtime = IOS / "Runtime"
        subprocess.run([javac, "-source", "8", "-target", "8", "-encoding", "UTF-8",
                        "-bootclasspath", str(runtime / "minijvm_rt.jar"),
                        "-cp", str(runtime / "microemu-ios.jar"), "-d", str(classes),
                        str(IOS / "tests/java/lifecycle/BackgroundMIDlet.java")], check=True)
        with socketserver.ThreadingTCPServer(("127.0.0.1", 0), EchoHandler) as server:
            server.daemon_threads = True
            server.exchanges = 0
            threading.Thread(target=server.serve_forever, daemon=True).start()
            try:
                game = root / "Background.jar"
                with zipfile.ZipFile(game, "w", zipfile.ZIP_DEFLATED) as jar:
                    for file in classes.rglob("*.class"):
                        jar.write(file, file.relative_to(classes).as_posix())
                    jar.writestr("META-INF/MANIFEST.MF",
                        "Manifest-Version: 1.0\r\nMIDlet-Name: Background\r\nMIDlet-Vendor: MicroEmu\r\n"
                        "MIDlet-1: Background,,lifecycle.BackgroundMIDlet\r\n"
                        "Test-Port: %d\r\n\r\n" % server.server_address[1])
                events = root / "events.txt"
                # Type 98 is a host-only adapter using the same policy as UIKit.
                events.write_text("200 98 1 1\n1700 13 97 0\n2800 98 0 1\n"
                                  "3400 13 98 0\n3900 98 1 0\n4200 98 1 0\n"
                                  "4600 98 1 1\n6100 13 99 0\n7200 98 1 0\n"
                                  "7700 98 0 0\n8300 13 100 0\n9400 10 0 0\n", encoding="utf-8")
                env = os.environ.copy()
                env.update(MICROEMU_HOST_MODE="1", MICROEMU_BACKGROUND_TEST="1", MICROEMU_SCHEDULE_ON_STATUS="1")
                result = subprocess.run([str(executable), str(runtime / "minijvm_rt.jar"),
                    str(runtime / "microemu-ios.jar"), str(game), str(root / "rms"), "14",
                    str(root / "frame.png"), str(events)], capture_output=True, text=True,
                    encoding="utf-8", errors="replace", timeout=20, env=env)
                print(result.stdout)
                print(result.stderr)
                output = result.stdout + result.stderr
                if (result.returncode or "BACKGROUND_FAIL" in output or
                        output.count("BACKGROUND_PASS") != 1 or
                        any(output.count("BACKGROUND_CHECK_" + key) != 1 for key in "abcd") or
                        output.find("BACKGROUND_CHECK_a") > output.find("hidden=0 audio=1") or
                        output.find("BACKGROUND_CHECK_c") > output.rfind("hidden=1 audio=0 sleeping=1 lifecycle=8") or
                        "[TAB_FINISHED tab=1 result=0]" not in output or server.exchanges < 10):
                    raise SystemExit("FAIL: background lifecycle/TCP regression")
                print("PASS: background paint/TCP, one-shot pause/resume, foreground return and Stop cleanup")
            finally:
                server.shutdown()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--javac", default="javac")
    args = parser.parse_args()
    main(args.executable.resolve(), args.javac)
