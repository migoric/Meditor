import XCTest
import WebKit

/// 预览热路径基准：`renderInto` 在「文档已渲染、来一轮更新」场景下的耗时。
///
/// 门控：只有 `MEDITOR_PREVIEW_BENCH=1` 时才真正跑（CI 与日常 `swift test` 跳过——
/// 耗时数字只有在同机对比时才有意义，不该占用常规测试时间）。
///
///     MEDITOR_PREVIEW_BENCH=1 swift test --filter PreviewRenderBenchTests
///
/// 四种语料对应真实文档形态，每种用**独立页面**（连测多形态会被 JIT 预热 /
/// 缓存状态污染）。每种测两条：
/// - `hotEdit`：交替渲染「改了一个中段块」的两个版本，每帧都是真实编辑；
/// - `hotNoop`：反复渲染同一内容，每帧都无实质变化。
@MainActor
final class PreviewRenderBenchTests: XCTestCase {

    override class func tearDown() {
        PreviewTestPage.tearDown()
        super.tearDown()
    }

    /// 语料生成器（在页面里跑）。每个语料都在中段块里埋 `MARKER-ALPHA`，
    /// bench 时换成 `MARKER-BETA` 当作「一次真实编辑」。
    private static let corpora: [(name: String, generator: String)] = [
        ("段落×3000", #"""
           function filler(n) {
             var s = 'lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod ';
             var out = ''; while (out.length < n) out += s; return out.slice(0, n);
           }
           var F = filler(280);
           var parts = [];
           for (var i = 0; i < 3000; i++) {
             parts.push('段落 ' + i + ' ' + (i === 1500 ? 'MARKER-ALPHA ' : '') + F);
           }
           var SRC = parts.join('\n\n');
         """#),
        ("松散列表", #"""
           var items = [];
           for (var i = 0; i < 6000; i++) {
             items.push('- 列表项 ' + i + (i === 3000 ? ' MARKER-ALPHA' : '') + '，松散排列的条目内容');
           }
           var SRC = items.join('\n\n');
         """#),
        ("标题×2000", #"""
           var parts = [];
           for (var i = 0; i < 2000; i++) {
             parts.push('## 标题 ' + i + (i === 1000 ? ' MARKER-ALPHA' : ''));
           }
           var SRC = parts.join('\n\n');
         """#),
        ("混合", #"""
           function filler(n) {
             var s = 'lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod ';
             var out = ''; while (out.length < n) out += s; return out.slice(0, n);
           }
           var F = filler(200);
           var parts = [];
           for (var i = 0; i < 400; i++) {
             parts.push('## 章节 ' + i);
             parts.push('段落 ' + i + (i === 200 ? ' MARKER-ALPHA ' : ' ') + F);
             parts.push('- 甲 ' + i + '\n- 乙 ' + i + '\n- 丙 ' + i);
             parts.push('```swift\nlet value' + i + ' = ' + i + '\nprint(value' + i + ')\n```');
           }
           var SRC = parts.join('\n\n');
         """#),
    ]

    private static let measure = #"""
      (function () {
        var el = document.getElementById('content');
        el.innerHTML = '';
        MEditorRender.resetRenderStats();
        MEditorRender.renderInto(el, SRC);   // 冷启：建缓存、建 DOM
        MEditorRender.renderInto(el, SRC);   // 第二帧：让增量状态（块缓存/对齐记录）就位

        var SRC2 = SRC.replace('MARKER-ALPHA', 'MARKER-BETA');
        function bench(fn, n) {
          fn();
          var t = performance.now();
          for (var k = 0; k < n; k++) fn();
          return (performance.now() - t) / n;
        }
        // 真实编辑：交替两个版本 ⇒ 每帧都有一个中段块真的变了
        var hotEdit = bench(function () {
          MEditorRender.renderInto(el, SRC);
          MEditorRender.renderInto(el, SRC2);
        }, 6) / 2;
        // 无实质变化：同一内容反复渲染
        var hotNoop = bench(function () { MEditorRender.renderInto(el, SRC); }, 8);
        return JSON.stringify({
          srcKB: Math.round(SRC.length / 1024),
          blocks: el.children.length,
          hotEdit: +hotEdit.toFixed(1),
          hotNoop: +hotNoop.toFixed(1)
        });
      })()
    """#

    func testRenderIntoHotBench() async throws {
        guard ProcessInfo.processInfo.environment["MEDITOR_PREVIEW_BENCH"] == "1" else {
            throw XCTSkip("基准默认跳过；MEDITOR_PREVIEW_BENCH=1 swift test --filter PreviewRenderBenchTests 开启")
        }
        for corpus in Self.corpora {
            let (webView, _) = try await PreviewTestPage.makeWebView()
            _ = try await PreviewTestPage.eval(corpus.generator + "\n;\n1;\n", webView)
            guard let raw = try await PreviewTestPage.eval(Self.measure, webView) else {
                XCTFail("拿不到基准输出：\(corpus.name)")
                continue
            }
            print("BENCH \(corpus.name) \(raw)")
        }
    }
}
