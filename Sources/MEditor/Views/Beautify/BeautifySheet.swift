import SwiftUI
import WebKit

// MARK: - BeautifySheet

@MainActor
struct BeautifySheet: View {
    @Environment(AppState.self) private var state
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var htmlTemplates: [DocumentTemplate] = []
    @State private var selectedTemplate: DocumentTemplate? = nil
    @State private var generatedHTML: String = ""
    @State private var isGenerating = false
    @State private var htmlRevision = 0
    @State private var errorMessage: String? = nil
    @State private var showDiffSheet = false
    @State private var savedToastVisible = false
    @State private var streamTask: Task<Void, Never>? = nil

    @State private var tokenOverrides: [String: String] = [:]
    @State private var showCustomize: Bool = false
    @State private var previewSelectedText: String = ""

    private let agent = BeautifyAgent()

    private var targetHTMLURL: URL? {
        guard let url = state.selectedTab?.url else { return nil }
        let stem = url.deletingPathExtension()
        return stem.appendingPathExtension("html")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            themeSelector
            customizeSection
            Divider()
            contentArea
            Divider()
            bottomBar
        }
        .frame(minWidth: 560, minHeight: 460)
        .sheet(isPresented: $showDiffSheet) {
            if let htmlURL = targetHTMLURL {
                BeautifyDiffSheet(
                    newHTML: generatedHTML,
                    existingURL: htmlURL,
                    onConfirm: {
                        // 用户确认覆盖 → 关 Sheet，走 DiffReview 对比后落盘
                        showDiffSheet = false
                        presentDiffReview(target: htmlURL)
                    },
                    onCancel: { showDiffSheet = false }
                )
                .presentationBackground(.regularMaterial)
            }
        }
        .overlay(alignment: .top) {
            if savedToastVisible {
                savedToast
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: savedToastVisible)
        .onAppear {
            let store = TemplateStore()
            htmlTemplates = store.htmlThemeTemplates()
            selectedTemplate = htmlTemplates.first(where: { $0.id == "html-craft" }) ?? htmlTemplates.first
            loadTokenOverrides()
        }
        .onChange(of: selectedTemplate?.id) { _, _ in
            loadTokenOverrides()
            // 已生成过或正在生成 → 切换模板后自动用新模板重新生成，让选择即时生效
            if !generatedHTML.isEmpty || isGenerating { startGeneration() }
        }
        .onDisappear { streamTask?.cancel() }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.appAccent)
            Text(L("beautify.title"))
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(Circle().fill(.quaternary))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Theme selector

