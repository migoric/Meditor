import SwiftUI

@MainActor
struct SettingsView: View {
    @Environment(AppSettings.self) var settings
    var bindableSettings: Bindable<AppSettings> { Bindable(settings) }
    @Environment(AppState.self) var state
    let loc = LocalizationManager.shared
    @State private var selectedTab: SettingsTab = .general
    @State var githubTokenInput = ""
    @State var shareLinkTokenInput = ""
    @State var aiKeyInput = ""
    @State var aiHasKey = AIAPIKeyStore.hasKey
    @State var aiModels: [String] = []
    @State var aiLoadingModels = false
    @State var aiDetecting = false
    @State var skillAddMessage: String? = nil
    @State var installingSkillID: String? = nil
    @State var installedSkillIDs: Set<String> = []
    // 技能 URL 导入
    @State var showingSkillURLImport = false
    @State var skillURLImportText = ""
    // AI 连通性测试
    @State var connectionTestResult: String? = nil
    @State var connectionTestOK: Bool = false
    @State var connectionTesting: Bool = false
    // AI 设置首屏：本机 Claude CLI 探测（驱动「快速开始」的推荐项）。
    // 初始 true：AI tab 的 .task 才开始探测，避免「未检测到」文案闪现。
    @State var aiCLIProbing = true
    @State var aiCLIDetectedPath: String? = nil

    // 记忆面板（MemorySettingsTab）：数据从 MemoryService 现取，不放 AppState ——
    // 记忆不是文档状态，塞进 AppState 会让「打开设置」变成全局刷新。
    @State var memoryAll: [MemoryRecord] = []
    @State var memoryArchived: [MemoryRecord] = []
    @State var memoryWarnings: [String] = []
    @State var memoryConvention: String = ""
    @State var memoryQuery: String = ""
    @State var memoryEditingID: String? = nil
    @State var memoryDraft: String = ""
    /// `nil` = 还没算过。必须走 `@State` 而不是现读 `MemoryService`：现读发生在 body
    /// 求值期，那时 `.onAppear` 还没跑，拿到的是激活前的空值——空态下又没有任何
    /// `@State` 变化触发重绘，横幅会一直错着挂在那里。
    @State var memoryWritable: Bool? = nil

        /// When true, the view is presented as an in-app hero overlay (not a window),
        /// so it must not mutate any NSWindow chrome.
        var embedded: Bool = false

    /// Dismiss handler for the embedded hero presentation (renders a close button).
    var onClose: (() -> Void)? = nil

    /// initialTab：外部深链指定首显 tab（如首启引导跳 AI tab），默认 general。
    init(initialTab: SettingsTab = .general, embedded: Bool = false, onClose: (() -> Void)? = nil) {
        self.embedded = embedded
        self.onClose = onClose
        _selectedTab = State(initialValue: initialTab)
    }

    // MARK: - Brand palette (shared with the welcome hero card)
    private static let tagline      = "Let the agent write. You review, then keep."

    enum SettingsTab: String, CaseIterable {
        case general, ai, integrations, sharing, plugins, memory, about

        var label: String {
            switch self {
            case .general:      return L("settings.tab.general")
            case .ai:           return L("settings.tab.ai")
            case .integrations: return L("settings.tab.integrations")
            case .sharing:      return L("settings.tab.sharing")
            case .plugins:      return L("settings.tab.plugins")
            case .memory:       return L("settings.tab.memory")
            case .about:        return L("settings.tab.about")
            }
        }

        var icon: String {
            switch self {
            case .general:      return "slider.horizontal.3"
            case .ai:           return "sparkles"
            case .integrations: return "puzzlepiece.extension"
            case .sharing:      return "square.and.arrow.up"
            case .plugins:      return "wand.and.stars"
            case .memory:       return "brain"
            case .about:        return "info.circle"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Branded hero banner ──
            hero

            // ── Sidebar + content ──
            HStack(spacing: 0) {
                // Left sidebar navigation
                VStack(spacing: DS.Space.xxs) {
                    ForEach(SettingsTab.allCases, id: \.self) { tab in
                        SettingsNavItem(
                            icon: tab.icon,
                            label: tab.label,
                            isSelected: selectedTab == tab
                        )
                        .onTapGesture { selectedTab = tab }
                    }
                    Spacer()
                }
                .padding(.top, DS.Space.md)
                .padding(.horizontal, DS.Space.sm)
                .frame(width: 148)
                .frame(maxHeight: .infinity)
                .background(DS.Color.sidebarBg)

                Rectangle()
                    .fill(DS.Color.divider)
                    .frame(width: 1)

                // Right content
                Group {
                    switch selectedTab {
                    case .general:      generalContent
                    case .ai:           aiContent
                    case .integrations: integrationsContent
                    case .sharing:      sharingContent
                    case .plugins:      pluginsContent
                    case .memory:       memoryContent
                    case .about:        aboutContent
                    }
                }
                .id(selectedTab)
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(DS.Color.sidebarBg)
                .animation(DS.Motion.fast, value: selectedTab)
            }
        }
        .frame(width: 680, height: 560)
        .onAppear { if !embedded { styleSettingsWindow() } }
    }

