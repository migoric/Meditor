import Foundation
import Observation

/// iOS 的 GitHub Gist 发布器：把当前文档**原文**发成一条 Gist，成功后把链接放上剪贴板。
///
/// 与「在线分享」（`ShareLinkPublisher`）是两条互不替代的通道：
/// - 在线分享走自建 Worker，上传的是渲染后的自包含 HTML —— 面向「给人看的成品页」；
/// - Gist 走 GitHub REST，上传的是 Markdown 原文 —— 面向「给开发者/存档的源文件」，
///   且不依赖自建服务是否在线。
///
/// 复用桌面端的 `GitHubGistService`（纯 Foundation + Security，无 AppKit 依赖）：
/// 它的 Keychain 条目（`com.meditor.github` / `gist-token`）两端同源，
/// 但 iOS 是独立沙盒，与桌面端的 token 互不可见 —— 需要各自配置一次。
@MainActor
@Observable
final class GistPublisher {

    static let shared = GistPublisher()

    private let service = GitHubGistService()

    // MARK: - 状态（UI 观察）

    var isPublishing = false
    var lastResultURL: String?
    var lastError: String?

    // MARK: - 配置

    private static let publicKey = "MEditor.gistIsPublic"

    /// 是否公开 Gist。默认私密：Gist 的 secret 只保证「不出现在列表与搜索里」，
    /// 拿到 URL 的人仍可访问 —— 所以默认值绝不该替用户选择公开。
    var isPublic: Bool {
        get { UserDefaults.standard.bool(forKey: Self.publicKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.publicKey) }
    }

    private(set) var hasToken: Bool = false
    var isConfigured: Bool { hasToken }

    /// 保存 Token。写入失败（钥匙串拒绝）必须让调用方知道：否则用户以为配好了，
    /// 直到点发布才看到「未配置」，且不知道是哪一步坏的。
    @discardableResult
    func saveToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            try GitHubGistService.saveToken(trimmed)
            hasToken = true
            return true
        } catch {
            lastError = error.localizedDescription
            hasToken = GitHubGistService.loadToken() != nil
            return false
        }
    }

    func clearToken() {
        GitHubGistService.deleteToken()
        hasToken = false
    }

    /// 设置页打开时调用一次（避免每次渲染都读 Keychain）。
    func refreshTokenStatus() {
        hasToken = GitHubGistService.loadToken() != nil
    }

    // MARK: - 发布

    /// 发布当前文档为一条 Gist；成功复制链接到剪贴板。
    /// 失败原因写进 `lastError`，由调用方弹窗展示。
    func publish(fileName: String, markdown: String) async {
        lastError = nil
        lastResultURL = nil
        guard let token = GitHubGistService.loadToken() else {
            lastError = GitHubGistError.notConfigured.errorDescription
            return
        }
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = "文档是空的，没有可发布的内容。"
            return
        }

        isPublishing = true
        defer { isPublishing = false }

        do {
            // Gist 的文件名决定语法高亮，没有扩展名就按 Markdown 处理。
            let name = fileName.isEmpty ? "untitled.md" : fileName
            let result = try await service.createGist(
                token: token,
                description: (name as NSString).deletingPathExtension,
                fileName: name,
                content: markdown,
                isPublic: isPublic
            )
            lastResultURL = result.url
            Pasteboard.copy(result.url)
        } catch let error as GitHubGistError {
            lastError = error.errorDescription
        } catch {
            lastError = error.localizedDescription
        }
    }
}
