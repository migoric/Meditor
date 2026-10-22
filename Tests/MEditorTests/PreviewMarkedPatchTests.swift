import XCTest
import WebKit
@testable import MEditor

/// `marked.min.js` 的本地补丁守卫。
///
/// 补丁本身见 `scripts/patch_marked.py`：把 `(?:x){3,}` 这类**分组上的无上界计数
/// 重复**展开成 `(?:x)(?:x)(?:x)(?:x)*`。原因是 JSC 的 YARR 在遇到这类量词时会丢掉
/// 「只在位置 0 尝试匹配」的优化，失败一次沿整串走一遍；而 marked 每产出一个 block
/// token 都把 ~12 条规则对**剩余全文**各试一遍 ⇒ O(n²)。
///
/// 这里守三件事：
/// 1. **补丁还在**——升级 marked 会静默冲掉它（补丁一丢，120KB 文档又回到 1.2s）；
/// 2. **改写等价**——随机字符串上旧式/新式逐字比对，防止展开写错语义；
/// 3. **扩展性**——30KB → 120KB 的耗时不得按平方增长。
@MainActor
final class PreviewMarkedPatchTests: XCTestCase {

    override func tearDown() {
        PreviewTestPage.tearDown()
        super.tearDown()
    }

    // MARK: - 1. 补丁是否还在

