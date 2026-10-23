import XCTest
import WebKit
@testable import MEditor

/// 块对齐增量 patch 的行为守卫：「哪些组变了」从 renderMarkdownBlocks 透传到
/// DOM 层，未变化组**零解析、零序列化、零替换**。
///
/// 断言口径有两层（缺一不可）：
/// 1. **节点身份**：未变化组对应的 `#content` 顶层子节点必须是同一个 DOM 节点
///    （被换掉说明走了全量重建）；
/// 2. **渲染计数**：`patchGroupsReplaced` / `patchBail` 把「只替换了变化组」
///    「没有回退全树 diff」钉住——产物正确性测试对「整树重 diff」同样是绿的。
///
/// 反向验证（改代码做过）：把 `patchDOMGroups` 入口改成恒 `return false`，
/// 本文件四个用例全红（compared 恒 0 / bail 递增 / 节点被全树 diff 换掉）。
@MainActor
final class PreviewBlockAlignedPatchTests: XCTestCase {

    override class func tearDown() {
        PreviewTestPage.tearDown()
        super.tearDown()
    }

    /// 改中段一段 ⇒ 只有对应组被替换，前后组的节点身份保留。
    func testMiddleEditReplacesOnlyThatGroup() async throws {
        let (webView, _) = try await PreviewTestPage.makeWebView()
        let docA = (0..<6).map { "段落 \($0)。" }.joined(separator: "\n\n")
        let docB = docA.replacingOccurrences(of: "段落 3。", with: "段落 3 改了。")

        _ = try await PreviewTestPage.render(docA, in: webView)   // 首帧：全量替换 + 建立组范围记录
        _ = try await PreviewTestPage.eval(
            "window.__kids = Array.prototype.slice.call(document.getElementById('content').children); 1",
            webView)
        try await PreviewTestPage.resetStats(webView)
        _ = try await PreviewTestPage.render(docB, in: webView)

        let stats = try await PreviewTestPage.stats(webView)
        XCTAssertEqual(stats.patchGroupsCompared, 6, "块对齐应检查全部 6 组：\(stats)")
        XCTAssertEqual(stats.patchGroupsReplaced, 1, "只改一段 ⇒ 只应替换 1 组：\(stats)")
        XCTAssertEqual(stats.patchBail, 0, "稳定对齐不该回退全树 diff：\(stats)")

        let identity = try await PreviewTestPage.eval("""
        (function () {
          var k = document.getElementById('content').children;
          if (k.length !== 6) return 'count:' + k.length;
          var kept = [0, 1, 2, 4, 5].every(function (i) { return k[i] === window.__kids[i]; });
          var swapped = k[3] !== window.__kids[3];
          return kept && swapped ? 'ok' : 'bad';
        })()
        """, webView)
        XCTAssertEqual(identity, "ok", "未变化组的 DOM 节点必须原样保留，只有第 4 段被换掉")

        // textContent 含块间的空白文本节点（全量替换保留 join 分隔符、组替换不带），
        // 空白对布局无影响，比较时归一化掉
        let text = try await PreviewTestPage.eval(
            "document.getElementById('content').textContent.replace(/\\s+/g, '')", webView)
        XCTAssertEqual(text, "段落0。段落1。段落2。段落3改了。段落4。段落5。")
    }

    /// 文首插入一段 ⇒ 后续组整体移位但不得错位：旧节点按后缀对齐原样保留。
    func testHeadInsertKeepsSuffixNodesAligned() async throws {
        let (webView, _) = try await PreviewTestPage.makeWebView()
        let docA = (0..<6).map { "段落 \($0)。" }.joined(separator: "\n\n")
        let docB = "文首新段。\n\n" + docA

        _ = try await PreviewTestPage.render(docA, in: webView)
        _ = try await PreviewTestPage.eval(
            "window.__kids = Array.prototype.slice.call(document.getElementById('content').children); 1",
            webView)
        try await PreviewTestPage.resetStats(webView)
        _ = try await PreviewTestPage.render(docB, in: webView)

        let stats = try await PreviewTestPage.stats(webView)
        XCTAssertEqual(stats.patchGroupsReplaced, 1, "文首插入 ⇒ 只应替换（插入）1 组：\(stats)")
        XCTAssertEqual(stats.patchBail, 0, "文首插入不该触发回退：\(stats)")

        // 旧 6 个节点按后缀对齐出现在新位置的 1...6，且一个不少
        let identity = try await PreviewTestPage.eval("""
        (function () {
          var k = document.getElementById('content').children;
          if (k.length !== 7) return 'count:' + k.length;
          for (var i = 0; i < 6; i++) {
            if (k[i + 1] !== window.__kids[i]) return 'misaligned:' + i;
          }
          return k[0].textContent === '文首新段。' ? 'ok' : 'head:' + k[0].textContent;
        })()
        """, webView)
        XCTAssertEqual(identity, "ok", "文首插入后旧节点必须不错位地整体后移")

        let text = try await PreviewTestPage.eval(
            "document.getElementById('content').textContent.replace(/\\s+/g, '')", webView)
        XCTAssertEqual(text, "文首新段。段落0。段落1。段落2。段落3。段落4。段落5。")
    }

