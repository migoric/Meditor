import Foundation

/// 从 Markdown 文本提取 ```mermaid 围栏代码块（开栏行号 + 代码内容）。
///
/// 行扫描口径与 DocumentDiagnostics 的围栏处理一致（``` 或 ~~~ 开栏、同字符关栏、
/// 行号 0-based），但只认**反引号**围栏且 info string 首 token 恰为 `mermaid`——
/// 与 render.js 的 `/```mermaid[^]*?```/g` 同一判定：预览不会把 ~~~mermaid 渲染成图，
/// 校验它只会产生用户在预览里看不到对应错误的误报；大小写同理（render.js 区分大小写）。
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
        var inFence = false
        var fenceMarker: Character = "`"
        var isMermaid = false
        var blockStartLine = 0
        var blockLines: [String] = []

        for (index, line) in content.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isBacktick = trimmed.hasPrefix("```")
            let isTilde = trimmed.hasPrefix("~~~")
            if isBacktick || isTilde {
                let marker: Character = isBacktick ? "`" : "~"
                if !inFence {
                    inFence = true
                    fenceMarker = marker
                    // info string：开栏标记后的语言标注，取空白分隔的首 token
                    //（```mermaid config=… 这类附带参数写法仍是 mermaid 块）
                    let info = trimmed.dropFirst(3)
                        .split(whereSeparator: { $0 == " " || $0 == "\t" })
                        .first.map(String.init) ?? ""
                    isMermaid = marker == "`" && info == "mermaid"
                    if isMermaid {
                        blockStartLine = index
                        blockLines = []
                    }
                } else if marker == fenceMarker {
                    inFence = false
                    if isMermaid {
                        blocks.append(Block(
                            startLine: blockStartLine,
                            code: blockLines.joined(separator: "\n")))
                        isMermaid = false
                    }
                }
                continue
            }
            if inFence, isMermaid { blockLines.append(line) }
        }

        // 扫描结束仍未闭合的 mermaid 块也产出：未闭合由 unclosedCodeBlock 另报，
        // 但围栏内的代码仍值得校验（错误往往就在内容里，不只差一个关栏）。
        if inFence, isMermaid {
            blocks.append(Block(
                startLine: blockStartLine,
                code: blockLines.joined(separator: "\n")))
        }
        return blocks
    }
}
