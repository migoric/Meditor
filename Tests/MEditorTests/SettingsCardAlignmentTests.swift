import XCTest
import SwiftUI
@testable import MEditor

/// 设置页卡片对齐守卫。
///
/// 为什么需要它：0.13.10 的记忆面板里，「项目约定」那张卡片比下面「记忆」那张窄一半、
/// 还被推到中间去（截图量出来中心线重合、宽度一为 774 一为 993）。成因不是宽度不够，
/// 而是**卡片宽度由内容撑**：节里只有一行短文字时 `Text` 只取固有宽度，卡片跟着缩窄，
/// 再被外层 `VStack(spacing: 0)` 的默认 `.center` 对齐居中。这类失效在纯值测试里看不见，
/// 只能真的排一次版再量像素。
///
/// 做法：用 `ImageRenderer` 离屏栅格化**真实的 `settingsGroup`**（不是仿写的副本），
/// 在像素上量两张卡片的左右边界。变异验证过：把 `settingsGroup` 里那句
/// `.frame(maxWidth: .infinity, alignment: .leading)` 删掉，本用例立刻转红
/// （左边线差 459 px、宽度差 917 px）。
///
/// 只在浅色外观下判：卡片填充是动态色（深色下是 0.16 灰），拿不到纯白就没法按像素分割，
/// 这时如实 `XCTSkip`，不假装通过。
@MainActor
final class SettingsCardAlignmentTests: XCTestCase {

    private struct Probe: View {
        var body: some View {
            VStack(spacing: 0) {
                // 内容只有一行短文字 —— 复现「还没有约定」那节
                SettingsView().settingsGroup(title: "项目约定（人写的）") {
                    Text("还没有约定。在 MEDITOR.md 里加一段「## 约定」，agent 每轮都会遵守。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                }
                // 内容自己撑满 —— 复现「还没有记忆」那节
                SettingsView().settingsGroup(title: "记忆 (0)") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("还没有记忆").font(.system(size: 12, weight: .medium))
                        Text("agent 会用 save_memory 记下长期成立的规则与术语。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
            }
            .padding(16)
            .frame(width: 900)
            .background(Color(white: 0.95))
            .environment(\.colorScheme, .light)
        }
    }

    func test_shortSectionCardFillsSameWidthAsFullSection() throws {
        let renderer = ImageRenderer(content: Probe())
        renderer.scale = 2
        let cg = try XCTUnwrap(renderer.cgImage, "ImageRenderer 没产出图像")
        let rep = try XCTUnwrap(NSBitmapImageRep(data: NSImage(cgImage: cg, size: .zero).tiffRepresentation ?? Data()),
                                "取不到位图")
        let w = rep.pixelsWide, h = rep.pixelsHigh

        /// 卡片填充是纯白（浅色外观）。取整行白色像素的**最左与最右**，
        /// 不能取「连续段」——文字笔画会把白色切断，量到的是字间空白。
        func cardRow(_ y: Int) -> (left: Int, right: Int)? {
            var left = -1, right = -1, count = 0
            for x in 0..<w {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if c.redComponent > 0.99, c.greenComponent > 0.99, c.blueComponent > 0.99 {
                    count += 1
                    if left < 0 { left = x }
                    right = x
                }
            }
            // 阈值放宽到 1/5：卡片窄了一半时也要能量到，否则只会得到「少了一张卡片」这种
            // 不说明问题的失败。
            guard count > w / 5 else { return nil }
            return (left, right)
        }

        var groups: [(y0: Int, y1: Int, left: Int, right: Int)] = []
        for y in stride(from: 0, to: h, by: 2) {
            guard let row = cardRow(y) else { continue }
            // 间距放宽到 40 px（20 pt）：卡片内部的文字行可能整行都不够白而被跳过，
            // 阈值太小时一张卡片会被劈成两段。两张卡片之间隔着标题，> 40 px，不会误并。
            if let last = groups.last, y - last.y1 <= 40 {
                // 取整张卡片的极值：单行会落在圆角或文字上，不能拿最后一行的值。
                groups[groups.count - 1] = (last.y0, y,
                                            min(last.left, row.left),
                                            max(last.right, row.right))
            } else {
                groups.append((y, y, row.left, row.right))
            }
        }

        let desc = groups.map { "[\($0.left)..\($0.right)]" }.joined(separator: " ")
        if groups.isEmpty {
            // 一张浅色卡片都量不到 ⇒ 外观不是浅色（卡片填 0.16 灰），如实跳过。
            throw XCTSkip("量不到浅色卡片（当前外观可能不是浅色），跳过对齐守卫")
        }
        XCTAssertEqual(groups.count, 2, "应当量到两张卡片，实际：\(desc)")
        guard groups.count == 2 else { return }

        let a = groups[0], b = groups[1]
        XCTAssertEqual(Double(a.left), Double(b.left), accuracy: 6,
                       "两张卡片左边线必须对齐（内容短的那张被居中缩窄了）")
        XCTAssertEqual(Double(a.right - a.left), Double(b.right - b.left), accuracy: 6,
                       "两张卡片宽度必须一致：内容多寡不能改变卡片宽度")
    }
}
