#!/usr/bin/env python3
"""Exercise the actual interpreter, raster, persistent RMS and native networking."""
import argparse
import os
from pathlib import Path
import socket
import socketserver
import subprocess
import tempfile
import threading
import zipfile

IOS = Path(__file__).resolve().parents[1]


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(5)
        data = self.request.recv(4096)
        if data.startswith(b"GET "):
            while b"\r\n\r\n" not in data:
                more = self.request.recv(4096)
                if not more:
                    return
                data += more
            self.request.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\nHTTP_OK")
        else:
            self.request.sendall(data)
            while True:
                data = self.request.recv(4096)
                if not data:
                    return
                self.request.sendall(data)


def main(executable, javac):
    with socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler) as server, tempfile.TemporaryDirectory(prefix="microemu-smoke-") as temp:
        server.daemon_threads = True
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        root = Path(temp)
        classes = root / "classes"
        classes.mkdir()
        resources = IOS / "Runtime"
        subprocess.run([javac, "-source", "8", "-target", "8", "-encoding", "UTF-8",
                        "-bootclasspath", str(resources / "minijvm_rt.jar"), "-cp", str(resources / "microemu-ios.jar"),
                        "-d", str(classes), str(IOS / "tests/java/org/microemu/ios/SmokeMIDlet.java")], check=True)
        game = root / "smoke.jar"
        with zipfile.ZipFile(game, "w", zipfile.ZIP_DEFLATED) as jar:
            for file in classes.rglob("*.class"):
                jar.write(file, file.relative_to(classes).as_posix())
            jar.writestr("META-INF/MANIFEST.MF", "Manifest-Version: 1.0\r\nMIDlet-Name: Smoke\r\nMIDlet-Vendor: MicroEmu\r\nMIDlet-1: Smoke,,org.microemu.ios.SmokeMIDlet\r\nTest-Port: %d\r\n\r\n" % server.server_address[1])
        environment = os.environ.copy()
        environment["MICROEMU_TEST_REPEATS"] = "2"
        control = root / "control.txt"
        control.write_text("12 0 0 0 Test42\n", encoding="utf-8")
        environment["MICROEMU_CONTROL_FILE"] = str(control)
        result = subprocess.run([str(executable), str(resources / "minijvm_rt.jar"), str(resources / "microemu-ios.jar"),
                                 str(game), str(root / "rms"), "10", str(root / "frame.png")],
                                text=True, encoding="utf-8", errors="replace", capture_output=True, timeout=45, env=environment)
        print(result.stdout)
        print(result.stderr)
        print("Host exit status:", result.returncode)
        server.shutdown()
        if result.returncode or result.stdout.count("SMOKE_PASS:") != 2 or "SMOKE_FAIL:" in result.stdout + result.stderr:
            raise SystemExit("Interpreter smoke test failed")
        print("PASS: actual miniJVM interpreter + MIDP graphics + RMS + TCP + HTTP")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--javac", default="javac")
    args = parser.parse_args()
    main(args.executable.resolve(), args.javac)
