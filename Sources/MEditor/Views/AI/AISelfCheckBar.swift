import SwiftUI

// MARK: - Agent 写后自检报告条

extension AIAssistantPanel {
    /// 自检发现的问题报告条：挂在 transcript 底部（与写确认条同一视觉范式）。
    /// fixable（确定性可修）给「一键修复」入口；reportOnly（死链/缺图）只列出不自动改。
    @ViewBuilder
    func selfCheckBar(_ report: AgentWriteSelfCheck.Report) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "stethoscope")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
                Text(L("ai.selfcheck.title"))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.craftPrimary)
            }
            Text(L("ai.selfcheck.summary",
                   report.totalCount, report.fixable.count, report.reportOnly.count))
                .font(.system(size: 11.5))
                .foregroundStyle(theme.craftSecondary)
            // 逐条列出（截断到 5 条防撑爆面板）；报告条目可点击跳转到对应行
            ForEach(Array((report.fixable + report.reportOnly).prefix(5))) { issue in
                Button {
                    if focusSelfCheckTarget(issue) {
                        state.requestEditorScroll(to: issue.line, select: true)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: issue.kind.icon)
                            .font(.system(size: 10))
                            .frame(width: 12)
                        Text("\(issue.fileURL.lastPathComponent):\(issue.line + 1) \(issue.kind.message)")
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(theme.craftPrimary)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                Spacer()
                Button(L("ai.selfcheck.dismiss")) { state.agentWriteSelfCheck.dismissReport() }
                    .buttonStyle(.bordered)
                if !report.fixable.isEmpty {
                    Button(L("ai.selfcheck.fix", report.fixable.count)) {
                        state.runAgentSelfCheckFix(report)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.appAccent)
                    .disabled(selfCheckFixTargetTooLarge(report))
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.appAccent.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.appAccent.opacity(0.3), lineWidth: DS.Stroke.regular))
    }

    /// 点击报告条目：打开/切换到对应文件（返回是否成功）。
    private func focusSelfCheckTarget(_ issue: DocumentIssue) -> Bool {
        state.focusSelfCheckTarget(url: issue.fileURL) != nil
    }

    /// 修复目标文档超 /fix 整篇上限时禁用按钮（与诊断面板同一降级口径）。
    private func selfCheckFixTargetTooLarge(_ report: AgentWriteSelfCheck.Report) -> Bool {
        guard let target = report.fixTarget else { return false }
        if let tab = state.openTabs.first(where: {
            $0.url.standardizedFileURL == target.standardizedFileURL
        }), !tab.awaitingInitialContent {
            return tab.content.count > SlashAICommandExecutor.maxDocumentChars
        }
        let size = (try? String(contentsOf: target, encoding: .utf8))?.count ?? 0
        return size > SlashAICommandExecutor.maxDocumentChars
    }
}
