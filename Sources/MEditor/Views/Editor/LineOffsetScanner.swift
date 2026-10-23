import AppKit

/// 行首 UTF-16 偏移表的分块快扫：逐单元比 `0x0A`，4,096 单元栈外缓冲。
/// 从 `EditorHighlightScheduler` 抽出共用——行号尺此前用逐行 `NSString.range`
/// 的旧法，同一份文本每击键被扫两遍、第二遍还慢 16.7×（实测见下调度器注释）。
///
/// 实测（`-O`）：218KB 6.17→0.62ms、2.2MB 54.4→3.25ms、5.5MB 135.4→7.95ms。
///
/// 正确性前提：`0x0A` 不会出现在任何多单元编码里（UTF-16 代理对的高位是
/// 0xD800–0xDBFF、低位 0xDC00–0xDFFF），按单元比较不会切坏字符。
enum LineOffsetScanner {
    static func build(for text: NSString) -> [Int] {
        let length = text.length
        var offsets: [Int] = [0]
        offsets.reserveCapacity(length / 40 + 1)

        let chunkSize = 4096
        var buffer = [unichar](repeating: 0, count: chunkSize)
        var position = 0
        buffer.withUnsafeMutableBufferPointer { raw in
            guard let base = raw.baseAddress else { return }
            while position < length {
                let count = min(chunkSize, length - position)
                text.getCharacters(base, range: NSRange(location: position, length: count))
                for i in 0..<count where base[i] == 0x0A {
                    offsets.append(position + i + 1)
                }
                position += count
            }
        }
        return offsets
    }
}
