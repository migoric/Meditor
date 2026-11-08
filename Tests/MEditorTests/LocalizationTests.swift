import XCTest
@testable import MEditor

/// Localization 健全性测试：翻译表结构（双语非空、占位符对齐、key 规范）、
/// L() 缺失 key 行为、语言切换与插值。CI 是英文 locale，所有断言都不写死某一语言的文案。
final class LocalizationTests: XCTestCase {

    private var savedLanguage: AppLanguage!

    override func setUp() {
        super.setUp()
        savedLanguage = LocalizationManager.shared.language
    }

    override func tearDown() {
        LocalizationManager.shared.language = savedLanguage
        super.tearDown()
    }

    // MARK: - 表结构

    func testTable_hasSubstantialCoverage() {
        // 防「某个 tableN 从 merge 里漏掉」的回归：当前 7 张分表合计 800+ key，
        // 阈值取保守下限，新增 key 不需要改这里。
        XCTAssertGreaterThanOrEqual(LocalizationManager.table.count, 600,
                                    "翻译表 key 数量异常收缩，检查 table0...table6 是否都在 merge 链上")
    }

    func testAllEntries_bothLanguagesNonEmpty() {
        for (key, pair) in LocalizationManager.table {
            XCTAssertFalse(pair.en.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(key) 英文文案为空")
            XCTAssertFalse(pair.zh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(key) 中文文案为空")
        }
    }

    func testAllKeys_wellFormed() {
        for key in LocalizationManager.table.keys {
            XCTAssertFalse(key.isEmpty, "存在空 key")
            XCTAssertEqual(key, key.trimmingCharacters(in: .whitespaces),
                           "key 含首尾空白：\"\(key)\"")
            XCTAssertFalse(key.contains(" "), "key 含空格：\"\(key)\"")
        }
    }

    /// 提取 printf 风格占位符（%@ / %d / %1$d 等），忽略 %% 转义。
    private func placeholders(in string: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"%(\d+\$)?[@df]"#) else { return [] }
        let nsRange = NSRange(string.startIndex..., in: string)
        return regex.matches(in: string, range: nsRange).compactMap {
            Range($0.range, in: string).map { String(string[$0]) }
        }
    }

    func testAllEntries_placeholderSetsMatchAcrossLanguages() {
        // 占位符数量/类型不一致会在 String(format:) 时崩溃或产出乱码，
        // 这个测试抓住「只改了一种语言」的回归。
        for (key, pair) in LocalizationManager.table {
            let en = placeholders(in: pair.en).sorted()
            let zh = placeholders(in: pair.zh).sorted()
            XCTAssertEqual(en, zh, "\(key) 中英占位符不一致：en=\(en) zh=\(zh)")
        }
    }

    // MARK: - L() 行为

    func testMissingKey_returnsKeyItself() {
        let key = "test.missing.\(UUID().uuidString)"
        XCTAssertEqual(L(key), key, "缺失 key 应原样返回，避免空白 UI")
    }

    func testLookup_english_returnsEnValue() {
        LocalizationManager.shared.language = .english
        for (key, pair) in LocalizationManager.table {
            XCTAssertEqual(L(key), pair.en, "\(key) 英文查找错误")
        }
    }

    func testLookup_chinese_returnsZhValue() {
        LocalizationManager.shared.language = .chinese
        for (key, pair) in LocalizationManager.table {
            XCTAssertEqual(L(key), pair.zh, "\(key) 中文查找错误")
        }
    }

    func testFormat_interpolatesArgumentsInBothLanguages() {
        // ai.error.server 同时含 %d 与 %@，两种语言各验一次
        let key = "ai.error.server"
        guard LocalizationManager.table[key] != nil else {
            return XCTFail("\(key) 应存在于翻译表")
        }
        for language in [AppLanguage.english, .chinese] {
            LocalizationManager.shared.language = language
            let rendered = L(key, 503, "overloaded")
            XCTAssertTrue(rendered.contains("503"), "\(language)：应插值数字，实际 \(rendered)")
            XCTAssertTrue(rendered.contains("overloaded"), "\(language)：应插值字符串，实际 \(rendered)")
            XCTAssertFalse(rendered.contains("%"), "\(language)：占位符应被完全替换，实际 \(rendered)")
        }
    }

    // MARK: - resolved

    func testResolved_explicitLanguages_passThrough() {
        LocalizationManager.shared.language = .english
        XCTAssertEqual(LocalizationManager.shared.resolved, .english)
        LocalizationManager.shared.language = .chinese
        XCTAssertEqual(LocalizationManager.shared.resolved, .chinese)
    }

    func testResolved_system_resolvesToConcreteLanguage() {
        // 不断言具体结果（取决于运行环境 locale），只保证 .system 不会泄漏到 resolved
        LocalizationManager.shared.language = .system
        let resolved = LocalizationManager.shared.resolved
        XCTAssertTrue(resolved == .english || resolved == .chinese,
                      ".system 必须解析为具体语言，实际：\(resolved)")
    }

    func testLanguageSwitch_changesLookupResult() {
        // 找一个中英文案不同的 key，验证切换语言后 L() 结果跟着变
        guard let (key, pair) = LocalizationManager.table.first(where: { $0.value.en != $0.value.zh }) else {
            return XCTFail("翻译表应至少有一条中英不同的文案")
        }
        LocalizationManager.shared.language = .english
        let enResult = L(key)
        LocalizationManager.shared.language = .chinese
        let zhResult = L(key)
        XCTAssertEqual(enResult, pair.en)
        XCTAssertEqual(zhResult, pair.zh)
        XCTAssertNotEqual(enResult, zhResult)
    }
}
