#!/usr/bin/env python3
"""Measure retained resource bytes using the real interpreter and production loader."""
import argparse
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile
import threading
import zipfile

IOS=Path(__file__).resolve().parents[1]

def measured_run(arguments,env):
    process=subprocess.Popen(arguments,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,encoding='utf-8',errors='replace')
    stop=threading.Event();peak=[0];handle=None;close=None
    if os.name=='nt':
        import ctypes
        from ctypes import wintypes
        class Counters(ctypes.Structure):
            _fields_=[('cb',wintypes.DWORD),('faults',wintypes.DWORD)]+[(name,ctypes.c_size_t) for name in
                ('peak_working_set','working_set','peak_paged','paged','peak_nonpaged','nonpaged','pagefile','peak_pagefile','private')]
        kernel=ctypes.WinDLL('kernel32',use_last_error=True);api=ctypes.WinDLL('psapi',use_last_error=True)
        kernel.OpenProcess.argtypes=[wintypes.DWORD,wintypes.BOOL,wintypes.DWORD];kernel.OpenProcess.restype=wintypes.HANDLE
        kernel.CloseHandle.argtypes=[wintypes.HANDLE]
        api.GetProcessMemoryInfo.argtypes=[wintypes.HANDLE,ctypes.POINTER(Counters),wintypes.DWORD]
        handle=kernel.OpenProcess(0x410,False,process.pid);close=kernel.CloseHandle
        def sample():
            data=Counters();data.cb=ctypes.sizeof(data)
            return data.peak_working_set if handle and api.GetProcessMemoryInfo(handle,ctypes.byref(data),data.cb) else 0
    else:
        def sample():
            try:
                text=Path('/proc/%d/status'%process.pid).read_text()
                match=re.search(r'^VmHWM:\s+(\d+) kB',text,re.M)
                return int(match[1])*1024 if match else 0
            except OSError:return 0
    def collect():
        while not stop.is_set():peak[0]=max(peak[0],sample());stop.wait(0.02)
    thread=threading.Thread(target=collect,daemon=True);thread.start()
    try:
        stdout,stderr=process.communicate(timeout=40)
        return subprocess.CompletedProcess(arguments,process.returncode,stdout,stderr),peak[0]
    except subprocess.TimeoutExpired:
        process.kill();stdout,stderr=process.communicate();print(stdout);print(stderr);raise
    finally:
        stop.set();thread.join()
        if handle:close(handle)

def class_header(name,payload_size):
    def utf(value):
        data=value.encode('utf-8');return b'\x01'+struct.pack('>H',len(data))+data
    pool=utf(name)+b'\x07\x00\x01'+utf('java/lang/Object')+b'\x07\x00\x03'+utf('Payload')
    return struct.pack('>IHHH',0xcafebabe,0,52,6)+pool+struct.pack('>8H',0x21,2,4,0,0,0,1,5)+struct.pack('>I',payload_size)

