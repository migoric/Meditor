import CryptoKit
import Foundation
import XCTest

/// `scripts/sign_update.swift` 的端到端测试。
///
/// 为什么值得测：`release.yml` 的发布链路依赖这个脚本产出正确的
/// `sparkle:edSignature`（签名错 ⇒ Sparkle 自动更新全挂），但它此前**零测试**
/// —— 是「打包/签名脚本无测试」这条存量债务里唯一可低成本覆盖的一块。
///
/// 测试方式：测试进程内用 CryptoKit 生成 Ed25519 密钥对 → 以子进程跑真的脚本
/// → 用公钥验证脚本产出的签名。**验证的是脚本本身**（含参数解析、base64 处理、
/// 输出格式），不是重实现一遍签名逻辑。
///
/// 覆盖：
///   - 正常签名：输出格式 `sparkle:edSignature="…" length="…"`，签名可被公钥验证，length 正确
///   - 64 字节 libsodium 格式私钥（seed||pub）同样可用
///   - `--expect-public-key` 匹配通过 / 不匹配 exit(1)
///   - 参数不足时打印 usage 并 exit(1)
final class SignUpdateScriptTests: XCTestCase {

    /// 仓根：本文件位于 `<root>/Tests/MEditorTests/SignUpdateScriptTests.swift`。
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)          // …/Tests/MEditorTests/SignUpdateScriptTests.swift
            .deletingLastPathComponent()          // …/Tests/MEditorTests
            .deletingLastPathComponent()          // …/Tests
            .deletingLastPathComponent()          // <root>
    }

    private static var scriptPath: String {
        repoRoot.appendingPathComponent("scripts/sign_update.swift").path
    }

    // MARK: - Helpers

    private struct RunResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    /// 跑 `swift scripts/sign_update.swift <args>`，返回输出与退出码。
    /// 用 `/usr/bin/env swift` 保证走当前 toolchain 的 swift（CI 已 xcode-select）。
    @discardableResult
    private func runScript(_ arguments: [String]) throws -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", Self.scriptPath] + arguments
        process.currentDirectoryURL = Self.repoRoot

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return RunResult(
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }

    private func makeTempFile(contents: Data, name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sign-update-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }

    /// 从脚本输出解析 `sparkle:edSignature="…" length="…"`。
    private func parseSignature(_ output: String) -> (signatureB64: String, length: Int)? {
        guard let sigRange = output.range(of: "sparkle:edSignature=\"") else { return nil }
        let rest = output[sigRange.upperBound...]
        guard let endQuote = rest.firstIndex(of: "\"") else { return nil }
        let sig = String(rest[..<endQuote])
        guard let lenRange = output.range(of: "length=\"") else { return nil }
        let lenRest = output[lenRange.upperBound...]
        guard let lenEnd = lenRest.firstIndex(of: "\"") else { return nil }
        guard let length = Int(lenRest[..<lenEnd]) else { return nil }
        return (sig, length)
    }

    // MARK: - 正常签名 + 验签往返

    func test_signsFile_outputFormatAndSignatureVerifies() throws {
        let key = Curve25519.Signing.PrivateKey()
        let privateB64 = key.rawRepresentation.base64EncodedString()

        let payload = Data("MEditor release payload — 带中文与 emoji 🚀 的内容".utf8)
        let file = try makeTempFile(contents: payload, name: "payload.zip")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let result = try runScript([privateB64, file.path])
        XCTAssertEqual(result.exitCode, 0, "脚本应成功退出，stderr=\(result.stderr)")

        let parsed = try XCTUnwrap(parseSignature(result.stdout), "输出应含 sparkle:edSignature 与 length，实际：\(result.stdout)")
        XCTAssertEqual(parsed.length, payload.count, "length 必须是文件字节数")

        let sigData = try XCTUnwrap(Data(base64Encoded: parsed.signatureB64), "签名应是合法 base64")
        XCTAssertTrue(
            key.publicKey.isValidSignature(sigData, for: payload),
            "签名必须能被对应公钥验证（与 Sparkle 的 libsodium 互通的前提）"
        )
    }

    /// 64 字节 libsodium 格式（seed || pub）也应被接受，且与 32 字节 seed 等价。
    func test_sixtyFourByteSodiumKey_isAccepted() throws {
        let key = Curve25519.Signing.PrivateKey()
        let sodiumKey = key.rawRepresentation + key.publicKey.rawRepresentation   // seed||pub
        XCTAssertEqual(sodiumKey.count, 64)

        let payload = Data("same key, two encodings".utf8)
        let file = try makeTempFile(contents: payload, name: "p.zip")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let result = try runScript([sodiumKey.base64EncodedString(), file.path])
        XCTAssertEqual(result.exitCode, 0, "64 字节私钥应被接受，stderr=\(result.stderr)")
        let parsed = try XCTUnwrap(parseSignature(result.stdout))
        let sigData = try XCTUnwrap(Data(base64Encoded: parsed.signatureB64))
        XCTAssertTrue(key.publicKey.isValidSignature(sigData, for: payload))
    }

    // MARK: - --expect-public-key 守卫（CI 用来提前发现 secret 配错）

    func test_expectPublicKeyMatching_passes() throws {
        let key = Curve25519.Signing.PrivateKey()
        let file = try makeTempFile(contents: Data("x".utf8), name: "a.zip")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let result = try runScript([
            key.rawRepresentation.base64EncodedString(),
            file.path,
            "--expect-public-key",
            key.publicKey.rawRepresentation.base64EncodedString(),
        ])
        XCTAssertEqual(result.exitCode, 0, "公钥匹配应通过，stderr=\(result.stderr)")
        XCTAssertTrue(result.stderr.contains("public key verified"), "应回显校验通过，stderr=\(result.stderr)")
    }

    func test_expectPublicKeyMismatch_exitsNonZero() throws {
        let key = Curve25519.Signing.PrivateKey()
        let otherKey = Curve25519.Signing.PrivateKey()
        let file = try makeTempFile(contents: Data("x".utf8), name: "a.zip")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let result = try runScript([
            key.rawRepresentation.base64EncodedString(),
            file.path,
            "--expect-public-key",
            otherKey.publicKey.rawRepresentation.base64EncodedString(),
        ])
        XCTAssertNotEqual(result.exitCode, 0, "公钥不匹配必须非零退出")
        XCTAssertTrue(result.stderr.contains("不匹配"), "应给出明确原因，stderr=\(result.stderr)")
        XCTAssertFalse(result.stdout.contains("edSignature"), "不匹配时不应产出签名")
    }

    // MARK: - 参数与输入校验

    func test_missingArguments_printsUsageAndExitsNonZero() throws {
        let result = try runScript([])
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.contains("usage: swift scripts/sign_update.swift"), "应打印用法，stderr=\(result.stderr)")
    }

    func test_invalidBase64Key_exitsNonZero() throws {
        let file = try makeTempFile(contents: Data("x".utf8), name: "a.zip")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let result = try runScript(["not-valid-base64!!!", file.path])
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.contains("base64"), "应说明 base64 非法，stderr=\(result.stderr)")
    }
}
