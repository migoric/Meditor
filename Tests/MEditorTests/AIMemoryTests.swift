import XCTest
@testable import MEditor

/// 记忆子系统的契约测试。
///
/// 这套用例守的是**设计稿 §8 的七条验收判据**（`docs/ai-memory-design.md`），
/// 不是「跑通了」。每条断言都能反问一句「如果实现错了，它会不会红」——
/// 不红的断言不写进来。
final class AIMemoryTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("meditor-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        try super.tearDownWithError()
    }

    private func makeStore() -> MemoryStore {
        MemoryStore(
            fileURL: tmpDir.appendingPathComponent("MEDITOR.md"),
            stateURL: tmpDir.appendingPathComponent(".meditor/memory-state.json")
        )
    }

    /// 全局层也指到临时目录：测试不能碰用户真实的 `Application Support`。
    private func makeService() -> MemoryService {
        MemoryService(
            globalFileURL: tmpDir.appendingPathComponent("global/MEDITOR.global.md"),
            globalStateURL: tmpDir.appendingPathComponent("global/state.json")
        )
    }

    private func record(
        _ text: String,
        kind: MemoryKind = .fact,
        useCount: Int = 0,
        pinned: Bool = false,
        lastUsedAt: Date? = nil,
        updatedAt: Date? = nil
    ) -> MemoryRecord {
        MemoryRecord(
            entry: MemoryEntry(id: MemoryEntry.makeID(text: text), kind: kind, text: text),
            counter: MemoryCounter(useCount: useCount, lastUsedAt: lastUsedAt, pinned: pinned, updatedAt: updatedAt),
            scope: .workspace
        )
    }

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: - 文档解析（判据 1）

    func test_parse_extractsEntriesAndPreservesEverythingElse() {
        let text = """
        # MEDITOR.md

        <!-- 人的备注 -->

        ## 约定

        章节标题只用两级。
        不要用 emoji。

        ## 记忆

        - [约定] 代码块必须带语言标记 [#a1b2c3]
        - 没有种类也没有 id 的一条

        ## 我的私人笔记

        这段不是记忆，必须原样保留。
        """
        let doc = MemoryDocument.parse(text)

        XCTAssertEqual(doc.entries.count, 2, "两条记忆都该被解析出来")
        XCTAssertEqual(doc.entries[0].id, "a1b2c3", "显式 id 必须原样保留")
        XCTAssertEqual(doc.entries[0].kind, .convention)
        XCTAssertEqual(doc.entries[1].kind, .fact, "缺种类标记时落 fact，而不是丢弃")
        XCTAssertEqual(doc.entries[1].id, MemoryEntry.makeID(text: "没有种类也没有 id 的一条"),
                       "缺 id 时用内容寻址补，且可复现")

        let rendered = doc.render()
        XCTAssertTrue(rendered.contains("<!-- 人的备注 -->"), "人的备注不能被吃掉")
        XCTAssertTrue(rendered.contains("这段不是记忆，必须原样保留。"), "非记忆段必须原样保留")
        XCTAssertEqual(doc.conventionText, "章节标题只用两级。\n不要用 emoji。")
    }

    func test_render_thenParse_isIdempotent() {
        var doc = MemoryDocument.empty
        doc.upsert(MemoryEntry(id: "aaaaaa", kind: .term, text: "hunk 指 diff 里的连续变更块"))
        doc.upsert(MemoryEntry(id: "bbbbbb", kind: .decision, text: "封面用蓝色"))

        let once = doc.render()
        let twice = MemoryDocument.parse(once).render()

        XCTAssertEqual(once, twice, "往返必须稳定：否则每次保存都会重写全文，git diff 全是噪音")
        XCTAssertEqual(MemoryDocument.parse(once).entries, doc.entries)
    }

    func test_render_keepsSectionOrder_whenUserContentFollows() {
        let text = """
        ## 记忆

        - [术语] 甲 [#111111]

        ## 附注

        用户写在后面的段落。
        """
        var doc = MemoryDocument.parse(text)
        doc.upsert(MemoryEntry(id: "222222", kind: .fact, text: "乙"))
        let lines = doc.render().components(separatedBy: "\n")

        let memoryIndex = lines.firstIndex(of: "## 记忆")
        let noteIndex = lines.firstIndex(of: "## 附注")
        XCTAssertNotNil(memoryIndex)
        XCTAssertNotNil(noteIndex)
        XCTAssertLessThan(memoryIndex!, noteIndex!, "记忆段必须留在原位置，不能漂到文件末尾")
    }

    // MARK: - 检索（判据 2、3、4）

    func test_select_respectsTokenBudget() {
        let records = (0..<120).map { index in
            record("第 \(index) 条关于排版与命名的约定，内容要足够长才能吃掉预算", kind: .convention)
        }
        let selection = MemorySelector.select(
            records, query: "排版 命名", budgetTokens: 800, now: now
        )

        XCTAssertLessThanOrEqual(selection.estimatedTokens, 800, "注入不得超过预算")
        XCTAssertFalse(selection.records.isEmpty, "预算内应该有东西被选中，否则预算算错了")
        XCTAssertGreaterThan(selection.droppedCount, 0, "120 条塞不进 800 token，必须有被放弃的")
    }

    func test_select_prefersKeywordMatch_overRecency() {
        let oldButRelevant = record(
            "「hunk」在本项目里指 diff 里的连续变更块",
            kind: .term,
            updatedAt: now.addingTimeInterval(-700 * 86_400)
        )
        let freshButIrrelevant = record(
            "封面主色用朱砂红",
            kind: .fact,
            updatedAt: now
        )
        let selection = MemorySelector.select(
            [freshButIrrelevant, oldButRelevant],
            query: "hunk 是什么意思",
            budgetTokens: 800,
            now: now
        )

        XCTAssertEqual(selection.records.first?.id, oldButRelevant.id,
                       "关键词精确命中的老条目必须排在新鲜但无关的条目前面")
    }

    func test_select_putsPinnedFirst_evenWhenIrrelevant() {
        let pinned = record("永远不要用「赋能」这个词", kind: .preference, pinned: true,
                            updatedAt: now.addingTimeInterval(-500 * 86_400))
        let relevant = record("章节标题只用两级", kind: .convention, updatedAt: now)
        let selection = MemorySelector.select(
            [relevant, pinned], query: "章节标题", budgetTokens: 800, now: now
        )

        XCTAssertEqual(selection.records.first?.id, pinned.id, "pinned 是用户显式意图，排最前")
    }

    func test_select_conventionTextEatsBudgetFirst() {
        let longConvention = String(repeating: "约定内容", count: 2000)
        let selection = MemorySelector.select(
            [record("一条记忆", kind: .fact)],
            query: "记忆",
            conventionText: longConvention,
            budgetTokens: 800,
            now: now
        )

        XCTAssertLessThanOrEqual(selection.estimatedTokens, 800)
        XCTAssertTrue(selection.records.isEmpty, "约定段已吃满预算时，条目一条都不该注入")
        XCTAssertFalse(selection.conventionText.isEmpty)
        XCTAssertLessThan(selection.conventionText.count, longConvention.count, "约定段超预算必须被截断")
    }

    func test_select_emptyQuery_degradesToWeightAndRecency() {
        let heavy = record("重要的约定", kind: .convention, updatedAt: now)
        let light = record("一条事实记录", kind: .fact, updatedAt: now.addingTimeInterval(-300 * 86_400))
        let selection = MemorySelector.select([light, heavy], query: "", budgetTokens: 800, now: now)

        XCTAssertEqual(selection.records.first?.id, heavy.id, "空查询也要给出稳定排序，不能是空集")
    }

    // MARK: - 捕获（判据 5）

    func test_record_duplicate_doesNotAddEntry_butBumpsUseCount() {
        let store = makeStore()
        let first = store.record(kind: .convention, text: "章节标题只用两级：## 与 ###", now: now)
        guard case .added(let entry) = first else { return XCTFail("首次必须新增，实际 \(first)") }

        let second = store.record(kind: .convention, text: "章节标题只用两级: ## 与 ###", now: now)

        XCTAssertEqual(second, .duplicate(id: entry.id, text: entry.text))
        XCTAssertEqual(store.records(scope: .workspace).count, 1, "相似度 ≥ 0.8 不得新增条目")
        XCTAssertEqual(store.records(scope: .workspace).first?.counter.useCount, 1,
                       "重复提出说明它重要，计数要 +1")
    }

    func test_record_enforcesPerRunLimit() {
        let store = makeStore()
        // 八条必须彼此不相似：相似度 ≥ 0.8 会被判重而不计入新增，
        // 那样这条用例测的就不是限额了（第一版就是这么写错的）。
        let topics = ["封面配色", "导出文件名规范", "iOS 部署目标", "预览刷新通道",
                      "构建产物体积", "签名方式", "发布流程", "依赖管理"]
        for topic in topics {
            let outcome = store.record(kind: .fact, text: "关于\(topic)的一条结论", now: now)
            guard case .added = outcome else {
                return XCTFail("主题「\(topic)」不该被判重，实际 \(outcome)")
            }
        }
        let overLimit = store.record(kind: .fact, text: "关于代码注释风格的一条结论", now: now)

        guard case .rejected = overLimit else {
            return XCTFail("超过单 run 上限必须被拒，实际 \(overLimit)")
        }
        XCTAssertEqual(store.records(scope: .workspace).count, MemorySelector.newEntriesPerRunLimit)

        store.resetSessionAddCount()
        let afterReset = store.record(kind: .fact, text: "重置之后可以再记一条完全不同的内容", now: now)
        guard case .added = afterReset else { return XCTFail("run 边界重置后应该能继续记") }
    }

    func test_record_persistsAcrossInstances() {
        let store = makeStore()
        _ = store.record(kind: .term, text: "hunk 指 diff 里的连续变更块", source: "docs/spec.md L42", now: now)

        let reopened = makeStore()
        let records = reopened.records(scope: .workspace)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.entry.kind, .term, "种类必须能从 Markdown 还原")
        XCTAssertEqual(records.first?.counter.source, "docs/spec.md L42", "出处走旁挂 JSON，不进 Markdown")
    }

    // MARK: - 外部改动（#110）

    /// 用户在编辑器里改 `MEDITOR.md`、或 `git pull` 拿到团队约定，都是在 App 之外改的文件。
    /// 同一个工作区再 `activate` 必须看到新内容 —— 否则注入的约定和你眼前看到的文件不一致，
    /// 而且没有任何报错。
    func test_activate_rereads_whenFileChangedExternally() throws {
        let service = makeService()
        service.activate(workspaceRoot: tmpDir)
        _ = service.record(kind: .convention, text: "章节标题只用两级", now: now)

        // 模拟外部改动：直接往文件里追加一段人写的条目。
        let file = MemoryService.workspaceFileURL(root: tmpDir)
        var text = try String(contentsOf: file, encoding: .utf8)
        text += "\n- [约定] 外部编辑器加进来的一条约定\n"
        try text.write(to: file, atomically: true, encoding: .utf8)

        service.activate(workspaceRoot: tmpDir)

        let texts = service.records().map(\.entry.text)
        XCTAssertTrue(
            texts.contains { $0.contains("外部编辑器加进来") },
            "外部改动后必须重读，实际条目：\(texts)"
        )
    }

    /// 自己写文件不能被误判成「外部改动」。
    ///
    /// 误判的代价不只是白做一次 parse：重建 store 会把 run 级限额计数清零，
    /// 于是「单 run 最多记 8 条」这道防提示注入刷屏的闸门被自己的写入冲开了。
    func test_activate_doesNotResetRunLimit_afterOwnWrites() {
        let service = makeService()
        service.activate(workspaceRoot: tmpDir)
        // 主题必须彼此不相似：相似度 ≥ 0.8 会被判重而不计入新增。
        let topics = ["封面配色", "导出文件名规范", "iOS 部署目标", "预览刷新通道",
                      "构建产物体积", "签名方式", "发布流程", "依赖管理"]
        for topic in topics {
            let outcome = service.record(kind: .fact, text: "关于\(topic)的一条结论", now: now)
            guard case .added = outcome else { return XCTFail("主题「\(topic)」不该被判重，实际 \(outcome)") }
        }

        // 自己的写入刚刚落盘。这一步必须是空操作 —— 说明 mtime 哨兵同步了。
        service.activate(workspaceRoot: tmpDir)

        let overLimit = service.record(kind: .fact, text: "关于代码注释风格的一条结论", now: now)
        guard case .rejected = overLimit else {
            return XCTFail("自己的写入不该重置 run 限额，实际 \(overLimit)")
        }
    }

    // MARK: - 作用域隔离（#110）

    /// 写操作必须只作用于一层。
    ///
    /// id 是内容寻址的：同一条正文既在工作区又在全局时，两层 id 一模一样。
    /// 曾经的做法是「按 id 遍历两层」，于是「在工作区删掉这条」会顺手删掉全局那条，
    /// 而且面板里两条是一起消失的 —— 用户看不出发生了什么。
    func test_delete_isScopedToSingleLayer() throws {
        let service = makeService()

        // 没有工作区时记录落在全局层。
        service.activate(workspaceRoot: nil)
        _ = service.record(kind: .preference, text: "不写赋能这类词", now: now)

        // 打开工作区后记同一条正文：两层各一条，id 相同。
        service.activate(workspaceRoot: tmpDir)
        _ = service.record(kind: .preference, text: "不写赋能这类词", now: now)

        let before = service.records()
        XCTAssertEqual(before.count, 2, "两层应各有一条")
        XCTAssertEqual(Set(before.map(\.entry.id)).count, 1, "内容寻址 ⇒ 两层同 id")

        let workspaceRecord = try XCTUnwrap(before.first { $0.scope == .workspace })
        service.delete(id: workspaceRecord.entry.id, scope: .workspace)

        let after = service.records()
        XCTAssertEqual(after.count, 1, "只该删掉工作区那条")
        XCTAssertEqual(after.first?.scope, .global, "全局那条必须还在")
    }

    // MARK: - 工具与遗忘的联动（#110）

    /// 主动 `recall_memory` 命中的条目也必须记一次使用。
    ///
    /// 遗忘判据是「90 天没用 **且** 一次都没被检索到」。漏记这一笔，被 agent 反复
    /// recall 的条目 `useCount` 永远是 0，90 天后会被归档 —— 最该留的反倒先走。
    ///
    /// 这条会用 `MemoryService.shared`（工具内部就取它），所以收尾必须把工作区还原，
    /// 否则会把临时目录的副本留给后面的用例。
    @MainActor
    func test_recallTool_countsHitsAsUsage() async throws {
        MemoryService.shared.activate(workspaceRoot: tmpDir)
        defer { MemoryService.shared.activate(workspaceRoot: nil) }
        _ = MemoryService.shared.record(kind: .preference, text: "不写赋能这类词")

        let recorded = try XCTUnwrap(MemoryService.shared.records().first)
        XCTAssertEqual(recorded.counter.useCount, 0, "刚记下时不该有使用记录")

        let ctx = MockAgentContext()
        ctx.workspaceURL = tmpDir
        let output = try await RecallMemoryTool().execute(
            arguments: ["query": .string("赋能")],
            context: ctx
        )
        XCTAssertTrue(output.contains("赋能"), "查询应命中这条，实际：\(output)")

        let after = try XCTUnwrap(MemoryService.shared.records().first)
        XCTAssertEqual(after.counter.useCount, 1, "recall 命中要记一次使用")
        XCTAssertNotNil(after.counter.lastUsedAt, "最近使用时间也要写，否则老化判据仍按旧时间算")
    }

    // MARK: - 遗忘（判据 6）

    func test_archiveStale_movesUnusedOldEntries_outOfInjection() {
        let store = makeStore()
        _ = store.record(kind: .fact, text: "一条很久没人用的事实", now: now.addingTimeInterval(-200 * 86_400))
        _ = store.record(kind: .fact, text: "一条刚记下的事实", now: now)

        XCTAssertEqual(store.archiveStale(now: now), 1)
        XCTAssertEqual(store.records(scope: .workspace).count, 1, "活跃区只剩新的那条")
        XCTAssertEqual(store.archivedRecords(scope: .workspace).count, 1, "归档不删除，只是移走")
    }

    func test_archiveStale_neverTouchesPinnedOrUsedEntries() {
        let store = makeStore()
        let old = now.addingTimeInterval(-200 * 86_400)
        _ = store.record(kind: .fact, text: "被 pin 住的老事实", now: old)
        _ = store.record(kind: .fact, text: "用过很多次的老事实", now: old)

        let pinned = store.records(scope: .workspace)[0].id
        let used = store.records(scope: .workspace)[1].id
        store.setPinned(true, id: pinned, now: old)
        store.touch(ids: [used], now: now)

        XCTAssertEqual(store.archiveStale(now: now), 0, "pin 过或用过的条目不能被老化掉")
    }

    func test_archivable_keepsUsedEntryWhoseTimestampWasLost() {
        // 变异验证抓到的漏：上面那条用例里 `touch` 会同时写 lastUsedAt，
        // 于是「useCount == 0」这个条件被 lastUsedAt 掩盖，删掉它用例照样绿。
        // 这里直接构造那个边缘态——用过多次，但时间戳在迁移里丢了。
        let migrated = MemoryRecord(
            entry: MemoryEntry(id: "cccccc", kind: .fact, text: "一条用过三次但时间戳丢失的事实"),
            counter: MemoryCounter(useCount: 3, lastUsedAt: nil,
                                   updatedAt: now.addingTimeInterval(-200 * 86_400)),
            scope: .workspace
        )

        XCTAssertTrue(MemorySelector.archivable([migrated], now: now).isEmpty,
                      "用过就说明有价值；时间戳丢了不该被当成从没用过")
    }

    // MARK: - 巩固

    func test_consolidate_mergesSimilarEntriesWithinSameKind() {
        let a = record("章节标题只用两级，不要用四级标题", kind: .convention, useCount: 2)
        let b = record("章节标题只用两级，不要用四级标题。", kind: .convention, useCount: 3)
        let c = record("章节标题只用两级，不要用四级标题", kind: .term, useCount: 1)

        let merged = MemorySelector.consolidate([a, b, c])

        XCTAssertEqual(merged.count, 2, "同 kind 的合并，跨 kind 不动")
        XCTAssertEqual(merged[0].counter.useCount, 5, "计数相加")
    }

    // MARK: - 损坏与降级

    func test_corruptStateFile_isBackedUp_andEntriesSurvive() throws {
        let store = makeStore()
        _ = store.record(kind: .convention, text: "一条要活下来的约定", now: now)

        let stateURL = tmpDir.appendingPathComponent(".meditor/memory-state.json")
        try Data("not json".utf8).write(to: stateURL)

        let reopened = makeStore()

        XCTAssertEqual(reopened.records(scope: .workspace).count, 1, "计数坏了不能让正文消失")
        XCTAssertNotNil(reopened.loadWarning, "必须留下可见的告警，不能静默重置")
        let backups = try FileManager.default.contentsOfDirectory(atPath: tmpDir.appendingPathComponent(".meditor").path)
            .filter { $0.contains("corrupt") }
        XCTAssertEqual(backups.count, 1, "坏文件要留档，不能直接覆盖")
    }

    // MARK: - 注入契约（判据 7）

    func test_promptSection_isByteEmpty_whenNoMemoryExists() {
        // 全局层与工作区层都指向临时目录 ⇒ 两层都空。
        // 这条守的是「老用户升级后 system prompt 逐字节不变」这个承诺。
        let service = MemoryService(
            globalFileURL: tmpDir.appendingPathComponent("global/MEDITOR.global.md"),
            globalStateURL: tmpDir.appendingPathComponent("global/state.json")
        )
        service.activate(workspaceRoot: tmpDir)

        let section = service.promptSection(query: "任意问题")

        XCTAssertEqual(section.text, "", "没有任何记忆时不能往 prompt 里加一个字")
        XCTAssertTrue(section.injectedIDs.isEmpty)
    }

    func test_promptSection_marksEntriesWithIDs_forCitation() {
        let store = makeStore()
        _ = store.record(kind: .convention, text: "代码块必须带语言标记", now: now)
        XCTAssertEqual(store.records(scope: .workspace).count, 1)

        let record = store.records(scope: .workspace)[0]
        let selection = MemorySelector.select(
            store.records(scope: .workspace), query: "代码块", budgetTokens: 800, now: now
        )

        XCTAssertEqual(selection.records.first?.id, record.id)
        XCTAssertEqual(MemoryDocument.renderLine(record.entry),
                       "- [约定] 代码块必须带语言标记 [#\(record.id)]",
                       "文件里的行格式必须能被模型引用")
    }

    // MARK: - 面板判据
    //
    // 这两组守的是「设置 → 记忆」上那条橙色警告的真实性。它曾经在**文件完全可写**时
    // 也亮着：判据读的是 `MemoryService.hasWorkspaceStore`，而 store 由 `activate` 创建、
    // `activate` 挂在 `.onAppear` 上——首次渲染读到的一定是假值，空态下又没有任何
    // `@State` 变化触发重绘，横幅就一直错挂在那里。

    /// 家目录缩成 `~`。不缩的话 `.truncationMode(.head)` 会切在任意字符处，
    /// `~/Documents` 变成 `...s/shein`，读起来像乱码。
    func test_displayPath_abbreviatesHomeDirectory() {
        let home = "/Users/someone"
        XCTAssertEqual(
            MemoryService.displayPath("/Users/someone/Documents/shein/MEDITOR.md", home: home),
            "~/Documents/shein/MEDITOR.md"
        )
        XCTAssertEqual(MemoryService.displayPath("/Users/someone", home: home), "~")
        XCTAssertEqual(MemoryService.displayPath("/tmp/MEDITOR.md", home: home), "/tmp/MEDITOR.md")
        // 前缀相似但不是它的子目录。按裸前缀替换会把路径改坏成 `~else/x`。
        XCTAssertEqual(
            MemoryService.displayPath("/Users/someoneelse/x", home: home),
            "/Users/someoneelse/x"
        )
        XCTAssertEqual(MemoryService.displayPath("/x", home: ""), "/x")
    }

    /// 可写 ⇒ 不报警。这条同时也是「正常路径下横幅不该出现」的回归守卫。
    func test_isWorkspaceWritable_trueForWritableDirectory() {
        XCTAssertTrue(MemoryService.isWorkspaceWritable(root: tmpDir))
    }

    /// 根目录不可写：`MEDITOR.md` 都建不出来，agent 当然记不住新东西。
    func test_isWorkspaceWritable_falseWhenDirectoryIsReadOnly() throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: tmpDir.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: tmpDir.path
            )
        }
        // root 无视权限位，那种环境下这条判据测不出来，如实跳过而不是假装通过。
        guard !FileManager.default.isWritableFile(atPath: tmpDir.path) else {
            throw XCTSkip("当前身份无视权限位（多半是 root），无法构造只读目录")
        }
        XCTAssertFalse(MemoryService.isWorkspaceWritable(root: tmpDir))
    }

    /// `MEDITOR.md` 已经存在但本身只读：目录可写也没用，写回会失败。
    func test_isWorkspaceWritable_falseWhenFileIsReadOnly() throws {
        let file = MemoryService.workspaceFileURL(root: tmpDir)
        try "# 记忆\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444], ofItemAtPath: file.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: file.path
            )
        }
        guard !FileManager.default.isWritableFile(atPath: file.path) else {
            throw XCTSkip("当前身份无视权限位（多半是 root），无法构造只读文件")
        }
        XCTAssertFalse(MemoryService.isWorkspaceWritable(root: tmpDir))
    }
}
