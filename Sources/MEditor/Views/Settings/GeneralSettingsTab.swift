import SwiftUI

// MARK: - General tab

extension SettingsView {
    var generalContent: some View {
        ScrollView {
            VStack(spacing: 0) {
                // 外观
                settingsGroup(title: L("settings.section.appearance")) {
                    settingsRow(label: L("theme.title"), subtitle: L("settings.desc.theme")) {
                        SettingsMenu(
                            selection: Binding(
                                get: { state.themeStore.current },
                                set: { state.themeStore.current = $0 }
                            ),
                            options: PreviewTheme.allCases.map { ($0, $0.displayName) }
                        )
                        .frame(width: 170)
                    }
                    rowDivider
                    settingsRow(label: L("settings.language"), subtitle: L("settings.desc.language")) {
                        SettingsMenu(
                            selection: languageBinding,
                            options: [
                                (.system, L("lang.system")),
                                (.english, "English"),
                                (.chinese, "中文")
                            ]
                        )
                        .frame(width: 170)
                    }
                }

                // 编辑器
                settingsGroup(title: L("settings.section.editor")) {
                    settingsRow(label: L("settings.editorFont"), subtitle: L("settings.desc.editorFont")) {
                        SettingsMenu(
                            selection: bindableSettings.editorFontName,
                            options: EditorFont.allCases.map {
                                ($0.rawValue, $0 == .system ? L("settings.editorFont.system") : $0.displayName)
                            }
                        )
                        .frame(width: 170)
                    }
                    rowDivider
                    settingsStackedRow(label: L("settings.editorFontSize"), subtitle: L("settings.desc.editorFontSize")) {
                        HStack(spacing: DS.Space.md) {
                            Slider(value: editorFontSizeBinding, in: 11...24, step: 1)
                                .frame(maxWidth: .infinity)
                            Text("\(settings.editorFontSize) pt")
                                .font(DS.Font.mono(12))
                                .foregroundStyle(.secondary)
                                .frame(width: 42, alignment: .trailing)
                        }
                    }
                    rowDivider
                    settingsStackedRow(label: L("settings.fontSize"), subtitle: L("settings.desc.fontSize")) {
                        HStack(spacing: DS.Space.md) {
                            Slider(value: fontSizeBinding, in: 10...28, step: 1)
                                .frame(maxWidth: .infinity)
                            Text("\(settings.previewFontSize) px")
                                .font(DS.Font.mono(12))
                                .foregroundStyle(.secondary)
                                .frame(width: 42, alignment: .trailing)
                        }
                    }
                }

                // 保存与导出
                settingsGroup(title: L("settings.section.save")) {
                    settingsRow(label: L("settings.autoSave"), subtitle: L("settings.desc.autoSave")) {
                        Toggle("", isOn: bindableSettings.autoSave).labelsHidden()
                    }
                    if settings.autoSave {
                        rowDivider
                        settingsRow(label: L("settings.interval")) {
                            SettingsMenu(
                                selection: bindableSettings.autoSaveInterval,
                                options: [
                                    (10, L("settings.secondsFormat", 10)),
                                    (30, L("settings.secondsFormat", 30)),
                                    (60, L("settings.secondsFormat", 60)),
                                    (120, L("settings.secondsFormat", 120))
                                ]
                            )
                            .frame(width: 130)
                        }
                    }
                    rowDivider
                    settingsRow(label: L("settings.exportPreflight"), subtitle: L("settings.desc.exportPreflight")) {
                        Toggle("", isOn: bindableSettings.exportPreflightEnabled).labelsHidden()
                    }
                }

                // 系统搜索（Spotlight）：正文索引默认关，隐私优先
                settingsGroup(title: L("settings.section.spotlight")) {
                    settingsRow(label: L("settings.spotlightContent"), subtitle: L("settings.desc.spotlightContent")) {
                        Toggle("", isOn: bindableSettings.spotlightIndexContent).labelsHidden()
                    }
                }

                // 存储位置（原「路径」tab，两行配置并入通用）
                settingsGroup(title: L("paths.group")) {
                    PathRow(
                        icon: "folder.fill",
                        title: L("paths.userDocs"),
                        subtitle: L("paths.userDocsHint"),
                        iconColor: .blue,
                        currentPath: AppSettings.shared.userDocPath,
                        onChoose: { chooseUserDocPath() },
                        onClear:  { try? AppSettings.shared.setUserDocPath(nil) }
                    )

                    rowDivider

                    PathRow(
                        icon: "shippingbox.fill",
                        title: L("paths.appDocs"),
                        subtitle: L("paths.appDocsHint"),
                        iconColor: .orange,
                        currentPath: AppSettings.shared.appDocPath,
                        onChoose: { chooseAppDocPath() },
                        onClear:  { try? AppSettings.shared.setAppDocPath(nil) }
                    )
                }
            }
            .padding(DS.Space.lg)
        }
    }

    // MARK: - Bindings

    var fontSizeBinding: Binding<Double> {
        Binding(
            get: { Double(settings.previewFontSize) },
            set: { settings.previewFontSize = Int($0) }
        )
    }

    var editorFontSizeBinding: Binding<Double> {
        Binding(
            get: { Double(settings.editorFontSize) },
            set: { settings.editorFontSize = Int($0) }
        )
    }

    var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { loc.language },
            set: { loc.language = $0 }
        )
    }

    // MARK: - 存储位置

    func chooseUserDocPath() {
        Task {
            if let url = await state.filePickerService.pickFolder(message: nil) {
                try? AppSettings.shared.setUserDocPath(url)
            }
        }
    }

    func chooseAppDocPath() {
        Task {
            if let url = await state.filePickerService.pickFolder(message: nil) {
                try? AppSettings.shared.setAppDocPath(url)
            }
        }
    }
}

// MARK: - Path Row

struct PathRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let iconColor: Color
    let currentPath: URL?
    let onChoose: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(iconColor)
                .frame(width: 24, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                if let url = currentPath {
                    Text(url.path.replacingOccurrences(of:
                        FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Button(L("paths.choose"), action: onChoose)
                    .controlSize(.small)
                if currentPath != nil {
                    Button(L("paths.clear"), action: onClear)
                        .controlSize(.small)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
