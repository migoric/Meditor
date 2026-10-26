import XCTest
import PDFKit
@testable import MEditor

/// PDF 导出主题（功能9）：选项模型、打印 CSS、PDF 后处理（封面/页眉页脚/纸张归一）。
final class PDFExportOptionsTests: XCTestCase {

    // MARK: - 选项模型

    func test_paperSize_points() {
        XCTAssertEqual(PDFExportOptions.PaperSize.a4.pointsSize,
                       CGSize(width: 595.28, height: 841.89))
        XCTAssertEqual(PDFExportOptions.PaperSize.letter.pointsSize,
                       CGSize(width: 612, height: 792))
    }

    func test_margins_points() {
        XCTAssertEqual(PDFExportOptions.MarginPreset.narrow.points, 36)
        XCTAssertEqual(PDFExportOptions.MarginPreset.normal.points, 54)
        XCTAssertEqual(PDFExportOptions.MarginPreset.wide.points, 72)
    }

    func test_contentRect_insetsByMargins() {
        let options = PDFExportOptions(paperSize: .a4, margins: .normal)
        let content = options.contentRect
        XCTAssertEqual(content.minX, 54, accuracy: 0.01)
        XCTAssertEqual(content.minY, 54, accuracy: 0.01)
        XCTAssertEqual(content.width, 595.28 - 108, accuracy: 0.01)
        XCTAssertEqual(content.height, 841.89 - 108, accuracy: 0.01)
    }

    func test_printCSS_declaresPageSizeAndZeroMargin() {
        XCTAssertEqual(PDFExportOptions(paperSize: .a4).printCSS(),
                       "@page { size: A4; margin: 0; }")
        XCTAssertEqual(PDFExportOptions(paperSize: .letter).printCSS(),
                       "@page { size: letter; margin: 0; }")
    }

    // MARK: - isDefault（默认排版跳过后处理，保留可点击链接）

    func test_isDefault_freshOptionsAreDefault() {
        XCTAssertTrue(PDFExportOptions().isDefault)
        XCTAssertTrue(PDFExportOptions.default.isDefault)
    }

    func test_isDefault_anyCustomizationBreaksDefault() {
        XCTAssertFalse(PDFExportOptions(showHeader: true).isDefault)
        XCTAssertFalse(PDFExportOptions(showFooter: true).isDefault)
        XCTAssertFalse(PDFExportOptions(coverPage: true).isDefault)
        XCTAssertFalse(PDFExportOptions(paperSize: .letter).isDefault)
        XCTAssertFalse(PDFExportOptions(margins: .wide).isDefault)
        XCTAssertFalse(PDFExportOptions(margins: .narrow).isDefault)
    }

    // MARK: - CSS 注入（PreviewExporter.injectCSS）

    func test_injectCSS_insertsBeforeHeadEnd() {
        let html = "<html><head><title>t</title></head><body>x</body></html>"
        let result = PreviewExporter.injectCSS(html, css: "@page { size: A4; }")
        XCTAssertTrue(result.contains("<style>@page { size: A4; }</style></head>"))
    }

    func test_injectCSS_fallbackPrependsWhenNoHead() {
        let result = PreviewExporter.injectCSS("<body>x</body>", css: "css")
        XCTAssertTrue(result.hasPrefix("<style>css</style>"))
    }

    // MARK: - PDF 后处理

