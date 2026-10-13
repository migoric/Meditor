#!/usr/bin/env python3
"""Guard the iOS shell's cross-platform shared set.

背景
----
iOS 工程（Mobile/MEditorMobile.xcodeproj）里有两类源码：

  1. Mobile/Sources/**  —— 用 PBXFileSystemSynchronizedRootGroup 自动同步，
     往目录里丢文件就自动进 target，不需要改工程文件。
  2. ../Sources/MEditor/** —— 手工枚举的 49 条（39 个 .swift + 10 个预览资源；
     Shared 组 + PBXFileReference + PBXBuildFile）。macOS 桌面端新增文件后，
     **必须手工把这 49 条清单同步**，否则 iOS target 要么编不过、要么静默少编译一个文件。

第 2 条是历史上"iOS 编译兜底"提交的来源，也是这个脚本要守的东西。
它不追求自动发现"某个新文件应该被共享"（那需要业务判断），而是保证
**工程文件与磁盘、工程文件与编译阶段三者自洽**，并把容易踩的 macOS-only
符号挡在共享文件之外。

检查项
------
  A. 每条 ../Sources/... 引用在磁盘上存在（防重命名/删除后残留）
  B. 无重复引用
  C. Shared 组的 children 与全部引用集合一致（无孤儿引用/未入组的引用）
  D. 共享 .swift 出现在 Sources 编译阶段；共享 .js/.css/.html 出现在 Resources
  E. 共享 .swift 里的 macOS-only 符号必须包在 #if os(macOS) 里
  F. 共享 .swift 不得读 AppSettings（只允许作函数签名类型）——iOS 上
     AppSettings 是替身，读它拿到的是假值，且不报错

用法：
    python3 scripts/check_ios_shared_sources.py [--project Mobile/MEditorMobile.xcodeproj]
退出码 0 = 通过，1 = 有问题。
"""
import argparse
import os
import re
import sys

# macOS-only 符号：出现在共享 .swift 里就必须处于 #if os(macOS) 区块中。
MACOS_ONLY_SYMBOLS = (
    "import AppKit",
    "NSApp",
    "NSWorkspace",
    "NSScreen",
    "NSApplication",
    "homeDirectoryForCurrentUser",
)

SWIFT_SUFFIX = ".swift"
RESOURCE_SUFFIXES = (".js", ".css", ".html")


