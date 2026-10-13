import Foundation
import SwitchCore

/// Reads the account email that claude.ai caches in Claude Desktop's IndexedDB (the persisted query cache
/// holds `account { uuid, email_address, … }`). Values are V8-serialized and usually Snappy-compressed.
public enum DesktopProfile {
    public static let blobDirectory = "IndexedDB/https_claude.ai_0.indexeddb.blob"

    public static func files(desktop: URL) -> [URL] {
        files(under: desktop.appendingPathComponent(blobDirectory), depth: 0)
    }
    public struct Cache: Equatable, Sendable {
        /// Account UUID → email.
        public var emails: [String: String] = [:]
        /// Organization UUID → plan label such as "Pro" or "Max 20x".
        public var plans: [String: String] = [:]
        /// Organization UUID → when its tier record was written, whether or not it maps to a plan label.
        /// An unmapped record still outranks an older file's label, so a downgrade is not hidden behind a stale "Pro".
        public var observedAt: [String: Date] = [:]
        /// Organization UUID → reset times the server stated while a limit was near or hit.
        public var limits: [String: [ResetHint]] = [:]
        public init() {}
        /// `other` must be older than everything merged so far.
        public mutating func merge(_ other: Cache) {
            emails.merge(other.emails) { current, _ in current }
            for (org, date) in other.observedAt where observedAt[org] == nil {
                observedAt[org] = date; plans[org] = other.plans[org]
            }
            limits.merge(other.limits) { current, _ in current }
        }
    }

    /// Newest files first: old blobs can outlive a plan change.
    public static func read(files: [URL]) -> Cache {
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        var result = Cache()
        for file in files.sorted(by: { modified($0) > modified($1) }) {
            guard let data = try? SafeFiles.read(file, limit: 32 * 1024 * 1024) else { continue }
            result.merge(read(data, observedAt: modified(file)))
        }
        return result
    }

    /// Chromium names blob files by an increasing hex blob number; used where no modification date survives.
    public static func blobNumber(_ path: String) -> Int {
        path.split(separator: "/").last.flatMap { Int($0, radix: 16) } ?? -1
    }

    /// Each value is paired only with the `uuid` of the object that holds it: the account for
    /// `email_address`, the organization for `capabilities` and `rate_limit_tier`.
    public static func read(_ raw: Data, observedAt: Date) -> Cache {
        let bytes = [UInt8](raw)
        let value: [UInt8]
        if bytes.count > 3, bytes[0] == 0xFF, bytes[1] == 0x11, bytes[2] == 0x02 {
            guard let inflated = snappy(bytes[3...]) else { return Cache() }
            value = inflated
        } else { value = bytes }
        var result = Cache()
        let emailKey = oneByteString("email_address")
        var index = 0
        while let keyAt = find(emailKey, in: value, from: index) {
            index = keyAt + emailKey.count
            guard let email = readOneByteString(value, at: index), isEmail(email),
                  let id = owner(of: keyAt, in: value, within: 512) else { continue }
            if result.emails[id] == nil { result.emails[id] = email }
        }
        let tierKey = oneByteString("rate_limit_tier"), capabilitiesKey = oneByteString("capabilities")
        index = 0
        while let keyAt = find(tierKey, in: value, from: index) {
            index = keyAt + tierKey.count
            guard let org = owner(of: keyAt, in: value, within: 16 * 1024) else { continue }
            result.observedAt[org] = observedAt
            let tier = readOneByteString(value, at: index)
            var capabilities: [String] = []
            if let capAt = findLast(capabilitiesKey, in: value, from: max(0, keyAt - 512), before: keyAt) {
                var cursor = capAt + capabilitiesKey.count
                while cursor < keyAt {
                    if let text = readOneByteString(value, at: cursor) {
                        capabilities.append(text); cursor += 2 + text.utf8.count
                    } else { cursor += 1 }
                }
            }
            if result.plans[org] == nil, let plan = plan(tier: tier, capabilities: capabilities) { result.plans[org] = plan }
        }
        result.limits = messageLimits(value, observedAt: observedAt)
        return result
    }

    /// Maps the organization's rate-limit tier to a plan name; capabilities are the fallback when the tier is generic.
    public static func plan(tier: String?, capabilities: [String]) -> String? {
        let words = (tier ?? "").lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if let max = words.firstIndex(of: "max") {
            let next = words.indices.contains(max + 1) ? words[max + 1] : ""
            return next.last == "x" && Int(next.dropLast()) != nil ? "Max " + next : "Max"
        }
        for (word, label) in [("pro", "Pro"), ("team", "Team"), ("enterprise", "Enterprise")] where words.contains(word) {
            return label
        }
        for (capability, label) in [("claude_max", "Max"), ("claude_pro", "Pro")] where capabilities.contains(capability) {
            return label
        }
        return nil
    }

