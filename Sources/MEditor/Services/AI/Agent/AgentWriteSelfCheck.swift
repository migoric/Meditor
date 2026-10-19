import Foundation
import Observation

/// Agent 写后自检：AI 是文档的唯一作者，写工具内容生效后自动跑一遍本地诊断。
///
/// 挂点在最下游统一写入点（AppStateDocumentAdapter 的 writeDocument/patchDocument/
/// notifyFileWritten——内容已应用到 tab / 落盘之后），不在工具调用点：
/// diff 预览确认、回滚等链路最终都汇入这几个点，只触发一次不重复。
/// 用户手动编辑不经过这些路径，既有诊断行为（诊断面板手动扫描）不变。
///
/// 防打扰：同一静默窗口内的连续写入按文件合并，只在最后一改后跑一次；
/// Agent run 仍在进行（shouldDefer）时到点顺延一个窗口，避免拿中途态误报。
@MainActor
@Observable
final class AgentWriteSelfCheck {

    /// 一次防抖合并后的自检结果。
    /// fixable = 文本层面可确定性修复（进「一键修复」列表）；
    /// reportOnly = 结果可能受外部因素影响（死链目标可能稍后才创建、缺图是
    /// 资源缺失），只报告不自动改。
    struct Report: Equatable {
        var fileURLs: [URL]
        var fixable: [DocumentIssue]
        var reportOnly: [DocumentIssue]
        var totalCount: Int { fixable.count + reportOnly.count }
        /// 一键修复的目标文档（第一个有可修问题的文件；多文件报告逐个修，从它开始）
        var fixTarget: URL? { fixable.first?.fileURL }
    }

    /// 有未处理问题时报非 nil，AI 面板据此显示报告条。最新一次检查结果整体
    /// 替换旧值：最后一改后复查干净则回到 nil（静默），不打扰。
    private(set) var pendingReport: Report?

    /// 合并窗口内各文件的最新内容（key = 标准化路径）。同文档连写只留最新一份。
    @ObservationIgnored private var pendingWrites: [String: (url: URL, content: String)] = [:]
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    /// 上一轮未完成的 mermaid 异步校验；新一轮自检开始 / 用户忽略报告时取消，
    /// 迟到的结果不得合并进新报告。
    @ObservationIgnored private var mermaidValidationTask: Task<Void, Never>?

    /// 静默窗口时长（默认 1.5s；测试注入短间隔）。
    let debounceInterval: TimeInterval
    /// 到点时 Agent run 是否仍在进行（是则顺延一个窗口，只在 run 收尾后报告）。
    /// 由 AppState 接线到 aiConversation.isResponding；测试可注入。
    @ObservationIgnored var shouldDefer: () -> Bool = { false }
    /// 链接/图片目标存在性检查（测试注入，避免碰真实磁盘）。
    @ObservationIgnored var fileExists: (URL) -> Bool = {
        FileManager.default.fileExists(atPath: $0.path)
    }
    /// Mermaid 语法校验器：同步诊断之后异步跑真 mermaid.parse（隐藏 WKWebView）。
    /// 默认是懒初始化的 WebKit 实现（不建引擎直到真的有 mermaid 块）；测试注入 mock。
    /// 置 nil 可整体关闭异步校验。
    #if os(macOS)
    @ObservationIgnored var mermaidValidator: (any MermaidSyntaxChecking)? = MermaidWebKitValidator()
    #else
    @ObservationIgnored var mermaidValidator: (any MermaidSyntaxChecking)?
    #endif
    /// 每次实际执行检查后回调（参数为本次检查的文件数）——防抖合并的测试观测点；
    /// 发现新问题时也会回调 onReport。
    @ObservationIgnored var onDidRunChecks: ((Int) -> Void)?
    /// 检查发现新问题时回调（AppState 接线 toast 通知）；复查干净不回调（静默）。
    @ObservationIgnored var onReport: ((Report) -> Void)?

    init(debounceInterval: TimeInterval = 1.5) {
        self.debounceInterval = debounceInterval
    }

    deinit {
        debounceTask?.cancel()
        mermaidValidationTask?.cancel()
    }

    /// Agent 写入生效后调用（可多次；同文件只保留最新内容）。
    func notifyAgentWrite(url: URL, content: String) {
        pendingWrites[url.standardizedFileURL.path] = (url, content)
        schedule()
    }

    /// 用户关掉报告条（「忽略」）。进行中的 mermaid 校验一并取消，
    /// 否则迟到的合并会让刚被忽略的报告条复活。
    func dismissReport() {
        mermaidValidationTask?.cancel()
        mermaidValidationTask = nil
        pendingReport = nil
    }

