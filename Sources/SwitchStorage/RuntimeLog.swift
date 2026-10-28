import Foundation
import Darwin
import OSLog
import SwitchCore

public enum RuntimeLogContext {
    @TaskLocal public static var operationID: UUID?
}

/// Only typed fields cross this boundary. Error descriptions and userInfo are never recorded.
public struct RuntimeFailure: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case blocked, malformed, missing, changed, busy, decoding, encoding, cocoa, posix, osstatus, other
        case unsafePath = "unsafe-path"
    }
    public let kind: Kind
    public let code: Int?
    public init(_ error: Error) {
        var errorKind: Kind, numericCode: Int?
        if let error = error as? SwitchError {
            switch error {
            case .blocked: errorKind = .blocked
            case .malformed: errorKind = .malformed
            case .missing: errorKind = .missing
            case .unsafePath: errorKind = .unsafePath
            case .changed: errorKind = .changed
            case .busy: errorKind = .busy
            }
        } else if error is DecodingError { errorKind = .decoding }
        else if error is EncodingError { errorKind = .encoding }
        else {
            let value = error as NSError
            switch value.domain {
            case NSCocoaErrorDomain: errorKind = .cocoa; numericCode = value.code
            case NSPOSIXErrorDomain: errorKind = .posix; numericCode = value.code
            case NSOSStatusErrorDomain: errorKind = .osstatus; numericCode = value.code
            default: errorKind = .other
            }
        }
        kind = errorKind; code = numericCode
    }
    public var description: String { kind.rawValue + (code.map { ":\($0)" } ?? "") }
}

