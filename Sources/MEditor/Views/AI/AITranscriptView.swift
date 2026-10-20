import SwiftUI

/// Reports the transcript's bottom-marker offset within the scroll viewport,
/// used to decide whether to auto-follow streaming output.
private struct AIBottomOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Transcript（消息流 + agent 步骤 + 滚动跟随）

extension AIAssistantPanel {
    var transcriptView: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // 历史消息（响应中排除最后一条 reply 占位，交由下方单独渲染，
                        // 使 steps 能放在 reply 之上且能随 runner.steps 更新）
                        ForEach(displayMessages) { message in
                            // 纯图片消息文本为空也要渲染（气泡只画缩略图/占位）
                            if !message.text.isEmpty || !message.images.isEmpty || message.imageCount > 0 {
                                bubble(message).id(message.id)
                            }
                        }

                    if convo.isActiveSessionResponding {
                        // 当前轮 Agent steps —— 放在 reply 之上（过程在上、结论在下，减少抖动）
                        //（仅发起会话显示；切到其他会话时不展示别处的进行态）
                        if let runner = convo.agentRunner, !runner.steps.isEmpty {
                            agentStepsPanel(runner)
                        }
                    } else if let lastState = convo.lastRunState, !lastState.steps.isEmpty {
                        // 完成后：展示历史步骤（Runner 已 nil，但 state 保留）
                        agentStepsPanelFromState(lastState)
                    }
                    if convo.isActiveSessionResponding {
                        // 当前轮 reply（在 steps 之下流式增长）
                        if let last = convo.messages.last,
                           last.role == .assistant, !last.text.isEmpty {
                            bubble(last).id(last.id)
                        }
                        // 进行态提示
                        let streaming = !(convo.messages.last?.text.isEmpty ?? true)
                        let hasSteps  = !(convo.agentRunner?.steps.isEmpty ?? true)
                        if streaming {
                            StreamingCursorView()
                        } else if !hasSteps {
                            HStack(spacing: 8) {
                                AIAssistantOrb(size: 18, glow: true)
                                Text(L("ai.thinking"))
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.craftSecondary)
                                TypingDots(color: theme.craftSecondary)
                            }
                        }
                        // 有 steps 但还没最终文本：steps 内的 thinking 步骤已表示进行中
                    }
                    if let pending = convo.pendingCommand {
                        commandConfirmBar(pending)
                    }
                    if let pending = convo.pendingWrite {
                        writeConfirmBar(pending)
                    }
                    if let report = state.agentWriteSelfCheck.pendingReport {
                        selfCheckBar(report)
                    }
                    // 断点续传：上次 run 失败中断（网络/超时/模型错误，非用户取消）时，
                    // 提供「从中断处继续」——复用已完成工具调用结果续跑，而非从零重来
                    if !convo.isResponding, convo.lastRunState?.termination == .failed {
                        Button(action: resumeInterruptedRun) {
                            HStack(spacing: 5) {
                                Image(systemName: "play.circle")
                                    .font(.system(size: 10, weight: .semibold))
                                Text(L("ai.resume.continue"))
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(Color.appAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .overlay(
                                Capsule().strokeBorder(Color.appAccent.opacity(0.5), lineWidth: DS.Stroke.regular)
                            )
                        }
                        .buttonStyle(.plain)
                        .help(L("ai.resume.continueHint"))
                        .padding(.top, 2)
                    }
                    if !convo.isResponding && convo.messages.last?.role == .assistant {
                        Button(action: regenerate) {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 10, weight: .semibold))
                                Text(L("ai.regenerate"))
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(theme.craftSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .overlay(
                                Capsule().strokeBorder(theme.separator.opacity(0.6), lineWidth: DS.Stroke.regular)
                            )
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                    }
                    // Bottom anchor — ensures the last line fully clears the
                    // composer and that scroll-to-end reaches the true bottom.
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                        .background(
                            GeometryReader { g in
                                Color.clear.preference(
                                    key: AIBottomOffsetKey.self,
                                    value: g.frame(in: .named("aiScroll")).maxY
                                )
                            }
                        )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 16)
                .padding(.bottom, 10)
            }
            .coordinateSpace(name: "aiScroll")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onPreferenceChange(AIBottomOffsetKey.self) { maxY in
                // The bottom marker sits within ~1 viewport when the user is at
                // the end; only then do we follow streaming output.
                atBottom = maxY <= outer.size.height + 40
            }
            .onChange(of: convo.messages.count) { _, _ in
                // A new message (send/reply start) always jumps to the bottom.
                scrollToEnd(proxy)
            }
            .onChange(of: convo.messages.last?.text) { _, _ in
                // 流式输出每个 token 都触发：debounce 合并（60ms），避免逐字滚动导致抖动
                guard atBottom else { return }
                streamScrollWork?.cancel()
                let work = DispatchWorkItem { scrollToEnd(proxy) }
                streamScrollWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
            }
            .onChange(of: convo.agentRunner?.steps.count) { _, _ in
                // 新 step 到达：只有用户本来就贴底时才跟随滚动；上翻阅读时不打断，
                // 回到底部后 atBottom 恢复 true，自动恢复跟随。
                // 必须同步捕获 atBottom——新 step 布局完成后底部锚点被顶出视口，
                // preference 会把 atBottom 置 false，等 async 里再读就永远读不到
                // "插入前"的贴底状态。async 只为等布局 settle 后再滚动。
                let follow = atBottom
                DispatchQueue.main.async {
                    if follow { scrollToEnd(proxy) }
                }
            }
            .onChange(of: convo.pendingCommand?.id) { _, newID in
                // 待确认命令出现时滚到底，避免长命令把"执行/拒绝"按钮推到视口外
                if newID != nil { DispatchQueue.main.async { scrollToEnd(proxy) } }
            }
            .onChange(of: convo.pendingWrite?.id) { _, newID in
                // 待确认写入出现时同样滚到底（与 pendingCommand 同理）
                if newID != nil { DispatchQueue.main.async { scrollToEnd(proxy) } }
            }
            .onChange(of: state.agentWriteSelfCheck.pendingReport) { _, newReport in
                // 自检报告条出现时滚到底（与 pendingWrite 同理）
                if newReport != nil { DispatchQueue.main.async { scrollToEnd(proxy) } }
            }
            .onAppear {
                DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            }
        }
    }

    /// 响应中排除最后一条 reply 占位（交由 transcript 单独渲染，使 steps 能置于其上）。
    /// 仅发起会话排除——切到其他会话时，那里的已完成回复不是流式占位，不能 drop。
    private var displayMessages: [AIChatMessage] {
        if convo.isActiveSessionResponding, convo.messages.last?.role == .assistant {
            return Array(convo.messages.dropLast())
        }
        return convo.messages
    }

    /// 当前轮的 Agent 工具步骤面板（紧凑单行，渲染在流式 reply 之上）。
    @ViewBuilder
    private func agentStepsPanel(_ runner: AgentRunner) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(runner.steps) { step in
                AgentStepView(step: step, compact: true)
                    .environment(state)
                    .transition(.opacity)
            }
            .animation(DS.Motion.spring, value: runner.steps.count)
            usageFooter(runner.state)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.editorBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.separator.opacity(0.25), lineWidth: DS.Stroke.hairline)
        )
    }

    /// 历史步骤面板（Runner 完成后，从 AgentRunState 渲染已结束步骤）
    @ViewBuilder
    private func agentStepsPanelFromState(_ runState: AgentRunState) -> some View {
        let donesteps = runState.steps.filter { if case .thinking = $0 { return false }; return true }
        if !donesteps.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(donesteps) { step in
                    AgentStepView(step: step, compact: true)
                        .environment(state)
                }
                usageFooter(runState)
                rollbackFooter(runState)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.editorBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(theme.separator.opacity(0.25), lineWidth: DS.Stroke.hairline)
            )
        }
    }

    /// 步骤面板尾部的回滚入口：本次 run 写过文件时提供「撤销本次运行的全部修改」。
    /// 回滚后变为已回滚态（展示结果摘要，含被跳过文件的点名提示）。
    /// 只挂在完成态面板（agentStepsPanelFromState）：run 进行中不提供回滚。
    @ViewBuilder
    private func rollbackFooter(_ runState: AgentRunState) -> some View {
        if let checkpoint = runState.checkpoint {
            if let summary = checkpoint.rollbackSummary {
                // 已回滚态
                HStack(spacing: 5) {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .font(.system(size: 10, weight: .medium))
                    Text(summary)
                }
                .font(.system(size: 10))
                .foregroundStyle(theme.craftSecondary)
                .padding(.top, 2)
            } else {
                Button(action: { Task { await state.rollbackAgentRun(checkpoint) } }) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 10, weight: .semibold))
                        Text(L("ai.rollback.undoRun")
                             + String(format: L("ai.rollback.fileCountSuffix"), checkpoint.rollbackableCount))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(theme.craftSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .overlay(
                        Capsule().strokeBorder(theme.separator.opacity(0.6), lineWidth: DS.Stroke.regular)
                    )
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
    }

    /// 步骤面板尾部的用量脚注：「↑prompt ↓completion tokens · 缓存命中 · ≈成本 · 总耗时」。
    /// 后端未返回 usage（如 ClaudeCLI）时整体不显示，优雅降级；
    /// 模型价格表查不到时只省略成本部分（token 数照显）。
    @ViewBuilder
    private func usageFooter(_ runState: AgentRunState) -> some View {
        if let usage = runState.usage {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 8, weight: .medium))
                Text("↑\(ModelPricing.compactTokens(usage.promptTokens)) ↓\(ModelPricing.compactTokens(usage.completionTokens)) tokens")
                if usage.cacheReadTokens > 0 {
                    Text("· " + L("ai.usage.cachedHit", ModelPricing.compactTokens(usage.cacheReadTokens)))
                }
                if let cost = ModelPricing.estimateCost(usage: usage, model: runState.modelName) {
                    Text("· ≈" + ModelPricing.formatUSD(cost))
                }
                if let duration = runState.runDurationSeconds {
                    Text("· \(String(format: "%.1f", duration))s")
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
            .padding(.top, 2)
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(DS.Motion.standard) { proxy.scrollTo("bottom", anchor: .bottom) }
    }
}

// MARK: - Typing indicator

private struct TypingDots: View {
    let color: Color
    @State private var animating = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(color)
                    .frame(width: 5, height: 5)
                    .offset(y: animating ? -3 : 0)
                    .animation(
                        .easeInOut(duration: 0.45)
                            .repeatForever()
                            .delay(Double(i) * 0.15),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
        .accessibilityHidden(true)
    }
}

// MARK: - StreamingCursorView

/// 流式输出期间显示的闪烁光标，告知用户 AI 正在写内容。
private struct StreamingCursorView: View {
    @State private var visible = true

    var body: some View {
        Text("◍")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
            .opacity(visible ? 0.8 : 0.1)
            .padding(.leading, 2)
            .padding(.vertical, 2)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    visible = false
                }
            }
    }
}
