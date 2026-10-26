import XCTest
@testable import MEditor

/// EditorCoordinator 评审修复项的单测：
/// - tab 切换前把在途击键回推给旧 tab（flushPendingKeystrokeForDocumentSwitch）
/// - writeback 路径的 flushPendingKeystroke 保持「不回推」语义
/// - AI 插入/替换的 revision 协议与 pendingReplaceRange clamp
/// - 异步 HTML→Markdown 粘贴期间切 tab 放弃插入
@MainActor
final class EditorCoordinatorTests: XCTestCase {

    /// onContentChange 回推内容的收集盒（闭包捕获用）。
    private final class PushLog {
        var values: [String] = []
    }

    private func makeCoordinator(log: PushLog) -> (EditorCoordinator, NSTextView) {
        let coordinator = EditorCoordinator(
            onContentChange: { log.values.append($0) },
            onCursorChange: nil,
            onVisibleTopLineChange: nil
        )
        let textView = NSTextView()
        textView.delegate = coordinator
        coordinator.textView = textView
        return (coordinator, textView)
    }

    /// 模拟一次用户击键后的 textDidChange（调度防抖 Timer，未触发）。
    private func simulateKeystroke(_ coordinator: EditorCoordinator, in textView: NSTextView) {
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
    }

    /// 空转主 runloop，让可能存活的防抖 Timer 有机会触发。
    private func spinRunLoop(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - 问题1：tab 切换前冲刷在途击键给旧 tab

    func testFlushForDocumentSwitchPushesPendingContent() {
        let log = PushLog()
        let (coordinator, textView) = makeCoordinator(log: log)
        textView.string = "abc"
        simulateKeystroke(coordinator, in: textView)
        XCTAssertTrue(coordinator.localRevisionPredictionActive)

        coordinator.flushPendingKeystrokeForDocumentSwitch()

        // pending 内容立即回推（走旧 tab 的闭包），revision 预测不回退丢失
        XCTAssertEqual(log.values, ["abc"])
        XCTAssertEqual(coordinator.lastAcknowledgedContent, "abc")
        XCTAssertEqual(coordinator.lastAcknowledgedRevision, 1)
        XCTAssertFalse(coordinator.localRevisionPredictionActive)

        // 旧防抖 Timer 已作废，不会再二次回推
        spinRunLoop(0.15)
        XCTAssertEqual(log.values, ["abc"])
    }

    func testFlushForDocumentSwitchWithoutPendingIsNoOp() {
        let log = PushLog()
        let (coordinator, _) = makeCoordinator(log: log)
        coordinator.lastAcknowledgedRevision = 7

        coordinator.flushPendingKeystrokeForDocumentSwitch()

        XCTAssertEqual(log.values, [])
        XCTAssertEqual(coordinator.lastAcknowledgedRevision, 7)
    }

    /// writeback 用的 flushPendingKeystroke 必须保持「不回推」语义：
    /// 击键内容已在 textView 里，由写回自己的 onContentChange 一并携带。
    func testFlushPendingKeystrokeDoesNotPush() {
        let log = PushLog()
        let (coordinator, textView) = makeCoordinator(log: log)
        textView.string = "abc"
        simulateKeystroke(coordinator, in: textView)

        coordinator.flushPendingKeystroke()

        XCTAssertEqual(log.values, [])
        // 预测增量回滚（模型侧 revision 未变）
        XCTAssertEqual(coordinator.lastAcknowledgedRevision, 0)
        XCTAssertFalse(coordinator.localRevisionPredictionActive)
        spinRunLoop(0.15)
        XCTAssertEqual(log.values, [])
    }

    // MARK: - 问题3：AI 插入/替换走 revision 协议

    func testApplyProgrammaticReplacementSyncsRevisionAndPushes() {
        let log = PushLog()
        let (coordinator, textView) = makeCoordinator(log: log)
        textView.string = "hello"

        coordinator.applyProgrammaticReplacement(" world", range: NSRange(location: 5, length: 0), in: textView)

        XCTAssertEqual(textView.string, "hello world")
        XCTAssertEqual(log.values, ["hello world"])
        // 同步 lastAcknowledged*：下一次 updateNSView 不会误判为外部变更而整文重置
        XCTAssertEqual(coordinator.lastAcknowledgedContent, "hello world")
        XCTAssertEqual(coordinator.lastAcknowledgedRevision, 1)
        XCTAssertFalse(coordinator.localRevisionPredictionActive)
        // 光标落到插入文本末尾
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 11, length: 0))

