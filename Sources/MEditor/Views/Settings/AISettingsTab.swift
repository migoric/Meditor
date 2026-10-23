import SwiftUI
import AppKit

// MARK: - AI tab

extension SettingsView {
    var aiContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                aiQuickStartSection
                aiAdvancedSection
            }
            .padding(DS.Space.lg)
        }
        .task { await probeClaudeCLI() }
    }

    // MARK: - 快速开始（首屏唯一决策）

    /// 首屏只保留一个决策：本机 Claude CLI（零配置，检测到即推荐）或填自己的 API key。
    /// 其余配置项全部收进下方「高级」折叠区——功能不删，只分层（战略复核 P0：
    /// 新用户不该先做十几个技术决策才能看到第一个结果）。
    @ViewBuilder
    var aiQuickStartSection: some View {
        settingsGroup(title: L("settings.ai.quickStart")) {
            cliOptionRow
            rowDivider
            apiKeyOptionRow
            if usesRemoteAPI {
                rowDivider
                settingsStackedRow(label: L("ai.apiKey"), subtitle: L("ai.apiKey.localOnly")) { aiKeyField }
                rowDivider
                settingsStackedRow(label: L("settings.ai.connectionTest"), subtitle: L("settings.ai.connectionTestHint")) {
                    connectionTestButton { await runConnectionTest() }
                }
            }
        }
    }

    /// 「填自己的 API key」这一档包含两种线格式：OpenAI 兼容与 Anthropic 直连。
    /// 判断必须两处一起认，否则选了 Anthropic 预设之后整块远程设置（key / 测试连接
    /// / 模型）会从界面上消失——provider 被切成 anthropic 的那一刻配置就摸不到了。
    private var usesRemoteAPI: Bool {
        let kind = AIProviderKind(rawValue: settings.aiProvider)
        return kind == .openai || kind == .anthropic
    }

    private var cliOptionSelected: Bool {
        settings.aiProvider == AIProviderKind.claudeCLI.rawValue
    }

    /// 探测状态文案：探测中 / 已检测到（推荐）/ 已选用但本次未扫到（显示已配置路径）/ 未检测到。
    private var cliDetectionText: String {
        if aiCLIProbing { return L("settings.ai.cliDetecting") }
        if let path = aiCLIDetectedPath { return L("settings.ai.cliDetected", path) }
        if cliOptionSelected { return settings.aiCLIPath }
        return L("settings.ai.cliNotDetected")
    }

    var cliOptionRow: some View {
        Button(action: enableClaudeCLI) {
            HStack(alignment: .center, spacing: DS.Space.md) {
                Image(systemName: cliOptionSelected ? "checkmark.circle.fill" : "circle")
                    .font(DS.Font.label(15))
                    .foregroundStyle(cliOptionSelected ? Color.appAccent : Color.secondary.opacity(0.5))
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    HStack(spacing: DS.Space.sm) {
                        Text(L("settings.ai.quickCLITitle"))
                            .font(DS.Font.label(13, weight: .medium))
                            .foregroundStyle(.primary)
                        if aiCLIDetectedPath != nil {
                            Text(L("settings.ai.recommended"))
                                .font(DS.Font.label(9.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, DS.Space.xs)
                                .padding(.vertical, DS.Space.xxs)
                                .background(AIBrand.blue, in: Capsule())
                        }
                    }
                    Text(cliDetectionText)
                        .font(DS.Font.label(11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: DS.Space.md)
                if aiCLIProbing {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 未检测到且未选用时禁用（自定义路径走「高级」区的手动指定）
        .disabled(!cliOptionSelected && aiCLIDetectedPath == nil)
    }

    var apiKeyOptionRow: some View {
        let selected = usesRemoteAPI
        return Button(action: enableAPIKeyProvider) {
            HStack(alignment: .center, spacing: DS.Space.md) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(DS.Font.label(15))
                    .foregroundStyle(selected ? Color.appAccent : Color.secondary.opacity(0.5))
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(L("settings.ai.quickAPIKeyTitle"))
                        .font(DS.Font.label(13, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(L("settings.ai.quickAPIKeyHint"))
                        .font(DS.Font.label(11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: DS.Space.md)
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 高级（默认收起，展开状态持久化）

    var aiAdvancedSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                withAnimation(DS.Motion.fast) { settings.aiAdvancedExpanded.toggle() }
            } label: {
                HStack(spacing: DS.Space.sm) {
                    Text(L("settings.ai.advanced"))
                        .font(DS.Font.label(13.5, weight: .bold))
                        .foregroundStyle(.primary)
                    Text(L("settings.ai.advancedHint"))
                        .font(DS.Font.label(11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(DS.Font.label(11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(settings.aiAdvancedExpanded ? 90 : 0))
                }
                .padding(.leading, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if settings.aiAdvancedExpanded {
                aiAdvancedContent
            }
        }
        .padding(.bottom, 22)
    }

    /// 高级区内容：原有全部配置组原样保留（provider 细项 / 个性化 / 演示 / 端侧 / MCP）。
    @ViewBuilder
    var aiAdvancedContent: some View {
        settingsGroup(title: L("ai.section.mode")) {
            settingsStackedRow(label: L("ai.provider"), subtitle: L("settings.desc.provider")) {
                SettingsMenu(
                    selection: bindableSettings.aiProvider,
                    options: [
                        (AIProviderKind.disabled.rawValue, L("ai.provider.disabled")),
                        (AIProviderKind.claudeCLI.rawValue, L("ai.mode.local")),
                        (AIProviderKind.openai.rawValue, L("ai.mode.remote")),
                        // Anthropic 直连（Messages API）与 OpenAI 兼容是两套线格式：
                        // 端点、消息结构、prompt caching 断点都不同，必须能显式选到，
                        // 否则「选 Anthropic 预设」只能改 baseURL、线格式仍是 OpenAI。
                        (AIProviderKind.anthropic.rawValue, L("ai.mode.remoteAnthropic"))
                    ]
                )
            }
        }

        if settings.aiProvider == AIProviderKind.claudeCLI.rawValue {
            settingsGroup(title: L("ai.section.local")) {
                settingsStackedRow(label: L("ai.cliPath"), subtitle: L("ai.cliHint")) {
                    HStack(spacing: 8) {
                        TextField("/usr/local/bin/claude", text: bindableSettings.aiCLIPath)
                            .textFieldStyle(.plain)
                            .settingsField()
                        Button(action: detectCLI) {
                            if aiDetecting {
                                ProgressView().controlSize(.small)
                            } else {
                                Text(L("ai.detect"))
                            }
                        }
                        .disabled(aiDetecting)
                    }
                }
                rowDivider
                settingsStackedRow(label: L("ai.model"), subtitle: L("settings.ai.cliModelHint")) {
                    SettingsMenu(
                        selection: bindableSettings.aiCLIModel,
                        options: [
                            ("",                  L("settings.ai.cliModelDefault")),
                            ("claude-opus-4-5",   L("settings.ai.cliModelOpus")),
                            ("claude-sonnet-4-5", L("settings.ai.cliModelSonnet")),
                            ("claude-haiku-4-5",  L("settings.ai.cliModelHaiku")),
                        ]
                    )
                }
                rowDivider
                settingsStackedRow(label: L("settings.ai.connectionTest"), subtitle: L("settings.ai.connectionTestHint")) {
                    connectionTestButton(disabled: settings.aiCLIPath.isEmpty) { await runCLITest() }
                }
            }
        } else if usesRemoteAPI {
            settingsGroup(title: L("ai.section.remote")) {
                settingsStackedRow(label: L("ai.preset")) {
                    SettingsMenu(
                        selection: Binding<String>(
                            get: { AIPresets.match(settings.aiBaseURL)?.id ?? "custom" },
                            set: { id in
                                // 三个字段一起写：provider 决定线格式，漏掉它就是
                                // 「配置看着对、发出去 404」（Anthropic 预设的历史 bug）。
                                guard let applied = AIPresets.apply(id: id, currentModel: settings.aiModel) else { return }
                                settings.aiProvider = applied.kind.rawValue
                                settings.aiBaseURL = applied.baseURL
                                aiModels = AIPresets.all.first(where: { $0.id == id })?.models ?? aiModels
                                settings.aiModel = applied.model
                            }
                        ),
                        options: AIPresets.all.map { ($0.id, $0.name) } + [("custom", L("ai.preset.custom"))]
                    )
                }
                rowDivider
                settingsStackedRow(label: L("ai.baseURL")) {
                    TextField("https://api.openai.com/v1", text: bindableSettings.aiBaseURL)
                        .textFieldStyle(.plain)
                        .settingsField()
                }
                rowDivider
                settingsStackedRow(label: L("ai.apiKey"), subtitle: L("ai.apiKey.localOnly")) { aiKeyField }
                rowDivider
                settingsStackedRow(label: L("settings.ai.connectionTest")) {
                    connectionTestButton { await runConnectionTest() }
                }
                rowDivider
                settingsStackedRow(label: L("ai.model")) { aiModelField }
                rowDivider
                settingsStackedRow(label: L("settings.ai.agentModel"), subtitle: L("settings.ai.agentModelHint")) {
                    modelPickerField(binding: bindableSettings.aiAgentModel, placeholder: L("settings.ai.modelFallback"))
                }
                rowDivider
                settingsStackedRow(label: L("settings.ai.agentMaxSteps"), subtitle: L("settings.ai.agentMaxStepsHint")) {
                    TextField("30", value: bindableSettings.aiAgentMaxSteps, format: .number)
                        .textFieldStyle(.plain)
                        .settingsField()
                        .frame(width: 60)
                }
                rowDivider
                settingsStackedRow(label: L("settings.ai.inlineModel"), subtitle: L("settings.ai.inlineModelHint")) {
                    modelPickerField(binding: bindableSettings.aiInlineModel, placeholder: L("settings.ai.modelFallback"))
                }
            }
        }

        // MARK: 个性化（对所有 provider 生效）
        settingsGroup(title: L("settings.ai.sectionPersonal")) {
            settingsRow(label: L("ai.accentStyle"), subtitle: L("settings.desc.accent")) {
                SettingsMenu(
                    selection: Binding(
                        get: { AIAccentStyle.current(settings) },
                        set: { settings.aiAccentStyle = $0.rawValue }
                    ),
                    options: AIAccentStyle.allCases.map { ($0, L($0.labelKey)) }
                )
                .frame(width: 170)
            }

            rowDivider

            settingsRow(
                label: L("ai.autoAttach.toggle"),
                subtitle: L("ai.autoAttach.toggleHint")
            ) {
                Toggle("", isOn: bindableSettings.aiAutoAttachContext)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            rowDivider

            settingsRow(
                label: L("settings.ai.autoApplyWrites"),
                subtitle: L("settings.ai.autoApplyWritesHint")
            ) {
                Toggle("", isOn: bindableSettings.aiAgentAutoApplyWrites)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            rowDivider

            settingsRow(
                label: L("settings.ai.trace"),
                subtitle: L("settings.ai.traceHint")
            ) {
                Toggle("", isOn: bindableSettings.aiTraceEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            rowDivider

            settingsStackedRow(
                label: L("settings.ai.customPrompt"),
                subtitle: L("settings.ai.customPromptHint")
            ) {
                TextEditor(text: bindableSettings.aiCustomSystemPrompt)
                    .font(.system(size: 12))
                    .frame(minHeight: 64, maxHeight: 96)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }

        // MARK: 入门演示（可随时重看；未配置 AI 时离线预演）
        settingsGroup(title: L("settings.ai.replayDemo")) {
            settingsRow(label: L("settings.ai.replayDemoLabel"), subtitle: L("settings.ai.replayDemoHint")) {
                Button(L("settings.ai.replayDemoAction")) {
                    state.showingSettings = false
                    state.showingAIAssistant = true
                    Task { await state.agentDemoFlow.runAuto(appState: state, settings: settings) }
                }
            }
        }

        // MARK: 端侧智能（Apple Foundation Models，macOS 26+；默认关，静默回退）
        settingsGroup(title: L("settings.ai.onDevice")) {
            settingsRow(
                label: L("settings.ai.onDevicePasteCleanup"),
                subtitle: L("settings.ai.onDevicePasteCleanupHint")
            ) {
                Toggle("", isOn: bindableSettings.aiOnDevicePasteCleanup)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            rowDivider

            settingsRow(label: L("settings.ai.onDeviceStatus")) {
                onDeviceStatusView
            }
        }

        // MARK: MCP 服务器（外部 Agent 接入）
        settingsGroup(title: L("settings.ai.mcp")) {
            settingsStackedRow(label: L("settings.ai.mcpConfigLabel"), subtitle: L("settings.ai.mcpHint")) {
                HStack(alignment: .top, spacing: 8) {
                    Text(mcpConfigSnippet)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Button(L("settings.ai.mcpCopy")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(mcpConfigSnippet, forType: .string)
                        state.showToast(L("settings.ai.mcpCopied"), icon: "doc.on.doc")
                    }
                }
            }
        }
    }

    // MARK: - 连接测试按钮（快速开始 / CLI / 远程三处共用）

    func connectionTestButton(disabled: Bool = false, action: @escaping () async -> Void) -> some View {
        HStack(spacing: 10) {
            Button {
                Task { await action() }
            } label: {
                if connectionTesting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(L("settings.ai.testing"))
                    }
                } else {
                    Text(L("settings.ai.testConnection"))
                }
            }
            .disabled(connectionTesting || disabled)
            if let result = connectionTestResult {
                Text(result)
                    .font(DS.Font.label(11.5))
                    .foregroundStyle(connectionTestOK ? Color.green : Color.red)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    // MARK: - 快速开始逻辑

    /// 登录 shell 探测 + 常见路径扫描（与首启引导共用 AIClient.detectClaudeCLI），
    /// 可能耗时几百毫秒，异步进行；结果只用于推荐展示，不覆盖用户已配置的路径。
    @MainActor
    func probeClaudeCLI() async {
        aiCLIProbing = true
        aiCLIDetectedPath = await AIClient.detectClaudeCLI()
        aiCLIProbing = false
    }

    func enableClaudeCLI() {
        settings.aiProvider = AIProviderKind.claudeCLI.rawValue
        if let path = aiCLIDetectedPath { settings.aiCLIPath = path }
    }

    func enableAPIKeyProvider() {
        // 已经是远程档（openai / anthropic）就别再改：这一行是「切到本模式」，
        // 不是「重置为本模式的默认值」。否则在 anthropic 下点一下自己会被打回 openai。
        guard !usesRemoteAPI else { return }
        settings.aiProvider = AIProviderKind.openai.rawValue
    }

    // MARK: - Preset model picker for agent/inline fields

    /// Built-in preset models for the current base URL, merged with any fetched
    /// models and the currently-selected one.
    var candidateModels: [String] {
        var list = aiModels
        if list.isEmpty, let preset = AIPresets.match(settings.aiBaseURL) {
            list = preset.models
        }
        if !settings.aiModel.isEmpty && !list.contains(settings.aiModel) {
            list.insert(settings.aiModel, at: 0)
        }
        return list
    }

    @ViewBuilder
    var aiKeyField: some View {
        if aiHasKey {
            HStack(spacing: 8) {
                Text("•••••••• " + L("gitlab.tokenConfigured"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .settingsField()
                Button(L("gitlab.clearToken")) {
                    AIAPIKeyStore.clear(); aiKeyInput = ""; aiHasKey = false
                }
            }
        } else {
            HStack(spacing: 8) {
                SecureField("sk-…", text: $aiKeyInput)
                    .textFieldStyle(.plain)
                    .settingsField()
                Button(L("gitlab.saveConfig")) {
                    AIAPIKeyStore.save(aiKeyInput); aiKeyInput = ""; aiHasKey = AIAPIKeyStore.hasKey
                }
                .disabled(aiKeyInput.isEmpty)
            }
        }
    }

    @ViewBuilder
    var aiModelField: some View {
        HStack(spacing: 8) {
            let models = candidateModels
            if models.isEmpty {
                TextField("gpt-4o-mini", text: bindableSettings.aiModel)
                    .textFieldStyle(.plain)
                    .settingsField()
            } else {
                SettingsMenu(
                    selection: bindableSettings.aiModel,
                    options: models.map { ($0, $0) }
                )
            }
            Button(action: refreshModels) {
                if aiLoadingModels {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(aiLoadingModels)
            .help(L("ai.refreshModels"))
        }
    }

    // MARK: - 端侧智能状态展示

    /// 端侧模型当前可用状态（可用为绿色，不可用按原因展示灰色说明）。
    /// availability 探测是本地状态读取，直接放在 body 里同步计算。
    @ViewBuilder
    var onDeviceStatusView: some View {
        let availability = FoundationModelService.shared.availability
        HStack(spacing: 6) {
            Circle()
                .fill(availability.isAvailable ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            Text(L(availability.statusLabelKey))
                .font(.system(size: 12))
                .foregroundStyle(availability.isAvailable ? Color.primary : Color.secondary)
        }
    }

    func detectCLI() {
        aiDetecting = true
        Task {
            let path = await AIClient.detectClaudeCLI()
            await MainActor.run {
                if let path { settings.aiCLIPath = path }
                aiDetecting = false
            }
        }
    }

    // MARK: - Preset model picker for agent/inline fields

    /// Returns preset model list based on current provider/baseURL.
    var presetModelsForCurrentProvider: [String] {
        // If a known preset matches, use its models
        if let preset = AIPresets.match(settings.aiBaseURL) {
            return preset.models
        }
        // Fall back by base URL heuristics
        let base = settings.aiBaseURL.lowercased()
        if base.contains("anthropic") {
            return ["claude-opus-4-5", "claude-sonnet-4-5", "claude-haiku-3-5"]
        } else if base.contains("openai") {
            return ["gpt-4o", "gpt-4o-mini", "gpt-4-turbo", "o3", "o4-mini"]
        } else if base.contains("localhost:11434") || base.contains("ollama") {
            return ["llama3.2", "qwen2.5", "deepseek-r1"]
        }
        // Generic fallback
        return ["gpt-4o", "gpt-4o-mini", "gpt-4-turbo", "o3", "o4-mini",
                "claude-opus-4-5", "claude-sonnet-4-5", "claude-haiku-3-5",
                "llama3.2", "qwen2.5", "deepseek-r1"]
    }

    @ViewBuilder
    func modelPickerField(binding: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: binding)
                .textFieldStyle(.plain)
                .settingsField()
            Menu {
                Button(L("settings.ai.clearCustom")) { binding.wrappedValue = "" }
                Divider()
                ForEach(presetModelsForCurrentProvider, id: \.self) { model in
                    Button(model) { binding.wrappedValue = model }
                }
            } label: {
                Image(systemName: "chevron.down.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(L("settings.ai.pickPresetModel"))
        }
    }
}
