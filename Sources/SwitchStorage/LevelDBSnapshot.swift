import Foundation
import SwitchCore

/// An offline, bounded snapshot of Chromium's bytewise LevelDB. It never opens or edits a live DB.
/// MANIFEST membership and sequence numbers matter: obsolete tables must not resurrect deleted keys.
public enum LevelDBSnapshot {
    static let limit = 128 * 1024 * 1024
    static var invalid: SwitchError { .blocked(L10n.tr("The conversation history could not be verified. Its original data is unchanged.")) }

    public static func read(_ files: [String: Data]) throws -> [Data: Data] {
        guard files.count <= 20_000, files.values.reduce(0, { $0 + $1.count }) <= limit,
              let current = files["CURRENT"], let name = String(data: current, encoding: .utf8), name.hasSuffix("\n"),
              name.dropLast().hasPrefix("MANIFEST-"), !name.contains("/"),
              let manifest = files[String(name.dropLast())] else { throw invalid }
        var tables: [UInt64: UInt64] = [:], log: UInt64?, previous: UInt64 = 0
        var comparator: Data?, next: UInt64?, last: UInt64?
        for record in try records(manifest) {
            var input = Cursor(record)
            while !input.done {
                switch try input.varint() {
                case 1: comparator = try input.bytes()
                case 2: log = try input.varint()
                case 3: next = try input.varint()
                case 4: last = try input.varint()
                case 5: _ = try input.varint(); _ = try input.bytes()
                case 6: _ = try input.varint(); tables.removeValue(forKey: try input.varint())
                case 7:
                    guard try input.varint() < 7 else { throw invalid }
                    let number = try input.varint(), size = try input.varint()
                    _ = try input.bytes(); _ = try input.bytes(); tables[number] = size
                case 9: previous = try input.varint()
                default: throw invalid
                }
            }
        }
        guard comparator == Data("leveldb.BytewiseComparator".utf8), let log, next != nil, last != nil else { throw invalid }
        var entries: [Data: (UInt64, Data?)] = [:], bytes = 0, operations = 0
        func put(_ key: Data, _ value: Data?, _ sequence: UInt64) throws {
            operations += 1; bytes += key.count + (value?.count ?? 0)
            guard sequence < (1 << 56), operations <= 1_000_000, bytes <= limit * 4 else { throw invalid }
            if let old = entries[key] {
                if sequence < old.0 { return }
                if sequence == old.0 { guard value == old.1 else { throw invalid }; return }
            }
            entries[key] = (sequence, value)
        }
        for (number, size) in tables {
            let stem = String(format: "%06llu", number)
            guard let table = files[stem + ".ldb"] ?? files[stem + ".sst"], table.count == size else { throw invalid }
            for (key, value) in try tableEntries(table) {
                guard key.count >= 8 else { throw invalid }
                var tag = Cursor(Data(key.suffix(8))); let packed = try tag.fixed(8)
                guard packed & 255 <= 1 else { throw invalid }
                try put(Data(key.dropLast(8)), packed & 255 == 0 ? nil : value, packed >> 8)
            }
        }
        let logs = files.keys.compactMap { path -> (UInt64, String)? in
            guard path.hasSuffix(".log"), let number = UInt64(path.dropLast(4)), number >= log || number == previous else { return nil }
            return (number, path)
        }.sorted { $0.0 < $1.0 }
        guard log == 0 || logs.contains(where: { $0.0 == log }),
              previous == 0 || logs.contains(where: { $0.0 == previous }) else { throw invalid }
        for (_, path) in logs {
            for record in try records(files[path]!) {
                var input = Cursor(record)
                let sequence = try input.fixed(8), count = try input.fixed(4)
                guard count <= 1_000_000, sequence < (1 << 56), count < (1 << 56) - sequence else { throw invalid }
                for offset in 0..<count {
                    let type = try input.fixed(1), key = try input.bytes()
                    guard type <= 1 else { throw invalid }
                    try put(key, type == 1 ? try input.bytes() : nil, sequence + offset)
                }
                guard input.done else { throw invalid }
            }
        }
        return entries.compactMapValues { $0.1 }
    }

