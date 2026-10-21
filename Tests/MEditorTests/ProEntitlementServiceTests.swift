import XCTest
@testable import MEditor

// MARK: - ProEntitlementServiceTests
//
// Pro 资格（ProEntitlementService）：
//   门控判定 isProActive（同步读缓存 verdict）/ 在线验证写回 / 离线宽限的不对称
//   （曾验证通过 → fail-open 维持有效；从未验证 → fail-closed 不放行）/ 换 key 作废旧判定 /
//   refreshIfNeeded 的 24h 节流
//
// 存储是 AppSettings.shared（UserDefaults）——setUp/tearDown 保存并恢复四个 Pro 键，
// 不污染其他测试。在线验证器注入闭包，不打真实网络。
//
// 反向验证（AGENTS.md §6）：把 isProActive 改成恒 true，「无 key / 无效判定 / 换 key」
// 三条用例立即变红；把 verifyNow 的 catch 分支改成清空缓存，离线宽限两条变红。

@MainActor
final class ProEntitlementServiceTests: XCTestCase {

    private var settings: AppSettings!
    private var savedKey: String!
    private var savedVerdict: String!
    private var savedVerdictKey: String!
    private var savedVerifiedAt: Date?

    override func setUp() async throws {
        try await super.setUp()
        settings = AppSettings.shared
        savedKey = settings.proLicenseKey
        savedVerdict = settings.proKeyVerdict
        savedVerdictKey = settings.proKeyVerdictKeyHash
        savedVerifiedAt = settings.proKeyVerifiedAt
        // 干净起点
        settings.proLicenseKey = ""
        settings.proKeyVerdict = ""
        settings.proKeyVerdictKeyHash = ""
        settings.proKeyVerifiedAt = nil
    }

    override func tearDown() async throws {
        settings.proLicenseKey = savedKey
        settings.proKeyVerdict = savedVerdict
        settings.proKeyVerdictKeyHash = savedVerdictKey
        settings.proKeyVerifiedAt = savedVerifiedAt
        settings = nil
        try await super.tearDown()
    }

    private func makeService(verify: @escaping (String) async throws -> Bool = { _ in
        throw URLError(.notConnectedToInternet)
    }) -> ProEntitlementService {
        let service = ProEntitlementService(settings: settings)
        service.verify = verify
        return service
    }

    // MARK: - 门控判定（同步、不联网）

    func test_isProActive_noKey_false() {
        let service = makeService()
        XCTAssertFalse(service.isProActive)
        XCTAssertEqual(service.status, .noKey)
    }

    func test_isProActive_cachedValidForCurrentKey_true() {
        settings.proLicenseKey = "pro-key-1"
        settings.proKeyVerdict = "valid"
        settings.proKeyVerdictKeyHash = ProKeyCacheHash.hash("pro-key-1")
        let service = makeService()
        XCTAssertTrue(service.isProActive)
        XCTAssertEqual(service.status, .active(offlineCache: false))
    }

    func test_isProActive_cachedInvalid_false() {
        settings.proLicenseKey = "bad-key"
        settings.proKeyVerdict = "invalid"
        settings.proKeyVerdictKeyHash = ProKeyCacheHash.hash("bad-key")
        let service = makeService()
        XCTAssertFalse(service.isProActive)
        XCTAssertEqual(service.status, .invalid)
    }

    func test_isProActive_keyChangedSinceVerdict_false() {
        // verdict 属于旧 key：换 key 后不得继承 valid（防止改一个字符绕过门控）
        settings.proLicenseKey = "pro-key-2"
        settings.proKeyVerdict = "valid"
        settings.proKeyVerdictKeyHash = ProKeyCacheHash.hash("pro-key-1")
        let service = makeService()
        XCTAssertFalse(service.isProActive)
        XCTAssertEqual(service.status, .unverified)
    }

    // MARK: - 在线验证

    func test_verifyNow_serverValid_cachesAndActivates() async {
        settings.proLicenseKey = "pro-key-1"
        var seenKey: String?
        let service = makeService { key in
            seenKey = key
            return true
        }
        await service.verifyNow()
        XCTAssertEqual(seenKey, "pro-key-1")
        XCTAssertTrue(service.isProActive)
        XCTAssertEqual(service.status, .active(offlineCache: false))
        XCTAssertEqual(settings.proKeyVerdict, "valid")
        XCTAssertEqual(settings.proKeyVerdictKeyHash, ProKeyCacheHash.hash("pro-key-1"))
        XCTAssertNotNil(service.lastVerifiedAt)
    }

