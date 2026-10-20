import Foundation
import Observation

// MARK: - ProEntitlementService（Pro 资格：key 验证 + 离线宽限 + 门控判定，macOS-only 特性）
//
// 定价线（战略复核 §6）：免费 = 编辑器 + 手动触发 agent + 单篇导出；
// Pro = 定时自动化（AgentSchedulerService）+ 无限托管（worker PRO_TOKENS 免限量）。
// 本服务管「定时自动化」这一半的客户端门控；托管侧门控在 worker（发布时按 token 分档）。
//
// 设计前提——本仓 MIT 开源，本地门控本质是「官方分发二进制的荣誉系统」：
// 自己编译的人拦不住，也不试图拦。因此门控只做体面的默认行为，不做反破解对抗
// （不做混淆、不做签名校验）。
//
// 验证链路：key 存 AppSettings.proLicenseKey；在线验证打 worker 的
// GET /api/pro/verify（Bearer key → {valid}，复用托管的 PRO_TOKENS，不需新 secret）。
// 服务端判定按 key 缓存（proKeyVerdict + proKeyVerdictKey + proKeyVerifiedAt）。
//
// 离线宽限的不对称（有意为之）：
//   - 曾验证通过的 key：离线时缓存判定维持有效（fail-open——已付费用户离线不应被锁出）
//   - 从未验证通过的 key：离线时不放行（fail-closed——「声称付费」必须至少在线验证一次）
// 门控判定（isProActive）本身同步、不联网：定时任务 tick 每分钟一次，不能挂网络。
@MainActor
@Observable
final class ProEntitlementService {

    /// 供设置页展示的状态。门控不走这里，走 `isProActive`（直接读缓存判定）。
    enum Status: Equatable {
        /// 未填写 key
        case noKey
        /// 有 key，但当前 key 从未验证通过（含换 key 后旧判定失效的情形）
        case unverified
        /// 正在联网验证
        case verifying
        /// 已验证通过（offlineCache = true 表示当前离线、用的是缓存判定）
        case active(offlineCache: Bool)
        /// 服务端明确判定无效
        case invalid
    }

    static let shared = ProEntitlementService()

    private let settings: AppSettings

    private(set) var status: Status = .noKey
    /// 最近一次成功到达服务端的验证时间（UI 展示用）
    private(set) var lastVerifiedAt: Date?

    /// 在线验证器（测试注入；默认实现打 worker /api/pro/verify）。
    /// 返回服务端判定；网络错误 / 非 200 / 解析失败一律抛错，
    /// 由 verifyNow 按离线宽限规则归并——验证器本身不决定宽限。
    var verify: (String) async throws -> Bool

    /// 当前 key（trim 后）。
    var key: String {
        settings.proLicenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 门控判定：同步、不联网，只读缓存 verdict。
    /// true 当且仅当：有 key，且**这个 key**最近一次的在线判定是 valid。
    /// 离线宽限体现在「判定按 key 缓存、离线不重新验证」——而非门控时额外放行。
    var isProActive: Bool {
        !key.isEmpty
            && settings.proKeyVerdict == "valid"
            && settings.proKeyVerdictKey == key
    }

    init(settings: AppSettings = .shared) {
        self.settings = settings
        lastVerifiedAt = settings.proKeyVerifiedAt
        verify = Self.makeVerifier(settings: settings)
        status = Self.deriveStatus(settings: settings)
    }

    /// 由持久化状态推导展示态（init / 离线失败兜底共用）。
    private static func deriveStatus(settings: AppSettings, offlineCache: Bool = false) -> Status {
        let key = settings.proLicenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .noKey }
        guard settings.proKeyVerdictKey == key else { return .unverified }
        switch settings.proKeyVerdict {
        case "valid": return .active(offlineCache: offlineCache)
        case "invalid": return .invalid
        default: return .unverified
        }
    }

    /// 立即在线验证当前 key（设置页「验证」按钮 / 换 key 后 / 定期刷新）。
    /// 结果写回 AppSettings 缓存；网络失败不清缓存——离线宽限见文件头注释。
    func verifyNow() async {
        let currentKey = key
        guard !currentKey.isEmpty else {
            status = .noKey
            return
        }
        status = .verifying
        do {
            let ok = try await verify(currentKey)
            // 验证期间用户可能又改了 key——只写回「被验证的那个 key」的判定
            settings.proKeyVerdict = ok ? "valid" : "invalid"
            settings.proKeyVerdictKey = currentKey
            settings.proKeyVerifiedAt = Date()
            lastVerifiedAt = settings.proKeyVerifiedAt
            status = Self.deriveStatus(settings: settings)
        } catch {
            // 离线/服务端不可达：不改缓存判定。
            // 曾验证通过 → 维持 active（标 offlineCache）；从未通过 → 回落 unverified。
            status = Self.deriveStatus(settings: settings, offlineCache: true)
        }
    }

    /// 启动 / 打开设置页时的保守刷新：有 key 且判定过期（或从未验证）才联网。
    /// 默认 24h 内不重复打端点——荣誉系统不需要实时 revocation，也避免每次启动刷 worker。
    func refreshIfNeeded(maxAge: TimeInterval = 24 * 3600, now: Date = Date()) {
        guard !key.isEmpty else {
            status = .noKey
            return
        }
        if status == .noKey { status = Self.deriveStatus(settings: settings) }
        let stale = settings.proKeyVerifiedAt.map { now.timeIntervalSince($0) > maxAge } ?? true
        if stale {
            Task { await verifyNow() }
        }
    }

    // MARK: - 默认在线验证器

    enum VerifyError: Error {
        case badBaseURL
        case badServerResponse
    }

    /// 默认验证器：GET {shareBaseURL}/api/pro/verify，Bearer key，解析 {valid: Bool}。
    /// 复用分享服务的 base URL 与 PRO_TOKENS——worker 侧无需新增配置。
    static func makeVerifier(settings: AppSettings,
                             session: URLSession = .shared) -> (String) async throws -> Bool {
        { key in
            let base = settings.shareBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let url = URL(string: base + "/api/pro/verify") else { throw VerifyError.badBaseURL }
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw VerifyError.badServerResponse
            }
            struct Payload: Decodable { let valid: Bool }
            return try JSONDecoder().decode(Payload.self, from: data).valid
        }
    }
}
