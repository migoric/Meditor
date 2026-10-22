import Foundation
import XCTest

/// `WebViewPool.warmUp` 只该有**一套**资源镜像实现。
///
/// 背景：`warmUp` 曾经自己抄了一份「目标不存在才 `copyItem`」的逻辑，而真正的
/// 预览路径走的是 `PreviewAssetMirror.mirrorAssets`（hard-link + 按源/目标 mtime
/// 判定刷新 + 目录按条目集合补齐）。两套实现漂移的后果不是「重复代码」这么轻——
/// 预热缓存**永不刷新**：升级后残留的旧 CSS/JS 会一直喂给第一个预览，
/// 因为 `fileExists` 直接跳过，`shouldRefresh` / `directoryNeedsRefresh` 全都
/// 没有机会生效（`css/katex.min.css`、`css/fonts/*.woff2` 这类新增资源同理）。
///
/// 为什么用源码守卫而不是行为测试：`warmUp` 在 `swift test` 下跑不到——
/// 它依赖 `PreviewResourceLocator.resourcesRoot()`，而测试宿主是 xctest、
/// 资源不在 bundle 里，函数第一步就 return 了。既然拿不到可观测行为，
/// 就钉住「结构」：热路径不许再出现自己的拷贝实现。
final class WebViewPoolWarmUpSourceTests: XCTestCase {

    private static var poolSourceURL: URL {
        URL(fileURLWithPath: #filePath)              // …/Tests/MEditorTests/<this>.swift
            .deletingLastPathComponent()             // …/Tests/MEditorTests
            .deletingLastPathComponent()             // …/Tests
            .deletingLastPathComponent()             // <root>
            .appendingPathComponent("Sources/MEditor/Services/Preview/WebViewPool.swift")
    }

    /// 去掉整行注释（`//` / `///`），只留代码——说明性注释里会提到 `copyItem`
    /// 这类词，不该被守卫误判。
    private func codeOnly(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func testWarmUpDoesNotCarryItsOwnAssetCopying() throws {
        let source = try String(contentsOf: Self.poolSourceURL, encoding: .utf8)
        let code = codeOnly(source)

        XCTAssertFalse(
            code.contains("copyItem"),
            "warmUp 又自己拷贝资源了：镜像/刷新只有 PreviewAssetMirror 一套，否则预热缓存永不刷新"
        )
        XCTAssertTrue(
            code.contains("PreviewAssetMirror.prepareHTML"),
            "warmUp 应复用 PreviewAssetMirror.prepareHTML（hard-link + 按 mtime 刷新 + 目录按条目补齐）"
        )
    }

    func testWarmUpDoesNotHandWriteTheTemplate() throws {
        // 模板替换（主题、初始内容 JSON 转义）也必须单源：`{{INITIAL_CONTENT_JSON}}`
        // 里的 "<" 要转成 \u003c 才不会被 </script> 提前闭合，这份转义逻辑只有
        // PreviewAssetMirror.escapedInitialContentJSON 一处。
        let source = try String(contentsOf: Self.poolSourceURL, encoding: .utf8)
        XCTAssertFalse(
            codeOnly(source).contains("{{INITIAL_CONTENT_JSON}}"),
            "warmUp 不该自己拼模板：内容 JSON 的 \"<\" 转义只在 PreviewAssetMirror 一处"
        )
    }

    func testWarmUpKeepsFileSystemWorkOffTheMainThread() throws {
        // 镜像 856KB 资源曾经发生在主线程（bootSequence 的第一步）。
        let source = try String(contentsOf: Self.poolSourceURL, encoding: .utf8)
        XCTAssertTrue(
            source.contains("Task.detached"),
            "镜像/写盘应在后台任务里，主线程只建 WebView"
        )
    }
}