/// One actor owns append, rotation and export. The app is the only file-log producer;
/// switch-inspect, demo mode and tests leave the shared file sink disabled.
public actor RuntimeLog {
    public enum Level: String, Codable, Sendable { case info, warning, error }
    public enum Component: String, Codable, Sendable { case app, operation, storage, startup, usage, update, diagnostics }
    public enum Event: String, Codable, Sendable {
        case appStarted, appStopped, operationStarted, operationCompleted, failed, fileSinkFailed, rollbackStarted, rollbackCompleted, rollbackFailed
        case validationFailed, bindingReused, phaseStarted, exportStarted, exportCompleted, recoveryStarted, recoveryCompleted
    }
    public enum Source: String, Codable, Sendable { case conversationPresentation, conversationHistory, levelDBSnapshot }
    public enum Check: String, Codable, Sendable { case format, sessionIdentity, historyBinding, filePath, fileDigest, representation }
    public enum Detail: String, Codable, Sendable {
        case unauthorized, forbidden, missingScopes, invalidCredentials, ambiguousCredentials, identityMismatch, offline, server, invalidResponse, keychain
    }
    public enum Stage: String, Codable, Sendable {
        case validatingPlan = "validating-plan", loadingTargetLogin = "loading-target-login", validatingConversations = "validating-conversations"
        case quittingClaude = "quitting-claude", validatingStoppedLogin = "validating-stopped-login", savingLogin = "saving-login"
        case savingSourceLogin = "saving-source-login", creatingTransaction = "creating-transaction", readingLocalStorage = "reading-local-storage"
        case preparingConversationPresentation = "preparing-conversation-presentation", readingTargetConversations = "reading-target-conversations"
        case restoringTargetPresentation = "restoring-target-presentation", mergingConversationPresentation = "merging-conversation-presentation"
        case restoringTransferredPresentation = "restoring-transferred-presentation", stagingLogin = "staging-login", stagingLoginConfig = "staging-login-config"
        case revalidatingConversations = "revalidating-conversations", stagingConversations = "staging-conversations", reopeningClaude = "reopening-claude", applying, committing
    }
    struct Entry: Codable, Sendable {
        var schema = 1
        var timestamp: Date
        var runID: UUID
        var sequence: UInt64
        var version: String
        var build: String
        var buildID: String
        var level: Level
        var component: Component
        var event: Event
        var operationID: UUID?
        var stage: Stage?
        var failure: RuntimeFailure?
        var source: Source?
        var line: UInt?
        var check: Check?
        var detail: Detail?
    }
    struct Report: Codable {
        var schema = 1
        var exportedAt: Date
        var version: String
        var build: String
        var buildID: String
        var macOS: String
        var architecture: String
        var incomplete: Bool
        var events: [Entry]
    }
    public static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Claude Switch")
    public static let shared = RuntimeLog(directory: directory)
    private static let system = Logger(subsystem: "dev.claudeswitch.desktop", category: "runtime")
    private let directory: URL
    private let maximumBytes: Int
    private let fileCount: Int
    private let runID = UUID()
    private var sequence: UInt64 = 0
    private var version = "unknown", build = "unknown", buildID = "unknown"
    private var enabled = false
    private var writeFailed = false
    private var historyIncomplete = false

    public init(directory: URL, maximumBytes: Int = 1024 * 1024, fileCount: Int = 5) {
        precondition(maximumBytes >= 1024 && (1...10).contains(fileCount))
        self.directory = directory; self.maximumBytes = maximumBytes; self.fileCount = fileCount
    }
    @discardableResult public func start(version: String, build: String, buildID: String = "unknown") -> Bool {
        guard !enabled else { return !writeFailed }
        self.version = Self.versionField(version); self.build = Self.versionField(build); self.buildID = Self.buildField(buildID); enabled = true
        return record(.appStarted, component: .app)
    }
    private static func versionField(_ value: String) -> String {
        !value.isEmpty && value.count <= 32 && value.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) ? value : "unknown"
    }
    private static func buildField(_ value: String) -> String {
        value.count == 64 && value.allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains(String($0))) }) ? value : "unknown"
    }
    private func file(_ index: Int) -> URL {
        directory.appendingPathComponent(index == 0 ? "runtime.jsonl" : "runtime.\(index).jsonl")
    }
    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
    @discardableResult public func record(_ event: Event, component: Component, level: Level = .info,
        operationID: UUID? = RuntimeLogContext.operationID, stage: Stage? = nil, failure: RuntimeFailure? = nil,
        source: Source? = nil, line: UInt? = nil, check: Check? = nil, detail: Detail? = nil) -> Bool {
        sequence += 1
        let entry = Entry(timestamp: Date(), runID: runID, sequence: sequence, version: version, build: build, buildID: buildID,
            level: level, component: component, event: event, operationID: operationID, stage: stage,
            failure: failure, source: source, line: line, check: check, detail: detail)
        guard let encoded = try? encoder().encode(entry) else { return false }
        let text = String(decoding: encoded, as: UTF8.self)
        switch level {
        case .info: Self.system.info("\(text, privacy: .public)")
        case .warning: Self.system.warning("\(text, privacy: .public)")
        case .error: Self.system.error("\(text, privacy: .public)")
        }
        guard enabled else { return true }
        do {
            var data = encoded; data.append(10)
            guard data.count <= maximumBytes else { throw SwitchError.changed }
            try SafeFiles.privateDirectory(directory)
            if FileManager.default.fileExists(atPath: file(0).path) {
                let handle = FileHandle(fileDescriptor: try SafeFiles.openRead(file(0)), closeOnDealloc: true)
                let size = try SafeFiles.stamp(handle.fileDescriptor).size
                var partial = false
                if size > 0 {
                    try handle.seek(toOffset: UInt64(size - 1)); partial = try handle.read(upToCount: 1) != Data([10])
                }
                try handle.close()
                if size + Int64(data.count) > maximumBytes || partial { try rotate() }
            }
            let destination = file(0); try SafeFiles.validateAncestors(destination)
            let creating = !FileManager.default.fileExists(atPath: destination.path)
            let fd = open(destination.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw SwitchError.unsafePath }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            guard fchmod(fd, 0o600) == 0 else { throw SwitchError.unsafePath }
            try handle.write(contentsOf: data); try handle.synchronize()
            if creating { try SafeFiles.syncDirectory(directory) }
            writeFailed = false
            return true
        } catch {
            writeFailed = true; historyIncomplete = true; sequence += 1
            var failed = entry
            failed.sequence = sequence; failed.component = .diagnostics; failed.event = .fileSinkFailed
            failed.level = .error; failed.failure = RuntimeFailure(error)
            if let data = try? encoder().encode(failed) {
                let text = String(decoding: data, as: UTF8.self)
                Self.system.error("\(text, privacy: .public)")
            }
            return false
        }
    }
    private func rotate() throws {
        for index in (0..<fileCount).reversed() {
            let source = file(index)
            try SafeFiles.validateAncestors(source)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let handle = FileHandle(fileDescriptor: try SafeFiles.openRead(source), closeOnDealloc: true)
            let oversized = try SafeFiles.stamp(handle.fileDescriptor).size > maximumBytes
            try handle.close()
            if oversized { historyIncomplete = true }
            if index == fileCount - 1 || oversized { try FileManager.default.removeItem(at: source) }
            else {
                let target = file(index + 1); try SafeFiles.validateAncestors(target)
                try FileManager.default.moveItem(at: source, to: target)
            }
        }
        try SafeFiles.syncDirectory(directory)
    }
    public static func validation(_ source: Source, check: Check = .representation, line: UInt = #line) {
        let operationID = RuntimeLogContext.operationID
        Task { await shared.record(.validationFailed, component: .storage, level: .error,
            operationID: operationID, source: source, line: line, check: check) }
    }
    public static func failure(_ error: Error, component: Component) {
        let failure = RuntimeFailure(error), operationID = RuntimeLogContext.operationID
        Task { await shared.record(.failed, component: component, level: .error, operationID: operationID, failure: failure) }
    }
    /// Decode and re-encode only the typed schema. Foreign fields and arbitrary text never enter an export.
    public func export() throws -> Data {
        guard enabled else { throw SwitchError.blocked(L10n.tr("Could not export diagnostics.")) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var events: [Entry] = [], incomplete = writeFailed || historyIncomplete
        for index in (0..<fileCount).reversed() {
            let source = file(index)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let data: Data
            do { data = try SafeFiles.read(source, limit: maximumBytes) }
            catch { incomplete = true; continue }
            for line in data.split(separator: 10) {
                guard var entry = try? decoder.decode(Entry.self, from: Data(line)), entry.schema == 1 else { incomplete = true; continue }
                entry.version = Self.versionField(entry.version); entry.build = Self.versionField(entry.build)
                entry.buildID = Self.buildField(entry.buildID)
                events.append(entry)
            }
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        return try encoder().encode(Report(exportedAt: Date(), version: version, build: build, buildID: buildID,
            macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", architecture: architecture, incomplete: incomplete, events: events))
    }
}
