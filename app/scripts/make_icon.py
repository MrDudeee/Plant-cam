"""Draws the 1024x1024 app icon (a leaf on green) with no outside libraries.

Usage: python3 make_icon.py path/to/icon.png
The build runs this, so no image file has to live in the repository.
"""
import math
import struct
import sys
import zlib

SIZE = 1024
BG = (0x2F, 0x6B, 0x2E)
LEAF = (0xB9, 0xDF, 0x9E)
RIB = (0x2F, 0x6B, 0x2E)

CX, CY = 558, 466          # leaf center
A, B = 300, 150            # leaf half-length and half-width
ANGLE = math.radians(45)   # leaf points up and to the right
COS, SIN = math.cos(ANGLE), math.sin(ANGLE)


def color_at(x, y):
    dx, dy = x - CX, y - CY
    u = dx * COS - dy * SIN      # along the leaf
    v = dx * SIN + dy * COS      # across the leaf
    inside = (u / A) ** 2 + (v / B) ** 2 <= 1.0
    if inside:
        if abs(v) < 9 and u > -A + 20:
            return RIB
        return LEAF
    if -A - 130 <= u <= -A + 10 and abs(v) < 16:
        return LEAF              # short stem
    return BG


def main(path):
    rows = []
    for y in range(SIZE):
        row = bytearray([0])     # PNG filter type 0
        for x in range(SIZE):
            row.extend(color_at(x, y))
        rows.append(bytes(row))
    raw = b"".join(rows)

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0))  # 8-bit RGB, no transparency
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "icon.png")
