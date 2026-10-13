import Foundation

// MARK: - AppSettings 替身（iOS）
//
// 共享代码 AIService.swift 的 `AIConfig.current(_:)` 与 AIModels.swift 的
// `AIAccentStyle.current(_:)` 以 AppSettings 为参数类型。macOS 端的
// Services/Core/AppSettings.swift 使用 macOS-only 的 security-scoped bookmark，
// 无法编进 iOS target；移动端设置直接走 MobileAISettings（UserDefaults），
// 这里只提供让共享代码通过类型检查的最小替身（运行时不使用）。
//
// ⚠️ 隐患（历史）：本替身原先所有属性都返回**假默认值**（provider=disabled、model=""）。
// 共享代码里任何新读 AppSettings 的路径，在 iOS 上会静默拿到这些假值，
// 不报错、不崩溃，只表现为"AI 功能莫名不工作"。
//
// 现在的三道防线：
//   1. 本文件的属性改为**读即不可用**（见 unavailable）：Debug 构建里一次读取
//      就 fatalError 在明确调用点，不再有静默降级。
//   2. 属性是可读不可写的计算属性 —— 「在 iOS 上写 AppSettings」直接编译不过。
//   3. scripts/check_ios_shared_sources.py 在 CI 上扫描共享文件，发现
//      `AppSettings.xxx` 这类读取即失败（合并前拦住，早于运行期）。
//
// 当前 iOS 编译路径上的命中点（由上面的脚本机械核对，不再靠人工维护清单）：
//   - Services/AI/AIService.swift   `AIConfig.current(_ s: AppSettings, ...)` —— 仅签名类型
//   - Models/AIModels.swift         `AIAccentStyle.current(_ settings: AppSettings)` —— 仅签名类型
//   两处函数体读的是**参数**，iOS 端没有调用方（iOS 走 MobileAISettings.makeConfig()）。
//
// 新增共享代码时：共享文件里不要直接读 AppSettings.shared；需要配置时把值作为
// 参数传进来，由两端各自的平台壳注入（macOS: AppSettings.shared，iOS: MobileAISettings）。

@MainActor
final class AppSettings {
    static let shared = AppSettings()

    /// iOS 上所有 AppSettings 属性读取的统一出口。
    ///
    /// - Debug：立刻 `fatalError`。开发期一次读取就能在明确调用点暴露问题——
    ///   这正是"新增了 AppSettings 读取"最该被发现的地方。
    /// - Release：**不崩**，打日志并返回中性默认值。取舍与 Debug 不同：Release 里
    ///   让用户 App 崩掉的代价高于"AI 不工作"，而合并前的 CI 检查已经拦住了这类读取；
    ///   运行期再崩一次只会把可诊断的问题变成崩溃。这里如实说明这个残留降级。
    private func unavailable<T>(_ name: String, default fallback: @autoclosure () -> T) -> T {
        #if DEBUG
        fatalError("""
        AppSettings.\(name) 在 iOS 上不可用。
        AppSettings 是 macOS-only 的配置源（依赖 security-scoped bookmark），
        iOS target 里的它只是让共享代码通过类型检查的替身。
        请改用 MobileAISettings，或把需要的值作为参数由平台壳注入；
        共享代码不应直接读 AppSettings.shared。
        """)
        #else
        print("[AppSettingsShim] iOS 读取了 AppSettings.\(name)：共享代码不应直接读 AppSettings.shared，"
              + "请改用 MobileAISettings 或参数注入。")
        return fallback()
        #endif
    }

    var aiProvider: String { unavailable("aiProvider", default: "disabled") }
    var aiBaseURL: String { unavailable("aiBaseURL", default: "") }
    var aiModel: String { unavailable("aiModel", default: "") }
    var aiCLIPath: String { unavailable("aiCLIPath", default: "") }
    var aiCLIModel: String { unavailable("aiCLIModel", default: "") }
    var aiAgentModel: String { unavailable("aiAgentModel", default: "") }
    var aiInlineModel: String { unavailable("aiInlineModel", default: "") }
    var aiRequestTimeout: TimeInterval { unavailable("aiRequestTimeout", default: 300) }
    var aiAccentStyle: String { unavailable("aiAccentStyle", default: "system") }

    private init() {}
}
