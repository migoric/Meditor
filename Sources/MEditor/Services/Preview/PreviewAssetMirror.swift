import Foundation

/// Mirrors the bundle's static preview resources (`template.html`, `css/`,
/// `scripts/`, `marked.min.js`, …) into a cache directory, so the WKWebView
/// can load `preview.html` via `loadFileURL` with relative asset URLs resolved
/// and a stable `allowingReadAccessTo` root.
///
/// Extracted from `MarkdownWebPreview` (view layer) so the file-management
/// logic is testable and can run off the main thread. 写者间的互斥由
/// `cacheWriteLock` 承担（见下）——预热与真实预览会并发写同一个 cache dir，
/// 「调用方保证单写者」的约定在 warmUp 后台化之后已不成立。
enum PreviewAssetMirror {

    /// Assets mirrored eagerly on every preview init.
    /// mermaid.min.js (3.3 MB) is excluded here — it's copied on-demand
    /// the first time a document contains a ```mermaid block. This saves
    /// ~50-100ms of file I/O on every preview initialization for the 95%+
    /// of documents that don't use mermaid diagrams.
    ///
    /// katex.min.js（267KB）按启发式同步镜像：公式出现的频率远高于图表，
    /// 而且一旦懒加载，长文档滚动时公式会陆续弹出。KaTeX 样式与字体（
    /// css/katex.min.css 与 css/fonts/*.woff2）随 `css` 目录一起镜像。
    static let mirroredItems = ["css", "scripts", "marked.min.js", "purify.min.js", "highlight.min.js", "katex.min.js"]

    /// Hard cap on preview cache size. Beyond this we wipe the directory
    /// and let it rebuild on next render. mermaid.min.js (~3.3 MB) and
    /// the preview HTML are the only persistent artefacts.
    static let cacheSizeLimit: Int64 = 50 * 1024 * 1024  // 50 MB

    // MARK: - Pure decision logic (unit-testable)

    /// Decide whether `dst` should be replaced by `src`: true when the source
    /// is newer than the destination, or when attributes can't be read.
    static func shouldRefresh(src: URL, dst: URL, fileManager fm: FileManager = .default) -> Bool {
        guard let srcAttrs = try? fm.attributesOfItem(atPath: src.path),
              let dstAttrs = try? fm.attributesOfItem(atPath: dst.path) else {
            return true
        }
        let srcDate = srcAttrs[.modificationDate] as? Date ?? .distantPast
        let dstDate = dstAttrs[.modificationDate] as? Date ?? .distantPast
        return srcDate > dstDate
    }

    /// Mirror one asset: directories are copied wholesale; files are
    /// hard-linked (falling back to copy when linking is unsupported).
    static func mirrorAsset(src: URL, dst: URL, isDirectory: Bool, fileManager fm: FileManager = .default) {
        if isDirectory {
            try? fm.copyItem(at: src, to: dst)
            return
        }
        do {
            try fm.linkItem(at: src, to: dst)
        } catch {
            try? fm.copyItem(at: src, to: dst)
        }
    }