    /// 生成 N 页空白 PDF（Letter 尺寸）。
    private func makePDF(pageCount: Int) -> Data {
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let ctx = CGContext(consumer: consumer, mediaBox: nil, nil)!
        let rect = CGRect(x: 0, y: 0, width: 612, height: 792)
        for _ in 0..<pageCount {
            ctx.beginPDFPage([kCGPDFContextMediaBox: NSValue(rect: rect)] as CFDictionary)
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(rect)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    func test_decorate_normalizesPaperSize() {
        let options = PDFExportOptions(paperSize: .a4, margins: .normal,
                                       showHeader: false, showFooter: false)
        let out = PDFDocumentDecorator.decorate(data: makePDF(pageCount: 2),
                                                options: options, title: "Doc")
        XCTAssertNotNil(out)
        let doc = PDFDocument(data: out!)
        XCTAssertEqual(doc?.pageCount, 2)
        let box = doc?.page(at: 0)?.bounds(for: .mediaBox)
        XCTAssertEqual(box?.width ?? 0, 595.28, accuracy: 0.5)
        XCTAssertEqual(box?.height ?? 0, 841.89, accuracy: 0.5)
    }

    func test_decorate_coverPageAddsOnePage() {
        let options = PDFExportOptions(paperSize: .a4, margins: .normal,
                                       showHeader: true, showFooter: true, coverPage: true)
        let out = PDFDocumentDecorator.decorate(data: makePDF(pageCount: 2),
                                                options: options, title: "Doc")
        XCTAssertNotNil(out)
        XCTAssertEqual(PDFDocument(data: out!)?.pageCount, 3)
    }

    func test_decorate_invalidDataReturnsNil() {
        XCTAssertNil(PDFDocumentDecorator.decorate(data: Data([0, 1, 2]),
                                                   options: .default, title: "x"))
    }

    // MARK: - 后处理决策（PreviewExporter.postProcessPDFData）

    func test_postProcess_defaultOptionsReturnsOriginalUntouched() {
        // 默认选项必须完全不经过 decorate：重绘会丢链接 annotation
        let raw = makePDF(pageCount: 2)
        let out = PreviewExporter.postProcessPDFData(raw, options: .default, title: "Doc")
        XCTAssertEqual(out, raw)
    }

    func test_postProcess_nilOptionsReturnsOriginalUntouched() {
        let raw = makePDF(pageCount: 1)
        XCTAssertEqual(PreviewExporter.postProcessPDFData(raw, options: nil, title: "Doc"), raw)
    }

    func test_postProcess_nonDefaultOptionsDecorates() {
        let raw = makePDF(pageCount: 2)
        let options = PDFExportOptions(showFooter: true)
        let out = PreviewExporter.postProcessPDFData(raw, options: options, title: "Doc")
        XCTAssertNotEqual(out, raw)
        XCTAssertEqual(PDFDocument(data: out)?.pageCount, 2)
    }

    // MARK: - 离屏捕获的 HTML 预处理（PreviewExporter.prepareCaptureHTML）

    /// 管线语义钉住：内联样式表 →（预览缓存）剥离脚本 → 注入附加样式。
    /// 守卫的是「导出捕获页 = 预览渲染产物」这条不变量，顺序错了导出内容会变。
    func test_prepareCaptureHTML_inlinesLinkedCSS() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MEditorCaptureTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "body { color: red; }".write(to: dir.appendingPathComponent("style.css"),
                                         atomically: true, encoding: .utf8)
        let html = #"<html><head><link rel="stylesheet" href="style.css"/></head><body>x</body></html>"#
        let out = PreviewExporter.prepareCaptureHTML(
            html: html, stripsScripts: false, baseDir: dir, extraCSS: nil)
        XCTAssertFalse(out.contains("<link"), "link 标签应被内联替换")
        XCTAssertTrue(out.contains("<style>body { color: red; }</style>"))
    }

    func test_prepareCaptureHTML_stripsScriptsOnlyWhenRequested() {
        let html = "<html><head><script>boot()</script></head><body>x</body></html>"
        let stripped = PreviewExporter.prepareCaptureHTML(
            html: html, stripsScripts: true, baseDir: nil, extraCSS: nil)
        XCTAssertFalse(stripped.contains("<script"), "MEditor 预览缓存导出必须剥离脚本（防 boot 清空内容）")
        let kept = PreviewExporter.prepareCaptureHTML(
            html: html, stripsScripts: false, baseDir: nil, extraCSS: nil)
        XCTAssertTrue(kept.contains("<script>boot()</script>"), "用户 HTML 文件必须保留脚本（JS 渲染图表依赖）")
    }

    func test_prepareCaptureHTML_injectsExtraCSS() {
        let html = "<html><head></head><body>x</body></html>"
        let out = PreviewExporter.prepareCaptureHTML(
            html: html, stripsScripts: false, baseDir: nil, extraCSS: "@page { size: A4; }")
        XCTAssertTrue(out.contains("<style>@page { size: A4; }</style></head>"))
    }

    // MARK: - AppSettings 聚合

    @MainActor
    func test_appSettings_pdfExportOptions_roundTrip() {
        let s = AppSettings.shared
        let old = (s.pdfPaperSize, s.pdfMargins, s.pdfShowHeader, s.pdfShowFooter, s.pdfCoverPage)
        defer {
            s.pdfPaperSize = old.0; s.pdfMargins = old.1
            s.pdfShowHeader = old.2; s.pdfShowFooter = old.3; s.pdfCoverPage = old.4
        }
        s.pdfPaperSize = "letter"
        s.pdfMargins = "wide"
        s.pdfShowHeader = false
        s.pdfShowFooter = false
        s.pdfCoverPage = true
        let options = s.pdfExportOptions
        XCTAssertEqual(options.paperSize, .letter)
        XCTAssertEqual(options.margins, .wide)
        XCTAssertFalse(options.showHeader)
        XCTAssertFalse(options.showFooter)
        XCTAssertTrue(options.coverPage)
        // 非法 rawValue 回退默认
        s.pdfPaperSize = "tabloid"
        XCTAssertEqual(s.pdfExportOptions.paperSize, .a4)
    }
}
