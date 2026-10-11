#!/usr/bin/env python3
# fixstubs.py [--write] <dll>...: in ARM64X/ARM64EC PE files, finds lld's x64 import thunks (FF 25 disp32, a bare
# "jmp [rip+disp32]") inside the image's x64 code ranges whose slot is in an import address table (or a delay-load
# one) and which are followed by padding, and (with --write) rewrites each as 48 FF 25 disp32-1: the same jump with a
# REX.W prefix, the form x64 Windows DLLs use for their import-forwarding stubs. A stub that ends its section's virtual
# size grows the section by the byte, within the section's raw data. Prints counts per file. A prototype for aoe2
# HANDOFF §4 item 5 (AoE2DE quits a few minutes after start); wine-arm64/tests/x64-exportstubs.c checks the result.
import struct, sys

def parse(d):
    pe = struct.unpack_from('<I', d, 0x3c)[0]
    machine, nsec = struct.unpack_from('<HH', d, pe + 4)
    optsize = struct.unpack_from('<H', d, pe + 20)[0]
    opt = pe + 24
    assert struct.unpack_from('<H', d, opt)[0] == 0x20b, 'not PE32+'
    imagebase = struct.unpack_from('<Q', d, opt + 24)[0]
    ndirs = struct.unpack_from('<I', d, opt + 108)[0]
    dirs = [struct.unpack_from('<II', d, opt + 112 + 8 * i) for i in range(ndirs)]
    secs = []
    for i in range(nsec):
        name, vsize, va, rsize, rptr = struct.unpack_from('<8sIIII', d, opt + optsize + 40 * i)
        secs.append((name.rstrip(b'\0').decode(), va, vsize, rptr, rsize, opt + optsize + 40 * i))
    return machine, imagebase, dirs, secs

def rva2off(secs, rva):
    for name, va, vsize, rptr, rsize, hdr in secs:
        if va <= rva < va + max(vsize, rsize):
            return rptr + rva - va if rva - va < rsize else None
    return None

def x64_ranges(d, imagebase, dirs, secs):
    lc_rva, lc_size = dirs[10]
    lc = rva2off(secs, lc_rva)
    if lc is None or lc_size < 0xd0 or struct.unpack_from('<I', d, lc)[0] < 0xd0:
        return [], []
    chpe_va = struct.unpack_from('<Q', d, lc + 0xc8)[0]
    if not chpe_va:
        return [], []
    m = rva2off(secs, chpe_va - imagebase)
    version, codemap, count = struct.unpack_from('<III', d, m)
    aux_iat = struct.unpack_from('<I', d, m + 44)[0]
    aux_iat_copy = struct.unpack_from('<I', d, m + 76)[0] if version >= 2 else 0
    ranges = []
    cm = rva2off(secs, codemap)
    for i in range(count):
        start, length = struct.unpack_from('<II', d, cm + 8 * i)
        if start & 3 == 2:  # AMD64
            ranges.append((start & ~3, (start & ~3) + length))
    return ranges, [a for a in (aux_iat, aux_iat_copy) if a]

def scan(path, write):
    d = bytearray(open(path, 'rb').read())
    machine, imagebase, dirs, secs = parse(d)
    ranges, aux = x64_ranges(d, imagebase, dirs, secs)
    if not ranges:
        print('%s: machine %x, no x64 code ranges, skipped' % (path, machine))
        return
    # import address tables: the IAT directory and the auxiliary IATs, sized like the IAT
    iat_rva, iat_size = dirs[12]
    tables = [(iat_rva, iat_rva + iat_size)] + [(a, a + iat_size) for a in aux]
    # and the delay-load import address tables, as one span from the first to past the last
    delay_rva, delay_size = dirs[13] if len(dirs) > 13 else (0, 0)
    dd = rva2off(secs, delay_rva) if delay_size else None
    spans = []
    while dd is not None and struct.unpack_from('<I', d, dd + 4)[0]:
        iat = struct.unpack_from('<I', d, dd + 12)[0]
        n = 0
        while struct.unpack_from('<Q', d, rva2off(secs, iat) + 8 * n)[0]:
            n += 1
        spans.append((iat, iat + 8 * (n + 1)))
        dd += 32
    if spans:
        tables.append((min(a for a, b in spans), max(b for a, b in spans)))
    found = fixed = nopad = 0
    # the parts of the x64 ranges that have file data, per section
    pieces = []
    for lo, hi in ranges:
        for i, (name, va, vsize, rptr, rsize, hdr) in enumerate(secs):
            a, b = max(lo, va), min(hi, va + min(vsize, rsize))
            if a < b:
                # a thunk may grow into the section's raw padding, short of the next section
                limit = min(va + rsize, secs[i + 1][1] if i + 1 < len(secs) else va + rsize)
                pieces.append((a, b, limit, va, hdr))
    grown = 0
    for lo, hi, sec_end, sec_va, sec_hdr in pieces:
        rva = lo
        while rva + 6 <= hi:
            off = rva2off(secs, rva)
            if d[off] == 0xff and d[off + 1] == 0x25 and (rva == lo or d[off - 1] != 0x48):
                disp = struct.unpack_from('<i', d, off + 2)[0]
                target = rva + 6 + disp
                if any(a <= target < b for a, b in tables):
                    found += 1
                    if rva + 7 <= sec_end and d[off + 6] in (0xcc, 0x90, 0x00):
                        if write:
                            d[off:off + 7] = b'\x48\xff\x25' + struct.pack('<i', disp - 1)
                            if rva + 7 > sec_va + struct.unpack_from('<I', d, sec_hdr + 8)[0]:
                                struct.pack_into('<I', d, sec_hdr + 8, rva + 7 - sec_va)
                                grown += 1
                        fixed += 1
                        rva += 7
                        continue
                    nopad += 1
                rva += 6
                continue
            rva += 1
    print('%s: x64 ranges %d, import thunks %d, %s %d, without padding %d, section grown %d' %
          (path, len(ranges), found, 'rewritten' if write else 'rewritable', fixed, nopad, grown))
    if write and fixed:
        open(path, 'wb').write(d)

write = '--write' in sys.argv
for p in [a for a in sys.argv[1:] if a != '--write']:
    scan(p, write)