    /// 无实质变化的更新 ⇒ 0 组被替换、0 次回退，所有节点身份保留。
    func testNoChangeUpdateReplacesZeroGroups() async throws {
        let (webView, _) = try await PreviewTestPage.makeWebView()
        let doc = (0..<8).map { "段落 \($0)。" }.joined(separator: "\n\n")

        _ = try await PreviewTestPage.render(doc, in: webView)
        _ = try await PreviewTestPage.eval(
            "window.__kids = Array.prototype.slice.call(document.getElementById('content').children); 1",
            webView)
        try await PreviewTestPage.resetStats(webView)
        _ = try await PreviewTestPage.render(doc, in: webView)

        let stats = try await PreviewTestPage.stats(webView)
        XCTAssertEqual(stats.patchGroupsCompared, 8, "无变化也应走块对齐路径（而非回退）：\(stats)")
        XCTAssertEqual(stats.patchGroupsReplaced, 0, "无变化更新 ⇒ 0 组替换：\(stats)")
        XCTAssertEqual(stats.patchBail, 0, "无变化更新不该回退全树 diff：\(stats)")

        let identity = try await PreviewTestPage.eval("""
        (function () {
          var k = document.getElementById('content').children;
          if (k.length !== 8) return 'count:' + k.length;
          for (var i = 0; i < 8; i++) if (k[i] !== window.__kids[i]) return 'replaced:' + i;
          return 'ok';
        })()
        """, webView)
        XCTAssertEqual(identity, "ok", "无变化更新不得替换任何节点")
    }

    /// 表格组：改别处时包裹后的 `.table-wrapper` 节点原样保留（包裹结构参与范围记录）。
    func testTableGroupPreservedWhenEditingElsewhere() async throws {
        let (webView, _) = try await PreviewTestPage.makeWebView()
        let table = "| 甲 | 乙 |\n| --- | --- |\n| 1 | 2 |"
        let docA = "开头段。\n\n\(table)\n\n结尾段 v1。"
        let docB = "开头段。\n\n\(table)\n\n结尾段 v2。"

        _ = try await PreviewTestPage.render(docA, in: webView)
        let wrapped = try await PreviewTestPage.eval(
            "document.querySelectorAll('#content .table-wrapper').length", webView)
        XCTAssertEqual(wrapped, "1", "表格应被包进 .table-wrapper")

        _ = try await PreviewTestPage.eval(
            "window.__wrapper = document.querySelector('#content .table-wrapper'); 1", webView)
        try await PreviewTestPage.resetStats(webView)
        _ = try await PreviewTestPage.render(docB, in: webView)

        let stats = try await PreviewTestPage.stats(webView)
        XCTAssertEqual(stats.patchGroupsReplaced, 1, "只改结尾段 ⇒ 只替换 1 组：\(stats)")
        XCTAssertEqual(stats.patchBail, 0, "含表格的对齐不该回退：\(stats)")

        let identity = try await PreviewTestPage.eval(
            "document.querySelector('#content .table-wrapper') === window.__wrapper ? 'preserved' : 'replaced'",
            webView)
        XCTAssertEqual(identity, "preserved", "未变化的表格组（含包裹层）必须原样保留")

        let cell = try await PreviewTestPage.eval(
            "document.querySelector('#content .table-wrapper td').textContent", webView)
        XCTAssertEqual(cell, "1", "表格内容必须完好")
        let tail = try await PreviewTestPage.eval(
            "document.getElementById('content').lastElementChild.textContent", webView)
        XCTAssertEqual(tail, "结尾段 v2。")
    }
}
