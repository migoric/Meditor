import Foundation

// MARK: - HTMLTemplateAssembly

/// 模板引用式写入：「语义 body + 模板 id」→ 完整 HTML 文档。
///
/// 现状（`get_html_template`）是把 2,699 token 的整份模板灌进对话，让模型**逐字复制**
/// 再替换正文。那是一件纯机械、且复制必出错的活：模型抄错一个 `</div>`，整页布局就塌。
/// 这里把机械部分收回宿主：
///
/// - `<style>` 与 `<head>` 由模板提供，一个 token 都不进上下文；
/// - 正文只写语义标签，插进模板的 `<main>`（没有 `<main>` 就退回 `<body>`）；
/// - 侧边栏导航按 body 里的 `section#id` 或标题**重新生成**——否则生成出来的文档会
///   带着模板里的「概述 / 章节二 / 章节三」占位导航，那是比没导航更糟的观感。
enum HTMLTemplateAssembly {

    enum Failure: Error, Equatable {
        case bodyContainsStyle
        case bodyContainsExternalCSS
        case missingContentRegion

        var modelFacingMessage: String {
            switch self {
            case .bodyContainsStyle:
                return "[!] body 里不能带 <style>：样式由模板提供，要加规则请用 patch_style。请去掉 <style> 后重试。"
            case .bodyContainsExternalCSS:
                return "[!] body 里不能带 <link rel=\"stylesheet\">：模板已内联全部 CSS（离线可用），外部样式表会在预览里被 CSP 拦掉。"
            case .missingContentRegion:
                return "[!] 模板里找不到可填充的区域（既没有 <main> 也没有 <body>）。这份模板不适合模板引用式写入，请用 get_html_template 手动填写。"
            }
        }
    }

