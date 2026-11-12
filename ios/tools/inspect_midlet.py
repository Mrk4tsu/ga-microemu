#!/usr/bin/env python3
"""Inspect a MIDlet without executing it or modifying the supplied JAR."""
import argparse
import collections
import hashlib
import json
import re
import struct
import zipfile


def class_info(data):
    if data[:4] != b"\xca\xfe\xba\xbe":
        raise ValueError("Invalid Java class")
    minor, major, count = struct.unpack_from(">HHH", data, 4)
    pool = [None] * count
    offset, index = 10, 1
    while index < count:
        tag = data[offset]
        offset += 1
        if tag == 1:
            length = struct.unpack_from(">H", data, offset)[0]
            offset += 2
            pool[index] = (tag, data[offset:offset + length].decode("utf-8", "replace"))
            offset += length
        elif tag in (3, 4):
            offset += 4
        elif tag in (5, 6):
            offset += 8
            index += 1
        elif tag in (7, 8, 16, 19, 20):
            pool[index] = (tag, struct.unpack_from(">H", data, offset)[0])
            offset += 2
        elif tag in (9, 10, 11, 12, 17, 18):
            pool[index] = (tag, *struct.unpack_from(">HH", data, offset))
            offset += 4
        elif tag == 15:
            offset += 3
        else:
            raise ValueError("Unknown constant-pool tag %s" % tag)
        index += 1
    utf = lambda i: pool[i][1]
    classes = {utf(p[1]) for p in pool if p and p[0] == 7}
    members = set()
    for p in pool:
        if p and p[0] in (9, 10, 11):
            owner = utf(pool[p[1]][1])
            nt = pool[p[2]]
            members.add((owner, utf(nt[1]), utf(nt[2])))
    strings = {utf(p[1]) for p in pool if p and p[0] == 8}
    return major, classes, members, strings


def inspect(path):
    with zipfile.ZipFile(path) as jar:
        names = jar.namelist()
        manifest = jar.read("META-INF/MANIFEST.MF").decode("utf-8", "replace")
        # Some old build tools emit CRCRLF. Preserve continuation semantics.
        manifest = manifest.replace("\r\r\n", "\n").replace("\r\n", "\n").replace("\r", "\n")
        manifest = manifest.replace("\n ", "")
        properties = dict(line.split(": ", 1) for line in manifest.splitlines() if ": " in line)
        internal = {n[:-6] for n in names if n.endswith(".class")}
        references, members, strings, versions = set(), set(), set(), collections.Counter()
        for name in names:
            if not name.endswith(".class"):
                continue
            major, refs, refs_members, literals = class_info(jar.read(name))
            references.update(refs)
            members.update(refs_members)
            strings.update(literals)
            versions[major] += 1
        external = sorted(n for n in references - internal if not n.startswith("["))
        external_members = sorted("%s.%s%s" % m for m in members if m[0] not in internal)
        endpoints = sorted(s for s in strings if re.search(r"https?://|socket://|\b(?:\d{1,3}\.){3}\d{1,3}\b", s))
        return {
            "file": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "manifest": properties, "class_count": len(internal), "entry_count": len(names),
            "class_versions": dict(sorted(versions.items())), "external_classes": external,
            "external_members": external_members, "endpoint_literals": endpoints,
        }


if __name__ == "__main__":
    from pathlib import Path
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("jar", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    report = json.dumps(inspect(args.jar), ensure_ascii=False, indent=2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(report + "\n", encoding="utf-8")
    else:
        print(report)
