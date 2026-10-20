#!/usr/bin/env python3
"""裸数值棘轮：设计 token 的采纳率只许变好，不许变差。

## 为什么只做棘轮，不做大改

`docs/design-as-built.md` 声称「组件规范已 token 化」，实测采纳率是：

    字体    `.system(size:` 528 处  vs  `DS.Font`  39 处   → 基本没收
    间距    数字 padding   495 处  vs  `DS.Space` 103 处   → 基本没收
    圆角    `cornerRadius:` 14 个不同值，而 `DS.Radius` 只定义 5 档
    动效    `DS.Motion` 86 处                               → 真正收口了
    抬升    `dsElevation` 24 处 + `DS.Elevation` 3 处        → 真正收口了

把 528 处字体一次性改成 token 会让整个 App 的排版同时变样，而这类改动没法靠单测
验证（`Views` 覆盖率 ~2%）。所以这里只钉住三件能机械判定的事：

1. **不同字号档位数**不许变多（把半磅值 9.5/10.5/11.5/12.5/13.5 已经并掉，
   25 → 20 档）
2. **裸 `.system(size:)` 调用数**不许变多
3. **不同圆角值个数**不许变多

新代码请优先用 `DS.Font` / `DS.Space` / `DS.Radius`；确实需要裸数值时，
说明你不是在让状况变坏——棘轮只拦「更多」，不拦「更少」。

## 怎么降基线

改完之后直接跑本脚本，它会把当前值打出来；把 `BASELINE` 里的数字改成实测值即可。
**只许改小**：调大等于给自己开后门，review 时会被抓。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources/MEditor"

# 当前实测值。只许改小（见文件头「怎么降基线」）。
BASELINE = {
    "distinct_font_sizes": 20,
    "bare_system_font": 516,
    "distinct_radii": 14,
    # `try?` 棘轮：全仓 253 处 `try?` vs 105 处 `} catch`，但逐个数没有意义
    # （很多 `try?` 是在合法地忽略「删不存在的文件」这类无意义失败）。只钉住两条
    # 最容易吞掉真错误的路径：落盘与预览资源。
    # 典型受害者：TemplateStore 写模板元数据时 `try? encode` + `try? write`，
    # 写失败完全无声。
    "silent_try_optional": 60,
}

FONT = re.compile(r"\.system\(size:\s*([0-9]+(?:\.[0-9]+)?)")
RADIUS = re.compile(r"cornerRadius:\s*([0-9]+(?:\.[0-9]+)?)")
TRY_OPTIONAL = re.compile(r"\btry\?")
SILENT_PATHS = ("Services/Storage", "Services/Preview")


def scan() -> dict[str, int]:
    fonts: list[str] = []
    radii: list[str] = []
    silent = 0
    for path in SOURCES.rglob("*.swift"):
        text = path.read_text(encoding="utf-8")
        fonts.extend(FONT.findall(text))
        radii.extend(RADIUS.findall(text))
        rel = path.relative_to(SOURCES).as_posix()
        if rel.startswith(SILENT_PATHS):
            silent += len(TRY_OPTIONAL.findall(text))
    return {
        "distinct_font_sizes": len(set(fonts)),
        "bare_system_font": len(fonts),
        "distinct_radii": len(set(radii)),
        "silent_try_optional": silent,
    }


def main() -> int:
    current = scan()
    regressions = [
        (key, base, current[key])
        for key, base in BASELINE.items()
        if current[key] > base
    ]

    print("裸数值棘轮（当前 / 基线）：")
    for key in BASELINE:
        mark = "✗" if current[key] > BASELINE[key] else "✓"
        print(f"  {mark} {key:<22} {current[key]:>4} / {BASELINE[key]}")

    if regressions:
        print("\n✗ 新增了裸数值调用：", file=sys.stderr)
        for key, base, cur in regressions:
            print(f"  - {key}: {base} → {cur}（多了 {cur - base}）", file=sys.stderr)
        print(
            "\n修法：新代码用 DS.Font / DS.Space / DS.Radius；"
            "确实要加裸值就先把这个数字降回去。",
            file=sys.stderr,
        )
        return 1

    lowered = [
        (key, BASELINE[key], current[key])
        for key in BASELINE
        if current[key] < BASELINE[key]
    ]
    if lowered:
        print("\n提示：实测已低于基线，可以把 BASELINE 改小以锁住收益：")
        for key, base, cur in lowered:
            print(f"  - {key}: {base} → {cur}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
