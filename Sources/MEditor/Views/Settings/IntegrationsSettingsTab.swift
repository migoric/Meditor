import SwiftUI
import AppKit

// MARK: - Integrations tab（外部集成：Claude Code 监听 / MCP 服务器）

extension SettingsView {
    var integrationsContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Claude Code 监听
                claudeMonitorSection

                // MCP 客户端（内置 Agent 调用外部 MCP server 的工具）
                mcpClientSection

                // 定时任务（cron 触发的后台 Agent 任务）
                scheduledTasksSection

                // MCP 服务器（外部 Agent 接入）
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
            .padding(DS.Space.lg)
        }
    }

    /// Claude Desktop 的 MCP 配置片段：命令指向当前运行的 app 内二进制，
    /// 工作区默认填当前打开的目录（未打开时留占位提示用户替换）。
    var mcpConfigSnippet: String {
        let binary = Bundle.main.executableURL?.path ?? "/Applications/MEditor.app/Contents/MacOS/MEditor"
        let workspace = state.rootURL?.path ?? "/path/to/your/workspace"
        return """
        {
          "mcpServers": {
            "meditor": {
              "command": "\(binary)",
              "args": ["mcp", "--workspace", "\(workspace)"]
            }
          }
        }
        """
    }

    // MARK: - Claude Code 监听

    var claudeMonitorSection: some View {
        settingsGroup(title: L("settings.ai.claudeIntegration")) {
            settingsRow(label: L("settings.ai.monitorFiles"), subtitle: L("settings.ai.monitorFilesHint")) {
                Toggle("", isOn: bindableSettings.claudeMonitorEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            if settings.claudeMonitorEnabled {
                rowDivider

                settingsStackedRow(
                    label: L("settings.ai.monitorDir"),
                    subtitle: L("settings.ai.monitorDirHint")
                ) {
                    HStack(spacing: 8) {
                        TextField("~/.claude/projects/", text: bindableSettings.claudeMonitorCustomPath)
                            .textFieldStyle(.plain)
                            .settingsField()
                        Button(L("settings.ai.choose")) { selectClaudeMonitorDir() }
                    }
                }

                rowDivider

                settingsStackedRow(
                    label: L("settings.ai.fileTypes"),
                    subtitle: L("settings.ai.fileTypesHint")
                ) {
                    TextField("md,txt", text: bindableSettings.claudeMonitorFileExts)
                        .textFieldStyle(.plain)
                        .settingsField()
                }

                rowDivider

                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(L("settings.ai.monitorDirInfo", settings.claudeMonitorDirectory.path))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
    }

    func selectClaudeMonitorDir() {
        Task {
            if let url = await state.filePickerService.pickFolder(message: L("settings.ai.pickClaudeDir")) {
                settings.claudeMonitorCustomPath = url.path
            }
        }
    }

    // MARK: - MCP 客户端（内置 Agent → 外部 MCP server）

    var mcpClientSection: some View {
        settingsGroup(title: L("settings.ai.mcpClient")) {
            settingsStackedRow(label: L("settings.ai.mcpClientLabel"), subtitle: L("settings.ai.mcpClientHint")) {
                VStack(alignment: .leading, spacing: 8) {
                    let manager = state.mcpClientManager
                    if manager.statuses.isEmpty {
                        Text(L("settings.ai.mcpClientEmpty"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(manager.statuses) { status in
                            mcpServerRow(status)
                        }
                    }
                    // 配置解析容错记录（坏条目说明），有则展示
                    ForEach(manager.configIssues, id: \.self) { issue in
                        Text(L("settings.ai.mcpClientConfigIssue", issue))
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    // 工作区级 mcp.json：默认忽略，需显式授权（防不可信仓库 RCE）
                    if let wsInfo = manager.workspaceMCPInfo {
                        workspaceMCPTrustRow(wsInfo)
                    }
                    HStack(spacing: 8) {
                        Button(L("settings.ai.mcpClientOpenConfig")) { openMCPClientConfig() }
                        Button(L("settings.ai.mcpClientReconnect")) {
                            Task { await state.mcpClientManager.reconnectAll(workspaceURL: state.rootURL) }
                        }
                        .disabled(manager.statuses.isEmpty)
                    }
                }
            }
        }
        // 打开设置页时仅加载配置摘要（不发起连接）；连接发生在 agent run 开始时
        .onAppear { state.mcpClientManager.reloadConfigSummaries(workspaceURL: state.rootURL) }
    }

    /// 工作区级 mcp.json 的信任行：展示将执行的 server 名单，未授权时提供「信任并启用」。
    @ViewBuilder
    private func workspaceMCPTrustRow(_ info: MCPClientManager.WorkspaceMCPInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.vertical, 2)
            HStack(spacing: 6) {
                Image(systemName: info.trusted ? "checkmark.shield" : "exclamationmark.shield")
                    .foregroundStyle(info.trusted ? Color.green : Color.orange)
                Text(L("settings.ai.mcpWorkspaceConfig"))
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 8)
                if info.trusted {
                    Button(L("settings.ai.mcpWorkspaceRevoke")) {
                        Task { await state.mcpClientManager.revokeCurrentWorkspaceMCP() }
                    }
                    .controlSize(.small)
                } else {
                    Button(L("settings.ai.mcpWorkspaceTrust")) {
                        Task { await state.mcpClientManager.trustCurrentWorkspaceMCP() }
                    }
                    .controlSize(.small)
                }
            }
            if !info.serverNames.isEmpty {
                Text(info.serverNames.joined(separator: ", "))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.middle)
            }
            if !info.trusted {
                Text(L("settings.ai.mcpWorkspaceHint"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 单个 server 的状态行：名称 + 类型徽标 + 连接状态（工具数/错误摘要）
    private func mcpServerRow(_ status: MCPClientManager.ServerStatus) -> some View {        HStack(spacing: 8) {
            Circle()
                .fill(mcpStatusColor(status.state))
                .frame(width: 7, height: 7)
            Text(status.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Text(status.kindLabel)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Spacer(minLength: 8)
            Text(mcpStatusText(status.state))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }

    private func mcpStatusColor(_ state: MCPClientManager.ConnectionState) -> Color {
        switch state {
        case .connected:               return .green
        case .connecting:              return .orange
        case .failed:                  return .red
        case .disconnected:            return .secondary.opacity(0.4)
        }
    }

    private func mcpStatusText(_ state: MCPClientManager.ConnectionState) -> String {
        switch state {
        case .connected(let count):
            return "\(L("settings.ai.mcpClientConnected")) · \(L("settings.ai.mcpClientToolsCount", count))"
        case .connecting:              return L("settings.ai.mcpClientConnecting")
        case .failed(let message):     return "\(L("settings.ai.mcpClientFailed")): \(message)"
        case .disconnected:            return L("settings.ai.mcpClientDisconnected")
        }
    }

    /// 打开全局配置文件（~/.meditor/mcp.json）；不存在时先写入模板再打开。
    func openMCPClientConfig() {
        let url = MCPClientConfigLoader.defaultGlobalConfigURL
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let template = """
            {
              "mcpServers": {
                "example-stdio": {
                  "command": "npx",
                  "args": ["-y", "@modelcontextprotocol/server-everything"],
                  "env": {}
                },
                "example-http": {
                  "url": "https://example.com/mcp"
                }
              }
            }
            """
            try? template.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 定时任务（cron → 后台 Agent 任务）

    var scheduledTasksSection: some View {
        settingsGroup(title: L("settings.ai.scheduledTasks")) {
            // Pro key（定价线 §6：定时自动化是 Pro 功能）——key 输入与验证状态收在定时任务区；
            // 托管侧（无限发布）的 Pro 用的是同一把 key（worker PRO_TOKENS）
            settingsStackedRow(label: L("settings.pro.keyLabel"),
                               subtitle: L("settings.pro.keyHint")) {
                proKeyControls
            }

            rowDivider

            settingsStackedRow(label: L("settings.ai.scheduledTasksLabel"),
                               subtitle: L("settings.ai.scheduledTasksHint")) {
                VStack(alignment: .leading, spacing: 8) {
                    let scheduler = state.agentScheduler
                    if scheduler.entries.isEmpty {
                        Text(L("settings.ai.scheduledTasksEmpty"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(scheduler.entries) { entry in
                            scheduledTaskRow(entry)
                        }
                    }
                    // 非 Pro 时标注：配置无罪（可见可编辑），但触发会被门控拦下
                    if !state.proEntitlement.isProActive {
                        HStack(spacing: 6) {
                            proBadge
                            Text(L("settings.pro.scheduledHint"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    // 配置解析容错记录（坏条目说明），有则展示
                    ForEach(scheduler.configIssues, id: \.self) { issue in
                        Text(L("settings.ai.scheduledTasksConfigIssue", issue))
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    HStack(spacing: 8) {
                        Button(L("settings.ai.scheduledTasksOpenConfig")) { openScheduledTasksConfig() }
                    }
                }
            }
        }
        // 打开设置页时重载配置摘要（用户可能在外部编辑过 schedules.json）
        .onAppear { state.agentScheduler.reload(workspaceURL: state.rootURL) }
    }

    // MARK: - Pro key

    /// Pro 购买入口（官网同款 GitHub Sponsors 链接；key 线下发放）
    private static let proPurchaseURL = URL(string: "https://github.com/sponsors/retrychx")

    /// Pro 徽标（橙底小字，与 autoApprove 徽标同族；非 Pro 状态下标注付费边界）
    private var proBadge: some View {
        Text(L("settings.pro.badge"))
            .font(DS.Font.mono(10))
            .foregroundStyle(.orange)
            .padding(.horizontal, DS.Space.xs)
            .padding(.vertical, DS.Space.xxs)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous))
    }

    /// Pro key 输入行：SecureField + 验证按钮 + 获取入口 + 状态行
    private var proKeyControls: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                SecureField(L("settings.pro.keyPlaceholder"), text: bindableSettings.proLicenseKey)
                    .textFieldStyle(.plain)
                    .settingsField()
                Button(state.proEntitlement.status == .verifying
                       ? L("settings.pro.verifying") : L("settings.pro.verify")) {
                    Task { await state.proEntitlement.verifyNow() }
                }
                .controlSize(.small)
                .disabled(state.proEntitlement.key.isEmpty
                          || state.proEntitlement.status == .verifying)
                if let url = Self.proPurchaseURL {
                    Link(L("settings.pro.getKey"), destination: url)
                        .font(.system(size: 11))
                }
            }
            proStatusLine
        }
    }

    /// Pro 验证状态行：未验证 / 有效（含离线缓存标注）/ 无效 + 上次验证时间
    @ViewBuilder
    private var proStatusLine: some View {
        let pro = state.proEntitlement
        switch pro.status {
        case .noKey:
            EmptyView()
        case .unverified:
            proStatusLabel(icon: "exclamationmark.circle", color: .orange,
                           text: L("settings.pro.status.unverified"))
        case .verifying:
            proStatusLabel(icon: "arrow.triangle.2.circlepath", color: .secondary,
                           text: L("settings.pro.verifying"))
        case .active(let offlineCache):
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                proStatusLabel(icon: "checkmark.seal.fill", color: .green,
                               text: offlineCache ? L("settings.pro.status.activeOffline")
                                                  : L("settings.pro.status.active"))
                if let verifiedAt = pro.lastVerifiedAt {
                    Text(L("settings.pro.status.lastVerified",
                           verifiedAt.formatted(date: .abbreviated, time: .shortened)))
                        .font(DS.Font.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        case .invalid:
            proStatusLabel(icon: "xmark.circle", color: .red,
                           text: L("settings.pro.status.invalid"))
        }
    }

    private func proStatusLabel(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: icon)
                .font(DS.Font.caption)
                .foregroundStyle(color)
            Text(text)
                .font(DS.Font.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 单个定时任务行：启用开关 + 名称 + 来源徽标 + cron 与下次触发时间
    private func scheduledTaskRow(_ entry: ScheduledTaskConfig) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { entry.enabled },
                set: { state.agentScheduler.setEnabled($0, entry: entry) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(entry.source == .global
                         ? L("settings.ai.scheduledTasksGlobal")
                         : L("settings.ai.scheduledTasksWorkspace"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    // autoApprove 徽标：写入免确认必须一眼可见（无人值守写入是信任敏感能力）
                    if entry.autoApprove {
                        Text(L("settings.ai.scheduledTasksAutoApprove"))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    // 非 Pro 状态下条目标注 Pro 徽标：配置仍可见可改，触发时才会被门控拦下
                    if !state.proEntitlement.isProActive {
                        proBadge
                    }
                }
                HStack(spacing: 6) {
                    Text(entry.cron)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if entry.enabled, let next = state.agentScheduler.nextFireDate(for: entry) {
                        Text(L("settings.ai.scheduledTasksNext",
                               next.formatted(date: .abbreviated, time: .shortened)))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 2)
    }

    /// 打开全局配置文件（~/.meditor/schedules.json）；不存在时先写入示例模板再打开。
    func openScheduledTasksConfig() {
        let url = ScheduledTaskConfigLoader.defaultGlobalConfigURL
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? ScheduledTaskConfigWriter.template.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
        state.agentScheduler.reload(workspaceURL: state.rootURL)
    }
}