    /// Mirror all `mirroredItems` from `source` into `cacheDir`, refreshing
    /// entries whose source is newer than the mirrored copy.
    static func mirrorAssets(at cacheDir: URL, copyingFrom source: URL, fileManager fm: FileManager = .default) {
        for item in mirroredItems {
            let src = source.appendingPathComponent(item)
            let dst = cacheDir.appendingPathComponent(item)
            guard fm.fileExists(atPath: src.path) else { continue }
            let isDirectory = (try? src.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            // If destination exists and the source is newer, refresh.
            if fm.fileExists(atPath: dst.path) {
                // 目录不能只看 mtime：新增资源（如 css/katex.min.css、css/fonts/*.woff2）
                // 落在源目录里，但上次镜像的副本 mtime 可能更新，新文件会被整个漏掉
                // ——表现为「升级后公式字体缺失」。目录改用条目覆盖判据。
                let needsRefresh = isDirectory
                    ? directoryNeedsRefresh(src: src, dst: dst, fileManager: fm)
                    : shouldRefresh(src: src, dst: dst, fileManager: fm)
                if needsRefresh {
                    try? fm.removeItem(at: dst)
                    mirrorAsset(src: src, dst: dst, isDirectory: isDirectory, fileManager: fm)
                }
            } else {
                mirrorAsset(src: src, dst: dst, isDirectory: isDirectory, fileManager: fm)
            }
        }
    }

    /// 目标目录是否缺少源目录里的条目。
    ///
    /// 只看顶层不够：`css/fonts/` 是二级目录，新增的字体在 `css/` 顶层列表里
    /// 只体现为「`fonts` 已存在」⇒ 必须递归比较相对路径集合。
    static func directoryNeedsRefresh(src: URL, dst: URL, fileManager fm: FileManager) -> Bool {
        let sourcePaths = relativePaths(under: src, fileManager: fm)
        guard !sourcePaths.isEmpty else { return false }
        return !sourcePaths.isSubset(of: relativePaths(under: dst, fileManager: fm))
    }

    /// 目录下所有条目（含子目录）相对于 `root` 的路径集合。
    static func relativePaths(under root: URL, fileManager fm: FileManager) -> Set<String> {
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        let baseDepth = root.pathComponents.count
        var paths: Set<String> = []
        for case let url as URL in enumerator {
            let relative = url.pathComponents.dropFirst(baseDepth).joined(separator: "/")
            if !relative.isEmpty { paths.insert(relative) }
        }
        return paths
    }

    /// Inspect the preview cache directory and wipe it if it has grown
    /// beyond `sizeLimit`. Cheap to call: only walks immediate
    /// children, no deep recursion.
    static func pruneCacheIfNeeded(at dir: URL, sizeLimit: Int64 = cacheSizeLimit, fileManager fm: FileManager = .default) {
        guard let contents = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
            options: [.skipsSubdirectoryDescendants]
        ) else { return }
        var total: Int64 = 0
        for url in contents {
            if let size = (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                .totalFileAllocatedSize {
                total += Int64(size)
            }
        }
        if total > sizeLimit {
            // Removing the whole directory is safe — it will be re-created
            // and resources re-copied on the next preview load.
            try? fm.removeItem(at: dir)
        }
    }

    // MARK: - Mermaid (on-demand)

    /// 首次按需拷贝 mermaid.min.js 到预览缓存目录的标志。
    /// ensureMermaidProvisioned 是 nonisolated static，多个预览可能并发首次触发
    /// ⇒ 无锁时两个上下文都会看到 false、都去 copyItem，第二个撞上已存在的目标文件
    /// 静默失败（try? 吞掉），表现为「偶发没有 mermaid」。
    private static let mermaidLock = NSLock()
    nonisolated(unsafe) private static var mermaidProvisioned = false

    /// 同一个 cache dir 的写盘必须串行。
    ///
    /// `WebViewPool.warmUp` 把 `prepareHTML` 挪进 `Task.detached` 之后，预热与真实
    /// 预览会**并发**写同一个 `caches/com.meditor.preview`：`mirrorAssets` 在需要刷新
    /// 时先 `removeItem(css|scripts|marked.min.js…)`，`pruneCacheIfNeeded` 甚至整目录删
    /// ——正好删在另一个上下文的 `loadFileURL` 加载过程中，表现是有样式缺失 / 白屏。
    /// 这里把「prune + mirror + 写 preview.html + 按需拷 mermaid」整段串行化。
    ///
    /// 只串行化写者；WKWebView 侧读 preview.html 不在锁内（读取要等写者跑完才可能
    /// 看到完整目录，因为镜像在 `preview.html` 之前完成）。
    private static let cacheWriteLock = NSLock()

    /// Copy mermaid.min.js into the preview cache dir on first need.
    ///
    /// 资源定位与拷贝分离：定位（依赖 Bundle 布局）在这里，锁内的
    /// 「检查 + 拷贝 + 置位」在 `provisionMermaid(from:at:)`。拆分让测试
    /// 能注入合成源目录——`swift test` 下 `PreviewResourceLocator` 依赖的
    /// `Bundle.main` 是 Xcode 的 xctest 启动器（实测解析为 nil），不拆的
    /// 话这段拷贝逻辑在测试里一行都跑不到。
    static func ensureMermaidProvisioned(at cacheDir: URL, fileManager fm: FileManager = .default) {
        // 锁外调用点（预览 / mermaid 校验器）也要互斥：拷贝目标目录可能被
        // 另一上下文的 pruneCacheIfNeeded 整目录删掉。
        cacheWriteLock.withLock {
            ensureMermaidProvisionedLocked(at: cacheDir, fileManager: fm)
        }
    }

    /// 调用方必须已持 cacheWriteLock（如 prepareHTML）。
    private static func ensureMermaidProvisionedLocked(at cacheDir: URL, fileManager fm: FileManager) {
        // 定位失败不置位：下次预览打开还可重试（打包缺文件时不该永久放弃）。
        guard let root = PreviewResourceLocator.resourcesRoot() else { return }
        provisionMermaid(from: root, at: cacheDir, fileManager: fm)
    }

    /// 锁内的「检查 + 拷贝 + 置位」。`sourceRoot` 是含 mermaid.min.js 的目录。
    ///
    /// 整个临界区持锁：只锁检查的话，两个上下文会先后通过检查再重复拷贝，
    /// 第二个 copyItem 撞上已存在的目标文件、被 try? 静默吞掉——表现为
    /// 「偶发没有 mermaid」。首调是启动期一次性动作，持锁成本可忽略。
    static func provisionMermaid(from sourceRoot: URL,
                                 at cacheDir: URL,
                                 fileManager fm: FileManager = .default) {
        mermaidLock.withLock {
            guard !mermaidProvisioned else { return }
            let dst = cacheDir.appendingPathComponent("mermaid.min.js")
            if fm.fileExists(atPath: dst.path) { mermaidProvisioned = true; return }
            let src = sourceRoot.appendingPathComponent("mermaid.min.js")
            // 只有真的拷上了才置位：失败（比如目录恰好被并发 prune 整目录删掉）
            // 时置位等于本进程内 mermaid 永久缺失；不置位则下次触发自然重试，
            // 代价只是一次 stat。
            guard fm.fileExists(atPath: src.path),
                  (try? fm.copyItem(at: src, to: dst)) != nil else { return }
            mermaidProvisioned = true
        }
    }

    #if DEBUG
    /// 测试专用复位：mermaidProvisioned 是进程级静态标志，一旦置位对后续测试
    /// 一直可见（跨测试用例污染）。仅 DEBUG 编译，不进 Release 包。
    static func resetMermaidProvisionedForTesting() {
        mermaidLock.withLock { mermaidProvisioned = false }
    }
    #endif

    // MARK: - Template preparation

    /// Render `template.html` with substituted values, mirror the assets and
    /// write `preview.html` into `cacheDir`. Returns the file URL to load,
    /// or nil when the template resource is missing.
    ///
    /// 文件名固定为 preview.html，每次初始化重写覆盖；force-reload 通过
    /// 重新 loadFileURL 加载同一 URL 来绕过 WKWebView 的缓存。
    ///
    /// `resourcesRoot` / `templateURL` 可注入（同 `ensureMermaidProvisioned`
    /// 的理由）：`swift test` 下 `PreviewResourceLocator` 解析为 nil，不注入的话
    /// 这段逻辑在测试里一行都跑不到。
    @discardableResult
    static func prepareHTML(initialContent: String,
                            theme: PreviewTheme,
                            cacheDir: URL,
                            fileManager fm: FileManager = .default,
                            resourcesRoot: URL? = PreviewResourceLocator.resourcesRoot(),
                            templateURL: URL? = PreviewResourceLocator.templateURL()) -> URL? {
        guard let resourcesRoot, let templateURL,
              let template = try? String(contentsOf: templateURL, encoding: .utf8) else {
            return nil
        }

        let contentJSON = escapedInitialContentJSON(initialContent)
        let html = template
            .replacingOccurrences(of: "{{INITIAL_THEME}}", with: theme.rawValue)
            .replacingOccurrences(of: "{{INITIAL_CONTENT_JSON}}", with: contentJSON)

        // Write to caches so loadFileURL can grant readAccessTo a stable directory.
        // 整段写盘持锁：另一个上下文（预热 / 另一个预览）可能正在同一目录里
        // removeItem 或整目录 prune，见 cacheWriteLock 的说明。
        let fileURL = cacheDir.appendingPathComponent("preview.html")
        cacheWriteLock.withLock {
            try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            // Best-effort: prune if the cache has grown unreasonably large.
            pruneCacheIfNeeded(at: cacheDir, fileManager: fm)
            // Symlink (or copy) the resources into cache dir so relative paths work.
            mirrorAssets(at: cacheDir, copyingFrom: resourcesRoot, fileManager: fm)
            // 锚点守卫（markdown 预览）：单独写成脚本文件，因为模板的 CSP 是
            // `script-src 'self' file:`——内联脚本会被拦掉。口径是 strict：
            // 只接管纯 `#fragment`，跨文档链接交回 PreviewLinkNavigator。
            writeAnchorGuard(into: cacheDir, fileManager: fm)
            // 镜像先于 preview.html 落盘：读侧看到 preview.html 时，相对资源一定已在。
            try? html.write(to: fileURL, atomically: true, encoding: .utf8)

            // Provision mermaid.min.js only if initial content needs it.
            if initialContent.contains("```mermaid") {
                ensureMermaidProvisionedLocked(at: cacheDir, fileManager: fm)
            }
        }
        return fileURL
    }

    /// 把 markdown 预览用的锚点守卫写到 `<cacheDir>/scripts/anchor-guard.js`。
    ///
    /// 为什么是文件而不是 `WKUserScript`：markdown 预览的 webview 有两处构造
    /// （`WebViewPool.warmUp` 的预热、`MarkdownWebPreview` 的冷启动），用户脚本得
    /// 两处都加，漏一处就是「有时候点了没反应」。写进模板引用的资源文件则只有一份，
    /// 预热与冷启动读到的是同一个页面。模板里必须用 `<script src>` 引（CSP 禁内联）。
    private static func writeAnchorGuard(into cacheDir: URL, fileManager fm: FileManager) {
        let scriptsDir = cacheDir.appendingPathComponent("scripts", isDirectory: true)
        try? fm.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        let url = scriptsDir.appendingPathComponent("anchor-guard.js")
        try? HTMLAnchorGuard.script(interceptsFileNameLinks: false)
            .write(to: url, atomically: true, encoding: .utf8)
    }

    /// Run `prepareHTML` on a background queue; `completion` fires on the
    /// main thread. Keeps template read + asset mirroring off the main thread
    /// so first preview open doesn't stall UI.
    static func prepareHTMLAsync(initialContent: String,
                                 theme: PreviewTheme,
                                 cacheDir: URL,
                                 completion: @escaping @MainActor (URL?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fileURL = prepareHTML(initialContent: initialContent, theme: theme, cacheDir: cacheDir)
            DispatchQueue.main.async {
                completion(fileURL)
            }
        }
    }

    static func jsonEncode(string: String) -> String? {
        guard let data = try? JSONEncoder().encode(string) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 初始内容现在以 <script type="application/json"> 数据块传递（CSP
    /// 禁内联脚本）。JSON 串里的 "<" 必须转成 Unicode 转义（'\\u003c'），
    /// 否则内容中的 "</script>" 会提前闭合数据块，把文档内容变成可执行脚本。
    static func escapedInitialContentJSON(_ initialContent: String) -> String {
        return (jsonEncode(string: initialContent) ?? "\"\"")
            .replacingOccurrences(of: "<", with: "\\u003c")
    }
}
