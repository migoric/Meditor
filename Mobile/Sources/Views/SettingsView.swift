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
                            Text(shareSummary)
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
                    LabeledContent("版本") {
                        Text(Self.appVersion)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(PaperTheme.inkSecondary)
                    }
                    Link(destination: URL(string: "https://meditorapp.pages.dev")!) {
                        HStack {
                            Label("官网", systemImage: "globe")
                            Spacer()
                            Text("meditorapp.pages.dev")
                                .font(.subheadline)
                                .foregroundStyle(PaperTheme.inkSecondary)
                        }
                    }
                } header: {
                    sectionHeader("关于")
                } footer: {
                    Text("配置仅保存在本机，更改即刻生效。移动端暂不支持本地 Claude CLI。")
                        .font(.footnote)
                        .foregroundStyle(PaperTheme.inkSecondary)
                }
            }
            .contentMargins(.bottom, PaperTheme.Spacing.bottomBarInset, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .background(PaperTheme.paperBackground)
            .listRowBackground(PaperTheme.card)
            .foregroundStyle(PaperTheme.ink)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            // 两处「已配置」摘要都读 Keychain 的缓存态：进入列表时刷一次，
            // 否则从分享页配好 Token 返回后，这里仍显示「未配置」。
            .onAppear {
                ShareLinkPublisher.shared.refreshTokenStatus()
                GistPublisher.shared.refreshTokenStatus()
            }
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

    /// 分享状态摘要：两条通道各自独立，任一条配好都算「能用」，
    /// 只配了 Gist 时明确写「仅 Gist」——不然用户会以为在线分享也通了。
    private var shareSummary: String {
        if ShareLinkPublisher.shared.isConfigured { return "已配置" }
        return GistPublisher.shared.isConfigured ? "仅 Gist" : "未配置"
    }

    /// 版本号：短版本（+ 构建号）。设置页里唯一能确认「装的是哪一版」的地方——
    /// iOS 没有 Sparkle 更新通道，升级只能靠重装，报障时这串字符是唯一的对齐依据。
    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty else {
            return short
        }
        return "\(short) (\(build))"
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
            } footer: {
                Text("AI 对话使用的模型；Agent 没单独指定时也用它。")
                    .font(.footnote)
                    .foregroundStyle(PaperTheme.inkSecondary)
            }

            Section {
                TextField("跟随主模型", text: $settings.agentModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if let preset = settings.matchedPreset, !preset.models.isEmpty {
                    Picker("常用模型", selection: $settings.agentModel) {
                        Text("跟随主模型").tag("")
                        ForEach(preset.models, id: \.self) { Text($0).tag($0) }
                    }
                }
            } header: {
                header("Agent 模型")
            } footer: {
                Text("带工具调用的任务（改文档、查目录）用这个模型；留空则跟随上面的模型。"
                     + "把重活交给更强的模型、把聊天留给便宜的模型时用得上。")
                    .font(.footnote)
                    .foregroundStyle(PaperTheme.inkSecondary)
            }

            Section {
                Stepper(value: $settings.agentMaxSteps,
                        in: MobileAISettings.agentMaxStepsRange) {
                    HStack {
                        Text("最大步数")
                        Spacer()
                        Text("\(settings.agentMaxSteps)")
                            .monospacedDigit()
                            .foregroundStyle(PaperTheme.inkSecondary)
                    }
                }
            } header: {
                header("Agent 上限")
            } footer: {
                Text("单次任务最多执行多少步工具调用（5–100）。超时时间随步数一起放大："
                     + "每步十秒，最少五分钟。")
                    .font(.footnote)
                    .foregroundStyle(PaperTheme.inkSecondary)
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
    @State private var gistTokenInput = ""
    @State private var gist = GistPublisher.shared
    @State private var gistSaveFailed = false

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

            Section {
                if gist.hasToken {
                    HStack {
                        Text("•••••••• 已配置")
                            .foregroundStyle(PaperTheme.inkSecondary)
                        Spacer()
                        Button("清除") { gist.clearToken() }
                            .foregroundStyle(PaperTheme.seal)
                    }
                } else {
                    HStack {
                        SecureField("ghp_…", text: $gistTokenInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("保存") {
                            // 钥匙串写入可能被拒（设备无密码等），必须当场告知，
                            // 否则用户会以为配好了、点发布才看到「未配置」。
                            if gist.saveToken(gistTokenInput) {
                                gistTokenInput = ""
                            } else {
                                gistSaveFailed = true
                            }
                        }
                        .disabled(gistTokenInput.isEmpty)
                    }
                }
                Picker("可见性", selection: Binding(
                    get: { gist.isPublic },
                    set: { gist.isPublic = $0 }
                )) {
                    Text("私密").tag(false)
                    Text("公开").tag(true)
                }
            } header: {
                header("GitHub Gist")
            } footer: {
                Text("发布文档原文到 Gist，需在 GitHub 生成带 gist 权限的 Token。"
                     + "与上面的在线分享是两条独立通道：那边发布渲染后的网页，这边发布 Markdown 源文件。"
                     + "私密 Gist 不出现在列表与搜索里，但拿到链接的人仍可访问。")
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
        .onAppear {
            publisher.refreshTokenStatus()
            gist.refreshTokenStatus()
        }
        .alert("无法保存 Token", isPresented: $gistSaveFailed) {
            Button("好", role: .cancel) {}
        } message: {
            Text(gist.lastError ?? "钥匙串写入失败。")
        }
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
