import Foundation
import Observation

/// @unchecked Sendable：树模型在后台线程构建、主线程消费；现有设计已按此约定使用，
/// 迁移到 Swift 6 语言模式时显式标注该约定（真正的隔离重构另议）。
@Observable
final class FileItem: Identifiable, Hashable, @unchecked Sendable {
    /// Stable identity based on URL. Using the URL (not a per-instance UUID)
    /// is critical so that SwiftUI's List preserves expansion state when
    /// `reloadFileTree()` rebuilds the entire tree (e.g. after a file watcher
    /// event). Without a stable id, every reload would collapse all expanded
    /// folders.
    var id: URL { url }

    let url: URL
    let isDirectory: Bool
    var children: [FileItem]?
    var childrenLoaded: Bool
    var isLoadingChildren = false

    init(url: URL, isDirectory: Bool, children: [FileItem]? = nil, childrenLoaded: Bool? = nil) {
        self.url = url
        self.isDirectory = isDirectory
        self.children = children
        self.childrenLoaded = childrenLoaded ?? (!isDirectory || children != nil)
    }

    /// 文件名（`url.lastPathComponent`）。
    ///
    /// ⚠️ 这是**计算属性**，每次取值都要现算一个 String。任何「在比较器里取 name」的
    /// 排序都等于每次比较现算两次（4,500 项 ≈ 10.8 万次比较 ⇒ 排序 91.7ms，预取后
    /// 13.4ms）。需要批量用 name 的地方先映射出来，别在 `sorted(by:)` 里直接取。
    var name: String {
        #if DEBUG
        FileItem.nameAccessCount &+= 1
        #endif
        return url.lastPathComponent
    }
    var fileExtension: String { url.pathExtension.lowercased() }

    #if DEBUG
    /// name 取值次数。仅供测试验证「排序里没有逐次现取」这一性能属性——
    /// 排序 500 项时：预取实现 ≈500 次，逐次现取 ≈9000 次（n·log n·2）。
    nonisolated(unsafe) static var nameAccessCount = 0
    #endif


    /// True if this file can be opened by the editor.
    var isSupported: Bool {
        isDirectory || FileTypeConfiguration.shared.supportedExtensions.contains(fileExtension)
    }

    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.url == rhs.url
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }
}
