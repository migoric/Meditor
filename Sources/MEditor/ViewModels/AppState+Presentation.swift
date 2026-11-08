import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

extension AppState {

    /// 是否正在演讲模式放映中。
    var isPresenting: Bool { presentationManager.isPresenting }

    /// 以当前选中的 Markdown 文档进入演讲模式（无选中或非 Markdown 时无操作）。
    func startPresentation() {
        guard let tab = selectedTab, tab.language == .markdown else { return }
        presentationManager.start(markdown: tab.content, sourceURL: tab.url, theme: themeStore.current)
        if presentationManager.isPresenting {
            observePresentationThemeChanges()
        }
    }

    /// 把当前 Markdown 文档导出为演讲稿。
    /// 两种格式共用 SlideSplitter 的同一份分页结果。
    func exportPresentation() {
        guard let tab = selectedTab, tab.language == .markdown else { return }
        let slides = SlideSplitter.split(tab.content)
        let baseName = tab.url.deletingPathExtension().lastPathComponent + "-slides"
        let pptxType = UTType(filenameExtension: "pptx", conformingTo: .compositeContent) ?? .data

        let savePanel = NSSavePanel()
        savePanel.canCreateDirectories = true
        savePanel.title = L("export.presentation.title")
        savePanel.nameFieldStringValue = baseName + ".html"
        savePanel.allowedContentTypes = [.html]

        let popup = FormatPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 24), pullsDown: false)
        popup.addItems(withTitles: [L("export.presentation.formatHTML"), L("export.presentation.formatPPTX")])
        popup.onChange = { [weak savePanel] index in
            guard let savePanel else { return }
            let isPPTX = index == 1
            savePanel.allowedContentTypes = isPPTX ? [pptxType] : [.html]
            let base = (savePanel.nameFieldStringValue as NSString).deletingPathExtension
            savePanel.nameFieldStringValue = base + (isPPTX ? ".pptx" : ".html")
        }

        let label = NSTextField(labelWithString: L("export.presentation.format"))
        let accessory = NSStackView(views: [label, popup])
        accessory.orientation = .horizontal
        accessory.spacing = 8
        accessory.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 12, right: 12)
        savePanel.accessoryView = accessory

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }
            do {
                if popup.indexOfSelectedItem == 1 {
                    let data = PPTXExporter.makePPTX(
                        slides: slides,
                        title: tab.url.deletingPathExtension().lastPathComponent
                    )
                    try data.write(to: url)
                } else {
                    let baseHref = tab.url.deletingLastPathComponent().absoluteString
                    guard let html = PresentationExporter.makeHTML(
                        slides: slides, theme: self.themeStore.current, baseHref: baseHref
                    ) else {
                        self.showToast(L("toast.presentationResourcesMissing"), icon: "exclamationmark.triangle")
                        return
                    }
                    try html.write(to: url, atomically: true, encoding: .utf8)
                }
            } catch {
                let format = popup.indexOfSelectedItem == 1 ? "PPTX" : "HTML"
                self.report(.exportFailed(format: format, underlying: error), logger: AppLog.exporter)
            }
        }
    }

    private func observePresentationThemeChanges() {
        guard !isObservingPresentationTheme else { return }
        isObservingPresentationTheme = true
        withObservationTracking {
            _ = themeStore.current
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isObservingPresentationTheme = false
                guard self.presentationManager.isPresenting else { return }
                self.presentationManager.applyTheme(self.themeStore.current)
                self.observePresentationThemeChanges()
            }
        }
    }
}

/// Save-panel format selector that owns its target/action callback.
private final class FormatPopUpButton: NSPopUpButton {
    var onChange: ((Int) -> Void)?

    override init(frame frameRect: NSRect, pullsDown flag: Bool) {
        super.init(frame: frameRect, pullsDown: flag)
        target = self
        action = #selector(selectionDidChange)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func selectionDidChange() {
        onChange?(indexOfSelectedItem)
    }
}
