#!/usr/bin/env python3
"""把 marked 里「分组上的无上界计数重复」展开成等价式（MEditor 本地补丁）。

## 为什么

JSC（WKWebView 的 JS 引擎）的 YARR 对 `(?:X){n,}` 这类**分组上的无上界计数
重复**会丢掉「只在位置 0 尝试匹配」的优化：匹配失败时引擎要沿整串走一遍。
实测（`jsc`，无匹配输入，`^ {0,3}(?:-[\\t ]*){3,}`）：

    30KB → 215µs     120KB → 865µs      （线性于输入长度）
    改成本脚本产出的等价式后 → 0.0µs

marked 每产出一个 block token，就把 ~12 条块规则对**剩余全文**各试一遍 ⇒
O(n²)。120KB 技术文档整篇解析：原版 1257ms、打完补丁 238ms，同一份 marked
在 V8（node）上只要 8.9ms —— 差距全在这一处。

`Tokenizer.prototype.list` 内部还会用模板现场拼出同样的 hr 家族正则，所以
补丁必须落在**源文件文本**上，不能只改 `Lexer.rules`。

## 等价性

`(?:X){3,}` → `(?:X)(?:X)(?:X)(?:X)*`：两者都表示「X 至少出现 3 次」。
`tests/MEditorTests/PreviewMarkedPatchTests.swift` 里有 12 万次差分模糊测试
（随机字符串上逐字比对旧式/新式的匹配结果），并有守卫用例断言补丁没被
marked 升级冲掉。

## 用法

    python3 scripts/patch_marked.py            # 就地打补丁（幂等）

升级 marked 后必须重跑本脚本，`PreviewMarkedPatchTests` 会在 CI 上红着提醒。
"""
import pathlib
import re
import sys

TARGET = pathlib.Path(__file__).resolve().parent.parent / (
    "Sources/MEditor/Resources/Preview/marked.min.js"
)

BANNER = (
    "/*! marked v12.0.2 | MIT | MEditor patch: expanded `(?:x){3,}` group quantifiers "
    "(JSC degenerates to an O(n) failure path) — regenerate with scripts/patch_marked.py */\n"
)

# 括号配对后判断分组是否属于 hr 家族（首个有效字符是 - _ \*）
HR_FAMILY = re.compile(r"^\\*[-_*]")


def _group_before(text: str, end: int):
    """返回以 text[end] == ')' 结尾的那个括号组的起始下标。"""
    depth = 0
    for i in range(end, -1, -1):
        ch = text[i]
        if ch == ")":
            depth += 1
        elif ch == "(":
            depth -= 1
            if depth == 0:
                return i
    return -1


def expand_group_quantifiers(text: str) -> tuple[str, int]:
    changed = 0
    cursor = 0
    while True:
        at = text.find("{3,}", cursor)
        if at == -1:
            break
        if at == 0 or text[at - 1] != ")":
            cursor = at + 4
            continue
        start = _group_before(text, at - 1)
        if start == -1:
            break
        group = text[start:at]
        body = group[1:-1]
        if body.startswith("?"):
            body = body.split(":", 1)[-1]
        body = body.lstrip()
        if not HR_FAMILY.match(body):
            cursor = at + 4
            continue
        replacement = group * 4 + "*"
        text = text[:start] + replacement + text[at + 4:]
        cursor = start + len(replacement)
        changed += 1
    return text, changed


def main() -> int:
    if not TARGET.exists():
        print(f"找不到 {TARGET}", file=sys.stderr)
        return 1
    original = TARGET.read_text(encoding="utf-8")
    body = original[len(BANNER):] if original.startswith(BANNER) else original

    patched, changed = expand_group_quantifiers(body)
    leftovers = [
        m.group(0)
        for m in re.finditer(r"\(\?:[^()]{0,24}\)\{\d+,\}", patched)
    ]
    if leftovers:
        print("仍有未展开的分组量词：" + ", ".join(leftovers), file=sys.stderr)
        return 1

    if changed == 0 and original.startswith(BANNER):
        print("已经是打过补丁的版本，无需改动")
        return 0

    TARGET.write_text(BANNER + patched, encoding="utf-8")
    print(f"展开 {changed} 处分组量词 → {TARGET.relative_to(TARGET.parents[4])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
