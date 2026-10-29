import Foundation

// MARK: - Agent run 一键回滚（执行层）
//
// 数据层（快照采集 / 回滚规划）在 AgentRunCheckpoint；这里负责把规划出的动作
// 落到磁盘与 UI：写盘/删文件走 fileService，打开的 tab 同步走与外部变更静默重载
//（AppState+ExternalMod.silentlyReloadTab）同一套步骤——content + contentRevision +
// isModified=false + recordModDate + 预览刷新，不新造通道。

extension AppState {

    /// 撤销一次 agent run 的全部文件修改。
    ///
    /// 安全语义（由 AgentRunCheckpoint.planRollback 保证）：
    /// 文件当前内容必须等于 run 最后一次写入的内容才恢复/删除；run 结束后用户又
    /// 改过的文件一律跳过并在结果摘要里点名——绝不覆盖用户编辑。
    ///
    /// - Returns: 实际执行的动作序列（含跳过项），已在 checkpoint 上记录摘要；
    ///   重复回滚返回空序列（幂等）。
    @discardableResult
    func rollbackAgentRun(_ checkpoint: AgentRunCheckpoint) async -> [AgentRollbackAction] {
        guard !checkpoint.isRolledBack else { return [] }

        // 1) 主线程收集「当前内容」：打开的 tab 内存内容优先（用户视角最新），否则读盘。
        //    一次读完，planRollback 的闭包只做字典查找（纯函数、无 I/O）。
        var currentContent: [String: String] = [:]
        for snapshot in checkpoint.snapshots {
            let url = snapshot.url
            if let tab = tabManager.openTabs.first(where: {
                TabManager.urlsReferToSameFile($0.url, url)
            }), !tab.awaitingInitialContent {
                currentContent[url.standardizedFileURL.path] = tab.content
            } else if fileService.fileExists(at: url),
                      let content = try? fileService.readFile(at: url) {
                currentContent[url.standardizedFileURL.path] = content
            }
        }
        let actions = checkpoint.planRollback { url in
            currentContent[url.standardizedFileURL.path]
        }

        // 2) 磁盘写/删移到后台任务：多文件回滚不再在主线程上逐文件阻塞。
        let fileService = self.fileService
        let writeSucceeded: [Int: Bool] = await Task.detached(priority: .userInitiated) {
            var succeeded: [Int: Bool] = [:]
            for (index, action) in actions.enumerated() {
                switch action {
                case .restore(let url, let content):
                    do {
                        try fileService.writeFile(at: url, content: content)
                        succeeded[index] = true
                    } catch {
                        succeeded[index] = false
                    }
                case .deleteCreated(let url):
                    do {
                        try fileService.removeItem(at: url)
                        succeeded[index] = true
                    } catch {
                        succeeded[index] = false
                    }
                case .skip:
                    succeeded[index] = true
                }
            }
            return succeeded
        }.value

        // 3) 回到主线程应用结果 + 同步 UI。
        var restored = 0, deleted = 0
        var skipped: [String] = []
        var hadWriteFailure = false

        for (index, action) in actions.enumerated() {
            switch action {
            case .restore(let url, let content):
                guard writeSucceeded[index] == true else {
                    hadWriteFailure = true
                    skipped.append("\(url.lastPathComponent)（\(L("ai.rollback.skipWriteFailed"))）")
                    continue
                }
                restored += 1
                // 同步打开的 tab：复用外部变更重载的同一套步骤，避免触发
                // 「磁盘已更新」的误报（recordModDate 同步登记新修改时间）
                if let tab = tabManager.openTabs.first(where: {
                    TabManager.urlsReferToSameFile($0.url, url)
                }) {
                    tab.content = content
                    tab.isModified = false
                    tab.awaitingInitialContent = false
                    tab.contentRevision &+= 1
                    if tabManager.selectedTabID == tab.id {
                        syncPreviewContent(from: tab)
                    }
                }
                recordModDate(for: url)
                reloadHTMLPreviewIfShowing(url)

            case .deleteCreated(let url):
                guard writeSucceeded[index] == true else {
                    hadWriteFailure = true
                    skipped.append("\(url.lastPathComponent)（\(L("ai.rollback.skipWriteFailed"))）")
                    continue
                }
                deleted += 1
                // planRollback 已校验 tab 内容 == run 写入内容，直接关闭不丢用户编辑；
                // 走 performCloseTab（不经 closeTab 的未保存确认弹窗）
                if let tab = tabManager.openTabs.first(where: {
                    TabManager.urlsReferToSameFile($0.url, url)
                }) {
                    tabManager.performCloseTab(tab.id)
                }
                externalModDates[url] = nil

            case .skip(let url, let reason):
                skipped.append("\(url.lastPathComponent)（\(reasonText(reason))）")
            }
        }

        reloadFileTree()

        // 摘要：回滚数 + 跳过清单（跳过必须点名，让用户知道哪些文件没动）
        var summary = String(format: L("ai.rollback.summaryDone"), restored + deleted)
        if !skipped.isEmpty {
            summary += String(format: L("ai.rollback.summarySkipped"), skipped.joined(separator: "、"))
        }
        if hadWriteFailure {
            checkpoint.recordRollbackSummary(summary)
        } else {
            checkpoint.markRolledBack(summary: summary)
        }
        showToast(summary, icon: "arrow.uturn.backward")
        return actions
    }

    /// 跳过原因的本地化文案（结构化 reason → 用户可读一句话）
    private func reasonText(_ reason: AgentRollbackSkipReason) -> String {
        switch reason {
        case .editedAfterRun:            return L("ai.rollback.skipEdited")
        case .fileMissing:               return L("ai.rollback.skipMissing")
        case .notSnapshotable(let why):  return why
        }
    }
}
