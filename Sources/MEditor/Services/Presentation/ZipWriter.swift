import Foundation

/// 最小 ZIP 写入器：**未压缩存储（stored, method 0）**。
///
/// 取舍：.pptx/.docx 等 OOXML 包的合法性与压缩方式无关——ZIP 规范允许 stored，
/// Keynote / PowerPoint / WPS / QuickLook 均接受。选 stored 换来零依赖
/// （仓内只有 Sparkle，不为导出加压缩库），代价是体积约为 deflate 的 3–5 倍；
/// 演示文稿是纯 XML 文本，体量小，可接受。
///
/// 只实现所需子集：本地文件头 + 中央目录 + EOCD。无加密、无分卷、
/// 无 data descriptor、无 ZIP64（条目数与体积远未到上限）。
/// 文件名均为 ASCII，flags 保持 0。修改时间固定为 2026-01-01（DOS 时间戳
/// 语义对本场景无意义，固定值让产物字节级可复现，测试可断言）。
enum ZipWriter {

    struct Entry {
        /// 归档内路径，`/` 分隔，ASCII。
        let name: String
        let data: Data
    }

    /// 按给定顺序写出完整 ZIP 数据。
    static func write(_ entries: [Entry]) -> Data {
        // DOS 日期 2026-01-01 00:00:00：((2026-1980) << 9) | (1 << 5) | 1
        let dosDate: UInt16 = (46 << 9) | (1 << 5) | 1
        let dosTime: UInt16 = 0

        var out = Data()
        /// 中央目录条目所需的回看信息（SwiftLint large_tuple：四元组换具名结构）。
        struct CentralEntry {
            let name: String
            let crc: UInt32
            let size: UInt32
            let offset: UInt32
        }
        var central: [CentralEntry] = []

        for entry in entries {
            let nameBytes = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(out.count)

            // Local file header（30 字节定长 + 文件名，无 extra field）
            out.appendUInt32LE(0x0403_4B50)   // signature
            out.appendUInt16LE(20)            // version needed（2.0，stored 足够）
            out.appendUInt16LE(0)             // flags（文件名纯 ASCII，无需 UTF-8 标志位）
            out.appendUInt16LE(0)             // method 0 = stored
            out.appendUInt16LE(dosTime)
            out.appendUInt16LE(dosDate)
            out.appendUInt32LE(crc)
            out.appendUInt32LE(size)          // compressed size
            out.appendUInt32LE(size)          // uncompressed size（stored 两者相同）
            out.appendUInt16LE(UInt16(nameBytes.count))
            out.appendUInt16LE(0)             // extra length
            out.append(nameBytes)
            out.append(entry.data)

            central.append(CentralEntry(name: entry.name, crc: crc, size: size, offset: offset))
        }

        let centralOffset = UInt32(out.count)

        for item in central {
            let nameBytes = Data(item.name.utf8)
            out.appendUInt32LE(0x0201_4B50)   // central directory signature
            out.appendUInt16LE(20)            // version made by
            out.appendUInt16LE(20)            // version needed
            out.appendUInt16LE(0)             // flags
            out.appendUInt16LE(0)             // method = stored
            out.appendUInt16LE(dosTime)
            out.appendUInt16LE(dosDate)
            out.appendUInt32LE(item.crc)
            out.appendUInt32LE(item.size)
            out.appendUInt32LE(item.size)
            out.appendUInt16LE(UInt16(nameBytes.count))
            out.appendUInt16LE(0)             // extra length
            out.appendUInt16LE(0)             // comment length
            out.appendUInt16LE(0)             // disk number
            out.appendUInt16LE(0)             // internal attrs
            out.appendUInt32LE(0)             // external attrs
            out.appendUInt32LE(item.offset)
            out.append(nameBytes)
        }

        let centralSize = UInt32(out.count) - centralOffset

        // End of central directory
        out.appendUInt32LE(0x0605_4B50)
        out.appendUInt16LE(0)                 // disk number
        out.appendUInt16LE(0)                 // central dir start disk
        out.appendUInt16LE(UInt16(central.count))
        out.appendUInt16LE(UInt16(central.count))
        out.appendUInt32LE(centralSize)
        out.appendUInt32LE(centralOffset)
        out.appendUInt16LE(0)                 // comment length

        return out
    }

    /// 标准 CRC32（多项式 0xEDB88320，查表法；表在首次访问时按位生成）。
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crcTable: [UInt32] = (0..<256).map { UInt32($0) }.map { seed in
        var c = seed
        for _ in 0..<8 {
            c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
