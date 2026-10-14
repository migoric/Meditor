import SwiftUI

// MARK: - Command confirm bar

extension AIAssistantPanel {
    /// agent step 流里的「待确认执行命令」确认条。
    @ViewBuilder
    func commandConfirmBar(_ pending: PendingCommand) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(L("ai.command.pendingTitle"))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.craftPrimary)
            }
            Text(pending.command)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.craftPrimary)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.editorBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            if let cwd = pending.cwd {
                Text(L("ai.command.cwd", cwd))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(theme.craftSecondary)
                    .lineLimit(1)
            }
            HStack(spacing: 8) {
                Spacer()
                Button(L("ai.command.reject")) { pending.reject() }
                    .buttonStyle(.bordered)
                Button(L("ai.execute")) { pending.approve() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.appAccent)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            Text(L("ai.command.rememberHint"))
                .font(.system(size: 10))
                .foregroundStyle(theme.craftSecondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.3), lineWidth: DS.Stroke.regular))
    }
}

// MARK: - File write confirm bar

extension AIAssistantPanel {
    /// agent step 流里的「待确认文件写入」确认条（与 commandConfirmBar 同一范式）。
    /// 多一个「本次运行全部允许」：置位 run 级开关，之后本 run 的写工具直接放行。
    @ViewBuilder
    func writeConfirmBar(_ pending: PendingWrite) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "doc.badge.gearshape")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(L("ai.write.pendingTitle"))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.craftPrimary)
            }
            Text(pending.path)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.craftPrimary)
                .textSelection(.enabled)
                .lineLimit(2)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.editorBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            Text(pending.summary)
                .font(.system(size: 10.5))
                .foregroundStyle(theme.craftSecondary)
                .lineLimit(2)
            WriteDiffDisclosure(diff: pending.diff, theme: theme)
            HStack(spacing: 8) {
                Spacer()
                Button(L("ai.command.reject")) { pending.reject() }
                    .buttonStyle(.bordered)
                Button(L("ai.write.allowAll")) { pending.approveAll() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                Button(L("ai.write.allow")) { pending.approve() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.appAccent)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            Text(L("ai.write.allowAllHint"))
                .font(.system(size: 10))
                .foregroundStyle(theme.craftSecondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.3), lineWidth: DS.Stroke.regular))
    }
}

// MARK: - Write diff disclosure

/// 写确认条里的 diff 预览区：默认收起保持确认条紧凑，点「查看改动」展开/收起。
/// 视觉语言与确认条一致（等宽字体 + 圆角色块），删/增段用红/绿底色区分。
private struct WriteDiffDisclosure: View {
    let diff: WriteDiff
    let theme: PreviewTheme
    /// 最多展示的改动块数，超出折叠为计数提示（防超长 diff 撑爆面板）
    private static let maxHunks = 30
    @State private var isExpanded = false

    var body: some View {
        switch diff {
        case .hunks(let hunks) where !hunks.isEmpty:
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(DS.Motion.springFast) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text(isExpanded ? L("ai.write.hideDiff") : L("ai.write.viewDiff", hunks.count))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Color.appAccent)
                }
                .buttonStyle(.plain)
                if isExpanded { hunkList(hunks) }
            }
        case .tooLarge:
            // 超大文件退化：只给提示，不展示 diff（对齐 1MB 快照上限的取舍）
            Text(L("ai.write.diffTooLarge"))
                .font(.system(size: 10.5))
                .foregroundStyle(theme.craftSecondary)
        default:
            // .unavailable / 无实质改动：不占确认条空间
            EmptyView()
        }
    }

    @ViewBuilder
    private func hunkList(_ hunks: [WriteDiffHunk]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(hunks.prefix(Self.maxHunks)) { hunk in
                    if !hunk.original.isEmpty { hunkBlock(hunk.original, isRemoval: true) }
                    if !hunk.modified.isEmpty { hunkBlock(hunk.modified, isRemoval: false) }
                }
                if hunks.count > Self.maxHunks {
                    Text(L("ai.write.diffMore", hunks.count - Self.maxHunks))
                        .font(.system(size: 10))
                        .foregroundStyle(theme.craftSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 220)
    }

    private func hunkBlock(_ text: String, isRemoval: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(isRemoval ? "−" : "+")
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundStyle(isRemoval ? Color.red : Color.green)
            Text(text)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(theme.craftPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(6)
        .background((isRemoval ? Color.red : Color.green).opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 5))
    }
}
