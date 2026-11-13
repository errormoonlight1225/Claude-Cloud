#!/usr/bin/env python3
"""Mark the arm64e slice of a Mach-O as new-ABI (CPU_SUBTYPE_PTRAUTH_ABI).

Open-source clang/ld64 on Linux emit pointer-authenticated arm64e code but do
not set the ABI flag, so dyld on iOS 14+ treats the slice as the unsupported
"old" arm64e ABI. Re-sign the binary after running this.
"""
import struct, sys

CPU_TYPE_ARM64 = 0x0100000C
CPU_SUBTYPE_ARM64E = 2
PTRAUTH_ABI = 0x80000000
MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC, FAT_MAGIC_64 = 0xCAFEBABE, 0xCAFEBABF

def patch_thin(buf, off):
    magic, cputype, subtype = struct.unpack_from("<III", buf, off)
    if magic != MH_MAGIC_64 or cputype != CPU_TYPE_ARM64 or (subtype & 0xFF) != CPU_SUBTYPE_ARM64E:
        return False
    struct.pack_into("<I", buf, off + 8, (subtype & 0x00FFFFFF) | PTRAUTH_ABI)
    return True

def main(path):
    buf = bytearray(open(path, "rb").read())
    patched = 0
    magic = struct.unpack_from(">I", buf, 0)[0]
    if magic in (FAT_MAGIC, FAT_MAGIC_64):
        n = struct.unpack_from(">I", buf, 4)[0]
        size = 20 if magic == FAT_MAGIC else 32
        for i in range(n):
            ent = 8 + i * size
            cputype, subtype = struct.unpack_from(">II", buf, ent)
            off = struct.unpack_from(">I" if magic == FAT_MAGIC else ">Q", buf, ent + 8)[0]
            if cputype == CPU_TYPE_ARM64 and (subtype & 0xFF) == CPU_SUBTYPE_ARM64E:
                struct.pack_into(">I", buf, ent + 4, (subtype & 0x00FFFFFF) | PTRAUTH_ABI)
                patched += patch_thin(buf, off)
    else:
        patched += patch_thin(buf, 0)
    open(path, "wb").write(buf)
    print(f"fix_arm64e_abi: patched {patched} arm64e slice(s) in {path}")

if __name__ == "__main__":
    main(sys.argv[1])
