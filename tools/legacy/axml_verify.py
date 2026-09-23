#!/usr/bin/env python3
"""
axml_verify.py - sanity-check a binary AndroidManifest.xml.

Written deliberately as an INDEPENDENT reader rather than reusing
axml_add_perm.py, so that a bug shared between writer and reader cannot
hide itself. (During development exactly that happened: both had the same
off-by-8 in the attribute offset, so a broken manifest looked correct.)

Checks performed:
  * file starts with the AXML magic and the header size matches the file
  * every chunk has a non-zero size and the walk lands exactly on EOF
  * every <uses-permission> has attribute name="name"
  * its namespace really is the android namespace
  * its rawValue and typedValue.data agree
  * any permissions named on the command line are present

Usage:
  axml_verify.py <manifest.bin> [REQUIRED_PERMISSION ...]

Exit code 0 means every check passed.
"""

import struct
import sys

RES_XML_TYPE          = 0x0003
RES_XML_START_ELEMENT = 0x0102
UTF8_FLAG             = 1 << 8
TYPE_STRING           = 0x03

ANDROID_NS = "http://schemas.android.com/apk/res/android"


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)

    path = sys.argv[1]
    required = set(sys.argv[2:])
    data = open(path, "rb").read()

    u16 = lambda o: struct.unpack_from("<H", data, o)[0]
    u32 = lambda o: struct.unpack_from("<I", data, o)[0]

    problems = []

    if u16(0) != RES_XML_TYPE:
        sys.exit("! not a binary AndroidManifest.xml")
    if u32(4) != len(data):
        sys.exit("! header says %d bytes, file is %d" % (u32(4), len(data)))

    # ---- string pool -------------------------------------------------
    pool_header = u16(10)
    pool_size   = u32(12)
    str_count   = u32(16)
    flags       = u32(24)
    strs_start  = u32(28)
    utf8        = bool(flags & UTF8_FLAG)
    offsets     = [u32(8 + pool_header + 4 * i) for i in range(str_count)]

    NO_ENTRY = 0xFFFFFFFF

    def read_string(index):
        # 0xFFFFFFFF means "absent". An attribute's rawValue is commonly
        # -1 when only the typed value carries the data; indexing the
        # offsets table with it walks off the end.
        if index == NO_ENTRY or index >= len(offsets):
            return None
        pos = 8 + strs_start + offsets[index]
        if utf8:
            n = data[pos]; pos += 1
            if n & 0x80:
                n = ((n & 0x7F) << 8) | data[pos]; pos += 1
            m = data[pos]; pos += 1
            if m & 0x80:
                m = ((m & 0x7F) << 8) | data[pos]; pos += 1
            return data[pos:pos + m].decode("utf-8", "replace")
        n = struct.unpack_from("<H", data, pos)[0]; pos += 2
        return data[pos:pos + n * 2].decode("utf-16-le", "replace")

    # ---- walk chunks -------------------------------------------------
    off = 8 + pool_size
    chunks = 0
    found = []

    while off + 8 <= len(data):
        chunk_type = u16(off)
        chunk_size = u32(off + 4)
        if chunk_size <= 0:
            sys.exit("! zero-size chunk at %d" % off)

        if chunk_type == RES_XML_START_ELEMENT \
                and read_string(u32(off + 20)) == "uses-permission":
            attr_base  = off + 16 + u16(off + 24)
            attr_count = u16(off + 28)

            # A uses-permission element may legitimately carry several
            # attributes - maxSdkVersion and usesPermissionFlags are both
            # common. Only android:name identifies the permission; the rest
            # are not our business and must not be flagged.
            named = 0
            for k in range(attr_count):
                a = attr_base + 20 * k
                ns   = read_string(u32(a))
                name = read_string(u32(a + 4))
                if name != "name":
                    continue
                named += 1

                raw   = read_string(u32(a + 8))
                dtype = data[a + 15]
                typed = read_string(u32(a + 16)) if dtype == TYPE_STRING else None
                value = raw if raw is not None else typed

                if ns != ANDROID_NS:
                    problems.append("%s: namespace is %r" % (value, ns))
                if dtype != TYPE_STRING:
                    problems.append("%s: android:name dataType is 0x%02x" % (value, dtype))
                elif raw is not None and typed is not None and raw != typed:
                    problems.append("%s: rawValue != typedValue (%r)" % (raw, typed))

                if value is None:
                    problems.append("permission entry has no readable name")
                else:
                    found.append(value)

            if named == 0:
                problems.append("a uses-permission element has no android:name")

        off += chunk_size
        chunks += 1

    if off != len(data):
        sys.exit("! chunk walk ended at %d, file is %d bytes" % (off, len(data)))

    missing = required - set(found)
    for m in sorted(missing):
        problems.append("required permission absent: %s" % m)

    print("  %d chunks walked, %d strings, %d uses-permission entries"
          % (chunks, str_count, len(found)))

    if problems:
        for p in problems:
            print("  PROBLEM: %s" % p)
        sys.exit("! %d problem(s) found" % len(problems))

    print("  structure intact, all checks passed")


if __name__ == "__main__":
    main()
