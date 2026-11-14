#!/usr/bin/env python3
"""Inspect a MIDlet without executing it or modifying the supplied JAR."""
import argparse
import collections
import hashlib
import json
import re
import struct
import zipfile


SCHEMA_VERSION = 1


def class_info(data, include_header=False):
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
    if include_header:
        flags, own, parent = struct.unpack_from(">HHH", data, offset)
        return major, classes, members, strings, (utf(pool[own][1]), utf(pool[parent][1]) if parent else None, flags)
    return major, classes, members, strings


def inspect(path):
    with zipfile.ZipFile(path) as jar:
        names = jar.namelist()
        manifest_name = next((n for n in names if n.replace("\\", "/").lstrip("/").lower() == "meta-inf/manifest.mf"), None)
        if manifest_name is None:
            manifest_name = next((n for n in names if n.replace("\\", "/").lstrip("/").lower() == "manifest.mf"), None)
        manifest = jar.read(manifest_name).decode("utf-8-sig", "replace") if manifest_name else ""
        # Some old build tools emit CRCRLF. Preserve continuation semantics.
        manifest = manifest.replace("\r\r\n", "\n").replace("\r\n", "\n").replace("\r", "\n")
        manifest = manifest.replace("\n ", "")
        properties = {}
        for line in manifest.splitlines():
            if ":" in line:
                key, value = line.split(":", 1)
                properties[key.strip()] = value.strip()
        internal = {n[:-6] for n in names if n.endswith(".class")}
        references, members, strings, versions = set(), set(), set(), collections.Counter()
        headers = {}
        for name in names:
            if not name.endswith(".class"):
                continue
            major, refs, refs_members, literals, header = class_info(jar.read(name), include_header=True)
            headers[header[0]] = header
            references.update(refs)
            members.update(refs_members)
            strings.update(literals)
            versions[major] += 1
        external = sorted(n for n in references - internal if not n.startswith("["))
        external_members = sorted("%s.%s%s" % m for m in members if m[0] not in internal)
        endpoints = sorted(s for s in strings if re.search(r"https?://|socket://|\b(?:\d{1,3}\.){3}\d{1,3}\b", s))
        candidates = []
        for name, (_, parent, flags) in sorted(headers.items()):
            if flags & 0x601 != 1: continue
            visited = set()
            while parent and parent not in visited:
                if parent == "javax/microedition/midlet/MIDlet":
                    candidates.append(name.replace("/", ".")); break
                visited.add(parent)
                parent = headers.get(parent, (None, None, 0))[1]
        densities = sorted({n.replace("\\", "/").lstrip("/").lower().split("/")[0]
                            for n in names if re.match(r"^/?x[1-4]/", n.replace("\\", "/"), re.I)})
        return {
            "schema_version": SCHEMA_VERSION,
            "file": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "manifest": properties, "manifest_entry": manifest_name, "class_count": len(internal), "entry_count": len(names),
            "class_versions": dict(sorted(versions.items())), "external_classes": external,
            "midlet_candidates": candidates, "resource_densities": densities,
            "uses_reflection": any(n.startswith("java/lang/reflect/") for n in references),
            "external_members": external_members, "endpoint_literals": endpoints,
        }


if __name__ == "__main__":
    from pathlib import Path
    import sys
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
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
