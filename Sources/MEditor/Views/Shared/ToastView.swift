import SwiftUI

/// 轻量 Toast — 底部居中弹出的半透明 pill，2.5s 后自动消失。
struct ToastView: View {
    let message: String
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 13, weight: .medium))
            }
            Text(message)
                .font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .dsElevation(.toast)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Toast 状态

struct ToastMessage: Equatable {
    let text: String
    let icon: String?

    init(_ text: String, icon: String? = nil) {
        self.text = text
        self.icon = icon
    }
}

// MARK: - ContentView Toast Overlay

extension View {
    /// 在视图底部渲染 toast，2.5s 后自动清除 binding。
    func toastOverlay(message: Binding<ToastMessage?>) -> some View {
        self.overlay(alignment: .bottom) {
            if let msg = message.wrappedValue {
                ToastView(message: msg.text, icon: msg.icon)
                    .padding(.bottom, 32)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity)
                            .animation(.spring(response: 0.35, dampingFraction: 0.72)),
                        removal: .opacity.animation(.easeOut(duration: 0.2))
                    ))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            withAnimation(DS.Motion.fast) {
                                message.wrappedValue = nil
                            }
                        }
                    }
            }
        }
        .animation(DS.Motion.springFast, value: message.wrappedValue)
    }
}

// MARK: - Claude 文件提示 Toast（带操作按钮）

struct ClaudeFilePromptToast: View {
    let prompt: ClaudeFilePrompt

    var body: some View {
        HStack(spacing: 12) {
            // 图标
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.appAccent)
                .accessibilityHidden(true)

            // 文字
            VStack(alignment: .leading, spacing: 2) {
                Text(L("toast.claudeFileCreated"))
                    .font(.system(size: 12, weight: .semibold))
                Text(prompt.fileName)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            // 按钮
            HStack(spacing: 6) {
                Button(L("toast.open")) {
                    withAnimation(DS.Motion.fast) { prompt.onAccept() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button(L("toast.ignore")) {
                    withAnimation(DS.Motion.fast) { prompt.onDismiss() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.appAccent.opacity(0.25), lineWidth: DS.Stroke.regular)
        )
        .dsElevation(.toast)
        .frame(maxWidth: 360)
    }
}

// MARK: - Claude 文件提示 Overlay

extension View {
    /// 在视图底部渲染 Claude 文件提示（带打开/忽略按钮，10s 超时自动消失）。
    func claudeFilePromptOverlay(prompt: Binding<ClaudeFilePrompt?>) -> some View {
        self.overlay(alignment: .bottom) {
            if let p = prompt.wrappedValue {
                ClaudeFilePromptToast(prompt: p)
                    .padding(.bottom, 40)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity)
                            .animation(.spring(response: 0.38, dampingFraction: 0.75)),
                        removal: .opacity.animation(.easeOut(duration: 0.2))
                    ))
                    .onAppear {
                        // 10 秒无操作自动消失
                        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                            if prompt.wrappedValue?.id == p.id {
                                withAnimation(DS.Motion.fast) {
                                    prompt.wrappedValue?.onDismiss()
                                }
                            }
                        }
                    }
            }
        }
        .animation(DS.Motion.springFast, value: prompt.wrappedValue)
    }
}
