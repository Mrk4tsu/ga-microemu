#!/usr/bin/env python3
"""Build the shared Java ME runtime as APK assets, never as Android DEX classes."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'ios/tools'))
from prepare_runtime import prepare
from build_java import build
from runtime_crypto import encrypt_blob
from generate_project import generate
from run_smoke import density_fixture

def main(runtime, javac):
    prepare(runtime)
    build(runtime, javac)
    # Generate the shared dependency notices with the same source of truth as iOS.
    generate(runtime, spec_only=True)
    assets = ROOT / 'android/app/build/generated/runtimeAssets'
    output = assets / 'runtime'
    output.mkdir(parents=True, exist_ok=True)
    for name in ('minijvm_rt.jar', 'microemu-ios.jar'):
        (output / name).write_bytes(encrypt_blob((ROOT / 'ios/Runtime' / name).read_bytes()))
    shutil.copytree(ROOT / 'ios/Runtime/ThirdParty', assets / 'ThirdParty', dirs_exist_ok=True)
    shutil.copyfile(ROOT / 'android/NOTICE', assets / 'ThirdParty/GaEmulator-AUTHOR.txt')
    classes = ROOT / 'android/build/fixtures/classes'
    classes.resolve().relative_to((ROOT / 'android/build').resolve())
    if classes.exists(): shutil.rmtree(classes)
    classes.mkdir(parents=True, exist_ok=True)
    subprocess.run([javac, '-source', '8', '-target', '8', '-encoding', 'UTF-8',
        '-bootclasspath', str(ROOT / 'ios/Runtime/minijvm_rt.jar'),
        '-cp', str(ROOT / 'ios/Runtime/microemu-ios.jar'), '-d', str(classes),
        str(ROOT / 'android/tests/java/AndroidSmokeMIDlet.java'),
        str(ROOT / 'ios/tests/java/lifecycle/SocketStopMIDlet.java'),
        str(ROOT / 'ios/tests/java/memory/MemoryMIDlet.java'),
        *map(str, sorted((ROOT / 'ios/tests/java/session').glob('*.java')))], check=True)
    tests = ROOT / 'android/app/build/generated/testAssets'
    tests.mkdir(parents=True, exist_ok=True)
    for name, entry, mode in [('smoke', 'ga.tests.AndroidSmokeMIDlet', ''),
                             ('idle-socket', 'lifecycle.SocketStopMIDlet', ''),
                             ('full-screen', 'session.FullScreenMIDlet', 'normal'),
                             ('blocked', 'session.SessionMIDlet', 'start'),
                             ('peer', 'session.SessionMIDlet', 'normal'),
                             ('memory', 'memory.MemoryMIDlet', 'resources'),
                             ('memory-abandon', 'memory.MemoryMIDlet', 'abandon')]:
        with zipfile.ZipFile(tests / (name + '.jar'), 'w', zipfile.ZIP_DEFLATED) as archive:
            for file in sorted(classes.rglob('*.class')):
                archive.write(file, file.relative_to(classes).as_posix())
            archive.writestr('x1/encoded.png', bytes(value ^ 0x5a for value in density_fixture()))
            if name.startswith('memory'):
                for index in range(24):archive.writestr('bulk/asset%d.bin'%index,bytes([index])*(1024*1024))
            archive.writestr('META-INF/MANIFEST.MF', 'Manifest-Version: 1.0\r\nMIDlet-Name: Android test\r\nMIDlet-Vendor: GaEmulator\r\nMIDlet-1: Test,,' + entry + '\r\nTest-Port: 41041\r\nTest-Mode: ' + mode + '\r\n\r\n')
    print('Prepared Android runtime and instrumentation fixtures:', assets)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', type=Path, default=ROOT / 'android/.deps/miniJVM')
    parser.add_argument('--javac', default='javac')
    args = parser.parse_args()
    main(args.runtime.resolve(), args.javac)
