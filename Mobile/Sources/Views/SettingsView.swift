import SwiftUI

/// 设置根列表：AI 服务 / AI 技能 / 关于 三个子页。
/// 行尾带当前状态摘要（系统设置范式），页面不再一屏滚到底。
struct SettingsView: View {
    @Environment(MobileAISettings.self) private var settings
    @Environment(AppAppearance.self) private var appearance

    var body: some View {
        @Bindable var appearance = appearance
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        AIServiceSettingsView()
                    } label: {
                        HStack {
                            Label("AI 服务", systemImage: "sparkles")
                            Spacer()
                            Text(serviceSummary)
                                .font(.subheadline)
                                .foregroundStyle(PaperTheme.inkSecondary)
                                .lineLimit(1)
                        }
                    }
                    NavigationLink {
                        AISkillsSettingsView()
                    } label: {
                        HStack {
                            Label("AI 技能", systemImage: "square.grid.2x2")
                            Spacer()
                            Text(skillSummary)
                                .font(.subheadline)
                                .foregroundStyle(PaperTheme.inkSecondary)
                        }
                    }
                } header: {
                    sectionHeader("AI")
                }

                Section {
                    NavigationLink {
                        ShareSettingsView()
                    } label: {
                        HStack {
                            Label("在线分享", systemImage: "globe")
                            Spacer()
                            Text(ShareLinkPublisher.shared.isConfigured ? "已配置" : "未配置")
                                .font(.subheadline)
                                .foregroundStyle(PaperTheme.inkSecondary)
                                .lineLimit(1)
                        }
                    }
                } header: {
                    sectionHeader("分享")
                }

                Section {
                    Picker(selection: $appearance.mode) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    } label: {
                        Label("外观", systemImage: "circle.lefthalf.filled")
                    }
                }

                Section {
                    Text("配置仅保存在本机，更改即刻生效。移动端暂不支持本地 Claude CLI。")
                        .font(.footnote)
                        .foregroundStyle(PaperTheme.inkSecondary)
                } header: {
                    sectionHeader("关于")
                }
            }
            .contentMargins(.bottom, PaperTheme.Spacing.bottomBarInset, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .background(PaperTheme.paperBackground)
            .listRowBackground(PaperTheme.card)
            .foregroundStyle(PaperTheme.ink)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// AI 服务摘要：关闭 / 预设名 / 自定义 baseURL 的模型。
    private var serviceSummary: String {
        if settings.provider == .disabled { return "关闭" }
        if let preset = settings.matchedPreset { return preset.name }
        return settings.model.isEmpty ? "自定义" : settings.model
    }

    private var skillSummary: String {
        "\(MobileSkillStore.shared.enabledSkills.count)/\(MobileSkills.all.count) 启用"
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(PaperTheme.inkSecondary)
    }
}

// MARK: - AI 服务（提供商 / 接口 / 模型）

/// 本地 AI 配置页：provider 预设 / baseURL / apiKey / model，存 UserDefaults。
private struct AIServiceSettingsView: View {
    @Environment(MobileAISettings.self) private var settings
    @State private var connectionTesting = false
    @State private var connectionTestResult: String? = nil
    @State private var connectionTestOK = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("预设", selection: presetBinding) {
                    ForEach(AIPresets.all) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                    Text("自定义").tag("custom")
                }
                Picker("类型", selection: $settings.provider) {
                    Text("关闭（预览）").tag(AIProviderKind.disabled)
                    Text("OpenAI 兼容").tag(AIProviderKind.openai)
                    Text("Anthropic").tag(AIProviderKind.anthropic)
                }
            } header: {
                header("Provider")
            }

            Section {
                TextField("Base URL", text: $settings.baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API Key", text: $settings.apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack(spacing: 10) {
                    Button {
                        Task { await runConnectionTest() }
                    } label: {
                        if connectionTesting {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("测试中…")
                            }
                        } else {
                            Text("测试连接")
                        }
                    }
                    .disabled(connectionTesting)
                    if let result = connectionTestResult {
                        Text(result)
                            .font(.footnote)
                            .foregroundStyle(connectionTestOK ? Color.green : PaperTheme.seal)
                            .lineLimit(2)
                    }
                }
            } header: {
                header("接口")
            }

            Section {
                TextEditor(text: $settings.customSystemPrompt)
                    .frame(minHeight: 88)
                    .scrollContentBackground(.hidden)
            } header: {
                header("自定义系统提示词")
            } footer: {
                Text("追加到每次对话的系统提示词末尾。例如：「回答一律用中文，风格简洁直接」。")
                    .font(.footnote)
                    .foregroundStyle(PaperTheme.inkSecondary)
            }

            Section {
                TextField("Model", text: $settings.model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if let preset = settings.matchedPreset, !preset.models.isEmpty {
                    Picker("常用模型", selection: $settings.model) {
                        ForEach(preset.models, id: \.self) { Text($0).tag($0) }
                    }
                }
            } header: {
                header("模型")
            }
        }
        .contentMargins(.bottom, PaperTheme.Spacing.bottomBarInset, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(PaperTheme.paper)
        .listRowBackground(PaperTheme.card)
        .foregroundStyle(PaperTheme.ink)
        .navigationTitle("AI 服务")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(PaperTheme.inkSecondary)
    }

    /// 预设选择：匹配当前 baseURL 的预设，否则 "custom"。
    private var presetBinding: Binding<String> {
        Binding(
            get: { settings.matchedPreset?.id ?? "custom" },
            set: { id in
                if let preset = AIPresets.all.first(where: { $0.id == id }) {
                    settings.applyPreset(preset)
                }
            }
        )
    }

    /// 连接测试：与桌面端同一思路——复用 RestAgentBackend 的请求构造，
    /// 收紧超时（10s）与负载（单条 "hi"，非流式）。
    private func runConnectionTest() async {
        connectionTesting = true
        connectionTestResult = nil
        let model = settings.model.isEmpty ? "gpt-4o-mini" : settings.model
        let isAnthropic = settings.provider == .anthropic
            || settings.baseURL.lowercased().contains("anthropic")
        do {
            let config = AIConfig(
                kind: isAnthropic ? .anthropic : .openai,
                baseURL: settings.baseURL.trimmingCharacters(in: .whitespaces),
                model: model,
                cliPath: "",
                cliModel: "",
                apiKey: settings.apiKey.trimmingCharacters(in: .whitespaces),
                requestTimeoutSeconds: 10
            )
            let backend = RestAgentBackend(config: config, wire: isAnthropic ? .anthropic : .openAI)
            _ = try await backend.complete(
                messages: [AgentMessage(role: .user, content: "hi")],
                tools: []
            )
            connectionTestOK = true
            connectionTestResult = "✓ 连接成功（\(model)）"
        } catch {
            connectionTestOK = false
            connectionTestResult = "✗ 连接失败：\(error.localizedDescription)"
        }
        connectionTesting = false
    }
}

