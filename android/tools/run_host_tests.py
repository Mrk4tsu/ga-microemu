#!/usr/bin/env python3
"""Verify Android's platform-independent JAR metadata reader using real ZIP files."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]
def jdk_tool(name):
    home=os.environ.get('JAVA_HOME')
    return str(Path(home)/'bin'/(name+('.exe' if os.name=='nt' else ''))) if home else name

with tempfile.TemporaryDirectory(prefix='ga-android-metadata-') as temporary:
    directory=Path(temporary)
    subprocess.run([jdk_tool('javac'),'--release','8','-encoding','UTF-8','-d',str(directory),
        str(ROOT/'app/src/main/java/com/gamod/gaemulator/GameMetadata.java'),
        str(ROOT/'tests/host/com/gamod/gaemulator/MetadataTest.java')],check=True)
    subprocess.run([jdk_tool('java'),'-cp',str(directory),'com.gamod.gaemulator.MetadataTest',str(directory)],check=True)
