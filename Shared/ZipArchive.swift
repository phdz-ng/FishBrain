import Compression
import Foundation

/// A small zip reader and writer, enough for Anki packages: stored and deflated entries, no encryption, no
/// Zip64. Reading is defensive, since the file comes from someone else: names that climb out of the folder
/// are refused, and what a zip claims to hold is capped before anything is unpacked.
struct ZipArchive {
    enum ZipError: Error, Equatable {
        case notAZip
        case unsupported(String)
        case unsafePath(String)
        case tooLarge(bytes: Int, limit: Int)
        case corrupt(String)
    }

    struct Entry: Equatable {
        var name: String
        var method: UInt16
        var crc: UInt32
        var compressedSize: Int
        var uncompressedSize: Int
        var localOffset: Int
    }

    /// What a package may unpack to, all entries together.
    static let defaultMaxUncompressedBytes = 250_000_000
    static let maxEntries = 200_000

    private let data: Data
    private(set) var entries: [Entry]

    init(data: Data, maxUncompressedBytes: Int = ZipArchive.defaultMaxUncompressedBytes) throws {
        self.data = Data(data) // indices from zero
        self.entries = []
        let bytes = self.data
        guard bytes.count >= 22 else { throw ZipError.notAZip }

        // The end-of-central-directory record is in the last 64 KB.
        var eocd: Int?
        var position = bytes.count - 22
        let lowest = max(0, bytes.count - 22 - 65_535)
        while position >= lowest {
            if try Self.u32(bytes, position) == 0x0605_4B50 { eocd = position; break }
            position -= 1
        }
        guard let eocd else { throw ZipError.notAZip }

        let total = Int(try Self.u16(bytes, eocd + 10))
        let directorySize = Int(try Self.u32(bytes, eocd + 12))
        let directoryOffset = Int(try Self.u32(bytes, eocd + 16))
        if total == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            throw ZipError.unsupported("Zip64")
        }
        guard total <= Self.maxEntries else { throw ZipError.tooLarge(bytes: total, limit: Self.maxEntries) }
        guard directoryOffset >= 0, directoryOffset <= bytes.count else { throw ZipError.corrupt("directory") }

