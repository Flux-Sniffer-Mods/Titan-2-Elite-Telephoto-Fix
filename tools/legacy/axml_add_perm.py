#!/usr/bin/env python3
"""
axml_add_perm.py - add <uses-permission> entries to a *compiled*
AndroidManifest.xml (binary AXML) without recompiling resources.

WHY THIS EXISTS
---------------
The normal way to add a permission is `apktool d` -> edit the XML ->
`apktool b`. That fails on this APK: it contains 712 resources named
"$$action_animation__NN__N", and aapt2 rejects any entry name containing
'$' ("has invalid entry name"). apktool 3.x has no aapt1 fallback, so the
rebuild can never succeed.

This tool sidesteps the problem by never touching resources at all. It
edits the already-compiled binary manifest in place, which is then swapped
back into the APK zip. Everything else in the APK - resources.arsc, dex,
native libs - is copied byte-for-byte.

HOW IT WORKS
------------
Two edits, both purely additive:

  1. Append the new permission strings to the end of the string pool.
     Appending is safe because every reference in AXML is an *index*, so
     existing indices keep pointing at the same strings.

  2. Clone the chunk bytes of an existing <uses-permission> element and
     repoint its android:name attribute at the new string index. Cloning
     guarantees the element header, namespace, attribute layout and
     typed-value encoding are all byte-identical to something the platform
     already accepts.

Finally the total file size in the AXML header is corrected.

BINARY LAYOUT REFERENCE
-----------------------
File header:        ResChunk_header { u16 type=0x0003, u16 headerSize,
                                      u32 size }  -- size = whole file

String pool chunk:  u16 type=0x0001, u16 headerSize, u32 chunkSize,
                    u32 stringCount, u32 styleCount, u32 flags,
                    u32 stringsStart, u32 stylesStart,
                    u32 stringOffsets[stringCount],
                    u32 styleOffsets[styleCount],
                    <string data>, <style data>

XML element chunk (START_ELEMENT, type 0x0102):
                    +0   ResChunk_header (8 bytes)
                    +8   u32 lineNumber
                    +12  u32 comment
                    +16  u32 ns            <-- ResXMLTree_attrExt starts here
                    +20  u32 name
                    +24  u16 attributeStart   (relative to +16, normally 20)
                    +26  u16 attributeSize
                    +28  u16 attributeCount
                    +30  u16 idIndex
                    +32  u16 classIndex
                    +34  u16 styleIndex
                    then attributeCount * 20-byte attributes

Attribute (20 bytes), relative to its own start B:
                    B+0   u32 ns
                    B+4   u32 name
                    B+8   u32 rawValue        (string index, or -1)
                    B+12  u16 size (always 8)
                    B+14  u8  res0
                    B+15  u8  dataType        (0x03 = TYPE_STRING)
                    B+16  u32 data            (string index when TYPE_STRING)

Note the +16 above: attributeStart is relative to the start of attrExt
(offset 16), NOT to the start of the chunk. Getting this wrong silently
clobbers the namespace field while leaving the typed value untouched,
which produces a manifest that parses but whose permissions are wrong.

USAGE
-----
  axml_add_perm.py <in.xml> <out.xml> PERMISSION [PERMISSION ...]

Exits non-zero on any structural surprise rather than writing a
half-valid manifest.
"""

import struct
import sys

# Chunk type IDs from ResourceTypes.h
RES_XML_TYPE          = 0x0003
RES_STRING_POOL_TYPE  = 0x0001
RES_XML_START_ELEMENT = 0x0102
RES_XML_END_ELEMENT   = 0x0103

# String pool flags
UTF8_FLAG   = 1 << 8   # strings stored as UTF-8 rather than UTF-16LE
SORTED_FLAG = 1 << 0   # pool is sorted; appending would break the ordering

TYPE_STRING = 0x03     # Res_value dataType for a string reference


# --------------------------------------------------------------- primitives

def u16(buf, off):
    return struct.unpack_from("<H", buf, off)[0]


def u32(buf, off):
    return struct.unpack_from("<I", buf, off)[0]


