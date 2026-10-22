import Foundation
import OSLog

/// Categorized application errors. Used in place of raw String error messages
/// so error sites have semantic context, are testable, and can be routed
/// (some surface to the user, some only to logs).
enum AppError: LocalizedError {
    case fileRead(URL, underlying: Error)
    case fileWrite(URL, underlying: Error)
    case fileDelete(URL, underlying: Error)
    case fileRename(URL, to: URL, underlying: Error)
    case fileCreate(URL, underlying: Error)
    case sandboxAccessDenied(URL)
    case previewResourceMissing(String)
    case exportFailed(format: String, underlying: Error?)
    case sessionRestoreFailed(String)
    /// 文件体积超过编辑器上限（`TabManager.openSizeLimit(for:)`），拒绝打开。
    /// 与「读失败」分开：文件是好的，只是这里打不开。
    case fileTooLarge(URL, size: Int64, limit: Int64)

    /// Short, end-user-friendly description.
    var errorDescription: String? {
        switch self {
        case .fileRead(let url, let e):
            return L("error.openFailed", url.lastPathComponent, e.localizedDescription)
        case .fileWrite(let url, let e):
            return L("error.saveFailed", url.lastPathComponent, e.localizedDescription)
        case .fileDelete(let url, let e):
            return L("error.deleteFailed2", url.lastPathComponent, e.localizedDescription)
        case .fileRename(let url, _, let e):
            return L("error.renameFailed2", url.lastPathComponent, e.localizedDescription)
        case .fileCreate(let url, let e):
            return L("error.createFailed", url.lastPathComponent, e.localizedDescription)
        case .sandboxAccessDenied(let url):
            return L("error.accessDenied", url.lastPathComponent)
        case .previewResourceMissing(let name):
            return L("error.previewResourceMissing", name)
        case .exportFailed(let format, let e):
            return L("error.exportFailed", format, e?.localizedDescription ?? L("error.unknown"))
        case .sessionRestoreFailed(let detail):
            return L("error.sessionRestoreFailed", detail)
        case .fileTooLarge(let url, let size, let limit):
            return L("error.fileTooLarge",
                     url.lastPathComponent,
                     Self.byteText(size),
                     Self.byteText(limit))
        }
    }

    /// 「23.4 MB」这类展示用体积。用 `ByteCountFormatter` 而不是自己除 1024：
    /// 单位与系统其余地方一致，且中英切换时单位词也跟着系统走。
    static func byteText(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useMB, .useGB]
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: bytes)
    }

    /// Severity for routing: `.user` errors are surfaced via Alert, `.silent`
    /// only go to OSLog (e.g. session restore failures shouldn't pop up).
    enum Severity { case user, silent }

    var severity: Severity {
        switch self {
        case .sessionRestoreFailed, .previewResourceMissing:
            return .silent
        default:
            return .user
        }
    }
}

/// Centralized logging facade. Categorized loggers let Console.app filter
/// by area. All error sites should `AppLog.error(.X, ...)` so we have a
/// uniform record of failures in production.
enum AppLog {
    private static let subsystem = "com.meditor.app"

    static let app      = Logger(subsystem: subsystem, category: "app")
    static let file     = Logger(subsystem: subsystem, category: "file")
    static let preview  = Logger(subsystem: subsystem, category: "preview")
    static let editor   = Logger(subsystem: subsystem, category: "editor")
    static let session  = Logger(subsystem: subsystem, category: "session")
    static let exporter = Logger(subsystem: subsystem, category: "exporter")
    static let ai       = Logger(subsystem: subsystem, category: "ai")

    /// Log an `AppError` with its details. Always at .error level.
    static func error(_ error: AppError, in logger: Logger = app) {
        logger.error("\(error.errorDescription ?? String(describing: error), privacy: .public)")
    }
}
