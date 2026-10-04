import Foundation
import Compression

// MARK: - 校验和

enum Checksum {
    static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) == 1 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for byte in data {
            c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFFFFFF
    }

    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }
}

// MARK: - 写入 ZIP（STORED 无压缩，Office 完全兼容）

struct ZipWriter {
    private struct Entry {
        let name: String
        let data: Data
    }
    private var entries: [Entry] = []

    mutating func add(_ name: String, _ data: Data) {
        entries.append(Entry(name: name, data: data))
    }

    mutating func add(_ name: String, _ text: String) {
        add(name, Data(text.utf8))
    }

    func finalize() -> Data {
        var out = Data()
        var central = Data()

        for entry in entries {
            let nameBytes = Data(entry.name.utf8)
            let crc = Checksum.crc32(entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(out.count)

            // Local file header
            out.appendLE(UInt32(0x04034b50))
            out.appendLE(UInt16(20))
            out.appendLE(UInt16(0x0800))   // UTF-8 文件名
            out.appendLE(UInt16(0))        // stored
            out.appendLE(UInt16(0))        // time
            out.appendLE(UInt16(0x21))     // date（1980-01-01）
            out.appendLE(crc)
            out.appendLE(size)
            out.appendLE(size)
            out.appendLE(UInt16(nameBytes.count))
            out.appendLE(UInt16(0))
            out.append(nameBytes)
            out.append(entry.data)

            // Central directory record
            central.appendLE(UInt32(0x02014b50))
            central.appendLE(UInt16(20))
            central.appendLE(UInt16(20))
            central.appendLE(UInt16(0x0800))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0x21))
            central.appendLE(crc)
            central.appendLE(size)
            central.appendLE(size)
            central.appendLE(UInt16(nameBytes.count))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt32(0))
            central.appendLE(offset)
            central.append(nameBytes)
        }

        let centralOffset = UInt32(out.count)
        let centralSize = UInt32(central.count)
        out.append(central)

        // End of central directory
        out.appendLE(UInt32(0x06054b50))
        out.appendLE(UInt16(0))
        out.appendLE(UInt16(0))
        out.appendLE(UInt16(entries.count))
        out.appendLE(UInt16(entries.count))
        out.appendLE(centralSize)
        out.appendLE(centralOffset)
        out.appendLE(UInt16(0))
        return out
    }
}

// MARK: - 读取 ZIP（支持 stored 与 deflate，用于解析 docx/xlsx/pptx）

enum ZipReaderError: Error, LocalizedError {
    case notArchive
    case entryNotFound(String)
    case inflateFailed

    var errorDescription: String? {
        switch self {
        case .notArchive: return "不是有效的压缩包"
        case .entryNotFound(let n): return "压缩包内找不到 \(n)"
        case .inflateFailed: return "解压失败"
        }
    }
}

struct ZipReader {
    let data: Data

    private struct CentralEntry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localOffset: Int
    }

    private func u16(_ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[data.startIndex + offset]) | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }

    private func u32(_ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let b = data.startIndex + offset
        return UInt32(data[b]) | (UInt32(data[b + 1]) << 8) | (UInt32(data[b + 2]) << 16) | (UInt32(data[b + 3]) << 24)
    }

    private func centralEntries() -> [CentralEntry] {
        // 从尾部向前找 EOCD（0x06054b50）
        let maxScan = min(data.count, 66000)
        var eocd = -1
        var i = data.count - 22
        let lowerBound = data.count - maxScan
        while i >= max(lowerBound, 0) {
            if u32(i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return [] }

        let total = Int(u16(eocd + 10))
        var offset = Int(u32(eocd + 16))
        var result: [CentralEntry] = []

        for _ in 0..<total {
            guard offset + 46 <= data.count, u32(offset) == 0x02014b50 else { break }
            let method = u16(offset + 10)
            let csize = Int(u32(offset + 20))
            let usize = Int(u32(offset + 24))
            let nameLen = Int(u16(offset + 28))
            let extraLen = Int(u16(offset + 30))
            let commentLen = Int(u16(offset + 32))
            let localOffset = Int(u32(offset + 42))
            let nameStart = offset + 46
            guard nameStart + nameLen <= data.count else { break }
            let nameData = data.subdata(in: (data.startIndex + nameStart)..<(data.startIndex + nameStart + nameLen))
            let name = String(data: nameData, encoding: .utf8) ?? ""
            result.append(CentralEntry(name: name, method: method, compressedSize: csize,
                                       uncompressedSize: usize, localOffset: localOffset))
            offset = nameStart + nameLen + extraLen + commentLen
        }
        return result
    }

    func entryNames() -> [String] {
        centralEntries().map(\.name)
    }

    func data(for name: String) throws -> Data {
        guard let entry = centralEntries().first(where: { $0.name == name }) else {
            throw ZipReaderError.entryNotFound(name)
        }
        let lo = entry.localOffset
        guard lo + 30 <= data.count, u32(lo) == 0x04034b50 else { throw ZipReaderError.notArchive }
        let nameLen = Int(u16(lo + 26))
        let extraLen = Int(u16(lo + 28))
        let start = lo + 30 + nameLen + extraLen
        guard start <= data.count else { throw ZipReaderError.notArchive }

        let available = min(entry.compressedSize, data.count - start)
        guard available > 0 else { return Data() }
        let payload = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + available))

        switch entry.method {
        case 0:
            return payload
        case 8:
            guard let inflated = Self.inflateRaw(payload, expectedSize: entry.uncompressedSize) else {
                throw ZipReaderError.inflateFailed
            }
            return inflated
        default:
            throw ZipReaderError.inflateFailed
        }
    }

    /// 用 Compression 解 raw deflate：补 zlib 头与 adler32 校验尾
    static func inflateRaw(_ raw: Data, expectedSize: Int) -> Data? {
        guard !raw.isEmpty else { return Data() }
        var z = Data([0x78, 0x9C])
        z.append(raw)
        let a = Checksum.adler32(raw)
        z.append(contentsOf: [
            UInt8((a >> 24) & 0xFF), UInt8((a >> 16) & 0xFF),
            UInt8((a >> 8) & 0xFF), UInt8(a & 0xFF),
        ])

        let capacity = max(expectedSize, 64 * 1024)
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            z.withUnsafeBytes { src -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(d, capacity, s, z.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return out.prefix(written)
    }
}

// MARK: - 小端写入辅助

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