    func testPatchedMarkedHasNoGroupQuantifier() throws {
        let source = try PreviewTestPage.previewScript(named: "marked.min.js")
        // 顶部 banner 里就写着 `(?:x){3,}`，扫描时跳过它
        let body = source.contains("\n") ? String(source[source.index(after: source.firstIndex(of: "\n")!)...]) : source

        XCTAssertTrue(
            source.contains("MEditor patch"),
            "marked.min.js 顶部的补丁标记不见了 —— 大概是被升级覆盖，请重跑 scripts/patch_marked.py"
        )

        // 分组上的 {n,}：`(?:…){3,}` / `(…){2,}`。单字符量词（`{3,} / ~{3,}）不在其中。
        let pattern = try NSRegularExpression(pattern: #"\(\?:[^()]{0,24}\)\{\d+,\}"#)
        let range = NSRange(body.startIndex..., in: body)
        let leftovers = pattern.matches(in: body, range: range).map {
            String(body[Range($0.range, in: body)!])
        }
        XCTAssertEqual(leftovers, [], "仍有分组量词未展开：\(leftovers)")
    }

    /// `render.js` 里的前置判据确实装上了（html 规则已不是原生 RegExp）。
    func testHTMLRuleGuardIsInstalled() async throws {
        let (webView, _) = try await PreviewTestPage.makeWebView()
        let raw = try await PreviewTestPage.eval("""
        (function () {
          var r = marked.Lexer.rules.block.gfm.html;
          return (r instanceof RegExp ? 'native' : 'guarded') + '/' + typeof r.exec;
        })()
        """, webView)
        XCTAssertEqual(raw, "guarded/function", "html 规则没有被前置判据包装")
    }

    // MARK: - 2. 改写等价性（差分模糊）

    func testQuantifierRewriteIsEquivalent() async throws {
        let (webView, _) = try await PreviewTestPage.makeWebView()
        let raw = try await PreviewTestPage.eval(Self.fuzzScript, webView)
        XCTAssertEqual(raw, "0", "改写后的正则与旧式不等价：\(raw ?? "nil")")
    }

    private static let fuzzScript = """
    (function () {
      var PAIRS = [
        ['(?:- *){3,}', '(?:- *)(?:- *)(?:- *)(?:- *)*'],
        ['(?:_ *){3,}', '(?:_ *)(?:_ *)(?:_ *)(?:_ *)*'],
        ['(?:\\\\* *){3,}', '(?:\\\\* *)(?:\\\\* *)(?:\\\\* *)(?:\\\\* *)*'],
        ['(?:-[\\\\t ]*){3,}', '(?:-[\\\\t ]*)(?:-[\\\\t ]*)(?:-[\\\\t ]*)(?:-[\\\\t ]*)*'],
        ['(?:_[ \\\\t]*){3,}', '(?:_[ \\\\t]*)(?:_[ \\\\t]*)(?:_[ \\\\t]*)(?:_[ \\\\t]*)*'],
        ['(?:\\\\*[ \\\\t]*){3,}', '(?:\\\\*[ \\\\t]*)(?:\\\\*[ \\\\t]*)(?:\\\\*[ \\\\t]*)(?:\\\\*[ \\\\t]*)*']
      ];
      var ALPHABET = ['-', '-', '_', '*', ' ', ' ', '\\t', '\\n', 'a', '1'];
      var seed = 20261022;
      function rnd() { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed / 0x7fffffff; }
      function randStr() {
        var n = Math.floor(rnd() * 14), s = '';
        for (var i = 0; i < n; i++) s += ALPHABET[Math.floor(rnd() * ALPHABET.length)];
        return s;
      }
      var mismatches = [];
      for (var p = 0; p < PAIRS.length; p++) {
        var a = new RegExp('^ {0,3}' + PAIRS[p][0] + '(?:\\\\n+|$)');
        var b = new RegExp('^ {0,3}' + PAIRS[p][1] + '(?:\\\\n+|$)');
        for (var k = 0; k < 5000; k++) {
          var s = randStr();
          var m1 = a.exec(s), m2 = b.exec(s);
          var s1 = m1 ? m1[0] : null, s2 = m2 ? m2[0] : null;
          if (s1 !== s2 && mismatches.length < 5) {
            mismatches.push('pattern' + p + ' ' + JSON.stringify(s) + ' → ' + JSON.stringify(s1) + ' vs ' + JSON.stringify(s2));
          }
        }
      }
      return mismatches.length ? mismatches.join(' | ') : '0';
    })()
    """

    // MARK: - 3. 扩展性守卫

    /// 30KB → 120KB 的解析耗时不得按平方增长（线性 ≈4×，平方 ≈16×）。
    ///
    /// 补丁前实测：30KB 96ms / 120KB 1257ms（13×）；补丁后 12ms / 35ms。
    /// 阈值取 6×，给 CI 机器留余量。
    func testParseScalesLinearly() async throws {
        let (webView, _) = try await PreviewTestPage.makeWebView()
        let raw = try await PreviewTestPage.eval(Self.scalingScript, webView)

        let parts = (raw ?? "").split(separator: "/").compactMap { Double($0) }
        XCTAssertEqual(parts.count, 2, "测量脚本没返回两个耗时：\(raw ?? "nil")")
        guard parts.count == 2 else { return }
        let (ms30, ms120) = (parts[0], parts[1])

        XCTAssertLessThan(ms120, ms30 * 6,
                          "解析耗时按平方增长：30KB \(ms30)ms / 120KB \(ms120)ms —— marked 补丁可能失效")
        XCTAssertLessThan(ms120, 400, "120KB 整篇解析 \(ms120)ms，超出可用范围")
    }

    private static let scalingScript = """
    (function () {
      function corpus(bytes) {
        var block = '## 小节\\n\\n一段普通正文，含 **粗体** 与 `行内码`。\\n\\n' +
                    '```sh\\n$ echo hello\\n\\n$ echo world\\n```\\n\\n' +
                    '| a | b |\\n| --- | --- |\\n| 1 | 2 |\\n\\n' +
                    '- 列表项一\\n- 列表项二\\n\\n';
        var s = '';
        while (s.length < bytes) s += block;
        return s;
      }
      function ms(text) {
        var best = Infinity;
        for (var i = 0; i < 3; i++) {
          var t0 = performance.now();
          marked.parse(text, { gfm: true, breaks: false });
          var d = performance.now() - t0;
          if (d < best) best = d;
        }
        return Math.max(best, 0.5);
      }
      return ms(corpus(30 * 1024)) + '/' + ms(corpus(120 * 1024));
    })()
    """
}