def _read_len8(buf, pos):
    """UTF-8 pool length: 1 byte, or 2 bytes when the high bit is set."""
    n = buf[pos]
    pos += 1
    if n & 0x80:
        n = ((n & 0x7F) << 8) | buf[pos]
        pos += 1
    return n, pos


def _read_len16(buf, pos):
    """UTF-16 pool length: 1 u16, or 2 u16s when the high bit is set."""
    n = struct.unpack_from("<H", buf, pos)[0]
    pos += 2
    if n & 0x8000:
        low = struct.unpack_from("<H", buf, pos)[0]
        pos += 2
        n = ((n & 0x7FFF) << 16) | low
    return n, pos


def _write_len8(n):
    return bytes([n]) if n < 0x80 else bytes([0x80 | (n >> 8), n & 0xFF])


def _write_len16(n):
    if n < 0x8000:
        return struct.pack("<H", n)
    return struct.pack("<HH", 0x8000 | (n >> 16), n & 0xFFFF)


def fail(msg):
    sys.exit("! %s" % msg)


# -------------------------------------------------------------- string pool

def parse_string_pool(data, off):
    """Decode the string pool chunk at `off` into a dict."""
    if u16(data, off) != RES_STRING_POOL_TYPE:
        fail("no string pool at offset %d" % off)

    header_size = u16(data, off + 2)
    chunk_size  = u32(data, off + 4)
    str_count   = u32(data, off + 8)
    style_count = u32(data, off + 12)
    flags       = u32(data, off + 16)
    strs_start  = u32(data, off + 20)
    styles_start = u32(data, off + 24)

    base = off + header_size
    str_offsets   = [u32(data, base + 4 * i) for i in range(str_count)]
    style_offsets = [u32(data, base + 4 * str_count + 4 * i)
                     for i in range(style_count)]

    utf8 = bool(flags & UTF8_FLAG)
    strings = []
    for rel in str_offsets:
        pos = off + strs_start + rel
        if utf8:
            _, pos = _read_len8(data, pos)          # character count (unused)
            nbytes, pos = _read_len8(data, pos)     # byte count
            strings.append(data[pos:pos + nbytes].decode("utf-8", "replace"))
        else:
            nchars, pos = _read_len16(data, pos)
            strings.append(
                data[pos:pos + nchars * 2].decode("utf-16-le", "replace"))

    # Style data is opaque to us; keep the bytes and replay them verbatim.
    style_blob = data[off + styles_start:off + chunk_size] if style_count else b""

    return {
        "off":           off,
        "chunk_size":    chunk_size,
        "flags":         flags,
        "utf8":          utf8,
        "strings":       strings,
        "style_count":   style_count,
        "style_offsets": style_offsets,
        "style_blob":    style_blob,
    }


def build_string_pool(pool, strings):
    """Re-emit a string pool chunk containing `strings`."""
    utf8 = pool["utf8"]
    blobs, offsets, cursor = [], [], 0

    for s in strings:
        offsets.append(cursor)
        if utf8:
            raw = s.encode("utf-8")
            blob = _write_len8(len(s)) + _write_len8(len(raw)) + raw + b"\x00"
        else:
            raw = s.encode("utf-16-le")
            blob = _write_len16(len(s)) + raw + b"\x00\x00"
        blobs.append(blob)
        cursor += len(blob)

    string_data = b"".join(blobs)
    while len(string_data) % 4:      # chunks must stay 4-byte aligned
        string_data += b"\x00"

    header_size  = 0x1C
    str_count    = len(strings)
    style_count  = pool["style_count"]
    strs_start   = header_size + 4 * str_count + 4 * style_count
    styles_start = (strs_start + len(string_data)) if style_count else 0
    chunk_size   = strs_start + len(string_data) + len(pool["style_blob"])

    out = struct.pack(
        "<HHIIIIII",
        RES_STRING_POOL_TYPE, header_size, chunk_size,
        str_count, style_count, pool["flags"], strs_start, styles_start,
    )
    out += b"".join(struct.pack("<I", o) for o in offsets)
    out += b"".join(struct.pack("<I", o) for o in pool["style_offsets"])
    return out + string_data + pool["style_blob"]


