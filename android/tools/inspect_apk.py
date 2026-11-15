#!/usr/bin/env python3
"""Check the APK's ABIs, encrypted runtime assets and 16 KB ELF/ZIP alignment."""
import argparse
from pathlib import Path
import struct
import zipfile

def inspect(path, abis):
    with zipfile.ZipFile(path) as apk, open(path, 'rb') as stream:
        notice=apk.read('assets/ThirdParty/GaEmulator-AUTHOR.txt').decode('utf-8')
        if 'Author: MrK4tsu' not in notice:
            raise ValueError('Missing application author notice')
        for asset in ('minijvm_rt.jar', 'microemu-ios.jar'):
            data = apk.read('assets/runtime/' + asset)
            if len(data) < 64 or not data.startswith(b'GEMU01\x01\x00'):
                raise ValueError('Missing/encrypted runtime asset check failed: ' + asset)
        if 'classes.dex' not in apk.namelist():
            raise ValueError('Missing Android application classes')
        for abi in abis:
            info = apk.getinfo('lib/' + abi + '/libgaemulator.so')
            elf = apk.read(info)
            if elf[:4] != b'\x7fELF':
                raise ValueError('Invalid ELF for ' + abi)
            expected={'arm64-v8a':(2,183),'armeabi-v7a':(1,40),'x86_64':(2,62)}[abi]
            if (elf[4],struct.unpack_from('<H',elf,18)[0])!=expected:
                raise ValueError('Native architecture does not match ' + abi)
            if elf[4] == 2:
                offset, entry_size, count = struct.unpack_from('<Q', elf, 32)[0], struct.unpack_from('<H', elf, 54)[0], struct.unpack_from('<H', elf, 56)[0]
                alignment_offset, alignment_format = 48, '<Q'
            else:
                offset, entry_size, count = struct.unpack_from('<I', elf, 28)[0], struct.unpack_from('<H', elf, 42)[0], struct.unpack_from('<H', elf, 44)[0]
                alignment_offset, alignment_format = 28, '<I'
            loads = 0
            for i in range(count):
                header = offset + i * entry_size
                if struct.unpack_from('<I', elf, header)[0] == 1:
                    loads += 1
                    if struct.unpack_from(alignment_format, elf, header + alignment_offset)[0] < 16384:
                        raise ValueError('ELF load segment is not 16 KB aligned: ' + abi)
            if not loads:
                raise ValueError('No ELF load segments: ' + abi)
            stream.seek(info.header_offset + 26)
            name_length, extra_length = struct.unpack('<HH', stream.read(4))
            data_offset = info.header_offset + 30 + name_length + extra_length
            if info.compress_type != zipfile.ZIP_STORED or data_offset % 16384:
                raise ValueError('Native library is compressed or not ZIP aligned: ' + abi)
            print('PASS:', abi, 'ELF + ZIP 16 KB alignment')
    print('PASS: installable Android package structure + runtime assets')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apk', type=Path)
    parser.add_argument('--abis', default='arm64-v8a,armeabi-v7a,x86_64')
    args = parser.parse_args()
    inspect(args.apk, args.abis.split(','))