        var cursor = directoryOffset
        var declared = 0
        for _ in 0..<total {
            guard try Self.u32(bytes, cursor) == 0x0201_4B50 else { throw ZipError.corrupt("directory entry") }
            let flags = try Self.u16(bytes, cursor + 8)
            let method = try Self.u16(bytes, cursor + 10)
            let crc = try Self.u32(bytes, cursor + 16)
            let compressed = Int(try Self.u32(bytes, cursor + 20))
            let uncompressed = Int(try Self.u32(bytes, cursor + 24))
            let nameLength = Int(try Self.u16(bytes, cursor + 28))
            let extraLength = Int(try Self.u16(bytes, cursor + 30))
            let commentLength = Int(try Self.u16(bytes, cursor + 32))
            let offset = Int(try Self.u32(bytes, cursor + 42))
            let nameStart = cursor + 46
            guard nameStart + nameLength <= bytes.count else { throw ZipError.corrupt("name") }
            let nameBytes = bytes[nameStart..<(nameStart + nameLength)]
            let name = String(data: nameBytes, encoding: .utf8) ?? String(decoding: nameBytes, as: UTF8.self)
            cursor = nameStart + nameLength + extraLength + commentLength

            if flags & 1 != 0 { throw ZipError.unsupported("encryption") }
            if compressed == 0xFFFF_FFFF || uncompressed == 0xFFFF_FFFF { throw ZipError.unsupported("Zip64") }
            if name.hasSuffix("/") { continue } // a folder
            try Self.checkSafe(name)

            declared += uncompressed
            guard declared <= maxUncompressedBytes else { throw ZipError.tooLarge(bytes: declared, limit: maxUncompressedBytes) }
            entries.append(Entry(
                name: name, method: method, crc: crc, compressedSize: compressed,
                uncompressedSize: uncompressed, localOffset: offset
            ))
        }
    }

    func entry(named name: String) -> Entry? { entries.first { $0.name == name } }

    func contents(of entry: Entry) throws -> Data {
        let header = entry.localOffset
        guard try Self.u32(data, header) == 0x0403_4B50 else { throw ZipError.corrupt("local header") }
        let nameLength = Int(try Self.u16(data, header + 26))
        let extraLength = Int(try Self.u16(data, header + 28))
        let start = header + 30 + nameLength + extraLength
        let end = start + entry.compressedSize
        guard start >= 0, end <= data.count else { throw ZipError.corrupt("entry data") }
        let raw = data[start..<end]

        let result: Data
        switch entry.method {
        case 0:
            guard raw.count == entry.uncompressedSize else { throw ZipError.corrupt("size") }
            result = Data(raw)
        case 8:
            if entry.uncompressedSize == 0 {
                result = Data()
            } else {
                var output = [UInt8](repeating: 0, count: entry.uncompressedSize)
                let written = raw.withUnsafeBytes { source -> Int in
                    guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(&output, output.count, base, raw.count, nil, COMPRESSION_ZLIB)
                }
                guard written == entry.uncompressedSize else { throw ZipError.corrupt("deflate") }
                result = Data(output)
            }
        default:
            throw ZipError.unsupported("compression method \(entry.method)")
        }
        guard Self.crc32(result) == entry.crc else { throw ZipError.corrupt("checksum") }
        return result
    }

    func contents(named name: String) throws -> Data? {
        guard let entry = entry(named: name) else { return nil }
        return try contents(of: entry)
    }

    // MARK: Safety

    /// Names must stay inside the folder they are unpacked into.
    static func checkSafe(_ name: String) throws {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        if name.hasPrefix("/") || name.hasPrefix("\\") || name.contains("\0") || name.contains("\\")
            || parts.contains("..") || name.range(of: "^[A-Za-z]:", options: .regularExpression) != nil {
            throw ZipError.unsafePath(name)
        }
    }

    // MARK: Writing

    /// A zip of these files, in order. Each is deflated when that makes it smaller.
    static func write(_ files: [(name: String, data: Data)]) -> Data {
        var output = Data()
        var directory = Data()
        for file in files {
            let nameBytes = Data(file.name.utf8)
            let crc = crc32(file.data)
            var method: UInt16 = 0
            var payload = file.data
            if file.data.count > 32, let packed = deflate(file.data), packed.count < file.data.count {
                method = 8
                payload = packed
            }
            let offset = output.count

            output.append(le32(0x0403_4B50))
            output.append(le16(20)) // version needed
            output.append(le16(0x0800)) // UTF-8 names
            output.append(le16(method))
            output.append(le16(0)) // time
            output.append(le16(0x0021)) // date: 1980-01-01
            output.append(le32(crc))
            output.append(le32(UInt32(payload.count)))
            output.append(le32(UInt32(file.data.count)))
            output.append(le16(UInt16(nameBytes.count)))
            output.append(le16(0))
            output.append(nameBytes)
            output.append(payload)

            directory.append(le32(0x0201_4B50))
            directory.append(le16(20)) // made by
            directory.append(le16(20)) // version needed
            directory.append(le16(0x0800))
            directory.append(le16(method))
            directory.append(le16(0))
            directory.append(le16(0x0021))
            directory.append(le32(crc))
            directory.append(le32(UInt32(payload.count)))
            directory.append(le32(UInt32(file.data.count)))
            directory.append(le16(UInt16(nameBytes.count)))
            directory.append(le16(0)) // extra
            directory.append(le16(0)) // comment
            directory.append(le16(0)) // disk
            directory.append(le16(0)) // internal attributes
            directory.append(le32(0)) // external attributes
            directory.append(le32(UInt32(offset)))
            directory.append(nameBytes)
        }
        let directoryOffset = output.count
        output.append(directory)
        output.append(le32(0x0605_4B50))
        output.append(le16(0))
        output.append(le16(0))
        output.append(le16(UInt16(files.count)))
        output.append(le16(UInt16(files.count)))
        output.append(le32(UInt32(directory.count)))
        output.append(le32(UInt32(directoryOffset)))
        output.append(le16(0))
        return output
    }

    private static func deflate(_ data: Data) -> Data? {
        var output = [UInt8](repeating: 0, count: data.count + 1024)
        let written = data.withUnsafeBytes { source -> Int in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(&output, output.count, base, data.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { return nil }
        return Data(output[0..<written])
    }

    // MARK: Bytes

    private static func le16(_ value: UInt16) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8)]) }
    private static func le32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)])
    }

    private static func u16(_ data: Data, _ offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { throw ZipError.corrupt("truncated") }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func u32(_ data: Data, _ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { throw ZipError.corrupt("truncated") }
        return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }

    // MARK: CRC-32

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