# ------------------------------------------------------------ element search

def find_template_element(data, scan_from, uses_perm_index):
    """
    Walk the XML chunks and return the first <uses-permission> element that
    has exactly one attribute and is immediately followed by its END_ELEMENT.

    Returns (start_off, start_len, end_off, end_len, attr_off).
    """
    off = scan_from
    total = len(data)

    while off + 8 <= total:
        chunk_type = u16(data, off)
        chunk_size = u32(data, off + 4)
        if chunk_size <= 0:
            fail("zero-size chunk at offset %d (manifest is corrupt)" % off)

        if chunk_type == RES_XML_START_ELEMENT:
            name_index = u32(data, off + 20)
            attr_count = u16(data, off + 28)

            if name_index == uses_perm_index and attr_count == 1:
                end_off = off + chunk_size
                if u16(data, end_off) == RES_XML_END_ELEMENT:
                    end_len  = u32(data, end_off + 4)
                    attr_off = off + 16 + u16(data, off + 24)
                    return off, chunk_size, end_off, end_len, attr_off

        off += chunk_size

    fail("no single-attribute <uses-permission> element found to clone")


# --------------------------------------------------------------------- main

def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)

    src_path, dst_path = sys.argv[1], sys.argv[2]
    wanted = sys.argv[3:]

    data = bytearray(open(src_path, "rb").read())

    if u16(data, 0) != RES_XML_TYPE:
        fail("%s is not a binary AndroidManifest.xml" % src_path)

    pool = parse_string_pool(data, 8)
    if pool["flags"] & SORTED_FLAG:
        fail("string pool is SORTED; appending strings would corrupt it")

    strings = list(pool["strings"])
    already = set(strings)

    todo = []
    for perm in wanted:
        if perm in already:
            print("  already present, skipping: %s" % perm)
        else:
            todo.append(perm)

    if not todo:
        open(dst_path, "wb").write(bytes(data))
        print("  nothing to add")
        return

    if "uses-permission" not in strings:
        fail("'uses-permission' is not in the string pool")

    pool_end = pool["off"] + pool["chunk_size"]
    start_off, start_len, end_off, end_len, attr_off = find_template_element(
        data, pool_end, strings.index("uses-permission"))

    if data[attr_off + 15] != TYPE_STRING:
        fail("template attribute is not TYPE_STRING; refusing to clone it")

    # Both fields are rewritten to the new index below, so a template whose
    # rawValue was absent (0xFFFFFFFF) still yields a well-formed clone.
    if u32(data, attr_off + 8) == 0xFFFFFFFF:
        print("  note: template rawValue was absent; clone will set both fields")

    template_start = bytes(data[start_off:start_off + start_len])
    template_end   = bytes(data[end_off:end_off + end_len])
    attr_rel       = attr_off - start_off   # attribute offset within the chunk

    new_chunks = b""
    for perm in todo:
        index = len(strings)
        strings.append(perm)

        clone = bytearray(template_start)
        struct.pack_into("<I", clone, attr_rel + 8,  index)   # rawValue
        struct.pack_into("<I", clone, attr_rel + 16, index)   # typedValue.data
        new_chunks += bytes(clone) + template_end

        print("  + %s  (string index %d)" % (perm, index))

    # Reassemble: everything before the pool, the new pool, everything from
    # the old pool's end up to and including the template's END_ELEMENT, the
    # cloned elements, then the remainder of the file.
    out = bytearray()
    out += data[:pool["off"]]
    out += build_string_pool(pool, strings)
    out += data[pool_end:end_off + end_len]
    out += new_chunks
    out += data[end_off + end_len:]

    struct.pack_into("<I", out, 4, len(out))   # correct the total file size

    open(dst_path, "wb").write(bytes(out))
    print("  wrote %s (%d bytes)" % (dst_path, len(out)))


if __name__ == "__main__":
    main()
