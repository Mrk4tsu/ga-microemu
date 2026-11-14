#!/usr/bin/env python3
"""Verify profile precedence, analysis caching and Stop isolation with loopback TCP."""
import argparse
import hashlib
import os
from pathlib import Path
import socketserver
import struct
import subprocess
import tempfile
import threading
import zipfile

IOS = Path(__file__).resolve().parents[1]


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(8)
        if self.request.recv(1) == b"\0":
            self.server.release.wait(8)
            return
        while True:
            data = self.request.recv(64)
            if not data: return
            self.request.sendall(data)


def main(executable, javac):
    rt = IOS / "Runtime"
    with tempfile.TemporaryDirectory(prefix="microemu-compat-") as temp:
        root = Path(temp)
        classes = root / "classes"; classes.mkdir()
        subprocess.run([javac, "-source", "8", "-target", "8", "-encoding", "UTF-8",
            "-bootclasspath", str(rt / "minijvm_rt.jar"), "-cp", str(rt / "microemu-ios.jar"), "-d", str(classes),
            *map(str, sorted((IOS / "tests/java/session").glob("*.java")))], check=True)

        def game(name, entry, mode, extra=""):
            file = root / (name + ".jar")
            with zipfile.ZipFile(file, "w", zipfile.ZIP_DEFLATED) as jar:
                for item in classes.rglob("*.class"): jar.write(item, item.relative_to(classes).as_posix())
                jar.writestr("x1/metadata-only", b"resource directory must not determine viewport")
                jar.writestr("META-INF/MANIFEST.MF", "MIDlet-Name: " + name + "\r\nMIDlet-Vendor: MicroEmu\r\n"
                    "MIDlet-1: Test,,session." + entry + "\r\nTest-Mode: " + mode + "\r\n" + extra + "\r\n")
            return file

        def run(jar, rms, env, frame, seconds=10):
            try:
                result = subprocess.run([str(executable), str(rt / "minijvm_rt.jar"), str(rt / "microemu-ios.jar"),
                    str(jar), str(rms), str(seconds), str(frame)], env=env, capture_output=True,
                    text=True, encoding="utf-8", errors="replace", timeout=15)
            except subprocess.TimeoutExpired as error:
                for stream in (error.stdout, error.stderr):
                    text = stream.decode("utf-8", "replace") if isinstance(stream, bytes) else (stream or "")
                    print("\n".join(text.splitlines()[-50:]))
                raise SystemExit("Compatibility timeout: " + jar.stem) from error
            if result.returncode:
                print(result.stdout); print(result.stderr)
                raise SystemExit("Compatibility regression, status=" + str(result.returncode))
            return result.stdout

        jar = game("profile", "SessionMIDlet", "normal")
        sha = hashlib.sha256(jar.read_bytes()).hexdigest()
        rms = root / "profile-data"
        env = os.environ.copy()
        env.update(MICROEMU_HOST_MODE="1", MICROEMU_STOP_ON_STATUS="1", MICROEMU_TEST_WIDTH="600", MICROEMU_TEST_HEIGHT="800")
        frame = root / "profile.png"
        for case, profile, expected in (("default", None, (600, 800)),
            ("override", "width=320\nheight=480\nviewport=requested\n", (320, 480)),
            ("legacy", "viewport=legacy-x1-budget\n", (339, 452))):
            directory = rms / "profiles"; directory.mkdir(parents=True, exist_ok=True)
            if profile is not None: (directory / (sha + ".properties")).write_text(profile, encoding="utf-8")
            frame.unlink(missing_ok=True)
            output = run(jar, rms, env, frame)
            size = struct.unpack(">II", frame.read_bytes()[16:24])
            if size != expected or (case != "default" and "cache=hit" not in output):
                raise SystemExit("Profile precedence/cache mismatch: " + case + " " + str(size))
            print("PASS: profile %s %dx%d (x1 assets, metadata scan does not initialize StaticBlockMIDlet)" % (case, *size))

        with socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler) as server:
            server.daemon_threads = True; server.release = threading.Event()
            threading.Thread(target=server.serve_forever, daemon=True).start()
            try:
                extra = "Test-Port: %d\r\n" % server.server_address[1]
                idle = game("idle", "SocketSessionMIDlet", "idle", extra)
                peer = game("peer", "SocketSessionMIDlet", "peer", extra)
                env = os.environ.copy()
                env.update(MICROEMU_MULTI_TAB="1", MICROEMU_STOP_ON_STATUS="1", MICROEMU_SECOND_JAR=str(peer))
                output = run(idle, root / "isolation-data", env, root / "isolation.png")
                if "SESSION_ISOLATION_PASS" not in output or "SESSION_SOCKET_IDLE" not in output:
                    print(output); raise SystemExit("Neighbour tab did not survive Stop")
                print("PASS: Stop tab A with idle TCP; tab B continues drawing and TCP traffic; both registries empty")
            finally:
                server.release.set(); server.shutdown()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--javac", default="javac")
    args = parser.parse_args()
    main(args.executable.resolve(), args.javac)