    private static func owner(of keyAt: Int, in value: [UInt8], within distance: Int) -> String? {
        let uuidKey = oneByteString("uuid")
        guard let uuidAt = findLast(uuidKey, in: value, from: max(0, keyAt - distance), before: keyAt),
              let uuid = readOneByteString(value, at: uuidAt + uuidKey.count) else { return nil }
        return UUID(uuidString: uuid)?.uuidString.lowercased()
    }

    private static func files(under url: URL, depth: Int) -> [URL] {
        guard depth <= 4, let children = try? SafeFiles.children(url) else { return [] }
        return children.flatMap { child -> [URL] in
            let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            return isDirectory ? files(under: child, depth: depth + 1) : [child]
        }
    }
    private static func oneByteString(_ text: String) -> [UInt8] { [0x22, UInt8(text.utf8.count)] + Array(text.utf8) }
    private static func readOneByteString(_ bytes: [UInt8], at index: Int) -> String? {
        guard index + 1 < bytes.count, bytes[index] == 0x22 else { return nil }
        let length = Int(bytes[index + 1])
        guard length < 0x80, index + 2 + length <= bytes.count else { return nil }
        return String(bytes: bytes[(index + 2)..<(index + 2 + length)], encoding: .isoLatin1)
    }
    private static func isEmail(_ text: String) -> Bool {
        text.range(of: #"^[^@\s"]+@[^@\s"]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil
    }
    private static func find(_ needle: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard bytes.count >= needle.count else { return nil }
        var i = start
        while i <= bytes.count - needle.count {
            if bytes[i..<(i + needle.count)].elementsEqual(needle) { return i }
            i += 1
        }
        return nil
    }
    private static func findLast(_ needle: [UInt8], in bytes: [UInt8], from start: Int, before end: Int) -> Int? {
        var i = end - needle.count
        while i >= start {
            if bytes[i..<(i + needle.count)].elementsEqual(needle) { return i }
            i -= 1
        }
        return nil
    }

    /// `current_account` → `messageLimits[<org>]`. The server only adds reset times while a limit is
    /// near or hit: `resetsAt` for `representativeClaim`, and `windows["5h" | "7d"].resets_at`.
    static func messageLimits(_ value: [UInt8], observedAt: Date) -> [String: [ResetHint]] {
        let key = oneByteString("messageLimits")
        var result: [String: [ResetHint]] = [:]
        var index = 0
        while let keyAt = find(key, in: value, from: index) {
            index = keyAt + key.count
            var fields: [String: [String: V8Scalar]] = [:]
            guard walkObject(value, at: index, visit: { path, scalar in
                guard let org = path.first.flatMap({ UUID(uuidString: $0)?.uuidString.lowercased() }) else { return }
                fields[org, default: [:]][path.dropFirst().joined(separator: ".")] = scalar
            }) else { continue }
            for (org, f) in fields where result[org] == nil {
                var hints: [ResetHint] = []
                func add(_ window: String, _ scalar: V8Scalar?) {
                    guard case .number(let n)? = scalar, let date = Dates.parse(.number(n)) else { return }
                    hints.append(ResetHint(windowID: window, resetsAt: date, seenAt: observedAt))
                }
                if case .string(let claim)? = f["representativeClaim"], ResetInference.lengths[claim] != nil {
                    add(claim, f["resetsAt"])
                }
                add("five_hour", f["windows.5h.resets_at"]); add("seven_day", f["windows.7d.resets_at"])
                result[org] = hints
            }
        }
        return result
    }

    enum V8Scalar: Equatable { case string(String), number(Double), bool(Bool), null }

    /// Walks one V8-serialized object starting at its `o` tag, reporting scalars by key path. Unknown tags
    /// (references, typed arrays, …) end the walk with `false` rather than guessing at the layout.
    static func walkObject(_ b: [UInt8], at start: Int, visit: ([String], V8Scalar) -> Void) -> Bool {
        enum Kind { case object, dense, sparse }
        struct Frame { var kind: Kind; var path: [String]; var key: String?; var index = 0 }
        guard start < b.count, b[start] == 0x6F else { return false }
        var i = start + 1, stack = [Frame(kind: .object, path: [], key: nil)], steps = 0
        func varint() -> Int? {
            var result = 0, shift = 0
            while i < b.count, shift < 35 {
                let byte = b[i]; i += 1
                result |= Int(byte & 0x7F) << shift; shift += 7
                if byte < 0x80 { return result }
            }
            return nil
        }
        func scalar() -> V8Scalar? {
            guard i < b.count else { return nil }
            let tag = b[i]; i += 1
            switch tag {
            case 0x22: // one-byte string
                guard let n = varint(), i + n <= b.count else { return nil }
                defer { i += n }; return .string(String(bytes: b[i..<(i + n)], encoding: .isoLatin1) ?? "")
            case 0x63: // two-byte string
                guard let n = varint(), i + n <= b.count else { return nil }
                defer { i += n }; return .string(String(bytes: b[i..<(i + n)], encoding: .utf16LittleEndian) ?? "")
            case 0x49: guard let z = varint() else { return nil }; return .number(Double((z >> 1) ^ -(z & 1)))
            case 0x55: return varint().map { .number(Double($0)) }
            case 0x4E:
                guard i + 8 <= b.count else { return nil }
                defer { i += 8 }
                return .number(Double(bitPattern: b[i..<(i + 8)].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }))
            case 0x54: return .bool(true)
            case 0x46: return .bool(false)
            case 0x30, 0x5F: return .null
            default: i -= 1; return nil
            }
        }
        while var top = stack.last {
            steps += 1
            guard steps < 20_000, i < b.count else { return false }
            let tag = b[i]
            let ends = (top.kind == .object && tag == 0x7B) || (top.kind == .dense && tag == 0x24) || (top.kind == .sparse && tag == 0x40)
            if ends && top.key == nil {
                i += 1
                guard varint() != nil, top.kind == .object || varint() != nil else { return false }
                stack.removeLast()
                if stack.isEmpty { return true }
                stack[stack.count - 1].key = nil; stack[stack.count - 1].index += 1
                continue
            }
            if top.kind != .dense && top.key == nil {
                switch scalar() {
                case .string(let s)?: top.key = s
                case .number(let n)? where n.isFinite && abs(n) < 1e15: top.key = String(Int(n))
                default: return false
                }
                stack[stack.count - 1] = top
                continue
            }
            let path = top.path + [top.key ?? String(top.index)]
            switch tag {
            case 0x6F: i += 1; stack.append(Frame(kind: .object, path: path, key: nil))
            case 0x41, 0x61:
                i += 1
                guard varint() != nil else { return false }
                stack.append(Frame(kind: tag == 0x41 ? .dense : .sparse, path: path, key: nil))
            default:
                guard let value = scalar() else { return false }
                visit(path, value)
                stack[stack.count - 1].key = nil; stack[stack.count - 1].index += 1
            }
        }
        return false
    }

