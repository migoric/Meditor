#if os(macOS)
import SwiftUI

// MARK: - 后台 Agent 任务列表

/// AI 助手面板 header 下方的后台任务区：进行中 + 最近完成的任务。
/// 行 = 状态图标 + 标题 + 耗时；点击展开查看 run 的思考/工具调用摘要
///（直接复用 runner.state.steps，不另起存储）；进行中的行提供取消按钮。
@MainActor
struct AIBackgroundTasksSection: View {
    @Environment(AppState.self) private var state
    let theme: PreviewTheme
    @State private var expandedID: UUID? = nil

    var body: some View {
        let tasks = state.backgroundAgentTasks.tasks
        if !tasks.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Image(systemName: "moon.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text(L("ai.background.section"))
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(theme.craftSecondary)
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 4)

                ForEach(tasks) { task in
                    taskRow(task)
                    if expandedID == task.id {
                        taskDetail(task)
                    }
                }
            }
            .background(theme.editorBackground)
            .overlay(alignment: .bottom) { theme.separator.opacity(0.4).frame(height: 0.5) }
        }
    }

    // MARK: - 行

    private func taskRow(_ task: BackgroundAgentTask) -> some View {
        HStack(spacing: 8) {
            statusIcon(task)

            Text(task.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.craftPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if task.isRunning {
                // 运行中的耗时每秒走表；结束后定格为最终耗时
                TimelineView(.periodic(from: task.startedAt, by: 1)) { context in
                    Text(durationText(seconds: context.date.timeIntervalSince(task.startedAt)))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.craftSecondary)
                }
                Button {
                    state.backgroundAgentTasks.cancel(task)
                } label: {
                    Image(systemName: "stop.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.red.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help(L("ai.background.cancelTask"))
            } else {
                Text(durationText(seconds: task.durationSeconds))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.craftSecondary)
                Image(systemName: expandedID == task.id ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.craftSecondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(DS.Motion.fast) {
                expandedID = expandedID == task.id ? nil : task.id
            }
        }
    }

    private func statusIcon(_ task: BackgroundAgentTask) -> some View {
        Group {
            switch task.termination {
            case .running:
                ProgressView().controlSize(.mini).scaleEffect(0.8)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color.red)
            case .cancelled:
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(theme.craftSecondary)
            }
        }
        .font(.system(size: 12))
        .frame(width: 14, height: 14)
    }

    // MARK: - 展开详情（思考/工具调用摘要 + 结果）

    private func taskDetail(_ task: BackgroundAgentTask) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            let steps = task.runner.state.steps
            if steps.isEmpty {
                Text(task.isRunning ? L("ai.background.running") : (task.resultSummary ?? ""))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.craftSecondary)
            } else {
                ForEach(steps) { step in
                    AgentStepView(step: step, compact: true)
                        .environment(state)
                }
            }
            if let summary = task.resultSummary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(task.termination == .failed ? Color.red : theme.craftSecondary)
                    .lineLimit(3)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.craftHover.opacity(0.4))
    }

    // MARK: - Helpers

    private func durationText(seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
#endif
