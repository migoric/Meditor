import XCTest
@testable import MEditor

final class PreviewAssetMirrorTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewAssetMirrorTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeFile(_ relative: String, contents: String = "x",
                          modificationDate: Date? = nil) -> URL {
        let url = tempDir.appendingPathComponent(relative)
        try! FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! contents.write(to: url, atomically: true, encoding: .utf8)
        if let modificationDate {
            try! FileManager.default.setAttributes(
                [.modificationDate: modificationDate], ofItemAtPath: url.path)
        }
        return url
    }

    // MARK: - shouldRefresh

    func test_shouldRefresh_sourceNewer_returnsTrue() {
        let src = makeFile("src.txt", modificationDate: Date(timeIntervalSince1970: 2000))
        let dst = makeFile("dst.txt", modificationDate: Date(timeIntervalSince1970: 1000))
        XCTAssertTrue(PreviewAssetMirror.shouldRefresh(src: src, dst: dst))
    }

    func test_shouldRefresh_destinationNewer_returnsFalse() {
        let src = makeFile("src.txt", modificationDate: Date(timeIntervalSince1970: 1000))
        let dst = makeFile("dst.txt", modificationDate: Date(timeIntervalSince1970: 2000))
        XCTAssertFalse(PreviewAssetMirror.shouldRefresh(src: src, dst: dst))
    }

    func test_shouldRefresh_sameDate_returnsFalse() {
        let date = Date(timeIntervalSince1970: 1000)
        let src = makeFile("src.txt", modificationDate: date)
        let dst = makeFile("dst.txt", modificationDate: date)
        XCTAssertFalse(PreviewAssetMirror.shouldRefresh(src: src, dst: dst))
    }

    func test_shouldRefresh_missingSource_returnsTrue() {
        let src = tempDir.appendingPathComponent("nonexistent.txt")
        let dst = makeFile("dst.txt")
        XCTAssertTrue(PreviewAssetMirror.shouldRefresh(src: src, dst: dst))
    }

    // MARK: - mirrorAssets

    /// Build a fake "bundle resources" directory containing a subset of
    /// `mirroredItems`, plus an unrelated file that must not be mirrored.
    private func makeSourceRoot() -> URL {
        let root = tempDir.appendingPathComponent("Source", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try! "body{}".write(to: root.appendingPathComponent("css").appendingPathComponent("themes").appendingPathComponent("github.css"), atomically: true, encoding: .utf8)
        // createDirectory for nested css/themes first
        return root
    }

    private func makeBundleSource() -> URL {
        let root = tempDir.appendingPathComponent("BundlePreview", isDirectory: true)
        let cssDir = root.appendingPathComponent("css/themes", isDirectory: true)
        let scriptsDir = root.appendingPathComponent("scripts", isDirectory: true)
        try! FileManager.default.createDirectory(at: cssDir, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        try! "body{}".write(to: cssDir.appendingPathComponent("github.css"), atomically: true, encoding: .utf8)
        try! "console.log(1)".write(to: scriptsDir.appendingPathComponent("bridge.js"), atomically: true, encoding: .utf8)
        try! "marked".write(to: root.appendingPathComponent("marked.min.js"), atomically: true, encoding: .utf8)
        try! "purify".write(to: root.appendingPathComponent("purify.min.js"), atomically: true, encoding: .utf8)
        try! "hljs".write(to: root.appendingPathComponent("highlight.min.js"), atomically: true, encoding: .utf8)
        try! "katex".write(to: root.appendingPathComponent("katex.min.js"), atomically: true, encoding: .utf8)
        try! "SHOULD-NOT-MIRROR".write(to: root.appendingPathComponent("mermaid.min.js"), atomically: true, encoding: .utf8)
        return root
    }

    func test_mirrorAssets_copiesAllMirroredItems() throws {
        let source = makeBundleSource()
        let cache = tempDir.appendingPathComponent("Cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        PreviewAssetMirror.mirrorAssets(at: cache, copyingFrom: source)

        let fm = FileManager.default
        for item in PreviewAssetMirror.mirroredItems {
            XCTAssertTrue(fm.fileExists(atPath: cache.appendingPathComponent(item).path),
                          "expected \(item) to be mirrored")
        }
        XCTAssertEqual(try String(contentsOf: cache.appendingPathComponent("css/themes/github.css"), encoding: .utf8), "body{}")
        // mermaid.min.js must NOT be mirrored eagerly.
        XCTAssertFalse(fm.fileExists(atPath: cache.appendingPathComponent("mermaid.min.js").path))
    }

    func test_mirrorAssets_skipsMissingSourceItems() throws {
        let source = tempDir.appendingPathComponent("SparseSource", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "marked".write(to: source.appendingPathComponent("marked.min.js"), atomically: true, encoding: .utf8)
        let cache = tempDir.appendingPathComponent("SparseCache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        PreviewAssetMirror.mirrorAssets(at: cache, copyingFrom: source)

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: cache.appendingPathComponent("marked.min.js").path))
        XCTAssertFalse(fm.fileExists(atPath: cache.appendingPathComponent("css").path))
    }

    func test_mirrorAssets_refreshesStaleDestination() throws {
        let source = makeBundleSource()
        let cache = tempDir.appendingPathComponent("StaleCache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        // Pre-existing stale copy: plain file (not a hard link) with an old mtime.
        let staleMarked = cache.appendingPathComponent("marked.min.js")
        try "OLD".write(to: staleMarked, atomically: true, encoding: .utf8)
        let old = Date(timeIntervalSince1970: 1000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: staleMarked.path)
        // Make sure the source reads newer than the stale copy.
        let srcMarked = source.appendingPathComponent("marked.min.js")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2000)], ofItemAtPath: srcMarked.path)

        PreviewAssetMirror.mirrorAssets(at: cache, copyingFrom: source)

        XCTAssertEqual(try String(contentsOf: staleMarked, encoding: .utf8), "marked")
    }

    func test_mirrorAssets_keepsUpToDateDestination() throws {
        let source = makeBundleSource()
        let cache = tempDir.appendingPathComponent("FreshCache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        // Destination newer than source → must be left untouched.
        let dstMarked = cache.appendingPathComponent("marked.min.js")
        try "CUSTOM".write(to: dstMarked, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 3000)], ofItemAtPath: dstMarked.path)
        let srcMarked = source.appendingPathComponent("marked.min.js")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2000)], ofItemAtPath: srcMarked.path)

        PreviewAssetMirror.mirrorAssets(at: cache, copyingFrom: source)

        XCTAssertEqual(try String(contentsOf: dstMarked, encoding: .utf8), "CUSTOM")
    }

    // MARK: - 目录条目覆盖判据（directoryNeedsRefresh）

    /// 目录只看 mtime 会漏新增文件：源目录里多了一个条目而目标目录 mtime 更新时
    /// （CI 解包 / 增量构建的典型情形），仍必须判定为需要刷新。
    func test_directoryNeedsRefresh_sourceHasNewEntry_returnsTrue() throws {
        let srcCSS = tempDir.appendingPathComponent("DirSrc/css", isDirectory: true)
        let dstCSS = tempDir.appendingPathComponent("DirDst/css", isDirectory: true)
        try FileManager.default.createDirectory(at: srcCSS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dstCSS, withIntermediateDirectories: true)
        try "new".write(to: srcCSS.appendingPathComponent("katex.min.css"), atomically: true, encoding: .utf8)

        XCTAssertTrue(PreviewAssetMirror.directoryNeedsRefresh(src: srcCSS, dst: dstCSS, fileManager: .default))
    }

    /// 二级目录里的新文件也必须被发现——只看顶层会漏（css/fonts/ 新增字体）。
    func test_directoryNeedsRefresh_nestedNewFile_returnsTrue() throws {
        let srcCSS = tempDir.appendingPathComponent("NestedSrc/css", isDirectory: true)
        let dstCSS = tempDir.appendingPathComponent("NestedDst/css", isDirectory: true)
        try FileManager.default.createDirectory(at: srcCSS.appendingPathComponent("fonts"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dstCSS.appendingPathComponent("fonts"), withIntermediateDirectories: true)
        // 两边都有 fonts/，差别只在 fonts/ 里头多了一份字体
        try "same".write(to: srcCSS.appendingPathComponent("fonts/KaTeX_Main-Regular.woff2"), atomically: true, encoding: .utf8)
        try "same".write(to: dstCSS.appendingPathComponent("fonts/KaTeX_Main-Regular.woff2"), atomically: true, encoding: .utf8)
        XCTAssertFalse(PreviewAssetMirror.directoryNeedsRefresh(src: srcCSS, dst: dstCSS, fileManager: .default))

        try "extra".write(to: srcCSS.appendingPathComponent("fonts/KaTeX_Size4-Regular.woff2"), atomically: true, encoding: .utf8)
        XCTAssertTrue(PreviewAssetMirror.directoryNeedsRefresh(src: srcCSS, dst: dstCSS, fileManager: .default),
                      "新增的二级目录文件必须被识别")
    }

    /// 目标目录条目完全覆盖源目录时不需要刷新（避免每轮预览都重拷整个目录）。
    func test_directoryNeedsRefresh_fullyMirrored_returnsFalse() throws {
        let srcCSS = tempDir.appendingPathComponent("FullSrc/css", isDirectory: true)
        let dstCSS = tempDir.appendingPathComponent("FullDst/css", isDirectory: true)
        for base in [srcCSS, dstCSS] {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            try "a".write(to: base.appendingPathComponent("base.css"), atomically: true, encoding: .utf8)
        }
        XCTAssertFalse(PreviewAssetMirror.directoryNeedsRefresh(src: srcCSS, dst: dstCSS, fileManager: .default))
    }

    /// 端到端：目标 css/ 已存在但缺 katex 资源，镜像后必须补齐
    ///（回归：修前只看 mtime，目标更新时新文件会永远漏下去）。
    func test_mirrorAssets_completesPartiallyMirroredDirectory() throws {
        let source = tempDir.appendingPathComponent("PartialSrc", isDirectory: true)
        let sourceCSS = source.appendingPathComponent("css", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceCSS, withIntermediateDirectories: true)
        try "old".write(to: sourceCSS.appendingPathComponent("base.css"), atomically: true, encoding: .utf8)
        try "new".write(to: sourceCSS.appendingPathComponent("katex.min.css"), atomically: true, encoding: .utf8)

        let cache = tempDir.appendingPathComponent("PartialCache", isDirectory: true)
        let cacheCSS = cache.appendingPathComponent("css", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheCSS, withIntermediateDirectories: true)
        try "old".write(to: cacheCSS.appendingPathComponent("base.css"), atomically: true, encoding: .utf8)
        // 目标 css/ 的 mtime 比源新：这正是修前会跳过刷新的条件
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 5000)], ofItemAtPath: cacheCSS.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 4000)], ofItemAtPath: sourceCSS.path)

        PreviewAssetMirror.mirrorAssets(at: cache, copyingFrom: source)

        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheCSS.appendingPathComponent("katex.min.css").path),
                      "新增的 css 资源必须被补齐")
    }

    // MARK: - pruneCacheIfNeeded

    func test_pruneCache_underLimit_keepsDirectory() throws {
        let dir = tempDir.appendingPathComponent("SmallCache", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "tiny".write(to: dir.appendingPathComponent("preview.html"), atomically: true, encoding: .utf8)

        PreviewAssetMirror.pruneCacheIfNeeded(at: dir, sizeLimit: 1024 * 1024)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("preview.html").path))
    }

    func test_pruneCache_overLimit_wipesDirectory() throws {
        let dir = tempDir.appendingPathComponent("BigCache", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try String(repeating: "x", count: 4096).write(to: dir.appendingPathComponent("preview.html"), atomically: true, encoding: .utf8)

        PreviewAssetMirror.pruneCacheIfNeeded(at: dir, sizeLimit: 1)

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func test_pruneCache_missingDirectory_noOp() {
        let dir = tempDir.appendingPathComponent("NoSuchDir", isDirectory: true)
        // Must not crash or create anything.
        PreviewAssetMirror.pruneCacheIfNeeded(at: dir, sizeLimit: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    // MARK: - jsonEncode

    func test_jsonEncode_producesValidJSONStringLiteral() throws {
        let encoded = try XCTUnwrap(PreviewAssetMirror.jsonEncode(string: "hello \"world\"\nline2"))
        let data = try XCTUnwrap(encoded.data(using: .utf8))
        let decoded = try JSONDecoder().decode(String.self, from: data)
        XCTAssertEqual(decoded, "hello \"world\"\nline2")
    }

    // MARK: - escapedInitialContentJSON

    /// 初始内容写进 <script type="application/json"> 数据块：内容里的 "</script>"
    /// 必须被转义，否则会提前闭合数据块变成可执行脚本（XSS）。
    func test_escapedInitialContentJSON_closesScriptTagSafely() throws {
        let payload = "before </script><script>alert(1)</script> after"
        let encoded = PreviewAssetMirror.escapedInitialContentJSON(payload)

        XCTAssertFalse(encoded.contains("</script>"), "closing tag must be escaped")
        XCTAssertFalse(encoded.contains("<"), "no raw '<' may survive")

        // 仍是合法 JSON，且解码后还原原文。
        let unescaped = encoded.replacingOccurrences(of: "\\u003c", with: "<")
        let data = try XCTUnwrap(unescaped.data(using: .utf8))
        let decoded = try JSONDecoder().decode(String.self, from: data)
        XCTAssertEqual(decoded, payload)
    }

    // MARK: - Mermaid 按需供给（provisionMermaid）

    /// 造一个含 mermaid.min.js 的合成源目录。
    private func makeMermaidSource(contents: String = "MERMAID-PAYLOAD") throws -> URL {
        let source = tempDir.appendingPathComponent("MermaidSrc", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try contents.write(to: source.appendingPathComponent("mermaid.min.js"),
                           atomically: true, encoding: .utf8)
        return source
    }

    private func makeCacheDir(_ name: String) throws -> URL {
        let cache = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        return cache
    }

    /// 首调必须真的把 mermaid.min.js 拷进缓存目录（内容一致），
    /// 且二次调用是纯 no-op（置位后不再碰文件系统）。
    func test_provisionMermaid_copiesOnFirstCall_andIsIdempotent() throws {
        PreviewAssetMirror.resetMermaidProvisionedForTesting()
        defer { PreviewAssetMirror.resetMermaidProvisionedForTesting() }

        let source = try makeMermaidSource()
        let cache = try makeCacheDir("MermaidCache")
        let dst = cache.appendingPathComponent("mermaid.min.js")

        PreviewAssetMirror.provisionMermaid(from: source, at: cache)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.path),
                      "首调必须拷贝 mermaid.min.js 到缓存目录")
        XCTAssertEqual(try String(contentsOf: dst, encoding: .utf8), "MERMAID-PAYLOAD")

        // 幂等性：把目标替换成哨兵值后再调，必须原样不动。
        // （此时标志已置位、目标文件也存在，两条短路任一成立都必须是 no-op；
        // 标志的独立贡献——失败时不置位、可重试——由 missingSource 测试钉住。）
        try "SENTINEL".write(to: dst, atomically: true, encoding: .utf8)
        PreviewAssetMirror.provisionMermaid(from: source, at: cache)
        XCTAssertEqual(try String(contentsOf: dst, encoding: .utf8), "SENTINEL",
                       "标志已置位，二次调用必须是 no-op")
    }

    /// 缓存里已有 mermaid.min.js（上次预览留下）时不重复拷贝。
    func test_provisionMermaid_existingDestination_skipsCopy() throws {
        PreviewAssetMirror.resetMermaidProvisionedForTesting()
        defer { PreviewAssetMirror.resetMermaidProvisionedForTesting() }

        let source = try makeMermaidSource()
        let cache = try makeCacheDir("ExistingCache")
        let dst = cache.appendingPathComponent("mermaid.min.js")
        try "CUSTOM".write(to: dst, atomically: true, encoding: .utf8)

        PreviewAssetMirror.provisionMermaid(from: source, at: cache)

        XCTAssertEqual(try String(contentsOf: dst, encoding: .utf8), "CUSTOM",
                       "目标已存在时必须保留，不覆盖")
    }

    /// 源里没有 mermaid.min.js（打包缺文件）或拷贝失败时**不得置位**——置位
    /// 意味着本进程内 mermaid 永久缺失（目录恰好被并发 prune 掉就是这种）。
    /// 重试的代价只是一次 stat。后验：源随后出现时必须补拷成功。
    func test_provisionMermaid_missingSource_retriesWhenSourceAppears() throws {
        PreviewAssetMirror.resetMermaidProvisionedForTesting()
        defer { PreviewAssetMirror.resetMermaidProvisionedForTesting() }

        let source = tempDir.appendingPathComponent("EmptyMermaidSrc", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let cache = try makeCacheDir("MissingSrcCache")
        let dst = cache.appendingPathComponent("mermaid.min.js")

        PreviewAssetMirror.provisionMermaid(from: source, at: cache)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst.path), "无源时不得凭空造文件")

        // 源随后出现（模拟延迟挂载）：未置位 ⇒ 重试必须补拷。
        try "LATE".write(to: source.appendingPathComponent("mermaid.min.js"),
                         atomically: true, encoding: .utf8)
        PreviewAssetMirror.provisionMermaid(from: source, at: cache)
        XCTAssertEqual(try String(contentsOf: dst, encoding: .utf8), "LATE",
                       "失败/缺源不置位，源出现后必须能补拷")
    }

    /// 并发首调：8 个上下文同时首次触发，必须全部安全返回、文件恰好一份、
    /// 内容正确。锁的真正价值（消除 nonisolated(unsafe) 逃逸、避免重复
    /// copyItem 被 try? 静默吞掉）在本环境无法确定性验证——无锁时本测试
    /// 大概率仍绿（后到者 copyItem 失败也被 try? 吞掉），其确定性部分是
    /// 「不挂住、不崩、拷出来的内容对」。
    func test_provisionMermaid_concurrentFirstCalls_areSafeAndCopyOnce() throws {
        PreviewAssetMirror.resetMermaidProvisionedForTesting()
        defer { PreviewAssetMirror.resetMermaidProvisionedForTesting() }

        let source = try makeMermaidSource()
        let cache = try makeCacheDir("ConcurrentCache")
        let dst = cache.appendingPathComponent("mermaid.min.js")

        let group = DispatchGroup()
        let queue = DispatchQueue(
            label: "mermaid-provision-\(UUID().uuidString)",
            attributes: .concurrent
        )
        for _ in 0..<8 {
            queue.async(group: group) {
                PreviewAssetMirror.provisionMermaid(from: source, at: cache)
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success, "并发首调不应挂住")

        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.path))
        XCTAssertEqual(try String(contentsOf: dst, encoding: .utf8), "MERMAID-PAYLOAD",
                       "并发首调后文件内容必须完整（不是半个写入）")
    }

    // MARK: - Mermaid 按需供给（ensureMermaidProvisioned 包装层）

    /// ensure 包装层的降级语义：资源定位不到时不得崩。
    ///
    /// 实证：`swift test` 下 `PreviewResourceLocator.resourcesRoot()` 解析为
    /// nil（Bundle.main 是 Xcode 的 xctest 启动器 `/Applications/Xcode.app/
    /// Contents/Developer/usr/bin`，三个候选路径全部落空），所以本测试实际
    /// 跑的就是「定位失败」分支——断言它安静返回即可；拷贝路径的覆盖由上面
    /// 4 个 provisionMermaid 直接测试承担。
    func test_ensureMermaidProvisioned_unresolvedResources_staysSilent() {
        PreviewAssetMirror.resetMermaidProvisionedForTesting()
        defer { PreviewAssetMirror.resetMermaidProvisionedForTesting() }

        let cache = tempDir.appendingPathComponent("EnsureCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        // 不得抛、不得崩；本环境定位不到资源，预期不产生任何文件。
        PreviewAssetMirror.ensureMermaidProvisioned(at: cache)
        PreviewAssetMirror.ensureMermaidProvisioned(at: cache)
    }
}
