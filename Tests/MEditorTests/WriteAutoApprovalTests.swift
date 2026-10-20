import XCTest
@testable import MEditor

// MARK: - WriteAutoApprovalTests
//
// 定时任务 autoApprove 的免确认匹配（WriteAutoApproval.allows）：
//   .none 一律不放行；.all 一律放行；
//   .dirs 只对白名单目录前缀内的路径放行（裸文件名 / 工作区相对 / 绝对路径三种形态），
//   前缀比较补尾斜杠（"weekly" 不得命中 "weekly-old"）；
//   无工作区根 / 空白名单时 .dirs 一律不放行——失败方向永远是回落确认条。
//
// 根路径用一个不存在且无 symlink 的固定路径（"/auto-approve-ws"）：匹配是纯字符串
// 归一化比较，不触碰文件系统；/tmp 这类路径在 macOS 上是 symlink，会引入无关变量。

final class WriteAutoApprovalTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/auto-approve-ws")

    func test_none_neverAllows() {
        XCTAssertFalse(WriteAutoApproval.none.allows(path: "weekly/a.md", workspaceRoot: root))
        XCTAssertFalse(WriteAutoApproval.none.allows(path: "/auto-approve-ws/weekly/a.md",
                                                     workspaceRoot: root))
    }

    func test_all_allowsEverything() {
        XCTAssertTrue(WriteAutoApproval.all.allows(path: "anything.md", workspaceRoot: root))
        XCTAssertTrue(WriteAutoApproval.all.allows(path: "/elsewhere/x.md", workspaceRoot: nil))
    }

    func test_dirs_matchesWhitelistPrefix() {
        let approval = WriteAutoApproval.dirs(["weekly/", "reports"])
        XCTAssertTrue(approval.allows(path: "weekly/2026-W42.md", workspaceRoot: root),
                      "工作区相对路径命中")
        XCTAssertTrue(approval.allows(path: "reports/q4.md", workspaceRoot: root),
                      "无尾斜杠的前缀同样按目录匹配")
        XCTAssertTrue(approval.allows(path: "/auto-approve-ws/weekly/a.md", workspaceRoot: root),
                      "绝对路径命中")
        XCTAssertTrue(approval.allows(path: "weekly", workspaceRoot: root),
                      "目标即白名单目录本身也算命中")
    }

    func test_dirs_rejectsOutsideWhitelist() {
        let approval = WriteAutoApproval.dirs(["weekly"])
        XCTAssertFalse(approval.allows(path: "weekly-old/a.md", workspaceRoot: root),
                       "前缀不得误命中同头目录")
        XCTAssertFalse(approval.allows(path: "docs/weekly/a.md", workspaceRoot: root),
                       "中间路径段不算命中")
        XCTAssertFalse(approval.allows(path: "/etc/passwd", workspaceRoot: root),
                       "工作区外绝对路径不命中")
        XCTAssertFalse(approval.allows(path: "a.md", workspaceRoot: root),
                       "根目录文件不在 weekly/ 内")
        XCTAssertFalse(approval.allows(path: "../weekly/a.md", workspaceRoot: root),
                       "跳出工作区的相对路径不命中")
    }

    func test_dirs_requiresRootAndNonEmptyPrefixes() {
        XCTAssertFalse(WriteAutoApproval.dirs(["weekly"]).allows(path: "weekly/a.md",
                                                                 workspaceRoot: nil))
        XCTAssertFalse(WriteAutoApproval.dirs([]).allows(path: "weekly/a.md",
                                                         workspaceRoot: root))
    }
}
