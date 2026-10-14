import SwiftUI

// MARK: - 首启引导决策（纯逻辑，便于单测）

enum AIOnboardingLogic {
    /// 是否展示引导：从未配置任何 AI provider 且用户未跳过。
    /// 配置完成后 isConfigured 变 true，引导自动消失（无需额外标记）。
    static func shouldShow(isConfigured: Bool, dismissed: Bool) -> Bool {
        !isConfigured && !dismissed
    }
}

// MARK: - AIOnboardingView

/// 无 AI 配置时的首启引导（嵌入 AI 助手面板空态，不新造窗口）。
/// 路径优先级：检测到 Claude Code → 一键零配置；否则跳设置页填 key；或暂时跳过。
/// 在引导内完成配置后切到「就绪」阶段，给出 30 秒演示入口。
@MainActor
struct AIOnboardingView: View {
    let theme: PreviewTheme
    /// 当前是否已有可用 AI 配置（外部计算传入，驱动 setup → ready 切换）
    let isConfigured: Bool
    /// 当前 provider 是否为 ClaudeCLI（决定就绪阶段跑不跑 CLI 自检）
    let isCLIProvider: Bool
    /// CLI 连接自检（外部注入，复用 AIClient.testClaudeCLI）；返回 nil = 成功
    let cliTest: () async -> String?
    let onUseClaudeCLI: (String) -> Void
    let onOpenSettings: () -> Void
    let onRunDemo: () -> Void
    /// 关闭引导（跳过 / 就绪后「开始对话」）
    let onDismiss: () -> Void

    /// CLI 探测三态：probing 期间不闪烁「未检测到」
    enum CLIDetection: Equatable {
        case probing
        case found(String)
        case notFound
    }
    @State private var detection: CLIDetection = .probing
    /// 本次引导会话内完成了配置 → 停在 ready 阶段（否则 isConfigured 后引导直接消失，
    /// 演示入口来不及展示）
    @State private var configuredInSession = false
    @State private var cliTesting = false
    @State private var cliTestError: String?? = nil   // 外层 nil = 未测；内层 nil = 成功

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                header
                if isConfigured && configuredInSession {
                    readySection
                } else {
                    setupSection
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            DotGridBackground(opacity: theme.isDark ? 0.10 : 0.18)
                .allowsHitTesting(false)
        )
        .task {
            // 登录 shell 探测 + 常见路径扫描，可能耗时几百毫秒，异步进行
            if let path = await AIClient.detectClaudeCLI() {
                detection = .found(path)
            } else {
                detection = .notFound
            }
        }
        .onChange(of: isConfigured) { _, configured in
            if configured && !configuredInSession {
                configuredInSession = true
                runCLITestIfNeeded()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                AIAssistantOrb(size: 36, glow: true)
                Text(isConfigured && configuredInSession ? L("onboarding.title.ready") : L("onboarding.title.setup"))
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.craftPrimary)
            }
            if !(isConfigured && configuredInSession) {
                Text(L("onboarding.subtitle"))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.craftSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 配置阶段

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            // 首选：Claude Code 零配置
            claudeCLICard

            // 30 秒演示：无 key 时自动降级为离线预演（runAuto 决定）
            demoCard(offline: true)

            // 次选：预设 provider 填 key（跳设置页 AI tab）
            Button(action: onOpenSettings) {
                HStack(spacing: 10) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 26, height: 26)
                        .foregroundStyle(AIBrand.orange)
                        .background(AIBrand.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L("onboarding.otherProvider"))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(theme.craftPrimary)
                        Text(L("onboarding.otherProviderSub"))
                            .font(.system(size: 11))
                            .foregroundStyle(theme.craftSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.craftSecondary)
                }
                .padding(10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .fill(theme.craftHover.opacity(0.5))
            )

            Button(L("onboarding.skip"), action: onDismiss)
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.craftSecondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 2)
        }
    }

    private var claudeCLICard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 26)
                    .foregroundStyle(AIBrand.blue)
                    .background(AIBrand.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(L("onboarding.useClaudeCode"))
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(theme.craftPrimary)
                        Text(L("onboarding.recommended"))
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(AIBrand.blue, in: Capsule())
                    }
                    switch detection {
                    case .probing:
                        Text(L("onboarding.detecting"))
                            .font(.system(size: 11))
                            .foregroundStyle(theme.craftSecondary)
                    case .found(let path):
                        Text(L("onboarding.detected", path))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(theme.craftSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    case .notFound:
                        Text(L("onboarding.notDetected"))
                            .font(.system(size: 11))
                            .foregroundStyle(theme.craftSecondary)
                    }
                }
                Spacer()
            }

            if case .found(let path) = detection {
                Button {
                    onUseClaudeCLI(path)
                } label: {
                    Text(L("onboarding.useDirectly"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(AIBrand.blue, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .fill(AIBrand.blue.opacity(theme.isDark ? 0.10 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .strokeBorder(AIBrand.blue.opacity(0.25), lineWidth: DS.Stroke.regular)
        )
    }

    // MARK: - 就绪阶段（引导内完成配置后）

    private var readySection: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            // CLI 自检结果（仅 ClaudeCLI provider）
            if isCLIProvider {
                HStack(spacing: 6) {
                    if cliTesting {
                        ProgressView().controlSize(.small)
                        Text(L("onboarding.verifying"))
                    } else if let result = cliTestError {
                        if let error = result {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                            Text(L("onboarding.connectFailed", error))
                        } else {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text(L("onboarding.connectOK"))
                        }
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(theme.craftSecondary)
                .lineLimit(2)
            }

            demoCard(offline: false)

            Button(L("onboarding.startChat"), action: onDismiss)
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.craftSecondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 2)
        }
    }

    // MARK: - 30 秒演示卡片（setup / ready 两阶段共用）

    /// offline = true 时提示「无需配置」的离线预演（实际模式由 AgentDemoFlow.runAuto 按配置状态决定）
    private func demoCard(offline: Bool) -> some View {
        Button(action: onRunDemo) {
            HStack(spacing: 10) {
                Image(systemName: "play.fill")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 26)
                    .foregroundStyle(.white)
                    .background(AIBrand.violet, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("onboarding.demoTitle"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(theme.craftPrimary)
                    Text(L(offline ? "onboarding.demoSubOffline" : "onboarding.demoSub"))
                        .font(.system(size: 11))
                        .foregroundStyle(theme.craftSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .fill(AIBrand.violet.opacity(theme.isDark ? 0.12 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .strokeBorder(AIBrand.violet.opacity(0.25), lineWidth: DS.Stroke.regular)
        )
    }

    // MARK: - Logic

    private func runCLITestIfNeeded() {
        guard isCLIProvider, !cliTesting else { return }
        cliTesting = true
        Task {
            let error = await cliTest()
            cliTestError = error   // 内层 nil = 成功
            cliTesting = false
        }
    }
}
