import Foundation

#if os(macOS)

extension ChromiumLocalStorageReader {
    // MARK: - LevelDB traversal

    struct LevelDBEntry: Sendable {
        let key: Data
        let value: Data
        let isDeletion: Bool
    }

    static func levelDBEntries(
        in levelDBURL: URL,
        logger: ((String) -> Void)? = nil) -> [LevelDBEntry]?
    {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: levelDBURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else { return nil }

        let files = entries.filter { url in
            let ext = url.pathExtension.lowercased()
            return ext == "ldb" || ext == "log"
        }
        .sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            return (left ?? .distantPast) > (right ?? .distantPast)
        }

        var results: [LevelDBEntry] = []
        for file in files {
            let ext = file.pathExtension.lowercased()
            if ext == "log" {
                let logEntries = self.readLogEntries(from: file, logger: logger)
                if logEntries.isEmpty {
                    logger?("LevelDB log yielded no entries for \(file.lastPathComponent)")
                }
                results.append(contentsOf: logEntries)
            } else {
                let tableEntries = self.readTableEntries(from: file, logger: logger)
                if tableEntries.isEmpty {
                    logger?("LevelDB table yielded no entries for \(file.lastPathComponent)")
                }
                results.append(contentsOf: tableEntries)
            }
        }
        return results
    }

    // MARK: - Log parsing

    private enum LogRecordType: UInt8 {
        case full = 1
        case first = 2
        case middle = 3
        case last = 4
    }

    private static func readLogEntries(from url: URL, logger: ((String) -> Void)? = nil) -> [LevelDBEntry] {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return [] }
        var entries: [LevelDBEntry] = []
        var recordBuffer = Data()
        var offset = 0

        while offset < data.count {
            let blockEnd = min(offset + self.blockSize, data.count)
            var blockOffset = offset
            while blockOffset + 7 <= blockEnd {
                let length = Int(self.readUInt16LE(data, at: blockOffset + 4))
                let type = data[blockOffset + 6]
                blockOffset += 7
                if length == 0 { continue }
                guard blockOffset + length <= blockEnd else { break }
                let chunk = data.subdata(in: blockOffset..<(blockOffset + length))
                blockOffset += length

                guard let recordType = LogRecordType(rawValue: type) else { continue }
                switch recordType {
                case .full:
                    entries.append(contentsOf: self.decodeWriteBatch(chunk))
                case .first:
                    recordBuffer = chunk
                case .middle:
                    recordBuffer.append(chunk)
                case .last:
                    recordBuffer.append(chunk)
                    entries.append(contentsOf: self.decodeWriteBatch(recordBuffer))
                    recordBuffer.removeAll(keepingCapacity: true)
                }
            }
            offset += self.blockSize
        }
        if !recordBuffer.isEmpty {
            entries.append(contentsOf: self.decodeWriteBatch(recordBuffer))
        }
        return Array(entries.reversed())
    }

    private static func decodeWriteBatch(_ data: Data) -> [LevelDBEntry] {
        guard data.count >= 12 else { return [] }
        var entries: [LevelDBEntry] = []
        var offset = 12
        while offset < data.count {
            guard let tag = self.readUInt8(data, at: &offset) else { break }
            switch tag {
            case 0:
                guard let key = self.readLengthPrefixedSlice(data, at: &offset) else { break }
                entries.append(LevelDBEntry(key: key, value: Data(), isDeletion: true))
            case 1:
                guard let key = self.readLengthPrefixedSlice(data, at: &offset),
                      let value = self.readLengthPrefixedSlice(data, at: &offset)
                else { break }
                entries.append(LevelDBEntry(key: key, value: value, isDeletion: false))
            default:
                return entries
            }
        }
        return entries
    }

    // MARK: - Table parsing

    private struct BlockHandle: Sendable {
        let offset: Int
        let size: Int
    }

    private static func readTableEntries(from url: URL, logger: ((String) -> Void)? = nil) -> [LevelDBEntry] {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return [] }
        guard data.count >= self.footerSize else { return [] }

        let footerStart = data.count - self.footerSize
        let footerData = data.subdata(in: footerStart..<(data.count - 8))
        var reader = ByteReader(footerData)
        guard self.readBlockHandle(&reader) != nil,
              let indexHandle = self.readBlockHandle(&reader)
        else { return [] }

        guard let indexBlock = self.readBlock(data: data, handle: indexHandle, logger: logger) else { return [] }
        let indexEntries = self.parseDataBlock(indexBlock, treatKeysAsInternal: false)
        var results: [LevelDBEntry] = []

        for entry in indexEntries {
            guard let handle = self.decodeBlockHandle(from: entry.value) else { continue }
            guard let blockData = self.readBlock(data: data, handle: handle, logger: logger) else { continue }
            let dataEntries = self.parseDataBlock(blockData, treatKeysAsInternal: true)
            results.append(contentsOf: dataEntries)
        }
        return results
    }

    private static func readBlock(
        data: Data,
        handle: BlockHandle,
        logger: ((String) -> Void)? = nil) -> Data?
    {
        let start = handle.offset
        let end = handle.offset + handle.size
        guard start >= 0, end + 5 <= data.count else { return nil }
        let rawBlock = data.subdata(in: start..<end)
        let compressionType = data[end]
        switch compressionType {
        case 0:
            return rawBlock
        case 1:
            return SnappyDecoder.decompress(rawBlock)
        default:
            logger?("Unsupported block compression: \(compressionType)")
            return nil
        }
    }

    private static func parseDataBlock(
        _ data: Data,
        treatKeysAsInternal: Bool) -> [LevelDBEntry]
    {
        guard data.count >= 4 else { return [] }
        let restartCount = Int(self.readUInt32LE(data, at: data.count - 4))
        let restartArraySize = (restartCount + 1) * 4
        guard data.count >= restartArraySize else { return [] }
        let limit = data.count - restartArraySize

        var entries: [LevelDBEntry] = []
        var offset = 0
        var lastKey = Data()
        while offset < limit {
            guard let shared = self.readVarint32(data, at: &offset),
                  let nonShared = self.readVarint32(data, at: &offset),
                  let valueLength = self.readVarint32(data, at: &offset)
            else { break }

            let keyEnd = offset + Int(nonShared)
            guard keyEnd <= limit else { break }
            let keySuffix = data.subdata(in: offset..<keyEnd)
            offset = keyEnd

            let valueEnd = offset + Int(valueLength)
            guard valueEnd <= limit else { break }
            let value = data.subdata(in: offset..<valueEnd)
            offset = valueEnd

            let prefix = lastKey.prefix(Int(shared))
            var fullKey = Data(prefix)
            fullKey.append(keySuffix)
            lastKey = fullKey

            if treatKeysAsInternal, let internalKey = self.decodeInternalKey(fullKey) {
                if internalKey.valueType == 0 {
                    entries.append(LevelDBEntry(key: internalKey.userKey, value: Data(), isDeletion: true))
                } else {
                    entries.append(LevelDBEntry(key: internalKey.userKey, value: value, isDeletion: false))
                }
            } else {
                entries.append(LevelDBEntry(key: fullKey, value: value, isDeletion: false))
            }
        }
        return entries
    }

    private static func decodeInternalKey(_ data: Data) -> (userKey: Data, valueType: UInt8)? {
        guard data.count >= 8 else { return nil }
        let userKey = data.prefix(data.count - 8)
        let tag = self.readUInt64LE(data, at: data.count - 8)
        let valueType = UInt8(tag & 0xFF)
        return (Data(userKey), valueType)
    }

    private static func readBlockHandle(_ reader: inout ByteReader) -> BlockHandle? {
        guard let offset = reader.readVarint64(),
              let size = reader.readVarint64()
        else { return nil }
        return BlockHandle(offset: Int(offset), size: Int(size))
    }

    private static func decodeBlockHandle(from value: Data) -> BlockHandle? {
        var reader = ByteReader(value)
        guard let offset = reader.readVarint64(),
              let size = reader.readVarint64()
        else { return nil }
        return BlockHandle(offset: Int(offset), size: Int(size))
    }

    // MARK: - Data helpers

    private struct ByteReader {
        private let bytes: [UInt8]
        private(set) var index: Int = 0

        init(_ data: Data) {
            self.bytes = Array(data)
        }

        mutating func readVarint64() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while shift < 64 {
                guard let byte = self.readUInt8() else { return nil }
                result |= UInt64(byte & 0x7F) << shift
                if (byte & 0x80) == 0 {
                    return result
                }
                shift += 7
            }
            return nil
        }

        mutating func readUInt8() -> UInt8? {
            guard self.index < self.bytes.count else { return nil }
            let value = self.bytes[self.index]
            self.index += 1
            return value
        }
    }

    private static func readUInt8(_ data: Data, at offset: inout Int) -> UInt8? {
        guard offset < data.count else { return nil }
        let value = data[offset]
        offset += 1
        return value
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        let byte0 = UInt16(data[offset])
        let byte1 = UInt16(data[offset + 1])
        return byte0 | (byte1 << 8)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        let byte0 = UInt32(data[offset])
        let byte1 = UInt32(data[offset + 1]) << 8
        let byte2 = UInt32(data[offset + 2]) << 16
        let byte3 = UInt32(data[offset + 3]) << 24
        return byte0 | byte1 | byte2 | byte3
    }

    private static func readUInt64LE(_ data: Data, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(data[offset + index]) << (UInt64(index) * 8)
        }
        return value
    }

    private static func readVarint32(_ data: Data, at offset: inout Int) -> UInt32? {
        var result: UInt32 = 0
        var shift: UInt32 = 0
        while shift < 32 {
            guard let byte = self.readUInt8(data, at: &offset) else { return nil }
            result |= UInt32(byte & 0x7F) << shift
            if (byte & 0x80) == 0 {
                return result
            }
            shift += 7
        }
        return nil
    }

    private static func readLengthPrefixedSlice(_ data: Data, at offset: inout Int) -> Data? {
        guard let length = self.readVarint32(data, at: &offset) else { return nil }
        let count = Int(length)
        guard count >= 0, offset + count <= data.count else { return nil }
        let slice = data.subdata(in: offset..<(offset + count))
        offset += count
        return slice
    }
}

#endif
