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
from run_smoke import density_fixture

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
                jar.writestr("x1/encoded.png", bytes(value ^ 0x5a for value in density_fixture()))
                jar.writestr("META-INF/MANIFEST.MF", "MIDlet-Name: " + name + "\r\nMIDlet-Vendor: MicroEmu\r\n"
                    "MIDlet-1: Test,,session." + entry + "\r\nTest-Mode: " + mode + "\r\n" + extra + "\r\n")
            return file

        def run(jar, rms, env, frame, seconds=10, expect_failure=False):
            try:
                result = subprocess.run([str(executable), str(rt / "minijvm_rt.jar"), str(rt / "microemu-ios.jar"),
                    str(jar), str(rms), str(seconds), str(frame)], env=env, capture_output=True,
                    text=True, encoding="utf-8", errors="replace", timeout=15)
            except subprocess.TimeoutExpired as error:
                for stream in (error.stdout, error.stderr):
                    text = stream.decode("utf-8", "replace") if isinstance(stream, bytes) else (stream or "")
                    print("\n".join(text.splitlines()[-50:]))
                raise SystemExit("Compatibility timeout: " + jar.stem) from error
            if bool(result.returncode) != expect_failure:
                print(result.stdout); print(result.stderr)
                raise SystemExit("Compatibility regression, status=" + str(result.returncode))
            return result.stdout + result.stderr

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

        # An explicit launch choice wins over an old per-game profile file.
        env.update(MICROEMU_USER_VIEWPORT="1", MICROEMU_TEST_WIDTH="428", MICROEMU_TEST_HEIGHT="541")
        output=run(jar,rms,env,frame)
        if "source=user-selection" not in output or struct.unpack(">II",frame.read_bytes()[16:24])!=(428,541):
            raise SystemExit("The chosen launch size was overridden")
        env["MICROEMU_TEST_WIDTH"]="1921"
        output=run(jar,rms,env,frame,expect_failure=True)
        if "Invalid screen size" not in output or "state=STARTING" in output:
            raise SystemExit("An oversized launch reached game code")
        print("PASS: explicit launch size wins over profile; 1921 px is rejected before game startup")

        encoded=game("encoded", "FullScreenMIDlet", "normal")
        env.update(MICROEMU_TEST_WIDTH="428",MICROEMU_TEST_HEIGHT="541")
        output=run(encoded,root/"encoded-fixed",env,frame,expect_failure=True)
        if "[IMAGE_ERROR]" not in output or "resource=/x1/encoded.png requested=/x2/encoded.png" not in output or "[LAUNCH_FAILED]" not in output:
            raise SystemExit("Image-loading failure was hidden")
        env["MICROEMU_FULLSCREEN"]="1"
        frame.unlink(missing_ok=True)
        output=run(encoded,root/"encoded-full",env,frame)
        if ("[FULLSCREEN]" not in output or "retry-render=348x440 upscale-to=428x541" not in output
            or output.count("[SESSION] reclaimed")!=2 or struct.unpack(">II",frame.read_bytes()[16:24])!=(348,440)):
            print(output);raise SystemExit("Full screen did not restart and upscale after the image failure")
        print("PASS: fixed size reports encoded x1/x2 failure; Full screen retries at 348x440 and scales to 428x541")
        paint=game("encoded-paint", "FullScreenMIDlet", "paint")
        output=run(paint,root/"encoded-paint",env,frame)
        if "[FULLSCREEN]" not in output or "[SESSION] first-frame" not in output:
            raise SystemExit("An image failure in the first paint did not trigger Full screen scaling")
        print("PASS: Full screen also recovers when images fail in the first paint callback")

        late=game("encoded-late", "FullScreenMIDlet", "late-paint")
        output=run(late,root/"encoded-late",env,frame)
        if "[PAINT_FAILED]" not in output or "[FULLSCREEN]" in output or output.count("[SESSION] reclaimed")!=1:
            print(output);raise SystemExit("Full screen restarted a game after its first successful frame")
        print("PASS: image errors after the first frame skip the failed paint without restarting the game")

        broken=game("encoded-broken", "FullScreenMIDlet", "unrecoverable")
        output=run(broken,root/"encoded-broken",env,frame,expect_failure=True)
        if output.count("[FULLSCREEN]")!=1 or output.count("[SESSION] reclaimed")!=2 or "result=-1" not in output:
            print(output);raise SystemExit("An unrecoverable image error did not stop after one retry")
        print("PASS: unrecoverable images report failure after exactly one retry")

        env.update(MICROEMU_STOP_ON_RETRY="1",MICROEMU_ALLOW_NO_FRAME="1")
        output=run(encoded,root/"encoded-stop",env,frame)
        if output.count("[SESSION] reclaimed")!=1 or "[SESSION] first-frame" in output:
            print(output);raise SystemExit("Stop at the retry boundary launched another game session")
        env.pop("MICROEMU_STOP_ON_RETRY");env.pop("MICROEMU_ALLOW_NO_FRAME")
        print("PASS: Stop at the retry boundary cancels the retry without opening another session")

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