    // MARK: - 内部

    private func schedule() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.debounceInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // run 还在进行（Agent 可能还要继续改）：顺延一个窗口，不拿中途态误报
            if self.shouldDefer() { self.schedule(); return }
            self.runPendingChecks()
        }
    }

    /// 执行一次合并检查（防抖触发；测试也可直接同步调用）。
    func runPendingChecks() {
        let batch = pendingWrites
        pendingWrites.removeAll()
        guard !batch.isEmpty else { return }

        // 新一轮自检开始：取消上一轮未完成的 mermaid 校验，
        // 它若迟到合并会把上一批内容的结果混进新报告
        mermaidValidationTask?.cancel()
        mermaidValidationTask = nil

        var fixable: [DocumentIssue] = []
        var reportOnly: [DocumentIssue] = []
        for entry in batch.values {
            let issues = DocumentDiagnostics.issues(
                in: entry.content, fileURL: entry.url, fileExists: fileExists)
            for issue in issues {
                if issue.kind.isDeterministicFix {
                    fixable.append(issue)
                } else {
                    reportOnly.append(issue)
                }
            }
        }
        onDidRunChecks?(batch.count)

        // 排序与诊断面板一致（路径 + 行号），多文件报告按路径聚合
        let order: (DocumentIssue, DocumentIssue) -> Bool = {
            $0.fileURL.path != $1.fileURL.path
                ? $0.fileURL.path < $1.fileURL.path
                : $0.line < $1.line
        }
        fixable.sort(by: order)
        reportOnly.sort(by: order)

        if fixable.count + reportOnly.count > 0 {
            let report = Report(
                fileURLs: batch.values.map(\.url).sorted { $0.path < $1.path },
                fixable: fixable,
                reportOnly: reportOnly)
            pendingReport = report
            onReport?(report)
        } else {
            pendingReport = nil   // 复查干净：静默，不打扰
        }

        // 同步诊断不含 mermaid 语法（本地规则猜不了语法）：
        // 含 ```mermaid 块的文件再起一轮异步真校验（mermaid.parse），
        // 错误以 reportOnly 合并进报告——修复要靠模型，不是确定性文本修复。
        startMermaidValidation(batch: batch)
    }

    /// 对本批写入内容里的 ```mermaid 块逐个跑真语法校验（串行）。
    /// 校验器为 nil（测试关闭）或没有 mermaid 块时直接返回，不付 webview 成本。
    private func startMermaidValidation(batch: [String: (url: URL, content: String)]) {
        guard let validator = mermaidValidator else { return }
        let jobs: [(url: URL, line: Int, code: String)] = batch.values.flatMap { entry in
            MermaidBlocks.extract(from: entry.content).map {
                (url: entry.url, line: $0.startLine, code: $0.code)
            }
        }
        guard !jobs.isEmpty else { return }
        mermaidValidationTask = Task { [weak self] in
            var issues: [DocumentIssue] = []
            for job in jobs {
                if Task.isCancelled { return }
                if let message = await validator.validate(code: job.code) {
                    issues.append(DocumentIssue(
                        kind: .mermaidSyntax(message), fileURL: job.url, line: job.line))
                }
            }
            // 已被新一轮取消 / 校验干净：不合并（干净不动既有报告，静默）
            guard !Task.isCancelled, let self, !issues.isEmpty else { return }
            self.mergeMermaidIssues(issues)
        }
    }

    /// 校验完成：把 mermaid 语法错误合并进当前报告（同步部分可能已有报告，
    /// 也可能是干净的——此时新建一份）。合并后重新排序并通知（toast 口径
    /// 与同步检查一致：发现新问题时回调）。
    private func mergeMermaidIssues(_ issues: [DocumentIssue]) {
        var report = pendingReport ?? Report(fileURLs: [], fixable: [], reportOnly: [])
        report.reportOnly.append(contentsOf: issues)
        report.reportOnly.sort {
            $0.fileURL.path != $1.fileURL.path
                ? $0.fileURL.path < $1.fileURL.path
                : $0.line < $1.line
        }
        let known = Set(report.fileURLs.map { $0.standardizedFileURL.path })
        for url in issues.map(\.fileURL) where !known.contains(url.standardizedFileURL.path) {
            report.fileURLs.append(url)
        }
        report.fileURLs.sort { $0.path < $1.path }
        pendingReport = report
        onReport?(report)
    }
}