def main(executable,record_only=False,report=None,emulator=None):
    with tempfile.TemporaryDirectory(prefix='ga-memory-') as temporary:
        root=Path(temporary);classes=root/'classes';classes.mkdir()
        subprocess.run(['javac','-source','8','-target','8','-encoding','UTF-8',
            '-bootclasspath',str(IOS/'Runtime/minijvm_rt.jar'),'-cp',str(IOS/'Runtime/microemu-ios.jar'),
            '-d',str(classes),str(IOS/'tests/java/memory/MemoryMIDlet.java')],check=True)
        env=os.environ.copy();env.update(MICROEMU_HOST_MODE='1',MICROEMU_STOP_ON_STATUS='1')
        output='';values={}
        for case in (('resources',) if record_only else ('resources','streams','abandon','cancel-read')):
            jar=root/(case+'.jar')
            with zipfile.ZipFile(jar,'w',zipfile.ZIP_DEFLATED) as archive:
                for item in classes.rglob('*.class'):archive.write(item,item.relative_to(classes).as_posix())
                for index in range(24):archive.writestr('bulk/asset%d.bin'%index,bytes([index])*(1024*1024))
                for index in range(8):
                    with archive.open('unused/Bulk%d.class'%index,'w') as entry:
                        entry.write(class_header('unused/Bulk%d'%index,4*1024*1024));entry.write(bytes(4*1024*1024))
                archive.writestr('bulk/empty.bin',b'')
                archive.writestr('bulk/stored.bin',b'Z'*16384,compress_type=zipfile.ZIP_STORED)
                archive.writestr('bulk/corrupt.bin',b'broken-crc'*1024)
                archive.writestr('META-INF/MANIFEST.MF','MIDlet-Name: Memory test\r\nMIDlet-Vendor: GaEmulator\r\nMIDlet-1: Test,,memory.MemoryMIDlet\r\nTest-Mode: '+case+'\r\n\r\n')
                bad=archive.getinfo('bulk/corrupt.bin')
            data=bytearray(jar.read_bytes());bad_crc=bad.CRC^1
            struct.pack_into('<I',data,bad.header_offset+14,bad_crc)
            end=data.rfind(b'PK\x05\x06');central=struct.unpack_from('<I',data,end+16)[0]
            while data[central:central+4]==b'PK\x01\x02':
                name_len,extra,comment=struct.unpack_from('<HHH',data,central+28)
                if data[central+46:central+46+name_len]==b'bulk/corrupt.bin':
                    struct.pack_into('<I',data,central+16,bad_crc);break
                central+=46+name_len+extra+comment
            jar.write_bytes(data)
            run,peak=measured_run([str(executable),str(IOS/'Runtime/minijvm_rt.jar'),str(emulator or IOS/'Runtime/microemu-ios.jar'),
                str(jar),str(root/('rms-'+case)),'30',str(root/(case+'.png'))],env)
            case_output=run.stdout+run.stderr;output+=case_output
            if run.returncode or 'MEMORY_FAIL' in case_output or 'zip_streams=0' not in case_output:
                print(case_output);raise SystemExit('Memory fixture failed: '+case)
            if case=='resources':
                match=re.search(r'MEMORY_RESULT before=(\d+) after=(\d+) retained=(-?\d+) payload=(\d+)',case_output)
                if not match:print(case_output);raise SystemExit('Missing memory measurement')
                values=dict(zip(('before','after','retained','payload'),map(int,match.groups())))
                values['process_peak_rss']=peak or None
                print(json.dumps(values))
                if not record_only and values['retained']>4*1024*1024:
                    raise SystemExit('FAIL: closed ZIP streams retained more than 4 MiB for a 24 MiB resource set')
            elif case=='streams':
                if 'STREAM_PASS' not in case_output:print(case_output);raise SystemExit('Stream contract regression')
                values['stream_open_delta']=int(re.search(r'STREAM_MEMORY open_delta=(-?\d+)',case_output)[1])
                print('PASS: bounded stream opening, independent reads, mark/reset, skip, empty/stored ZIP, CRC validation, close')
            elif case=='abandon':
                if 'ABANDONED_STREAMS_READY' not in case_output:print(case_output);raise SystemExit('Abandoned-stream fixture did not start')
                print('PASS: Stop directly reclaimed eight abandoned native ZIP streams')
            else:
                if 'ACTIVE_STREAM_READY' not in case_output:print(case_output);raise SystemExit('Active-stream fixture did not start')
                print('PASS: Stop cancelled continuous read/reset after CCL replacement and GC; ZIP registry empty')
        if report:
            report.parent.mkdir(parents=True,exist_ok=True);report.write_text(json.dumps(values,indent=2),encoding='utf-8')
            report.with_suffix('.log').write_text(output,encoding='utf-8')
        print('PASS: real archive resource integrity, Stop, and retained-memory budget' if not record_only else 'Recorded pre-optimization memory')

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--executable',type=Path,required=True)
    parser.add_argument('--record-only',action='store_true')
    parser.add_argument('--report',type=Path)
    parser.add_argument('--emulator-jar',type=Path)
    args=parser.parse_args()
    main(args.executable.resolve(),args.record_only,args.report,args.emulator_jar)
