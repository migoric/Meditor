// 铰链几何的断言脚本。
//
// ## 为什么要单独跑
//
// iOS target 没有测试 target（`AGENTS.md` §3），而 `HingeLayout` 的取值全是纯几何计算——
// 这类代码最适合用断言钉住，不该只能靠「在真机上开合几次看看」。本文件把
// `Mobile/Sources/Theme/AdaptiveChrome.swift` 直接编进一个 macOS 命令行程序来跑，
// 不依赖模拟器、不依赖 Xcode 工程。
//
// ## 跑法
//
// ```bash
// swiftc -parse-as-library -O \
//   Mobile/Sources/Theme/AdaptiveChrome.swift scripts/verify_hinge_math.swift \
//   -o /tmp/verify_hinge_math && /tmp/verify_hinge_math
// ```
//
// 退出码非 0 = 断言失败。

import Foundation

@main
struct VerifyHingeMath {
    static func main() {
        var failures = 0

        func check(_ name: String, _ actual: String, _ expected: String) {
            if actual == expected {
                print("  ok   \(name) → \(actual)")
            } else {
                failures += 1
                print("  FAIL \(name) → 实际 \(actual)，期望 \(expected)")
            }
        }

        func spans(_ width: CGFloat, _ dividers: [ClosedRange<CGFloat>]) -> String {
            let result = AdaptiveChrome.freeSpans(width: width, dividers: dividers)
            return "[" + result.map { "\(fmt($0.lowerBound))–\(fmt($0.upperBound))" }.joined(separator: ",") + "]"
        }

        func chrome(_ width: CGFloat, _ dividers: [ClosedRange<CGFloat>]) -> String {
            var layout = HingeLayout(containerWidth: width)
            layout.dividers = dividers
            let span = layout.chromeSpan(cap: AdaptiveChrome.actionBar)
            return "w=\(fmt(span.width)) off=\(fmt(span.offset))"
        }

        print("freeSpans：切分与合并")
        check("无铰链", spans(1000, []), "[0–1000]")
        check("宽度 0（首帧未布局）", spans(0, []), "[]")
        check("单铰链居中", spans(1000, [480...520]), "[0–480,520–1000]")
        check("单铰链偏左", spans(1000, [400...480]), "[0–400,480–1000]")
        check("两个铰链", spans(1000, [300...340, 700...740]), "[0–300,340–700,740–1000]")
        check("相交铰链合并", spans(1000, [400...480, 450...520]), "[0–400,520–1000]")
        check("贴左边缘的铰链", spans(1000, [0...40]), "[40–1000]")
        check("贴右边缘的铰链", spans(1000, [960...1000]), "[0–960]")
        check("越界铰链被裁剪", spans(1000, [900...1200]), "[0–900]")
        check("完全覆盖（退化）", spans(1000, [0...1000]), "[]")

        print("chromeSpan：封顶、避让与横移")
        check("无铰链时与改动前等价", chrome(1000, []), "w=620 off=0")
        check("窄屏无铰链", chrome(402, []), "w=620 off=0")
        check("偏左铰链 → 移到右侧大块", chrome(1000, [400...480]), "w=496 off=240")
        check("居中铰链 → 等宽取左侧", chrome(1000, [480...520]), "w=456 off=-260")
        check("半折（670pt 内屏）", chrome(670, [500...520]), "w=476 off=-85")
        check("右铰链贴边 → 留在左侧", chrome(670, [200...640]), "w=176 off=-235")

        print("HingeLayout：无铰链时的退化")
        let empty = HingeLayout(containerWidth: 402)
        check("isSplit", "\(empty.isSplit)", "false")
        check("widestSpan", "\(fmt(empty.widestSpan.lowerBound))–\(fmt(empty.widestSpan.upperBound))", "0–402")
        let unmeasured = HingeLayout.none
        check("首帧未布局也不位移", "w=\(fmt(unmeasured.chromeSpan(cap: 620).width)) off=\(fmt(unmeasured.chromeSpan(cap: 620).offset))", "w=620 off=0")

        if failures > 0 {
            print("\n\(failures) 条断言失败")
            exit(1)
        }
        print("\n全部通过")
    }

    private static func fmt(_ value: CGFloat) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }
}
