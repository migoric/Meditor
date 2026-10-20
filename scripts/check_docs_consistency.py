#!/usr/bin/env python3
"""文档一致性守卫：让文档里的断言可被机械验证。

## 为什么需要这个脚本

这套文档已经出现过至少四处「权威文档写着与事实相反的东西」：

1. `AGENTS.md` 说 main 受保护，`docs/engineering-practices.md` 同一时期写
   `protected: false` —— 两份都算权威，读者只能二选一。
2. `.swiftlint.yml` 头部说「warning 可见但不阻塞」，CI 跑的却是 `--strict`。
3. `docs/design-as-built.md` 头部写「对应 macOS 端 0.8.x」，而 `VERSION` 是 0.13.0。
4. `AGENTS.md` 三处引用「深度 review 报告 P1」，而那份报告不在仓里。

人读是防不住的：文档写完就没人再读第二遍，改了代码也不会回头改描述。所以只留
能机械判定的那几条，交给 CI。判不了的（比如「架构描述是否还准确」）不硬凑。

## 检查项

1. `VERSION` 与 `docs/design-as-built.md` 头部「对应 macOS 端 X」的次版本号一致。
2. 文档里以反引号标注的**仓内路径**必须存在（`docs/*.md`、`scripts/*`、
   `Sources/*`、`.github/*` 等；glob、绝对路径、`.build` 一律跳过）。
3. 反引号标注的 **CI 检查名**（形如 `X (Y)`）必须是某个 workflow 的真实 job `name:`。
   这条专门防「改了 job 名 → 文档还写着旧名 → 新人按文档配必需检查 → PR 卡死」。
4. 若任何 workflow 对 swiftlint 用 `--strict`，`.swiftlint.yml` 不得再声称
   「warning 不阻塞」。

退出码 0 = 通过，1 = 有违规（每条都会打印文件:行号）。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# 会被检查「路径存在性」的文档。README 也纳入：它对外，写错代价最高。
DOC_FILES = [
    "AGENTS.md",
    "CONTRIBUTING.md",
    "README.md",
    "README.zh.md",
    "docs/design-as-built.md",
    "docs/engineering-practices.md",
]

BACKTICK = re.compile(r"`([^`\n]+)`")
# 看起来像仓内相对路径：以已知顶层目录开头，且不像命令（无空格、不含通配/占位符）。
PATH_TOKENS = re.compile(
    r"^(?:\./)?(?:docs|scripts|Sources|Mobile|Tests|\.github|website|worker|pages)/[^\s`]+$"
)
SIMPLE_FILES = {"CHANGELOG.md", "AGENTS.md", "CONTRIBUTING.md", "README.md", "README.zh.md", "VERSION"}
# CI 检查名：`Build & Test (macOS 26)` 这种「名字 + 括号」的形态。
# 不带括号的（SwiftLint / Coverage Gate）故意不在此列——它们经常出现在
# 「曾经是独立 job」的叙述里，检查它们只会制造噪音。
CHECK_NAME = re.compile(r"^(.+?) \(([^)]+)\)$")


def fail(errors: list[str], where: str, msg: str) -> None:
    errors.append(f"{where}: {msg}")


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def workflow_job_names() -> set[str]:
    """抓出所有 workflow 的 job `name:`（没有 name 的用 job id）。"""
    names: set[str] = set()
    for wf in sorted((ROOT / ".github/workflows").glob("*.yml")):
        text = wf.read_text(encoding="utf-8")
        names.update(re.findall(r"^\s{2,4}name:\s*(.+?)\s*$", text, re.MULTILINE))
    return {n.strip().strip("'\"") for n in names}


def check_version(errors: list[str]) -> None:
    version = read("VERSION").strip()
    doc = read("docs/design-as-built.md")
    m = re.search(r"对应 macOS 端\s*([0-9]+\.[0-9]+)(?:\.\w+)?", doc)
    if not m:
        fail(errors, "docs/design-as-built.md", "头部找不到「对应 macOS 端 X.Y」版本标记")
        return
    doc_minor = m.group(1)
    ver_minor = ".".join(version.split(".")[:2])
    if doc_minor != ver_minor:
        fail(
            errors,
            "docs/design-as-built.md",
            f"头部写「对应 macOS 端 {doc_minor}」，而 VERSION 是 {version} —— 现状文档已经落后于代码",
        )


def check_paths(errors: list[str]) -> None:
    for doc in DOC_FILES:
        path = ROOT / doc
        if not path.exists():
            fail(errors, doc, "文件不存在（DOC_FILES 里登记了它）")
            continue
        for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            for token in BACKTICK.findall(line):
                token = token.strip().rstrip(".,;:）)")
                if not token:
                    continue
                if any(ch in token for ch in "*{}<>$|\\"):
                    continue
                if token.endswith("…") or "…" in token:   # 省略号是占位，不是路径
                    continue
                if token.startswith(("/", "~", ".build", "http")):
                    continue
                candidate = token in SIMPLE_FILES or PATH_TOKENS.match(token)
                if not candidate:
                    continue
                if not (ROOT / token).exists():
                    fail(errors, f"{doc}:{lineno}", f"引用了不存在的路径 `{token}`")


def check_ci_job_names(errors: list[str]) -> None:
    real = workflow_job_names()
    for doc in DOC_FILES:
        path = ROOT / doc
        if not path.exists():
            continue
        for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            for token in BACKTICK.findall(line):
                if not CHECK_NAME.match(token):
                    continue
                if token not in real:
                    fail(
                        errors,
                        f"{doc}:{lineno}",
                        f"文档里的 CI 检查名 `{token}` 不是任何 workflow 的 job name"
                        f"（现有：{sorted(real)}）",
                    )


def check_swiftlint_claim(errors: list[str]) -> None:
    workflows = "\n".join(
        wf.read_text(encoding="utf-8") for wf in (ROOT / ".github/workflows").glob("*.yml")
    )
    if "--strict" not in workflows:
        return
    yml = (ROOT / ".swiftlint.yml").read_text(encoding="utf-8")
    for lineno, line in enumerate(yml.splitlines(), 1):
        if "warning" in line and ("不阻塞" in line or "non-blocking" in line):
            fail(
                errors,
                f".swiftlint.yml:{lineno}",
                "声称 warning 不阻塞，但 CI 用 `swiftlint lint --strict`（warning 会让它变红）",
            )


def main() -> int:
    errors: list[str] = []
    check_version(errors)
    check_paths(errors)
    check_ci_job_names(errors)
    check_swiftlint_claim(errors)

    if errors:
        print(f"✗ 文档一致性守卫失败（{len(errors)} 条）：\n", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        print(
            "\n修法：改文档使其与代码一致，或改代码使其与文档一致——但别让两者继续说不同的话。",
            file=sys.stderr,
        )
        return 1

    print("✓ 文档一致性守卫通过（版本号 / 路径引用 / CI 检查名 / swiftlint 声明）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