    // MARK: - Hero

    private var hero: some View {
        ZStack {
            // Static, expensive background (blurred aurora + dot-grid) is isolated
            // into its own rasterized view so it never re-renders on tab switches.
            SettingsHeroBackground()

            // Content
            HStack(spacing: DS.Space.md) {
                iconBadge

                VStack(alignment: .leading, spacing: 3) {
                    Text("MEditor")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(Self.tagline)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.62))
                }

                Spacer()

                HeroSectionPill(icon: selectedTab.icon, label: selectedTab.label)
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.top, 26)            // leave room for the traffic-light cluster
            .padding(.bottom, DS.Space.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(height: 108)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.black.opacity(0.18))
                .frame(height: 1)
        }
        .overlay(alignment: .topLeading) {
            if let onClose {
                HeroTrafficLights(onClose: onClose)
                    .padding(.leading, 13)
                    .padding(.top, 13)
            }
        }
    }

    private var iconBadge: some View {
        AppIconBadge(size: 48)
    }

    // MARK: - Window styling

    private func styleSettingsWindow() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let window = NSApp.windows.first(where: {
                $0.title.localizedCaseInsensitiveContains("setting") ||
                $0.title.localizedCaseInsensitiveContains("设置") ||
                ($0.isVisible && $0 !== NSApp.windows.first(where: { $0.title == "MEditor" }))
            }) else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
        }
    }
}

// MARK: - Hero Traffic Lights

/// Faux macOS window controls for the embedded hero panel. The red light
/// dismisses the panel; amber/green are decorative. Hovering the cluster
/// reveals the glyphs, mirroring native traffic-light behaviour.
private struct HeroTrafficLights: View {
    let onClose: () -> Void
    @State private var hovering = false

    private static let red    = Color(red: 1.00, green: 0.37, blue: 0.34)
    private static let amber  = Color(red: 1.00, green: 0.74, blue: 0.18)
    private static let green  = Color(red: 0.16, green: 0.79, blue: 0.25)

    var body: some View {
        HStack(spacing: 8) {
            light(color: Self.red,   glyph: "xmark",  action: onClose)
            light(color: Self.amber, glyph: "minus",  action: nil)
            light(color: Self.green, glyph: "arrow.up.left.and.arrow.down.right.circle", action: nil)
        }
        .onHover { hovering = $0 }
        .animation(DS.Motion.micro, value: hovering)
    }

    @ViewBuilder
    private func light(color: Color, glyph: String, action: (() -> Void)?) -> some View {
        let dot = Circle()
            .fill(color)
            .frame(width: 12, height: 12)
            .overlay(Circle().stroke(Color.black.opacity(0.12), lineWidth: DS.Stroke.hairline))
            .overlay(
                Image(systemName: glyph)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.55))
                    .opacity(hovering ? 1 : 0)
            )

        if let action {
            Button(action: action) { dot }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
        } else {
            dot
        }
    }
}


// MARK: - Hero Background (static, rasterized once)

/// Premium hero background: a deep matte base with a single soft brand-blue
/// glow anchored top-left and a fine film grain. Restraint over flashy
/// gradients. No inputs + `.drawingGroup()` keep it cached and cheap.
private struct SettingsHeroBackground: View {
    private static let base = Color(red: 0.075, green: 0.085, blue: 0.125)
    private static let glow = Color(red: 0.42,  green: 0.55,  blue: 1.00)   // icon accent

    var body: some View {
        ZStack {
            Self.base

            // Single soft corner glow (top-left), restrained.
            GeometryReader { geo in
                RadialGradient(
                    gradient: Gradient(colors: [Self.glow.opacity(0.30), Self.glow.opacity(0)]),
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: max(geo.size.width * 0.46, geo.size.height * 1.9)
                )
            }

            // Fine film grain for matte texture.
            Canvas { ctx, size in
                var rng = SystemRandomNumberGenerator()
                let n = Int(size.width * size.height / 90)
                for _ in 0..<max(0, n) {
                    let x = Double.random(in: 0..<max(size.width, 1), using: &rng)
                    let y = Double.random(in: 0..<max(size.height, 1), using: &rng)
                    let a = Double.random(in: 0...0.05, using: &rng)
                    let c: Color = Bool.random(using: &rng) ? .white : .black
                    ctx.fill(Path(CGRect(x: x, y: y, width: 1.2, height: 1.2)),
                             with: .color(c.opacity(a)))
                }
            }
            .allowsHitTesting(false)

            // Whisper-thin top highlight for crispness.
            LinearGradient(
                colors: [Color.white.opacity(0.05), Color.clear],
                startPoint: .top, endPoint: .center
            )
        }
        .drawingGroup()   // flatten to one cached layer
    }
}

// MARK: - Hero Section Pill


private struct HeroSectionPill: View {
    let icon: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(label)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.12))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: DS.Stroke.regular)
        )
    }
}
