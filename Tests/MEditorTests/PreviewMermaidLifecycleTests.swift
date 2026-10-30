import XCTest
import WebKit

/// Mermaid 异步代际：旧 Promise 不得写回新文档，旧观察器必须释放。
@MainActor
final class PreviewMermaidLifecycleTests: XCTestCase {

    override class func tearDown() {
        PreviewTestPage.tearDown()
        super.tearDown()
    }

    func testLateDiagramPromiseCannotOverwriteNewerDocument() async throws {
        let (webView, _) = try await PreviewTestPage.makeWebView()
        _ = try await PreviewTestPage.eval("""
        window.__requests = [];
        window.IntersectionObserver = undefined;
        window.mermaid = {
          initialize: function () {},
          render: function (id, code) {
            return new Promise(function (resolve) {
              window.__requests.push({ id: id, code: code, resolve: resolve });
            });
          }
        };
        1
        """, webView)
        let docA = "```mermaid\ngraph TD; A-->B;\n```"
        let docB = "```mermaid\ngraph TD; C-->D;\n```"
        _ = try await PreviewTestPage.render(docA, in: webView)
        try await PreviewTestPage.waitUntil(webView, "window.__requests.length === 1 ? 'ok' : 'pending'", timeout: 10)
        _ = try await PreviewTestPage.render(docB, in: webView)
        try await PreviewTestPage.waitUntil(webView, "window.__requests.length === 2 ? 'ok' : 'pending'", timeout: 10)

        _ = try await PreviewTestPage.eval(
            "window.__requests[0].resolve({ svg: '<svg id=\"old-result\"></svg>' }); 1", webView)
        try await Task.sleep(nanoseconds: 100_000_000)
        let oldCount = try await PreviewTestPage.eval(
            "document.querySelectorAll('#content #old-result').length", webView)
        XCTAssertEqual(oldCount, "0", "旧文档的晚到 SVG 不得覆盖新文档占位")
        let placeholders = try await PreviewTestPage.eval(
            "document.querySelectorAll('#content .mermaid-placeholder').length", webView)
        XCTAssertEqual(placeholders, "1")

        _ = try await PreviewTestPage.eval(
            "window.__requests[1].resolve({ svg: '<svg id=\"new-result\"></svg>' }); 1", webView)
        try await PreviewTestPage.waitUntil(
            webView, "document.querySelectorAll('#content #new-result').length === 1 ? 'ok' : 'pending'",
            timeout: 10)
    }

    func testRenderingPlainDocumentDisconnectsPreviousObserver() async throws {
        let (webView, _) = try await PreviewTestPage.makeWebView()
        _ = try await PreviewTestPage.eval("""
        window.__observers = [];
        window.mermaid = { initialize: function () {}, render: function () {
          return Promise.resolve({ svg: '<svg></svg>' });
        } };
        window.IntersectionObserver = function () {
          var observer = {
            disconnected: false,
            observe: function () {},
            unobserve: function () {},
            disconnect: function () { this.disconnected = true; }
          };
          window.__observers.push(observer);
          return observer;
        };
        1
        """, webView)
        _ = try await PreviewTestPage.render("```mermaid\ngraph TD; A-->B;\n```", in: webView)
        try await PreviewTestPage.waitUntil(webView, "window.__observers.length === 1 ? 'ok' : 'pending'", timeout: 10)
        _ = try await PreviewTestPage.render("只是普通文档。", in: webView)
        let disconnected = try await PreviewTestPage.eval(
            "String(window.__observers[0].disconnected)", webView)
        XCTAssertEqual(disconnected, "true", "空文档也必须断开上一轮的观察器")
    }
}