    /// Rebuild from the complete target keyspace, after merging only non-authentication state.
    public static func files(_ values: [Data: Data]) throws -> [String: Data] {
        guard values.count <= 1_000_000, values.reduce(0, { $0 + $1.key.count + $1.value.count }) <= limit else { throw invalid }
        var batch = fixed(1, 8) + fixed(UInt64(values.count), 4)
        for key in values.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            batch.append(1); batch += bytes(key); batch += bytes(values[key]!)
        }
        let manifest = Data([1]) + bytes(Data("leveldb.BytewiseComparator".utf8)) +
            Data([2, 3, 3, 4, 4]) + varint(UInt64(values.count))
        return ["CURRENT": Data("MANIFEST-000001\n".utf8), "MANIFEST-000001": logRecord(manifest), "000003.log": logRecord(batch)]
    }

    static func records(_ data: Data) throws -> [Data] {
        var result: [Data] = [], pending: Data?, offset = 0
        while offset < data.count {
            let remaining = min(32_768 - offset % 32_768, data.count - offset)
            if remaining < 7 {
                guard data[offset..<(offset + remaining)].allSatisfy({ $0 == 0 }) else { throw invalid }
                offset += remaining; continue
            }
            var header = Cursor(Data(data[offset..<(offset + 7)]))
            let checksum = try header.fixed(4), length = Int(try header.fixed(2)), type = try header.fixed(1)
            if checksum == 0 && length == 0 && type == 0 {
                guard data[offset..<(offset + remaining)].allSatisfy({ $0 == 0 }) else { throw invalid }
                offset += remaining; continue
            }
            guard length <= remaining - 7 else { throw invalid }
            let fragment = Data(data[(offset + 7)..<(offset + 7 + length)])
            guard UInt64(maskedCRC(Data([UInt8(type)]) + fragment)) == checksum else { throw invalid }
            switch type {
            case 1: guard pending == nil else { throw invalid }; result.append(fragment)
            case 2: guard pending == nil else { throw invalid }; pending = fragment
            case 3: guard pending != nil else { throw invalid }; pending! += fragment
            case 4:
                guard var complete = pending else { throw invalid }
                complete += fragment; result.append(complete); pending = nil
            default: throw invalid
            }
            offset += 7 + length
        }
        guard pending == nil else { throw invalid }
        return result
    }

    static func logRecord(_ record: Data) -> Data {
        var result = Data(), offset = 0, first = true
        repeat {
            let available = 32_768 - result.count % 32_768
            if available < 7 { result += Data(repeating: 0, count: available); continue }
            let length = min(available - 7, record.count - offset), last = offset + length == record.count
            let type: UInt8 = first ? (last ? 1 : 2) : (last ? 4 : 3)
            let fragment = Data(record[offset..<(offset + length)])
            result += fixed(UInt64(maskedCRC(Data([type]) + fragment)), 4) + fixed(UInt64(length), 2) + Data([type]) + fragment
            offset += length; first = false
        } while offset < record.count
        return result
    }

    static func tableEntries(_ table: Data) throws -> [(Data, Data)] {
        guard table.count >= 48 else { throw invalid }
        var magic = Cursor(Data(table.suffix(8)))
        guard try magic.fixed(8) == 0xdb4775248b80fb57 else { throw invalid }
        var footer = Cursor(Data(table[(table.count - 48)..<(table.count - 8)]))
        _ = try footer.varint(); _ = try footer.varint()
        let indexOffset = try footer.varint(), indexSize = try footer.varint()
        var result: [(Data, Data)] = [], seen = Set<UInt64>(), expanded = 0
        for (_, handle) in try blockEntries(block(table, offset: indexOffset, size: indexSize)) {
            var input = Cursor(handle); let offset = try input.varint(), size = try input.varint()
            guard input.done, seen.insert(offset).inserted else { throw invalid }
            let data = try block(table, offset: offset, size: size)
            expanded += data.count
            guard expanded <= limit else { throw invalid }
            result += try blockEntries(data)
        }
        return result
    }

    static func block(_ table: Data, offset: UInt64, size: UInt64) throws -> Data {
        guard offset <= table.count, size <= table.count, offset + size + 5 <= table.count - 48 else { throw invalid }
        let start = Int(offset), end = start + Int(size), compressed = Data(table[start..<end]), type = table[end]
        var input = Cursor(Data(table[(end + 1)..<(end + 5)]))
        guard try input.fixed(4) == UInt64(maskedCRC(compressed + Data([type]))) else { throw invalid }
        if type == 0 { return compressed }
        guard type == 1, let decoded = DesktopProfile.snappy(Array(compressed)[...]) else { throw invalid }
        return Data(decoded)
    }

    static func blockEntries(_ block: Data) throws -> [(Data, Data)] {
        guard block.count >= 8 else { throw invalid }
        var tail = Cursor(Data(block.suffix(4))); let count = Int(try tail.fixed(4))
        guard count > 0, count <= (block.count - 4) / 4 else { throw invalid }
        let end = block.count - 4 - count * 4
        var restarts = Cursor(Data(block[end..<(block.count - 4)])), positions = Set<Int>()
        for index in 0..<count {
            let position = Int(try restarts.fixed(4))
            guard position <= end, index != 0 || position == 0, positions.insert(position).inserted else { throw invalid }
        }
        var input = Cursor(Data(block.prefix(end))), previous = Data(), result: [(Data, Data)] = []
        while !input.done {
            let restart = positions.remove(input.offset) != nil
            let shared = Int(try input.varint()), extra = Int(try input.varint()), length = Int(try input.varint())
            guard shared <= previous.count, !restart || shared == 0 else { throw invalid }
            let key = Data(previous.prefix(shared)) + (try input.take(extra)), value = try input.take(length)
            result.append((key, value)); previous = key
        }
        guard positions.isEmpty || end == 0 && positions == [0] else { throw invalid }
        return result
    }

    struct Cursor {
        let data: Data
        var offset = 0
        init(_ data: Data) { self.data = data }
        var done: Bool { offset == data.count }
        mutating func take(_ length: Int) throws -> Data {
            guard length >= 0, offset <= data.count, length <= data.count - offset else { throw invalid }
            defer { offset += length }; return Data(data[offset..<(offset + length)])
        }
        mutating func fixed(_ width: Int) throws -> UInt64 {
            try take(width).enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
        }
        mutating func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                let byte = try fixed(1)
                guard shift < 63 || byte <= 1 else { throw invalid }
                value |= (byte & 127) << shift
                if byte < 128 { guard value <= UInt64(Int.max) else { throw invalid }; return value }
            }
            throw invalid
        }
        mutating func bytes() throws -> Data { let count = Int(try varint()); return try take(count) }
    }
    static func fixed(_ value: UInt64, _ width: Int) -> Data { Data((0..<width).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    static func varint(_ value: UInt64) -> Data {
        var value = value, data = Data()
        while value >= 128 { data.append(UInt8(value & 127) | 128); value >>= 7 }
        data.append(UInt8(value)); return data
    }
    static func bytes(_ value: Data) -> Data { varint(UInt64(value.count)) + value }
    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 0 ? value >> 1 : (value >> 1) ^ 0x82f63b78 }
        return value
    }
    static func maskedCRC(_ data: Data) -> UInt32 {
        let crc = ~data.reduce(UInt32.max) { ($0 >> 8) ^ crcTable[Int(($0 ^ UInt32($1)) & 255)] }
        return ((crc >> 15) | (crc << 17)) &+ 0xa282ead8
    }
}