    /// - Parameters:
    ///   - template: 模板全文（来自 `TemplateStore.builtins`）。
    ///   - title: 文档标题；nil / 空串时不改模板自带的 `<title>`。
    ///   - body: 语义 HTML 片段。
    static func assemble(template: String, title: String?, body: String) throws -> String {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmedBody.lowercased()
        if lowercased.contains("<style") { throw Failure.bodyContainsStyle }
        if lowercased.contains("rel=\"stylesheet\"") || lowercased.contains("rel='stylesheet'") {
            throw Failure.bodyContainsExternalCSS
        }

        let document = HTMLScanner.scan(template)
        // 没有 section#id 时按标题生成锚点，并把 id 补进 body —— 否则导航必然指空
        let (anchors, preparedBody) = anchorsForBody(trimmedBody)

        guard let region = contentRegion(in: document) else { throw Failure.missingContentRegion }

        var edits: [(range: Range<Int>, text: String)] = []
        edits.append((region, "\n\n" + preparedBody + "\n\n"))

        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty,
           let titleElement = document.elements.first(where: { $0.name == "title" }),
           titleElement.contentStart <= titleElement.contentEnd {
            edits.append((titleElement.contentStart..<titleElement.contentEnd, escape(title)))
        }
        if !anchors.isEmpty, let navRange = navigationRegion(in: document),
           !navRange.overlaps(region) {
            // 区间重叠时宁可不重建导航：两处替换交错会把标签切坏，
            // 而「导航是占位的」只是观感问题，「文档结构被切坏」是数据问题。
            edits.append((navRange, "\n" + navigationHTML(anchors) + "\n  "))
        }

        let chars = document.source
        var result = chars
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            let lower = max(0, min(edit.range.lowerBound, result.count))
            let upper = max(lower, min(edit.range.upperBound, result.count))
            result.replaceSubrange(lower..<upper, with: Array(edit.text))
        }
        return String(result)
    }

    // MARK: 区域定位

    /// 正文填充区：优先 `<main>`，退回 `<body>`。
    private static func contentRegion(in document: HTMLDocument) -> Range<Int>? {
        let target = document.elements.first(where: { $0.name == "main" })
            ?? document.elements.first(where: { $0.name == "body" })
        guard let target, target.contentStart <= target.contentEnd else { return nil }
        return target.contentStart..<target.contentEnd
    }

    /// 侧边栏导航区：`<aside>`（或 class 含 sidebar 的容器）里的 `<nav>` 内容。
    private static func navigationRegion(in document: HTMLDocument) -> Range<Int>? {
        let asideIndices = document.elements.indices.filter { index in
            let element = document.elements[index]
            guard element.name == "aside" else {
                return element.classes.contains("sidebar")
            }
            return true
        }
        for asideIndex in asideIndices {
            let aside = document.elements[asideIndex]
            for index in document.elements.indices where document.elements[index].name == "nav" {
                let nav = document.elements[index]
                guard nav.startOffset > aside.startOffset, nav.endOffset <= aside.contentEnd else { continue }
                guard nav.contentStart <= nav.contentEnd else { continue }
                return nav.contentStart..<nav.contentEnd
            }
        }
        return nil
    }

    // MARK: 导航

    /// body 里的锚点：`section#id` 优先；没有则取标题并给标题补 id。
    static func anchorsForBody(_ body: String) -> (anchors: [(id: String, title: String, level: Int)], body: String) {
        let document = HTMLScanner.scan(body)
        let sections = document.sectionAnchors()
        if !sections.isEmpty { return (sections, body) }

        var anchors: [(id: String, title: String, level: Int)] = []
        var edits: [(range: Range<Int>, text: String)] = []
        for element in document.elements where HTMLDocument.headingTags.contains(element.name) {
            guard element.id == nil else {
                let title = HTMLDocument.collapse(document.slice(element.contentStart..<element.contentEnd))
                anchors.append((element.id ?? "", title.isEmpty ? element.id ?? "" : title,
                                Int(element.name.dropFirst()) ?? 2))
                continue
            }
            guard element.contentStart <= element.contentEnd else { continue }
            let title = HTMLDocument.collapse(document.slice(element.contentStart..<element.contentEnd))
            guard !title.isEmpty else { continue }
            let id = uniqueSlug(for: title, existing: Set(anchors.map(\.id)))
            anchors.append((id, title, Int(element.name.dropFirst()) ?? 2))
            // 在标签名之后补 id：`<h2>` → `<h2 id="…">`
            edits.append((element.startOffset + 1 + element.name.count..<element.startOffset + 1 + element.name.count,
                          " id=\"\(id)\""))
        }
        guard !anchors.isEmpty else { return ([], body) }

        var chars = document.source
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            chars.replaceSubrange(edit.range, with: Array(edit.text))
        }
        return (anchors, String(chars))
    }

    private static func navigationHTML(_ anchors: [(id: String, title: String, level: Int)]) -> String {
        var lines: [String] = []
        for (offset, anchor) in anchors.enumerated() {
            let active = offset == 0 ? " class=\"active\"" : ""
            let indentStyle = anchor.level >= 3
                ? " style=\"padding-left:1.4rem;font-size:.75rem\""
                : ""
            lines.append("    <a href=\"#\(anchor.id)\"\(active)\(indentStyle)>\(escape(anchor.title))</a>")
        }
        return lines.joined(separator: "\n")
    }

    /// 标题 → 锚点 id（GitHub 风格：小写、非字母数字转 `-`）。
    static func slug(for title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        var scalars: [Character] = []
        var lastWasDash = false
        for ch in title.lowercased() {
            if ch.isWhitespace {
                if !lastWasDash { scalars.append("-"); lastWasDash = true }
                continue
            }
            if ch.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
                scalars.append(ch)
                lastWasDash = ch == "-"
            } else if !lastWasDash {
                scalars.append("-")
                lastWasDash = true
            }
        }
        var result = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if result.isEmpty { result = "section" }
        return String(result.prefix(48))
    }

    private static func uniqueSlug(for title: String, existing: Set<String>) -> String {
        let base = slug(for: title)
        guard existing.contains(base) else { return base }
        var index = 2
        while existing.contains("\(base)-\(index)") { index += 1 }
        return "\(base)-\(index)"
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