def read_project(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def source_root(project_path):
    """Directory the project's relative paths are resolved against ($(SRCROOT)).

    The .xcodeproj lives in SRCROOT, and file paths are relative to it
    (`../Sources/MEditor/x.swift` therefore means `<repo>/Sources/MEditor/x.swift`).
    """
    directory = os.path.dirname(os.path.abspath(project_path))
    while directory != "/" and not directory.endswith(".xcodeproj"):
        directory = os.path.dirname(directory)
    return os.path.dirname(directory)


def parse_refs(text):
    """Return (refs, group_children).

    refs          : {relative_path: [object ids]} from PBXFileReference section
    group_children: [relative_path] listed under the Shared PBXGroup

    ⚠️ `path` 有时带引号（`path = "../Sources/.../FileManager+Directories.swift"`）——
    文件名带 `+` 时 Xcode 会加引号。只匹配无引号形式会静默漏掉这类条目，
    历史上就因此把 39 个共享 .swift 数成了 38 个。
    """
    refs = {}
    for match in re.finditer(
        r"^\s*([0-9A-F]{24})\s*/\*[^*]*\*/\s*=\s*\{isa = PBXFileReference;"
        r"[^}]*?path = \"?([^\";]+)\"?;",
        text,
        re.MULTILINE,
    ):
        obj_id, path = match.group(1), match.group(2)
        if "../Sources/" not in path:
            continue
        refs.setdefault(path, []).append(obj_id)

    # 逐个 PBXGroup 解析，取 name = Shared 的那个（不能从第一个 children 懒匹配，
    # 那会跨到前面 root group 的 children 上）。
    group_children = []
    for group in re.finditer(
        r"isa = PBXGroup;\s*\n\s*children = \(\n(.*?)\n\s*\);\s*\n\s*name = ([^;]+);",
        text,
        re.DOTALL,
    ):
        if group.group(2).strip() != "Shared":
            continue
        group_children = [
            name for name in re.findall(r"/\* ([^*]+) \*/", group.group(1))
            if "../Sources/" in name
        ]
    return refs, group_children


def parse_build_phases(text):
    """Return {phase_name: set(relative paths)} for the PBXBuildFile entries.

    PBXBuildFile lines look like:
      <id> /* ../Sources/MEditor/x.swift in Sources */ = {isa = PBXBuildFile; fileRef = <ref> /* ../Sources/MEditor/x.swift */; };
    """
    phases = {}
    for match in re.finditer(
        r"^\s*[0-9A-F]{24}\s*/\* ([^*]+?) in ([A-Za-z]+) \*/\s*=\s*\{isa = PBXBuildFile;",
        text,
        re.MULTILINE,
    ):
        path, phase = match.group(1), match.group(2)
        if "../Sources/" not in path:
            continue
        phases.setdefault(phase, set()).add(path)
    return phases


def macos_only_regions(source):
    """Yield (line_number, text, in_macos_only_region) for each line.

    `#if os(macOS)` 区块判定用栈：只要有一层 #if 的条件里出现 os(macOS)，
    其内部所有行都算 macOS-only。够用即可——这里防的是"漏包 #if"。
    """
    stack = []
    for number, line in enumerate(source.splitlines(), start=1):
        stripped = line.strip()
        if stripped.startswith("#if"):
            stack.append("os(macOS)" in stripped.replace(" ", ""))
            yield number, line, any(stack[:-1]) or stack[-1]
            continue
        if stripped.startswith("#elseif"):
            if stack:
                stack[-1] = "os(macOS)" in stripped.replace(" ", "")
            yield number, line, any(stack)
            continue
        if stripped.startswith("#else"):
            if stack:
                stack[-1] = False
            yield number, line, any(stack)
            continue
        if stripped.startswith("#endif"):
            if stack:
                stack.pop()
            yield number, line, any(stack)
            continue
        yield number, line, any(stack)


def strip_trailing_comment(line):
    """Drop a trailing `//` comment.

    只在 `//` 前面是行首或空白时才当成注释——否则 `https://…` 这类字符串字面量
    会被误截断（截断本身是"漏报"方向，但没必要引入）。
    """
    for index in range(len(line) - 1):
        if line[index:index + 2] != "//":
            continue
        if index == 0 or line[index - 1] in " \t":
            return line[:index]
    return line


def is_type_only_appsettings_use(line):
    """True when every AppSettings occurrence on the line is a type annotation.

    Shared code is allowed to *name* AppSettings in a function signature
    (`_ settings: AppSettings`); it must never touch the global (`.shared`),
    construct one, or read a member off it.
    """
    code = strip_trailing_comment(line)
    for match in re.finditer(r"AppSettings", code):
        prefix = code[: match.start()].rstrip()
        if not prefix.endswith(":") and not prefix.endswith("(") and not prefix.endswith(","):
            return False
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--project", default="Mobile/MEditorMobile.xcodeproj/project.pbxproj")
    args = parser.parse_args()

    if not os.path.exists(args.project):
        print("ERROR: 找不到工程文件 %s" % args.project)
        return 1

    text = read_project(args.project)
    root = source_root(args.project)
    refs, group_children = parse_refs(text)
    phases = parse_build_phases(text)

    problems = []

    def on_disk(path):
        return os.path.exists(os.path.normpath(os.path.join(root, path)))

    # A. 引用必须落盘
    for path in sorted(refs):
        if not on_disk(path):
            problems.append("[A] 工程引用了不存在的文件：%s（源文件被改名/删除后残留）" % path)

    # B. 无重复引用
    for path, ids in sorted(refs.items()):
        if len(ids) > 1:
            problems.append("[B] 同一路径被引用 %d 次：%s（%s）" % (len(ids), path, ", ".join(ids)))

    # C. Shared 组与引用集合一致
    referenced = set(refs)
    listed = set(group_children)
    for path in sorted(referenced - listed):
        problems.append("[C] 有引用但不在 Shared 组里：%s" % path)
    for path in sorted(listed - referenced):
        problems.append("[C] Shared 组里列了但没有对应 PBXFileReference：%s" % path)

    # D. 编译阶段归属正确
    compiled_sources = phases.get("Sources", set())
    compiled_resources = phases.get("Resources", set())
    for path in sorted(referenced):
        if path.endswith(SWIFT_SUFFIX):
            if path not in compiled_sources:
                problems.append(
                    "[D] 共享 .swift 不在 Sources 编译阶段（会静默不被编译）：%s" % path)
        elif path.endswith(RESOURCE_SUFFIXES):
            if path not in compiled_resources:
                problems.append("[D] 共享资源不在 Resources 编译阶段：%s" % path)

    # E/F. 共享文件里的 macOS-only 符号与 AppSettings 读取
    shared_swift = sorted(p for p in referenced if p.endswith(SWIFT_SUFFIX))
    for path in shared_swift:
        if not on_disk(path):
            continue  # 已在 A 里报过
        with open(os.path.normpath(os.path.join(root, path)), encoding="utf-8") as handle:
            source = handle.read()
        for number, line, in_macos_only in macos_only_regions(source):
            code = strip_trailing_comment(line)
            if not code.strip():
                continue  # 纯注释行：文档里提到符号名不算使用
            if "AppSettings" in code and not is_type_only_appsettings_use(code):
                problems.append(
                    "[F] %s:%d 读了 AppSettings（iOS 上是假替身，读它拿到假值且不报错）：%s"
                    % (path, number, line.strip()))
            if in_macos_only:
                continue
            for symbol in MACOS_ONLY_SYMBOLS:
                if symbol in code:
                    problems.append(
                        "[E] %s:%d 使用了 macOS-only 符号 `%s`，但没有包在 #if os(macOS) 里：%s"
                        % (path, number, symbol, line.strip()))

    print("iOS 共享集：%d 条引用（%d 个 .swift + %d 个资源）"
          % (len(referenced), len(shared_swift), len(referenced) - len(shared_swift)))
    if problems:
        print("")
        for problem in problems:
            print(problem)
        print("")
        print("IOS SHARED SOURCE GUARD FAILED: %d 项" % len(problems))
        return 1
    print("iOS shared source guard passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