    func test_verifyNow_neverPersistsPlaintextKey() async {
        // 反向验证（AGENTS.md §6）：判定缓存若改回持久化 key 明文，本条立即变红——
        // 那等于把发布凭证在 Keychain 之外又存一份（proLicenseKey 迁移白做）。
        settings.proLicenseKey = "pro-key-1"
        let service = makeService { _ in true }
        await service.verifyNow()
        XCTAssertNil(
            UserDefaults.standard.string(forKey: "MEditor.proKeyVerdictKey"),
            "旧明文键必须随迁移删除，不得再写入"
        )
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: "MEditor.proKeyVerdictKeyHash"),
            ProKeyCacheHash.hash("pro-key-1"),
            "持久化的只能是哈希"
        )
        XCTAssertNotEqual(
            UserDefaults.standard.string(forKey: "MEditor.proKeyVerdictKeyHash"), "pro-key-1",
            "哈希键里不得是 key 原文"
        )
    }

    func test_verifyNow_serverInvalid_marksInvalid() async {
        settings.proLicenseKey = "bad-key"
        let service = makeService { _ in false }
        await service.verifyNow()
        XCTAssertFalse(service.isProActive)
        XCTAssertEqual(service.status, .invalid)
        XCTAssertEqual(settings.proKeyVerdict, "invalid")
    }

    func test_verifyNow_emptyKey_noKeyAndVerifierNotCalled() async {
        var calls = 0
        let service = makeService { _ in calls += 1; return true }
        await service.verifyNow()
        XCTAssertEqual(calls, 0, "空 key 不应发起网络验证")
        XCTAssertEqual(service.status, .noKey)
    }

    func test_verifyNow_keyChangedMidFlight_verdictBindsToVerifiedKey() async {
        settings.proLicenseKey = "key-a"
        let service = makeService { _ in
            // 验证在途时用户改成 key-b：判定只能写给被验证的 key-a
            self.settings.proLicenseKey = "key-b"
            return true
        }
        await service.verifyNow()
        XCTAssertEqual(settings.proKeyVerdictKeyHash, ProKeyCacheHash.hash("key-a"))
        XCTAssertFalse(service.isProActive, "当前 key-b 未验证，不得放行")
        XCTAssertEqual(service.status, .unverified)
    }

    // MARK: - 离线宽限（不对称：fail-open 已付费 / fail-closed 未验证）

    func test_verifyNow_offline_withCachedValid_staysActive() async {
        // 曾验证通过 → 网络失败维持有效（已付费用户离线可用）
        settings.proLicenseKey = "pro-key-1"
        settings.proKeyVerdict = "valid"
        settings.proKeyVerdictKeyHash = ProKeyCacheHash.hash("pro-key-1")
        let service = makeService()   // 默认 verify 抛 notConnectedToInternet
        await service.verifyNow()
        XCTAssertTrue(service.isProActive, "离线不得清掉已验证通过的缓存判定")
        XCTAssertEqual(service.status, .active(offlineCache: true))
        XCTAssertEqual(settings.proKeyVerdict, "valid", "离线失败不得改写缓存")
    }

    func test_verifyNow_offline_neverVerified_staysUnverified() async {
        // 从未验证通过 → 离线不放行（「声称付费」须先在线验证一次）
        settings.proLicenseKey = "unverified-key"
        let service = makeService()
        await service.verifyNow()
        XCTAssertFalse(service.isProActive)
        XCTAssertEqual(service.status, .unverified)
        XCTAssertEqual(settings.proKeyVerdict, "", "离线失败不得伪造判定")
    }

    // MARK: - 定期刷新节流

    func test_refreshIfNeeded_freshVerdict_skipsNetwork() {
        settings.proLicenseKey = "pro-key-1"
        settings.proKeyVerdict = "valid"
        settings.proKeyVerdictKeyHash = ProKeyCacheHash.hash("pro-key-1")
        settings.proKeyVerifiedAt = Date()
        var calls = 0
        let service = makeService { _ in calls += 1; return true }
        service.refreshIfNeeded(maxAge: 24 * 3600, now: Date())
        XCTAssertEqual(calls, 0, "24h 内已验证过不应重复打端点")
    }

    func test_refreshIfNeeded_staleOrNeverVerified_verifies() async {
        settings.proLicenseKey = "pro-key-1"
        // 从未验证 → stale
        var calls = 0
        let service = makeService { _ in calls += 1; return true }
        service.refreshIfNeeded(maxAge: 24 * 3600, now: Date())
        // refresh 内部是 Task——让出一个 runloop 等它跑完
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(service.isProActive)
    }
}
