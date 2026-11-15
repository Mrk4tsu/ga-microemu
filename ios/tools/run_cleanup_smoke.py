#!/usr/bin/env python3
"""Exercise frontend cleanup requests, live roots, coalescing and VM shutdown."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile
import zipfile
IOS=Path(__file__).resolve().parents[1]

def main(executable):
    with tempfile.TemporaryDirectory(prefix='ga-cleanup-') as temp:
        root=Path(temp);classes=root/'classes';classes.mkdir()
        subprocess.run(['javac','-source','8','-target','8','-encoding','UTF-8','-bootclasspath',str(IOS/'Runtime/minijvm_rt.jar'),
            '-cp',str(IOS/'Runtime/microemu-ios.jar'),'-d',str(classes),str(IOS/'tests/java/memory/CleanupMIDlet.java')],check=True)
        jar=root/'cleanup.jar'
        with zipfile.ZipFile(jar,'w',zipfile.ZIP_DEFLATED) as archive:
            for item in classes.rglob('*.class'):archive.write(item,item.relative_to(classes).as_posix())
            archive.writestr('META-INF/MANIFEST.MF','MIDlet-Name: Cleanup test\r\nMIDlet-Vendor: GaEmulator\r\nMIDlet-1: Test,,memory.CleanupMIDlet\r\n\r\n')
        env=os.environ.copy();env.update(MICROEMU_HOST_MODE='1',MICROEMU_CLEANUP_TEST='1',MICROEMU_STOP_ON_STATUS='1')
        run=subprocess.run([str(executable.resolve()),str(IOS/'Runtime/minijvm_rt.jar'),str(IOS/'Runtime/microemu-ios.jar'),str(jar),str(root/'rms'),'15'],
            env=env,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=25)
        output=run.stdout+run.stderr;print(output)
        if run.returncode or 'CLEANUP_TEST_FAIL' in output or 'CLEANUP_LIVE_FAIL' in output or 'CLEANUP_THREAD_PASS' not in output or 'CLEANUP_LIVE_PASS' not in output or 'zip_streams=0' not in output:
            raise SystemExit('FAIL: asynchronous memory cleanup')
        result=re.search(r'\[CLEANUP_RESULT\] state=3 heap_before=(\d+) heap_after=(\d+) elapsed_ms=(\d+)',output)
        if not result:raise SystemExit('FAIL: missing completed GC measurement')
        before,after,elapsed=map(int,result.groups())
        print('PASS: reclaimed %.2f MiB of unreachable objects; 8 MiB live data survived; request-to-GC acknowledgement %d ms; shutdown safe'%((before-after)/1048576,elapsed))

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--executable',type=Path,required=True)
    main(parser.parse_args().executable)
