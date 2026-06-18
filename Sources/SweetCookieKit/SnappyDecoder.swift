import Foundation

#if os(macOS)

enum SnappyDecoder {
    static func decompress(_ data: Data) -> Data? {
        var reader = ByteReader(data)
        guard let expectedLength = reader.readVarint32() else { return nil }
        var output: [UInt8] = []
        output.reserveCapacity(Int(expectedLength))

        while reader.hasBytes {
            guard let tag = reader.readUInt8() else { break }
            let type = tag & 0x03
            switch type {
            case 0:
                let literalLength = Self.readLiteralLength(tag: tag, reader: &reader)
                guard literalLength > 0, let literal = reader.readBytes(count: literalLength) else {
                    return nil
                }
                output.append(contentsOf: literal)
            case 1:
                let length = Int((tag >> 2) & 0x7) + 4
                guard let low = reader.readUInt8() else { return nil }
                let offset = (Int(tag >> 5) << 8) | Int(low)
                guard offset > 0 else { return nil }
                Self.copyBytes(length: length, offset: offset, output: &output)
            case 2:
                let length = Int(tag >> 2) + 1
                guard let offset = reader.readUInt16LE() else { return nil }
                let offsetValue = Int(offset)
                guard offsetValue > 0 else { return nil }
                Self.copyBytes(length: length, offset: offsetValue, output: &output)
            case 3:
                let length = Int(tag >> 2) + 1
                guard let offset = reader.readUInt32LE() else { return nil }
                let offsetValue = Int(offset)
                guard offsetValue > 0 else { return nil }
                Self.copyBytes(length: length, offset: offsetValue, output: &output)
            default:
                return nil
            }
        }

        return Data(output)
    }

    private static func readLiteralLength(tag: UInt8, reader: inout ByteReader) -> Int {
        let length = Int(tag >> 2)
        if length < 60 {
            return length + 1
        }

        let extraBytes = length - 59
        var computed = 0
        for byteIndex in 0..<extraBytes {
            guard let byte = reader.readUInt8() else { return 0 }
            computed |= Int(byte) << (8 * byteIndex)
        }
        return computed + 1
    }

    private static func copyBytes(length: Int, offset: Int, output: inout [UInt8]) {
        guard offset <= output.count else { return }
        let start = output.count - offset
        for index in 0..<length {
            output.append(output[start + (index % offset)])
        }
    }

    private struct ByteReader {
        private let bytes: [UInt8]
        private(set) var index: Int = 0

        init(_ data: Data) {
            self.bytes = Array(data)
        }

        var hasBytes: Bool {
            self.index < self.bytes.count
        }

        mutating func readUInt8() -> UInt8? {
            guard self.index < self.bytes.count else { return nil }
            let value = self.bytes[self.index]
            self.index += 1
            return value
        }

        mutating func readBytes(count: Int) -> [UInt8]? {
            guard count >= 0, self.index + count <= self.bytes.count else { return nil }
            let slice = self.bytes[self.index..<(self.index + count)]
            self.index += count
            return Array(slice)
        }

        mutating func readUInt16LE() -> UInt16? {
            guard let b0 = readUInt8(), let b1 = readUInt8() else { return nil }
            return UInt16(b0) | (UInt16(b1) << 8)
        }

        mutating func readUInt32LE() -> UInt32? {
            guard let b0 = readUInt8(),
                  let b1 = readUInt8(),
                  let b2 = readUInt8(),
                  let b3 = readUInt8()
            else { return nil }
            return UInt32(b0) | (UInt32(b1) << 8) | (UInt32(b2) << 16) | (UInt32(b3) << 24)
        }

        mutating func readVarint32() -> UInt32? {
            var result: UInt32 = 0
            var shift: UInt32 = 0
            while shift < 32 {
                guard let byte = readUInt8() else { return nil }
                result |= UInt32(byte & 0x7F) << shift
                if (byte & 0x80) == 0 {
                    return result
                }
                shift += 7
            }
            return nil
        }
    }
}

#endif
