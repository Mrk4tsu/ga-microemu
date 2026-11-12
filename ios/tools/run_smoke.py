#!/usr/bin/env python3
"""Exercise the actual interpreter, raster, persistent RMS and native networking."""
import argparse
import os
from pathlib import Path
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import zipfile

IOS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(IOS / "tools"))
from runtime_crypto import encrypt_blob


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
        if result.returncode or result.stdout.count("SMOKE_PASS:") != 2 or "SMOKE_FAIL:" in result.stdout + result.stderr:
            raise SystemExit("Interpreter smoke test failed")
        multi_env = os.environ.copy()
        multi_env["MICROEMU_MULTI_TAB"] = "1"
        multi = subprocess.run([str(executable), str(resources / "minijvm_rt.jar"), str(resources / "microemu-ios.jar"),
                                str(game), str(root / "rms-multi"), "15"],
                               text=True, encoding="utf-8", errors="replace", capture_output=True, timeout=45, env=multi_env)
        print(multi.stdout)
        print(multi.stderr)
        if multi.returncode or multi.stdout.count("SMOKE_PASS:") != 2 or "SMOKE_FAIL:" in multi.stdout + multi.stderr:
            raise SystemExit("Multi-tab interpreter smoke test failed")
        enc_dir = root / "enc-runtime"
        enc_dir.mkdir()
        enc_rt = enc_dir / "minijvm_rt.jar"
        enc_emu = enc_dir / "microemu-ios.jar"
        enc_rt.write_bytes(encrypt_blob((resources / "minijvm_rt.jar").read_bytes()))
        enc_emu.write_bytes(encrypt_blob((resources / "microemu-ios.jar").read_bytes()))
        enc_multi = subprocess.run([str(executable), str(enc_rt), str(enc_emu),
                                    str(game), str(root / "rms-enc"), "15"],
                                   text=True, encoding="utf-8", errors="replace", capture_output=True, timeout=45, env=multi_env)
        print(enc_multi.stdout)
        print(enc_multi.stderr)
        server.shutdown()
        if enc_multi.returncode or enc_multi.stdout.count("SMOKE_PASS:") != 2 or "SMOKE_FAIL:" in enc_multi.stdout + enc_multi.stderr:
            raise SystemExit("Encrypted runtime multi-tab smoke test failed")
        print("PASS: actual miniJVM interpreter + MIDP graphics + RMS + TCP + HTTP (single + multi-tab + encrypted runtime)")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--javac", default="javac")
    args = parser.parse_args()
    main(args.executable.resolve(), args.javac)