    /// Raw Snappy block decoder; returns nil on any malformed or oversized input.
    static func snappy(_ input: ArraySlice<UInt8>) -> [UInt8]? {
        let bytes = Array(input)
        var i = 0, length = 0, shift = 0
        while true {
            guard i < bytes.count, shift <= 28 else { return nil }
            let b = bytes[i]; i += 1
            length |= Int(b & 0x7F) << shift; shift += 7
            if b < 0x80 { break }
        }
        guard length <= 64 * 1024 * 1024 else { return nil }
        var out = [UInt8](); out.reserveCapacity(length)
        while i < bytes.count {
            let tag = bytes[i]; i += 1
            switch tag & 3 {
            case 0:
                var count = Int(tag >> 2)
                if count >= 60 {
                    let extra = count - 59
                    guard i + extra <= bytes.count else { return nil }
                    count = 0
                    for k in 0..<extra { count |= Int(bytes[i + k]) << (8 * k) }
                    i += extra
                }
                count += 1
                guard i + count <= bytes.count, out.count + count <= length else { return nil }
                out.append(contentsOf: bytes[i..<(i + count)]); i += count
            default:
                let count: Int, offset: Int
                switch tag & 3 {
                case 1:
                    guard i < bytes.count else { return nil }
                    count = Int((tag >> 2) & 7) + 4; offset = Int(tag >> 5) << 8 | Int(bytes[i]); i += 1
                case 2:
                    guard i + 2 <= bytes.count else { return nil }
                    count = Int(tag >> 2) + 1; offset = Int(bytes[i]) | Int(bytes[i + 1]) << 8; i += 2
                default:
                    guard i + 4 <= bytes.count else { return nil }
                    count = Int(tag >> 2) + 1
                    offset = Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24; i += 4
                }
                guard offset > 0, offset <= out.count, out.count + count <= length else { return nil }
                let start = out.count - offset
                for k in 0..<count { out.append(out[start + k]) }
            }
        }
        return out.count == length ? out : nil
    }
}
