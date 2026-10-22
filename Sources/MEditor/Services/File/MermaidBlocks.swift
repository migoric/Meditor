import Foundation

/// 从 Markdown 文本提取 ```mermaid 围栏代码块（开栏行号 + 代码内容）。
///
/// **围栏配对按 CommonMark 规则逐行扫描**，与 `render.js` 的 `extractMermaid`
/// 是同一口径——诊断校验的块必须恰好是预览会渲染成图的块，否则报的是用户在
/// 预览里根本看不见的错。规则：
///   - 开栏行 0–3 空格缩进（4 空格是缩进代码块，marked 不当围栏），≥3 个同字符；
///     反引号围栏的 info string 里不能再出现反引号；
///   - 关栏行只能有围栏字符与空白，且长度 ≥ 开栏长度（` ```` ` 能关 ` ``` `，反之不能）；
///   - 只认**反引号**围栏，且 info 首 token 恰为 `mermaid`（区分大小写，与预览一致；
///     `~~~mermaid` 预览不会出图，校验它只会产生用户看不见的误报）。
///
/// 纯逻辑、不依赖 WebKit，供 AgentWriteSelfCheck 定位待校验的代码块。
enum MermaidBlocks {

    /// 一个 mermaid 代码块。
    struct Block: Equatable, Sendable {
        /// 开栏行的 0-based 行号（与 DocumentIssue.line 同一约定）。
        let startLine: Int
        /// 围栏内的代码内容（不含开栏/关栏行本身）。
        let code: String
    }

    static func extract(from content: String) -> [Block] {
        var blocks: [Block] = []
        var fence: Fence? = nil
        var blockStartLine = 0
        var blockLines: [String] = []

        for (index, rawLine) in content.components(separatedBy: "\n").enumerated() {
            // CRLF 文本在 components 拆分后每行还挂着 \r——不剥掉它，
            // info string 会变成 "mermaid\r"，一行也认不出来。
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine

            if let open = fence {
                if isClosingFence(line, char: open.char, minLength: open.length) {
                    if open.isMermaid {
                        blocks.append(Block(
                            startLine: blockStartLine,
                            code: blockLines.joined(separator: "\n")))
                    }
                    fence = nil
                    blockLines = []
                } else if open.isMermaid {
                    blockLines.append(line)
                }
                continue
            }

            guard let open = openingFence(line) else { continue }
            fence = open
            if open.isMermaid {
                blockStartLine = index
                blockLines = []
            }
        }

        // 扫描结束仍未闭合的 mermaid 块也产出：未闭合由 unclosedCodeBlock 另报，
        // 但围栏内的代码仍值得校验（错误往往就在内容里，不只差一个关栏）。
        if let open = fence, open.isMermaid {
            blocks.append(Block(
                startLine: blockStartLine,
                code: blockLines.joined(separator: "\n")))
        }
        return blocks
    }

    // MARK: 围栏识别

    private struct Fence {
        let char: Character
        let length: Int
        /// info 首 token（` ```mermaid config=… ` 取 `mermaid`）。
        let info: String
        /// 只有反引号围栏 + info 恰为 mermaid 才出图。
        var isMermaid: Bool { char == "`" && info == "mermaid" }
    }

    /// 一行开头的围栏标记（`char` + `length` 个 + 标记之后的起始索引）。
    ///
    /// 是三成员的 struct 而不是元组：SwiftLint 的 `large_tuple`（error 级）
    /// 禁止超过两个成员的元组。
    private struct Marker {
        let char: Character
        let length: Int
        let end: String.Index
    }

    private static func openingFence(_ line: String) -> Fence? {
        guard let marker = scanMarker(line, char: nil) else { return nil }
        let rest = line[marker.end...]
        if marker.char == "`", rest.contains("`") { return nil }
        let info = rest
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .first.map(String.init) ?? ""
        return Fence(char: marker.char, length: marker.length, info: info)
    }

    private static func isClosingFence(_ line: String, char: Character, minLength: Int) -> Bool {
        guard let marker = scanMarker(line, char: char), marker.length >= minLength else { return false }
        return line[marker.end...].allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// 扫「0–3 空格缩进 + ≥3 个同字符围栏」，返回围栏字符、长度与围栏之后的末端索引。
    private static func scanMarker(_ line: String, char expected: Character?) -> Marker? {
        var spaces = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == " " {
            spaces += 1
            if spaces > 3 { return nil }        // 4 空格 = 缩进代码块
            idx = line.index(after: idx)
        }
        guard idx < line.endIndex else { return nil }
        let marker = line[idx]
        guard marker == "`" || marker == "~" else { return nil }
        if let expected, marker != expected { return nil }

        var length = 0
        var scan = idx
        while scan < line.endIndex, line[scan] == marker {
            length += 1
            scan = line.index(after: scan)
        }
        guard length >= 3 else { return nil }
        return Marker(char: marker, length: length, end: scan)
    }
}
