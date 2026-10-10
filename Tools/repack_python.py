"""Store pinned PyInstaller bytecode without inner compression for smaller DMGs.

All module bytes are preserved. PyInstaller's standard zlib reader still works;
the outer LZMA compressor can now share its dictionary across Python modules.
Archive layouts: PyInstaller/archive/{readers,writers}.py. Mach-O fixups follow
PyInstaller/utils/osx.py:fix_exe_for_code_signing (thin arm64 only).
"""
import hashlib
import marshal
from pathlib import Path
import struct
import subprocess
import sys
import zlib

COOKIE = struct.Struct('!8sIIII64s')
ENTRY = struct.Struct('!IIIIBc')
MAGIC = b'MEI\x0c\x0b\x0a\x0b\x0e'


def modules(archive):
    assert archive[:4] == b'PYZ\0', 'Unexpected Python archive'
    offset, = struct.unpack_from('!I', archive, 8)
    entries = marshal.loads(archive[offset:])
    return [(name, kind, zlib.decompress(archive[start:start + size]) if size else b'')
            for name, (kind, start, size) in entries]


def stored_archive(archive):
    original = modules(archive)
    result = bytearray(archive[:17])
    entries = []
    for name, kind, raw in original:
        stored = zlib.compress(raw, level=0) if raw else b''
        entries.append((name, (kind, len(result), len(stored))))
        result.extend(stored)
    struct.pack_into('!I', result, 8, len(result))
    result.extend(marshal.dumps(entries, 4))
    assert modules(result) == original, 'Python module bytes changed'
    return result


def repack(path):
    subprocess.run(['codesign', '--remove-signature', str(path)], check=True)
    original = path.read_bytes()
    assert original[:8] == bytes.fromhex('cffaedfe0c000001'), 'Expected thin arm64 Mach-O'
    cookie_at = original.rfind(MAGIC)
    assert cookie_at >= 0, 'PyInstaller cookie missing'
    magic, size, toc_offset, toc_size, version, library = COOKIE.unpack_from(original, cookie_at)
    start = cookie_at + COOKIE.size - size
    assert start > 0 and start + toc_offset + toc_size == cookie_at, 'Unexpected archive layout'
    toc = original[start + toc_offset:cookie_at]
    payload, entries = bytearray(), bytearray()
    position = 0
    replaced = 0
    while position < len(toc):
        length, offset, size, raw_size, compressed, kind = ENTRY.unpack_from(toc, position)
        assert length >= ENTRY.size and position + length <= len(toc)
        name = toc[position + ENTRY.size:position + length]
        data = original[start + offset:start + offset + size]
        if kind == b'z':
            assert name.rstrip(b'\0') == b'PYZ.pyz' and not compressed
            data = stored_archive(data)
            raw_size = len(data)
            replaced += 1
        entries.extend(ENTRY.pack(length, len(payload), len(data), raw_size, compressed, kind) + name)
        payload.extend(data)
        position += length
    assert replaced == 1, 'Expected exactly one Python archive'
    cookie = COOKIE.pack(magic, len(payload) + len(entries) + COOKIE.size,
                         len(payload), len(entries), version, library)
    result = bytearray(original[:start]) + payload + entries + cookie
    # Enlarged embedded archive is part of __LINKEDIT's string table, as in the
    # upstream bootloader. Restore header sizes before generating a new signature.
    position = 32
    fixed = set()
    for _ in range(struct.unpack_from('<I', result, 16)[0]):
        command, length = struct.unpack_from('<II', result, position)
        assert length >= 8 and position + length <= start
        assert command != 0x1d, 'Code signature must be removed before repacking'
        if command == 0x19 and result[position + 8:position + 24].rstrip(b'\0') == b'__LINKEDIT':
            file_offset, = struct.unpack_from('<Q', result, position + 40)
            file_size = len(result) - file_offset
            struct.pack_into('<Q', result, position + 32, (file_size + 0x3fff) & ~0x3fff)
            struct.pack_into('<Q', result, position + 48, file_size)
            fixed.add('segment')
        elif command == 2:
            string_offset, = struct.unpack_from('<I', result, position + 16)
            struct.pack_into('<I', result, position + 20, len(result) - string_offset)
            fixed.add('strings')
        elif command == 0x1b:
            result[position + 8:position + 24] = hashlib.sha256(result[position + 8:position + 24] + payload).digest()[:16]
        position += length
    assert fixed == {'segment', 'strings'}, 'Missing Mach-O archive headers'
    path.write_bytes(result)


if __name__ == '__main__':
    repack(Path(sys.argv[1]))
