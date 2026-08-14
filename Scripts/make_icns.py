#!/usr/bin/env python3
"""Упаковывает стандартный .iconset в ICNS без внешних библиотек.

ICNS состоит из заголовка и именованных PNG-блоков. Скрипт служит запасным
путём для версий iconutil, которые ошибочно отвечают `Invalid Iconset`.
"""

from pathlib import Path
import struct
import sys


CHUNKS = (
    ("icp4", "icon_16x16.png"),
    ("ic11", "icon_16x16@2x.png"),
    ("icp5", "icon_32x32.png"),
    ("ic12", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic13", "icon_128x128@2x.png"),
    ("ic08", "icon_256x256.png"),
    ("ic14", "icon_256x256@2x.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"),
)


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: make_icns.py INPUT.iconset OUTPUT.icns")

    source, output = Path(sys.argv[1]), Path(sys.argv[2])
    blocks = []
    for kind, name in CHUNKS:
        payload = (source / name).read_bytes()
        if not payload.startswith(b"\x89PNG\r\n\x1a\n"):
            raise SystemExit(f"{name}: ожидался PNG")
        blocks.append(kind.encode("ascii") + struct.pack(">I", len(payload) + 8) + payload)

    body = b"".join(blocks)
    output.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
    print(f"ICNS: {output} ({len(body) + 8} байт)")


if __name__ == "__main__":
    main()