// MARK: - 在线分享

/// 分享配置页：服务地址 + Token（需与 Worker 的 SHARE_TOKEN 一致）。
private struct ShareSettingsView: View {
    @State private var tokenInput = ""
    @State private var publisher = ShareLinkPublisher.shared

    var body: some View {
        Form {
            Section {
                TextField("服务地址", text: Binding(
                    get: { publisher.baseURL },
                    set: { publisher.baseURL = $0 }
                ))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                header("服务")
            } footer: {
                Text("自建分享服务地址，发布前可换成自定义域名。")
                    .font(.footnote)
                    .foregroundStyle(PaperTheme.inkSecondary)
            }

            Section {
                if publisher.hasToken {
                    HStack {
                        Text("•••••••• 已配置")
                            .foregroundStyle(PaperTheme.inkSecondary)
                        Spacer()
                        Button("清除") { publisher.clearToken() }
                            .foregroundStyle(PaperTheme.seal)
                    }
                } else {
                    HStack {
                        SecureField("分享 Token", text: $tokenInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("保存") {
                            publisher.saveToken(tokenInput)
                            tokenInput = ""
                        }
                        .disabled(tokenInput.isEmpty)
                    }
                }
            } header: {
                header("Token")
            } footer: {
                Text("需与 Worker 的 SHARE_TOKEN 密钥一致，仅保存在本机钥匙串。")
                    .font(.footnote)
                    .foregroundStyle(PaperTheme.inkSecondary)
            }
        }
        .contentMargins(.bottom, PaperTheme.Spacing.bottomBarInset, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(PaperTheme.paper)
        .listRowBackground(PaperTheme.card)
        .foregroundStyle(PaperTheme.ink)
        .navigationTitle("在线分享")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { publisher.refreshTokenStatus() }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(PaperTheme.inkSecondary)
    }
}

// MARK: - AI 技能

/// 技能开关页：启用的技能注入 AI 对话，并在输入栏上方提供快捷指令。
private struct AISkillsSettingsView: View {
    var body: some View {
        Form {
            Section {
                ForEach(MobileSkills.all) { skill in
                    Toggle(isOn: skillBinding(skill.id)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Label(skill.name, systemImage: skill.icon)
                            Text(skill.description)
                                .font(.footnote)
                                .foregroundStyle(PaperTheme.inkSecondary)
                        }
                    }
                }
            } footer: {
                Text("启用的技能会注入 AI 对话，并在输入栏上方提供快捷指令。")
                    .font(.footnote)
                    .foregroundStyle(PaperTheme.inkSecondary)
            }
        }
        .contentMargins(.bottom, PaperTheme.Spacing.bottomBarInset, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(PaperTheme.paper)
        .listRowBackground(PaperTheme.card)
        .foregroundStyle(PaperTheme.ink)
        .navigationTitle("AI 技能")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 技能开关绑定：读写 MobileSkillStore 单例。
    private func skillBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { MobileSkillStore.shared.isEnabled(id) },
            set: { MobileSkillStore.shared.setEnabled(id, $0) }
        )
    }
}