    private var themeSelector: some View {
        HStack(spacing: 10) {
            ForEach(htmlTemplates) { template in
                ThemeCard(template: template, isSelected: selectedTemplate?.id == template.id) {
                    selectedTemplate = template
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Customize section

    private var customizeSection: some View {
        VStack(spacing: 0) {
            Divider()
            DisclosureGroup(isExpanded: $showCustomize) {
                VStack(spacing: 0) {
                    tokenColorRow(label: L("beautify.token.accent"), key: "accent")
                    Divider().padding(.leading, 16)
                    tokenColorRow(label: L("beautify.token.bg"), key: "bg")
                    Divider().padding(.leading, 16)
                    tokenColorRow(label: L("beautify.token.text"), key: "text")
                    Divider().padding(.leading, 16)
                    tokenTextRow(label: L("beautify.token.font"), key: "font")
                    Divider().padding(.leading, 16)
                    tokenTextRow(label: L("beautify.token.width"), key: "width")
                    Divider().padding(.leading, 16)
                    tokenTextRow(label: L("beautify.token.fontMono"), key: "font-mono")
                    Divider().padding(.leading, 16)

                    HStack {
                        Spacer()
                        Button(L("beautify.resetTokens")) { resetTokens() }
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            } label: {
                HStack {
                    Text(L("beautify.customize"))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    if !tokenOverrides.isEmpty {
                        Text(L("beautify.tokensModified", tokenOverrides.count))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func tokenColorRow(label: String, key: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .frame(width: 60, alignment: .leading)
            ColorPicker("", selection: colorBinding(key: key, defaultVal: defaultTokenValue(key)))
                .labelsHidden()
                .frame(width: 44)
            if let overrideVal = tokenOverrides[key] {
                Text(overrideVal)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                Text(defaultTokenValue(key))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func tokenTextRow(label: String, key: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .frame(width: 60, alignment: .leading)
            TextField(defaultTokenValue(key), text: textBinding(key: key, defaultVal: defaultTokenValue(key)))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: Content area

    @ViewBuilder
    private var contentArea: some View {
        if isGenerating && generatedHTML.isEmpty {
            VStack(spacing: 14) {
                ProgressView()
                    .scaleEffect(0.9)
                Text(L("beautify.generating"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if generatedHTML.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.appAccent.opacity(0.45))
                Text(L("beautify.emptyHint"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZStack(alignment: .topTrailing) {
                HTMLStringWebView(html: generatedHTML, revision: htmlRevision, onSelectionChange: { text in
                    withAnimation(.easeInOut(duration: 0.18)) {
                        previewSelectedText = text
                    }
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    if !previewSelectedText.isEmpty {
                        PreviewInlineEditBar(
                            selectedText: previewSelectedText,
                            onDismiss: {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    previewSelectedText = ""
                                }
                            }
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                if isGenerating {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7)
                        Text(L("beautify.streaming"))
                            .font(.system(size: 11))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .padding(10)
                }
            }
        }
    }

    private var generateButtonLabel: String {
        if isGenerating { return L("beautify.stop") }
        return generatedHTML.isEmpty ? L("beautify.generate") : L("beautify.regenerate")
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if let err = errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(err)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(L("common.cancel")) { dismiss() }
                .keyboardShortcut(.escape, modifiers: [])

            Button(generateButtonLabel) {
                if isGenerating { stopGeneration() } else { startGeneration() }
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .buttonStyle(.borderedProminent)

            if !generatedHTML.isEmpty && !isGenerating {
                Button(L("beautify.save")) { handleSave() }
                    .keyboardShortcut("s", modifiers: [.command])
            }
        }
        .tint(Color.appAccent)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Toast

    private var savedToast: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            if let url = targetHTMLURL {
                Text(L("beautify.saved", url.lastPathComponent))
            } else {
                Text(L("beautify.savedGeneric"))
            }
        }
        .font(.system(size: 12.5, weight: .medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .dsElevation(.floatingBar)
    }

    // MARK: Actions

    private func startGeneration() {
        guard let tab = state.selectedTab, !tab.content.isEmpty,
              let template = selectedTemplate else { return }
        streamTask?.cancel()   // 取消上一个生成任务，避免切换模板时多个流并发累加
        errorMessage = nil
        isGenerating = true
        generatedHTML = ""
        htmlRevision  = 0
        let markdown  = tab.content
        let overrides = tokenOverrides
        let s         = settings

        streamTask = agent.generate(
            markdown: markdown,
            template: template,
            tokenOverrides: overrides,
            settings: s,
            pluginManager: state.pluginManager,
            onChunk: { [self] chunk in
                generatedHTML += chunk
                htmlRevision  += 1
            },
            onComplete: { [self] _, error in
                isGenerating = false
                if let error {
                    errorMessage = (error as? AIError)?.errorDescription ?? error.localizedDescription
                } else {
                    // 部分模型会把 HTML 包进 ```html … ``` 围栏，剥掉避免污染文档/预览
                    let stripped = Self.stripCodeFence(generatedHTML)
                    if stripped != generatedHTML { generatedHTML = stripped; htmlRevision += 1 }
                }
            }
        )
    }

    /// 去掉 AI 输出可能包裹的 markdown 代码围栏（```html … ```），返回纯 HTML。
    /// 仅在确实存在围栏时改动；HTML 正文以 <!DOCTYPE/< 开头，不会误删。
    static func stripCodeFence(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            if let nl = t.firstIndex(of: "\n") { t = String(t[t.index(after: nl)...]) } else { t = "" }
        }
        if t.hasSuffix("```") { t = String(t.dropLast(3)) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stopGeneration() {
        streamTask?.cancel()
        streamTask  = nil
        isGenerating = false
    }

    private func handleSave() {
        guard let url = targetHTMLURL else { return }

        // 文件已存在 → 弹覆盖确认 Sheet
        if FileManager.default.fileExists(atPath: url.path) {
            showDiffSheet = true
            return
        }

        // 文件不存在 → 走 DiffReviewOverlay 对比后保存
        presentDiffReview(target: url)
    }

    private func presentDiffReview(target: URL) {
        let markdown = state.selectedTab?.content ?? ""
        let html     = generatedHTML
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            state.diffReview.present(
                original: markdown,
                modified: html,
                mode: .markdownVsHTML,
                onFinalize: { finalHTML in
                    do {
                        try finalHTML.write(to: target, atomically: true, encoding: .utf8)
                    } catch {
                        state.errorMessage = error.localizedDescription
                    }
                }
            )
        }
    }

    private func saveHTML(to url: URL, overwrite: Bool) {
        do {
            try generatedHTML.write(to: url, atomically: true, encoding: .utf8)
            withAnimation { savedToastVisible = true }
            Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                withAnimation { savedToastVisible = false }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Token helpers

    private func loadTokenOverrides() {
        guard let template = selectedTemplate else { return }
        var overrides: [String: String] = [:]
        for key in ["accent", "bg", "text", "font", "width", "font-mono"] {
            if let val = settings.themeToken(key, forTheme: template.id) {
                overrides[key] = val
            }
        }
        tokenOverrides = overrides
    }

    private func resetTokens() {
        guard let template = selectedTemplate else { return }
        for key in ["accent", "bg", "text", "font", "width", "font-mono"] {
            settings.setThemeToken(nil, token: key, forTheme: template.id)
        }
        tokenOverrides = [:]
    }

    private func defaultTokenValue(_ key: String) -> String {
        let d = BuiltinTemplates.tokenDefaults(for: selectedTemplate?.id ?? "")
        switch key {
        case "accent":    return d.accent
        case "bg":        return d.bg
        case "text":      return d.text
        case "font":      return d.font
        case "width":     return d.width
        case "font-mono": return d.fontMono
        default:          return ""
        }
    }

    private func colorBinding(key: String, defaultVal: String) -> Binding<Color> {
        Binding(
            get: { Color(hex: tokenOverrides[key] ?? defaultVal) },
            set: { color in
                let hex = color.hexString()
                tokenOverrides[key] = hex
                settings.setThemeToken(hex, token: key, forTheme: selectedTemplate?.id ?? "")
            }
        )
    }

    private func textBinding(key: String, defaultVal: String) -> Binding<String> {
        Binding(
            get: { tokenOverrides[key] ?? "" },
            set: { val in
                if val.isEmpty {
                    tokenOverrides.removeValue(forKey: key)
                    settings.setThemeToken(nil, token: key, forTheme: selectedTemplate?.id ?? "")
                } else {
                    tokenOverrides[key] = val
                    settings.setThemeToken(val, token: key, forTheme: selectedTemplate?.id ?? "")
                }
            }
        )
    }
}

// MARK: - Theme Card

private struct ThemeCard: View {
    let template: DocumentTemplate
    let isSelected: Bool
    let action: () -> Void

    private var icon: String {
        switch template.id {
        case "html-tufte": return "book.closed"
        case "html-craft": return "rectangle.stack"
        case "html-dark":  return "moon.stars"
        default:           return "doc.text"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? .white : .primary)
                Text(template.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : .primary)
                Text(template.description)
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.appAccent : Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.clear : Color.primary.opacity(0.12), lineWidth: DS.Stroke.regular)
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

// MARK: - HTMLStringWebView

/// Minimal WKWebView wrapper that loads HTML from a string.
struct HTMLStringWebView: NSViewRepresentable {
    let html: String
    let revision: Int
    var onSelectionChange: ((String) -> Void)? = nil

    private static let selectionHandlerName = "selectionHandler"

    private static let selectionJS = """
    (function() {
        var _lastSel = '';
        document.addEventListener('selectionchange', function() {
            var sel = window.getSelection();
            var text = sel ? sel.toString().trim() : '';
            if (text === _lastSel) return;
            _lastSel = text;
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.selectionHandler) {
                window.webkit.messageHandlers.selectionHandler.postMessage({ text: text });
            }
        });
    })();
    """

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        userContent.add(context.coordinator, name: Self.selectionHandlerName)
        userContent.addUserScript(WKUserScript(source: Self.selectionJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController = userContent
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onSelectionChange = onSelectionChange
        guard revision != context.coordinator.lastRevision else { return }
        context.coordinator.lastRevision = revision
        webView.loadHTMLString(html, baseURL: nil)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: HTMLStringWebView.selectionHandlerName)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSelectionChange: onSelectionChange) }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var lastRevision = -1
        var onSelectionChange: ((String) -> Void)?

        init(onSelectionChange: ((String) -> Void)? = nil) {
            self.onSelectionChange = onSelectionChange
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "selectionHandler" else { return }
            let text = ((message.body as? [String: Any])?["text"] as? String) ?? ""
            DispatchQueue.main.async {
                self.onSelectionChange?(text)
            }
        }
    }
}