        // 不产生多余的防抖回推（旧实现会因 textDidChange 重走防抖而再推一次）
        spinRunLoop(0.15)
        XCTAssertEqual(log.values, ["hello world"])
    }

    func testApplyProgrammaticReplacementFlushesPendingKeystrokeFirst() {
        let log = PushLog()
        let (coordinator, textView) = makeCoordinator(log: log)
        textView.string = "abc"
        simulateKeystroke(coordinator, in: textView)

        coordinator.applyProgrammaticReplacement("X", range: NSRange(location: 3, length: 0), in: textView)

        // 在途击键被冲刷（不回推旧文本），只回推编辑后的完整内容
        XCTAssertEqual(textView.string, "abcX")
        XCTAssertEqual(log.values, ["abcX"])
        spinRunLoop(0.15)
        XCTAssertEqual(log.values, ["abcX"])
    }

    // MARK: - 问题4：pendingReplaceRange 边界 clamp

    func testApplyProgrammaticReplacementClampsOverlongRange() {
        let log = PushLog()
        let (coordinator, textView) = makeCoordinator(log: log)
        textView.string = "abc"

        // 保存时选区 (1, 5)，文档已变短为 3：clamp 到 (1, 2)
        coordinator.applyProgrammaticReplacement("X", range: NSRange(location: 1, length: 5), in: textView)

        XCTAssertEqual(textView.string, "aX")
        XCTAssertEqual(log.values, ["aX"])
    }

    func testApplyProgrammaticReplacementSkipsOutOfBoundsLocation() {
        let log = PushLog()
        let (coordinator, textView) = makeCoordinator(log: log)
        textView.string = "abc"
        let revision = coordinator.lastAcknowledgedRevision

        // 起点已越界：跳过本次替换，不崩溃、不回推、revision 不动
        coordinator.applyProgrammaticReplacement("X", range: NSRange(location: 10, length: 2), in: textView)
        coordinator.applyProgrammaticReplacement("Y", range: NSRange(location: NSNotFound, length: 0), in: textView)

        XCTAssertEqual(textView.string, "abc")
        XCTAssertEqual(log.values, [])
        XCTAssertEqual(coordinator.lastAcknowledgedRevision, revision)
    }

    func testClampedRange() {
        XCTAssertEqual(EditorCoordinator.clampedRange(NSRange(location: 0, length: 3), textLength: 3),
                       NSRange(location: 0, length: 3))
        XCTAssertEqual(EditorCoordinator.clampedRange(NSRange(location: 2, length: 10), textLength: 3),
                       NSRange(location: 2, length: 1))
        XCTAssertEqual(EditorCoordinator.clampedRange(NSRange(location: 3, length: 4), textLength: 3),
                       NSRange(location: 3, length: 0))
        XCTAssertNil(EditorCoordinator.clampedRange(NSRange(location: 4, length: 0), textLength: 3))
        XCTAssertNil(EditorCoordinator.clampedRange(NSRange(location: NSNotFound, length: 0), textLength: 3))
    }

    // MARK: - 问题5：异步 HTML→Markdown 粘贴期间切 tab

    private func makeHTMLPasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("MEditorTests-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString("<p>hello paste</p>", forType: .html)
        pb.setString("hello paste", forType: .string)
        return pb
    }

    func testPasteRichTextInsertsWhenDocumentUnchanged() async throws {
        let log = PushLog()
        let (coordinator, textView) = makeCoordinator(log: log)
        coordinator.documentURL = URL(fileURLWithPath: "/tmp/a.md")

        XCTAssertTrue(coordinator.pasteRichTextFromPasteboard(makeHTMLPasteboard()))

        // 等异步转换完成（离屏 WebView，单任务超时 3s）
        let deadline = Date().addingTimeInterval(10)
        while textView.string.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(textView.string.contains("hello paste"), "got: \(textView.string)")
        withExtendedLifetime(coordinator) {}
    }

    func testPasteRichTextAbortsWhenDocumentSwitched() async throws {
        let log = PushLog()
        let (coordinator, textView) = makeCoordinator(log: log)
        coordinator.documentURL = URL(fileURLWithPath: "/tmp/a.md")

        XCTAssertTrue(coordinator.pasteRichTextFromPasteboard(makeHTMLPasteboard()))
        // 转换完成前切 tab：textView 复用，documentURL 已指向新文档
        coordinator.documentURL = URL(fileURLWithPath: "/tmp/b.md")

        // 睡到转换超时（3s）之后，确保 completion 一定已回调过
        try await Task.sleep(nanoseconds: 3_600_000_000)
        XCTAssertEqual(textView.string, "")
        withExtendedLifetime(coordinator) {}
    }

    // MARK: - 行偏移表增量维护接线

    /// 放行的击键：shouldChangeTextIn 记录 delta，textDidChange 走增量，
    /// 不做全量重建。
    func testTextDidChangeAppliesRecordedEditIncrementally() {
        let log = PushLog()
        let (coordinator, textView) = makeCoordinator(log: log)
        textView.string = "aaa\nbbb\nccc"
        coordinator.highlighter.rebuildLineOffsets(for: textView.string)
        let rebuilds = coordinator.highlighter.rebuildCount

        XCTAssertTrue(coordinator.textView(
            textView, shouldChangeTextIn: NSRange(location: 4, length: 0),
            replacementString: "X\n"
        ))
        textView.textStorage?.replaceCharacters(in: NSRange(location: 4, length: 0), with: "X\n")
        simulateKeystroke(coordinator, in: textView)

        XCTAssertEqual(coordinator.highlighter.lineOffsets, [0, 4, 6, 10])
        XCTAssertEqual(coordinator.highlighter.incrementalApplyCount, 1)
        XCTAssertEqual(coordinator.highlighter.rebuildCount, rebuilds,
                       "记录到 delta 的击键不应触发全量重建")
    }

    /// 未经 shouldChangeTextIn 的存储直改（undo / 程序化路径）：没有 delta，
    /// textDidChange 必须回退全量重建，表仍然正确。
    func testTextDidChangeWithoutRecordedEditFallsBackToRebuild() {
        let log = PushLog()
        let (coordinator, textView) = makeCoordinator(log: log)
        textView.string = "a\nb"
        coordinator.highlighter.rebuildLineOffsets(for: textView.string)
        let rebuilds = coordinator.highlighter.rebuildCount

        textView.textStorage?.replaceCharacters(in: NSRange(location: 2, length: 0), with: "\nz")
        simulateKeystroke(coordinator, in: textView)

        XCTAssertEqual(coordinator.highlighter.lineOffsets, [0, 2, 3])
        XCTAssertEqual(coordinator.highlighter.incrementalApplyCount, 0)
        XCTAssertEqual(coordinator.highlighter.rebuildCount, rebuilds + 1,
                       "没有 delta 的变更必须回退全量重建")
    }

    /// 自动补对：击键 "(" 实际写入 "()" 两个字符，记录的 delta 对不上实际
    /// 变更，applyEdit 校验失败回退全量——表必须仍然正确。
    func testTextDidChangeAutoClosePairFallsBackToRebuild() {
        let log = PushLog()
        let (coordinator, textView) = makeCoordinator(log: log)
        textView.string = ""
        coordinator.highlighter.rebuildLineOffsets(for: "")
        let rebuilds = coordinator.highlighter.rebuildCount

        XCTAssertTrue(coordinator.textView(
            textView, shouldChangeTextIn: NSRange(location: 0, length: 0),
            replacementString: "("
        ))
        textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: "(")
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        simulateKeystroke(coordinator, in: textView)

        XCTAssertEqual(textView.string, "()")
        XCTAssertEqual(coordinator.highlighter.lineOffsets, [0])
        XCTAssertEqual(coordinator.highlighter.incrementalApplyCount, 0)
        XCTAssertEqual(coordinator.highlighter.rebuildCount, rebuilds + 1)
    }

    /// 程序化路径的编辑不记录 delta（记录了就会在 textDidChange 里把别人的
    /// 编辑错当成这次击键的 delta）。
    func testProgrammaticEditDoesNotRecordDelta() {
        let log = PushLog()
        let (coordinator, textView) = makeCoordinator(log: log)
        textView.string = "ab"
        coordinator.highlighter.rebuildLineOffsets(for: textView.string)
        let rebuilds = coordinator.highlighter.rebuildCount

        // 程序化路径：shouldChangeTextIn 放行但不记录
        coordinator.isProgrammaticChange = true
        XCTAssertTrue(coordinator.textView(
            textView, shouldChangeTextIn: NSRange(location: 2, length: 0),
            replacementString: "\n"
        ))
        coordinator.isProgrammaticChange = false
        textView.textStorage?.replaceCharacters(in: NSRange(location: 2, length: 0), with: "\n")
        simulateKeystroke(coordinator, in: textView)

        XCTAssertEqual(coordinator.highlighter.lineOffsets, [0, 3])
        XCTAssertEqual(coordinator.highlighter.incrementalApplyCount, 0)
        XCTAssertEqual(coordinator.highlighter.rebuildCount, rebuilds + 1)
    }
}
