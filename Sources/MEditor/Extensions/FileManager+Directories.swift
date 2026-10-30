import Foundation

extension FileManager {
    /// First URL of a user-domain search-path directory, with a defensive
    /// fallback so callers never need to force-unwrap (enforced by the
    /// force_unwrapping lint gate). These directories always exist in practice
    /// (iOS app sandbox guarantees them); the fallback is defense in depth and
    /// deliberately uses NSTemporaryDirectory() because it exists on both
    /// platforms — homeDirectoryForCurrentUser is macOS-only.
    func firstURL(for directory: SearchPathDirectory) -> URL {
        urls(for: directory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    /// 真实文件系统路径；目标已删除时借最近的现存父目录还原同一逻辑路径。
    func canonicalURL(for url: URL) -> URL {
        var candidate = url
        var suffix: [String] = []
        while true {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            if realpath(candidate.path, &buffer) != nil {
                let path = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                var resolved = URL(fileURLWithPath: String(bytes: path, encoding: .utf8) ?? "")
                for component in suffix { resolved.appendPathComponent(component) }
                return resolved
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return url }
            suffix.insert(candidate.lastPathComponent, at: 0)
            candidate = parent
        }
    }
}
