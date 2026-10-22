#!/usr/bin/env python3
"""把 AppIcon.icns 里的每一层 PNG 用最优编码重压一遍（像素不变）。

为什么需要手工重写容器
----------------------
`iconutil -c icns` 拿到 iconset 后会**用自己的编码器重新编码**每个 PNG，
我们压好的数据被丢掉：实测 642 KB 的 iconset 打回去仍是 969 KB。所以这里
直接按 icns 的容器格式逐块改写——icns = 魔数 + 总长度 + 若干「4 字节类型 +
4 字节长度 + 数据」，其中 ic07–ic14 的数据就是 PNG，原样替换即可，条目顺序
与类型保持不变。

收益（0.13.5 实测）
------------------
992,502 B → 659,420 B（-325 KB，-33%），压缩后仍占下载包 0.33 MB。
最大的那层 icon_512x512@2x（1024px）单层就从 565 KB 降到 377 KB。

⚠️ 这是**无损**的：只换 PNG 的压缩编码，像素逐层比对必须完全一致，不一致
直接失败退出。不要在这里加调色板量化——图标有渐变，量化会出色带，而且实测
量化到 256 色只再省 1%，不值得。

依赖 Pillow（系统 python3 没有）：
    /Users/migor/.workbuddy/binaries/python/envs/default/bin/python \
        scripts/optimize_appicon.py

用法：
    python scripts/optimize_appicon.py            # 就地重写
    python scripts/optimize_appicon.py --check    # 只报告，不写
"""

from __future__ import annotations

import io
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ICNS = ROOT / "Sources/MEditor/Resources/AppIcon.icns"

PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


def parse(data: bytes) -> list[tuple[bytes, bytes]]:
    if data[:4] != b"icns":
        raise SystemExit("不是 icns 文件")
    declared = struct.unpack(">I", data[4:8])[0]
    if declared != len(data):
        raise SystemExit(f"icns 头声明 {declared} B，实际 {len(data)} B，文件已损坏")
    entries, off = [], 8
    while off < declared:
        kind = data[off : off + 4]
        length = struct.unpack(">I", data[off + 4 : off + 8])[0]
        if length < 8 or off + length > declared:
            raise SystemExit(f"{kind!r} 条目长度 {length} 越界")
        entries.append((kind, data[off + 8 : off + length]))
        off += length
    return entries


def main() -> int:
    check_only = "--check" in sys.argv
    try:
        from PIL import Image
    except ImportError:
        raise SystemExit("需要 Pillow：用 ~/.workbuddy/binaries/python/envs/default/bin/python 跑")

    raw = ICNS.read_bytes()
    entries = parse(raw)
    print(f"icns 原始 {len(raw):,} B，{len(entries)} 个条目")

    out: list[tuple[bytes, bytes]] = []
    before = after = 0
    for kind, payload in entries:
        before += len(payload)
        if not payload.startswith(PNG_MAGIC):
            out.append((kind, payload))     # 'info' / 'TOC ' 之类非 PNG 条目原样保留
            continue

        img = Image.open(io.BytesIO(payload))
        img.load()
        buf = io.BytesIO()
        img.save(buf, "PNG", optimize=True)
        new = buf.getvalue()

        # 像素必须完全一致——这是「无损」二字的全部依据
        again = Image.open(io.BytesIO(new))
        again.load()
        if img.size != again.size or img.mode != again.mode or img.tobytes() != again.tobytes():
            raise SystemExit(f"{kind.decode()} 重压后像素不一致，中止")

        after += len(new)
        out.append((kind, new))

    body = b"".join(k + struct.pack(">I", len(p) + 8) + p for k, p in out)
    rebuilt = b"icns" + struct.pack(">I", len(body) + 8) + body

    delta = len(raw) - len(rebuilt)
    print(f"PNG 载荷 {before:,} B → {after:,} B")
    print(f"整个 icns {len(raw):,} B → {len(rebuilt):,} B（省 {delta:,} B，{delta / len(raw):.0%}）")

    if delta <= 0:
        print("已经是最优编码，不改动")
        return 0
    if check_only:
        print("--check：不写入")
        return 0
    ICNS.write_bytes(rebuilt)
    print(f"已写入 {ICNS.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
