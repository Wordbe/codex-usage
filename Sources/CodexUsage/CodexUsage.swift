import AppKit
import Darwin
import Foundation

let appVersion = "0.1.4"
let usageCacheMaxAge: TimeInterval = 30
let usageSyncInterval: TimeInterval = 60
let usageMenuDisplayMaxAge: TimeInterval = usageSyncInterval * 2 + usageCacheMaxAge
let usageStaleFallbackMaxAge: TimeInterval = 6 * 60 * 60

struct RateLimitWindow: Codable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: TimeInterval?
}

struct CreditsSnapshot: Codable {
    let hasCredits: Bool?
    let unlimited: Bool?
    let balance: String?
}

struct RateLimitSnapshot: Codable {
    let limitId: String?
    let limitName: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
    let credits: CreditsSnapshot?
    let planType: String?
    let rateLimitReachedType: String?
}

struct AccountRateLimitsResponse: Decodable {
    let rateLimits: RateLimitSnapshot
    let rateLimitsByLimitId: [String: RateLimitSnapshot]?
}

struct SessionRateLimitWindow: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case windowDurationMins = "window_minutes"
        case resetsAt = "resets_at"
    }

    var rateLimitWindow: RateLimitWindow {
        RateLimitWindow(usedPercent: usedPercent, windowDurationMins: windowDurationMins, resetsAt: resetsAt)
    }
}

struct SessionRateLimitSnapshot: Decodable {
    let limitId: String?
    let limitName: String?
    let primary: SessionRateLimitWindow?
    let secondary: SessionRateLimitWindow?
    let credits: CreditsSnapshot?
    let planType: String?
    let rateLimitReachedType: String?

    enum CodingKeys: String, CodingKey {
        case limitId = "limit_id"
        case limitName = "limit_name"
        case primary
        case secondary
        case credits
        case planType = "plan_type"
        case rateLimitReachedType = "rate_limit_reached_type"
    }

    func usageSnapshot(source: String, fetchedAt: Date) -> UsageSnapshot {
        UsageSnapshot(
            source: source,
            planType: planType,
            primary: primary?.rateLimitWindow,
            secondary: secondary?.rateLimitWindow,
            credits: credits,
            rateLimitReachedType: rateLimitReachedType,
            fetchedAt: fetchedAt
        )
    }
}

struct SessionEventPayload: Decodable {
    let type: String?
    let rateLimits: SessionRateLimitSnapshot?

    enum CodingKeys: String, CodingKey {
        case type
        case rateLimits = "rate_limits"
    }
}

struct SessionLogEvent: Decodable {
    let timestamp: String?
    let type: String
    let payload: SessionEventPayload?
}

struct SessionRateLimitRead {
    let snapshot: UsageSnapshot
    let timestamp: String?
    let path: String
}

struct UsageSnapshot: Codable {
    let source: String
    let planType: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
    let credits: CreditsSnapshot?
    let rateLimitReachedType: String?
    let fetchedAt: Date
    var account: UsageAccount? = nil

    var displayPercent: Double {
        usedPercent
    }

    var usedPercent: Double {
        fiveHourWindow?.usedPercent ?? 0
    }

    var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }

    var fiveHourWindow: RateLimitWindow? {
        [primary, secondary].compactMap { $0 }.first { $0.windowDurationMins == 300 }
    }

    var weeklyWindow: RateLimitWindow? {
        [primary, secondary].compactMap { $0 }.first { $0.windowDurationMins == 10080 }
    }
}

enum UsageError: Error, CustomStringConvertible {
    case codexNotFound
    case timeout
    case processLaunch(String)
    case rpc(String)
    case malformedResponse
    case accountChanged

    var description: String {
        switch self {
        case .codexNotFound:
            return "Codex CLI was not found. Set CODEXUSAGE_CODEX_PATH or install Codex."
        case .timeout:
            return "Timed out while reading Codex rate limits."
        case .processLaunch(let message):
            return "Failed to launch Codex: \(message)"
        case .rpc(let message):
            return message
        case .malformedResponse:
            return "Codex returned an unexpected rate-limit response."
        case .accountChanged:
            return "ChatGPT account changed while fetching usage. Refresh again."
        }
    }
}

final class CodexUsageFetcher: @unchecked Sendable {
    private let requestID = 3

    func fetch(timeout: TimeInterval = 20) throws -> UsageSnapshot {
        let context = try AccountContext.current()
        guard let codexPath = findCodexExecutable() else {
            throw UsageError.codexNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = ["-c", "cli_auth_credentials_store=\"file\"", "app-server"]
        process.environment = mergedEnvironment()

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw UsageError.processLaunch(error.localizedDescription)
        }

        let initMessage: [String: Any] = [
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": [
                    "name": "codexusage",
                    "title": "Codex Usage",
                    "version": appVersion
                ],
                "capabilities": [
                    "experimentalApi": true,
                    "requestAttestation": false,
                    "optOutNotificationMethods": []
                ]
            ]
        ]
        let rateLimitMessage: [String: Any] = [
            "id": requestID,
            "method": "account/rateLimits/read"
        ]
        let rateLimitData = Self.jsonLine(rateLimitMessage)

        input.fileHandleForWriting.write(Self.jsonLine(initMessage))
        defer {
            if process.isRunning {
                process.terminate()
            }
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }

        var buffer = Data()
        var sentRateLimitRequest = false
        var account: UsageAccount?
        let deadline = Date().addingTimeInterval(timeout)
        let stdoutFD = output.fileHandleForReading.fileDescriptor

        while Date() < deadline {
            let remainingMs = max(1, Int32(deadline.timeIntervalSinceNow * 1000))
            var pollFD = pollfd(fd: stdoutFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollFD, 1, remainingMs)
            if ready < 0 {
                if errno == EINTR {
                    continue
                }
                throw UsageError.malformedResponse
            }
            if ready == 0 {
                break
            }

            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(stdoutFD, &bytes, bytes.count)
            if count < 0 {
                if errno == EINTR || errno == EAGAIN {
                    continue
                }
                throw UsageError.malformedResponse
            }
            if count == 0 {
                break
            }
            buffer.append(contentsOf: bytes.prefix(count))
            while let newline = buffer.firstIndex(of: 0x0a) {
                let data = buffer[..<newline]
                guard let line = String(data: data, encoding: .utf8) else { throw UsageError.malformedResponse }
                buffer.removeSubrange(...newline)
                if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                if Self.responseID(line) == 1, !sentRateLimitRequest {
                    sentRateLimitRequest = true
                    _ = try Self.responseResult(line)
                    input.fileHandleForWriting.write(Self.jsonLine(["method": "initialized"]))
                    input.fileHandleForWriting.write(Self.jsonLine([
                        "id": 2, "method": "account/read", "params": ["refreshToken": false]
                    ]))
                    continue
                }
                if Self.responseID(line) == 2 {
                    let result = try Self.responseResult(line)
                    guard let info = result["account"] as? [String: Any], info["type"] as? String == "chatgpt" else {
                        throw UsageError.rpc("Sign in with a ChatGPT account to read quota.")
                    }
                    let email = info["email"] as? String
                    if let expected = context.email, let email, email != expected { throw UsageError.accountChanged }
                    try context.requireCurrent()
                    account = UsageAccount(key: context.key, email: email, planType: info["planType"] as? String)
                    input.fileHandleForWriting.write(rateLimitData)
                    continue
                }
                if let parsed = Self.parseRateLimitLine(line, expectedID: requestID) {
                    switch parsed {
                    case .success(var snapshot):
                        guard let account else { throw UsageError.malformedResponse }
                        try context.requireCurrent()
                        snapshot.account = account
                        return snapshot
                    case .failure(let error):
                        throw error
                    }
                }
            }
        }

        throw UsageError.timeout
    }

    private static func jsonLine(_ object: [String: Any]) -> Data {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [])
        var line = data
        line.append(0x0a)
        return line
    }

    private static func responseResult(_ line: String) throws -> [String: Any] {
        guard let data = line.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.malformedResponse
        }
        if let error = object["error"] as? [String: Any] {
            throw UsageError.rpc(error["message"] as? String ?? "Codex request failed.")
        }
        guard let result = object["result"] as? [String: Any] else { throw UsageError.malformedResponse }
        return result
    }

    private static func parseRateLimitLine(_ line: String, expectedID: Int) -> Result<UsageSnapshot, Error>? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? Int,
              id == expectedID else {
            return nil
        }

        if let error = object["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? "Codex rate-limit request failed."
            return .failure(UsageError.rpc(message))
        }

        guard let result = object["result"] as? [String: Any],
              let resultData = try? JSONSerialization.data(withJSONObject: result, options: []) else {
            return .failure(UsageError.malformedResponse)
        }

        do {
            let decoded = try JSONDecoder().decode(AccountRateLimitsResponse.self, from: resultData)
            let selected = decoded.rateLimitsByLimitId?["codex"] ?? decoded.rateLimits
            return .success(UsageSnapshot(
                source: selected.limitId ?? decoded.rateLimits.limitId ?? "codex",
                planType: selected.planType,
                primary: selected.primary,
                secondary: selected.secondary,
                credits: selected.credits,
                rateLimitReachedType: selected.rateLimitReachedType,
                fetchedAt: Date()
            ))
        } catch {
            return .failure(UsageError.malformedResponse)
        }
    }

    private static func responseID(_ line: String) -> Int? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["id"] as? Int
    }
}

func userHomeDirectory() -> String {
    if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
        return home
    }
    return NSHomeDirectory()
}

func codexUsageRootDirectory() -> String {
    "\(userHomeDirectory())/.codexusage"
}

func mergedEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    let home = userHomeDirectory()
    let additions = [
        "/usr/local/bin",
        "/opt/homebrew/bin",
        "\(codexUsageRootDirectory())/bin",
        "\(home)/.local/bin",
        "\(home)/.nvm/versions/node/current/bin"
    ]
    let existing = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    var seen = Set<String>()
    let pathDirs = (additions + existing.split(separator: ":").map(String.init)).filter { dir in
        if dir.isEmpty || seen.contains(dir) {
            return false
        }
        seen.insert(dir)
        return true
    }
    env["PATH"] = pathDirs.joined(separator: ":")
    env["CODEX_HOME"] = AccountContext.codexHome
    return env
}

func findCodexExecutable() -> String? {
    let fm = FileManager.default
    if let override = ProcessInfo.processInfo.environment["CODEXUSAGE_CODEX_PATH"],
       fm.isExecutableFile(atPath: override),
       isUsableCodexExecutable(override) {
        return override
    }

    for app in ["/Applications/ChatGPT.app", "\(userHomeDirectory())/Applications/ChatGPT.app"] {
        let bundled = "\(app)/Contents/Resources/codex"
        if fm.isExecutableFile(atPath: bundled), isUsableCodexExecutable(bundled) { return bundled }
    }

    let pathDirs = (mergedEnvironment()["PATH"] ?? "").split(separator: ":").map(String.init)
    for dir in pathDirs {
        let candidate = "\(dir)/codex"
        if fm.isExecutableFile(atPath: candidate), isUsableCodexExecutable(candidate) {
            return candidate
        }
    }

    let nvmRoot = "\(userHomeDirectory())/.nvm/versions/node"
    if let versions = try? fm.contentsOfDirectory(atPath: nvmRoot).sorted().reversed() {
        for version in versions {
            let candidate = "\(nvmRoot)/\(version)/bin/codex"
            if fm.isExecutableFile(atPath: candidate), isUsableCodexExecutable(candidate) {
                return candidate
            }
        }
    }

    return nil
}

func isUsableCodexExecutable(_ path: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = ["--version"]
    process.environment = mergedEnvironment()

    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error

    do {
        try process.run()
    } catch {
        return false
    }

    let semaphore = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
        process.waitUntilExit()
        semaphore.signal()
    }
    if semaphore.wait(timeout: .now() + 4) == .timedOut {
        if process.isRunning {
            process.terminate()
        }
        return false
    }

    let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return process.terminationStatus == 0 && (stdout + stderr).contains("codex-cli")
}

func runSmallCommand(_ executable: String, args: [String], timeout: TimeInterval) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = args
    process.environment = mergedEnvironment()

    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()

    do {
        try process.run()
    } catch {
        return nil
    }

    let semaphore = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
        process.waitUntilExit()
        semaphore.signal()
    }
    if semaphore.wait(timeout: .now() + timeout) == .timedOut {
        if process.isRunning {
            process.terminate()
        }
        return nil
    }

    let data = output.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func renderTerminalBar(_ percent: Double, width: Int = 12) -> String {
    let clamped = max(0, min(100, percent))
    let exact = clamped / 100.0 * Double(width)
    let fullCells = min(width, Int(exact))
    let partial = Int(((exact - Double(fullCells)) * 8).rounded())
    let partialBlocks = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]

    var cells = [String]()
    cells.append(contentsOf: Array(repeating: "█", count: fullCells))

    if cells.count < width {
        if partial > 0 {
            cells.append(partialBlocks[min(partial, partialBlocks.count - 1)])
        } else if clamped > 0 {
            cells.append("▏")
        }
    }

    if cells.count < width {
        cells.append(contentsOf: Array(repeating: "░", count: width - cells.count))
    }

    return cells.joined()
}

func formatPercent(_ percent: Double) -> String {
    "\(Int(percent.rounded()))%"
}

func formatReset(_ timestamp: TimeInterval?) -> String {
    guard let timestamp else { return "unknown" }
    let date = Date(timeIntervalSince1970: timestamp)
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

func statusLineText(_ snapshot: UsageSnapshot) -> String {
    guard snapshot.fiveHourWindow != nil else { return "5h quota unavailable" }
    return "\(formatPercent(snapshot.usedPercent)) used \(renderTerminalBar(snapshot.usedPercent))"
}

func snapshotUsesStatusSession(_ snapshot: UsageSnapshot, read: UsageRead?) -> Bool {
    read?.source == .statusSession || snapshot.source == "codex-status-session"
}

func resetMarkerProgress(for window: RateLimitWindow?, now: Date = Date()) -> Double? {
    guard let window, let resetsAt = window.resetsAt else {
        return nil
    }

    let durationSeconds = Double(window.windowDurationMins ?? 300) * 60
    guard durationSeconds > 0 else {
        return nil
    }

    let secondsUntilReset = Date(timeIntervalSince1970: resetsAt).timeIntervalSince(now)
    let elapsedSeconds = durationSeconds - secondsUntilReset
    return max(0, min(1, elapsedSeconds / durationSeconds))
}

enum UsageReadSource: Equatable {
    case statusSession
    case fresh
    case cache
    case staleCache

    var label: String {
        switch self {
        case .statusSession:
            return "status-session"
        case .fresh:
            return "fresh"
        case .cache:
            return "cache"
        case .staleCache:
            return "stale-cache"
        }
    }
}

struct UsageRead {
    let snapshot: UsageSnapshot
    let source: UsageReadSource
    let cacheSavedAt: Date?
    let fallbackError: String?
}

struct UsageCacheEnvelope: Codable {
    let version: Int
    let savedAt: Date
    let snapshot: UsageSnapshot
}

final class UsageCache: @unchecked Sendable {
    private let fm = FileManager.default
    let directory: String

    init(directory: String = "\(codexUsageRootDirectory())/cache/accounts") {
        self.directory = directory
    }

    var path: String {
        guard let context = try? AccountContext.current() else { return directory }
        return path(for: context.key)
    }

    func path(for key: String) -> String { "\(directory)/\(key).json" }

    func load(context: AccountContext, maxAge: TimeInterval? = nil) -> UsageCacheEnvelope? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path(for: context.key))),
              let envelope = try? JSONDecoder().decode(UsageCacheEnvelope.self, from: data),
              envelope.version == 2, envelope.snapshot.account?.key == context.key else { return nil }
        let age = Date().timeIntervalSince(envelope.savedAt)
        guard age >= -5 else { return nil }
        if let maxAge, age > maxAge { return nil }
        return envelope
    }

    func save(_ snapshot: UsageSnapshot) throws {
        guard let account = snapshot.account else { throw UsageError.malformedResponse }
        let envelope = UsageCacheEnvelope(version: 2, savedAt: Date(), snapshot: snapshot)
        let data = try JSONEncoder().encode(envelope)
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
        let url = URL(fileURLWithPath: path(for: account.key))
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

final class UsageService: @unchecked Sendable {
    private let fetcher = CodexUsageFetcher()
    let cache = UsageCache()

    func cached(maxAge: TimeInterval = usageStaleFallbackMaxAge) -> UsageRead? {
        guard let context = try? AccountContext.current(),
              let envelope = cache.load(context: context, maxAge: maxAge),
              (try? AccountContext.current().key) == context.key else { return nil }
        let source: UsageReadSource = Date().timeIntervalSince(envelope.savedAt) > usageCacheMaxAge ? .staleCache : .cache
        return UsageRead(snapshot: envelope.snapshot, source: source, cacheSavedAt: envelope.savedAt, fallbackError: nil)
    }

    func read(forceRefresh: Bool = false, maxAge: TimeInterval = usageCacheMaxAge) throws -> UsageRead {
        let context = try AccountContext.current()
        if !forceRefresh, let envelope = cache.load(context: context, maxAge: maxAge) {
            try context.requireCurrent()
            return UsageRead(snapshot: envelope.snapshot, source: .cache, cacheSavedAt: envelope.savedAt, fallbackError: nil)
        }
        do {
            let snapshot = try fetcher.fetch()
            try context.requireCurrent()
            guard snapshot.account?.key == context.key else { throw UsageError.accountChanged }
            try? cache.save(snapshot)
            return UsageRead(snapshot: snapshot, source: .fresh, cacheSavedAt: Date(), fallbackError: nil)
        } catch {
            try context.requireCurrent()
            if let envelope = cache.load(context: context, maxAge: usageStaleFallbackMaxAge) {
                return UsageRead(snapshot: envelope.snapshot, source: .staleCache,
                                 cacheSavedAt: envelope.savedAt, fallbackError: String(describing: error))
            }
            throw error
        }
    }
}

func latestSessionRateLimit(maxFiles: Int = 20) -> SessionRateLimitRead? {
    let fm = FileManager.default
    let root = "\(userHomeDirectory())/.codex/sessions"
    guard let enumerator = fm.enumerator(atPath: root) else { return nil }

    var files = [(path: String, modified: Date)]()
    for case let relativePath as String in enumerator where relativePath.hasSuffix(".jsonl") {
        let path = "\(root)/\(relativePath)"
        let modified = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
        files.append((path, modified))
    }

    files.sort { $0.modified > $1.modified }
    for file in files.prefix(maxFiles) {
        if let read = latestSessionRateLimit(in: file.path) {
            return read
        }
    }
    return nil
}

func latestSessionRateLimit(in path: String) -> SessionRateLimitRead? {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    let decoder = JSONDecoder()

    for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
        guard line.contains(#""rate_limits""#),
              line.contains(#""token_count""#),
              let data = String(line).data(using: .utf8),
              let event = try? decoder.decode(SessionLogEvent.self, from: data),
              event.type == "event_msg",
              event.payload?.type == "token_count",
              let rateLimits = event.payload?.rateLimits else {
            continue
        }
        let fetchedAt = parseSessionTimestamp(event.timestamp) ?? Date()
        return SessionRateLimitRead(
            snapshot: rateLimits.usageSnapshot(source: "codex-status-session", fetchedAt: fetchedAt),
            timestamp: event.timestamp,
            path: path
        )
    }
    return nil
}

func parseSessionTimestamp(_ timestamp: String?) -> Date? {
    guard let timestamp else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: timestamp) {
        return date
    }
    return ISO8601DateFormatter().date(from: timestamp)
}

func latestUsableSessionRateLimit() -> SessionRateLimitRead? {
    guard let read = latestSessionRateLimit() else {
        return nil
    }
    return isUsableStatusSessionSnapshot(read.snapshot, now: Date()) ? read : nil
}

func isUsableStatusSessionSnapshot(_ snapshot: UsageSnapshot, now: Date = Date()) -> Bool {
    guard let window = snapshot.fiveHourWindow,
          let resetsAt = window.resetsAt else {
        return false
    }

    let resetDate = Date(timeIntervalSince1970: resetsAt)
    guard resetDate > now else {
        return false
    }

    let durationSeconds = Double(window.windowDurationMins ?? 300) * 60
    guard durationSeconds > 0 else {
        return false
    }

    let age = now.timeIntervalSince(snapshot.fetchedAt)
    return age >= -5 && age <= durationSeconds
}

func formatSnapshotLine(label: String, snapshot: UsageSnapshot) -> String {
    let fiveHour = snapshot.fiveHourWindow.map { "\(formatPercent($0.usedPercent)) used, reset \(formatReset($0.resetsAt))" } ?? "unavailable"
    let weekly = snapshot.weeklyWindow.map { "\(formatPercent($0.usedPercent)) used" } ?? "unavailable"
    return "\(label): 5h \(fiveHour), weekly \(weekly)"
}

func diagnoseStatus() -> Int32 {
    let service = UsageService()
    do {
        let cachedBeforeRefresh = service.cached(maxAge: usageStaleFallbackMaxAge)
        let freshSnapshot = try CodexUsageFetcher().fetch()
        print(formatSnapshotLine(label: "App-server fresh", snapshot: freshSnapshot))
        print("  Source: account/rateLimits/read")
        print("  Field: rateLimitsByLimitId.codex.primary.usedPercent")
        print("  Synced: \(formatSyncTime(freshSnapshot.fetchedAt))")
        print("  Cache: \(service.cache.path)")

        if let cached = cachedBeforeRefresh {
            print(formatSnapshotLine(label: "Cache before refresh", snapshot: cached.snapshot))
            print("  Saved: \(formatSyncTime(cached.cacheSavedAt)) (age \(formatAge(cached.cacheSavedAt)))")
        } else {
            print("Cache before refresh: not found")
        }

        if let session = latestSessionRateLimit() {
            print(formatSnapshotLine(label: "Latest session token_count", snapshot: session.snapshot))
            print("  Timestamp: \(session.timestamp ?? "unknown")")
            print("  File: \(session.path)")
            print("  Diagnostic only: session ownership is not verified; never used for display.")
            let delta = freshSnapshot.usedPercent - session.snapshot.usedPercent
            if abs(delta) <= 1 {
                print("Compare: app-server and latest session agree within 1%.")
            } else {
                print("Compare: app-server differs from latest session by \(formatPercent(abs(delta))) used.")
            }
        } else {
            print("Latest session token_count: not found in ~/.codex/sessions")
        }

        let selected = try service.read(forceRefresh: true)
        print(formatSnapshotLine(label: "Default display", snapshot: selected.snapshot))
        print("  Source: \(selected.source.label)")
        print("Policy: account API first, menu sync every \(Int(usageSyncInterval))s, cache TTL \(Int(usageCacheMaxAge))s, stale fallback \(Int(usageStaleFallbackMaxAge / 3600))h")
        return 0
    } catch {
        fputs("\(String(describing: error))\n", stderr)
        return 1
    }
}

func formatSyncTime(_ date: Date?) -> String {
    guard let date else { return "unknown" }
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

func formatAge(_ date: Date?) -> String {
    guard let date else { return "unknown" }
    let seconds = max(0, Int(Date().timeIntervalSince(date).rounded()))
    if seconds < 60 {
        return "\(seconds)s"
    }
    let minutes = seconds / 60
    if minutes < 60 {
        return "\(minutes)m"
    }
    return "\(minutes / 60)h \(minutes % 60)m"
}

func jsonStatus(_ snapshot: UsageSnapshot, read: UsageRead? = nil) -> String {
    var object: [String: Any] = [
        "source": snapshot.source,
        "accountEmail": snapshot.account?.email ?? NSNull(),
        "accountKey": snapshot.account?.key ?? NSNull(),
        "planType": snapshot.planType ?? snapshot.account?.planType ?? NSNull(),
        "usedPercent": snapshot.fiveHourWindow?.usedPercent ?? NSNull(),
        "remainingPercent": snapshot.fiveHourWindow.map { max(0, min(100, 100 - $0.usedPercent)) } ?? NSNull(),
        "primaryUsedPercent": snapshot.primary?.usedPercent ?? NSNull(),
        "primaryRemainingPercent": snapshot.primary.map { max(0, min(100, 100 - $0.usedPercent)) } ?? NSNull(),
        "primaryWindowDurationMins": snapshot.primary?.windowDurationMins ?? NSNull(),
        "primaryResetsAt": snapshot.primary?.resetsAt ?? NSNull(),
        "secondaryUsedPercent": snapshot.secondary?.usedPercent ?? NSNull(),
        "secondaryWindowDurationMins": snapshot.secondary?.windowDurationMins ?? NSNull(),
        "secondaryResetsAt": snapshot.secondary?.resetsAt ?? NSNull(),
        "hasCredits": snapshot.credits?.hasCredits ?? NSNull(),
        "creditsBalance": snapshot.credits?.balance ?? NSNull(),
        "rateLimitReachedType": snapshot.rateLimitReachedType ?? NSNull(),
        "fetchedAt": ISO8601DateFormatter().string(from: snapshot.fetchedAt)
    ]
    if let read {
        object["dataSource"] = read.source.label
        object["cachePath"] = UsageCache().path
        object["cacheSavedAt"] = read.cacheSavedAt.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull()
        object["cacheAgeSeconds"] = read.cacheSavedAt.map { Date().timeIntervalSince($0) } ?? NSNull()
        object["cacheTtlSeconds"] = usageCacheMaxAge
        object["syncIntervalSeconds"] = usageSyncInterval
        object["fallbackError"] = read.fallbackError ?? NSNull()
    }
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    return String(data: data, encoding: .utf8)!
}

@MainActor
func makeMenuBarProgressImage(percent: Double?, label: String, markerProgress: Double?) -> NSImage {
    let size = NSSize(width: 52, height: 26)
    let image = NSImage(size: size)
    image.lockFocus()

    let white = NSColor.white
    let rect = NSRect(x: 5, y: 17, width: 42, height: 7.25)
    let track = NSBezierPath(roundedRect: rect, xRadius: 3.625, yRadius: 3.625)
    white.withAlphaComponent(0.20).setFill()
    track.fill()

    if let percent {
        let clamped = max(0, min(100, percent))
        if clamped > 0 {
            let fillWidth = max(2, rect.width * clamped / 100.0)
            let fillRect = NSRect(x: rect.minX, y: rect.minY, width: min(rect.width, fillWidth), height: rect.height)
            let fill = NSBezierPath(roundedRect: fillRect, xRadius: 3.625, yRadius: 3.625)
            white.setFill()
            fill.fill()
        }
    }

    white.withAlphaComponent(0.35).setStroke()
    track.lineWidth = 0.5
    track.stroke()

    if let markerProgress {
        let rawMarkerX = rect.minX + rect.width * max(0, min(1, markerProgress))
        let markerX = floor(rawMarkerX) + 0.5
        let marker = NSBezierPath()
        marker.move(to: NSPoint(x: markerX, y: rect.minY - 1.1))
        marker.line(to: NSPoint(x: markerX, y: rect.maxY + 1.1))
        marker.lineCapStyle = .round
        white.withAlphaComponent(0.68).setStroke()
        marker.lineWidth = 0.85
        marker.stroke()
    }

    let text = NSAttributedString(
        string: label,
        attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: white
        ]
    )
    let textSize = text.size()
    text.draw(at: NSPoint(x: max(0, (size.width - textSize.width) / 2), y: 2.25))

    image.unlockFocus()
    image.isTemplate = false
    return image
}

@MainActor
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let usageService = UsageService()
    private var timer: Timer?
    private var accountTimer: Timer?
    private var observedAccountKey: String?
    private var generation = 0
    private var latestSnapshot: UsageSnapshot?
    private var latestRead: UsageRead?
    private var latestError: String?
    private var isRefreshing = false

    func start() {
        observedAccountKey = try? AccountContext.current().key
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            applyMenuBarDisplay(percent: nil, title: "--%", tooltip: "Codex 5h usage is loading", markerProgress: nil)
        }
        rebuildMenu()
        installLaunchAgentIfAppropriate()
        installCLIHelperIfAppropriate()
        if let cached = usageService.cached(maxAge: usageCacheMaxAge) {
            latestSnapshot = cached.snapshot
            latestRead = cached
            updateTitle()
            rebuildMenu()
        }
        refresh(forceRefresh: false)
        timer = Timer.scheduledTimer(withTimeInterval: usageSyncInterval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refresh(forceRefresh: false)
            }
        }
        accountTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.checkAccount() }
        }
        if let accountTimer { RunLoop.main.add(accountTimer, forMode: .common) }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func checkAccount() {
        let key = try? AccountContext.current().key
        guard key != observedAccountKey else { return }
        observedAccountKey = key
        generation += 1
        isRefreshing = false
        latestSnapshot = nil
        latestRead = nil
        latestError = nil
        updateTitle()
        rebuildMenu()
        refresh(forceRefresh: true)
    }

    @objc func refreshNow() {
        refresh(forceRefresh: true)
    }

    private func refresh(forceRefresh: Bool) {
        guard !isRefreshing else { return }
        isRefreshing = true
        if latestSnapshot == nil {
            applyMenuBarDisplay(percent: nil, title: "...", tooltip: "Codex 5h usage is loading", markerProgress: nil)
        }

        let usageService = self.usageService
        let requestGeneration = generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let read = try usageService.read(forceRefresh: forceRefresh)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard requestGeneration == self.generation else { return }
                    guard read.snapshot.account?.key == (try? AccountContext.current().key) else {
                        self.isRefreshing = false
                        self.checkAccount()
                        return
                    }
                    self.latestSnapshot = read.snapshot
                    self.latestRead = read
                    self.latestError = nil
                    self.isRefreshing = false
                    self.updateTitle()
                    self.rebuildMenu()
                }
            } catch {
                let message = String(describing: error)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard requestGeneration == self.generation else { return }
                    if (try? AccountContext.current().key) != self.observedAccountKey {
                        self.isRefreshing = false
                        self.checkAccount()
                        return
                    }
                    self.latestError = message
                    self.isRefreshing = false
                    self.updateTitle()
                    self.rebuildMenu()
                }
            }
        }
    }

    private func updateTitle() {
        if let snapshot = latestSnapshot {
            guard snapshot.fiveHourWindow != nil else {
                applyMenuBarDisplay(percent: nil, title: "--%", tooltip: "\(snapshot.account?.email ?? "ChatGPT"): 5h quota unavailable", markerProgress: nil)
                return
            }
            let sourceLabel = latestRead?.source.label ?? "unknown"
            let snapshotDate = latestSnapshotDate(for: snapshot)
            if latestSnapshotIsTooStale(for: snapshot) {
                let lastValue = "last cached \(formatPercent(snapshot.usedPercent))"
                let errorText = latestError.map { "; \($0)" } ?? ""
                applyMenuBarDisplay(
                    percent: nil,
                    title: "--%",
                    tooltip: "Codex 5h usage is stale; \(lastValue); \(sourceLabel); synced \(formatSyncTime(snapshotDate))\(errorText)",
                    markerProgress: nil
                )
            } else {
                applyMenuBarDisplay(
                    percent: snapshot.usedPercent,
                    title: formatPercent(snapshot.usedPercent),
                    tooltip: "\(snapshot.account?.email ?? "ChatGPT"): Codex 5h used \(formatPercent(snapshot.usedPercent)); \(sourceLabel); synced \(formatSyncTime(snapshotDate))",
                    markerProgress: resetMarkerProgress(for: snapshot.fiveHourWindow)
                )
            }
        } else {
            applyMenuBarDisplay(
                percent: nil,
                title: "--%",
                tooltip: latestError ?? "Codex 5h usage unavailable",
                markerProgress: nil
            )
        }
    }

    private func applyMenuBarDisplay(percent: Double?, title: String, tooltip: String, markerProgress: Double?) {
        guard let button = statusItem.button else { return }
        button.image = makeMenuBarProgressImage(percent: percent, label: title, markerProgress: markerProgress)
        button.attributedTitle = NSAttributedString(string: "")
        button.toolTip = tooltip
    }

    private func latestSnapshotDate(for snapshot: UsageSnapshot) -> Date {
        latestRead?.cacheSavedAt ?? snapshot.fetchedAt
    }

    private func latestSnapshotIsTooStale(for snapshot: UsageSnapshot) -> Bool {
        if latestRead?.source == .staleCache {
            return true
        }
        guard latestRead?.source != .statusSession else {
            return !isUsableStatusSessionSnapshot(snapshot)
        }
        return Date().timeIntervalSince(latestSnapshotDate(for: snapshot)) > usageMenuDisplayMaxAge
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        if let snapshot = latestSnapshot {
            menu.addItem(infoItem("Account: \(snapshot.account?.email ?? "Email unavailable")", weight: .semibold))
            let isStale = latestSnapshotIsTooStale(for: snapshot)
            let titlePrefix = isStale ? "Cached Codex 5h Used" : "Codex 5h Used"
            let title = "\(titlePrefix) \(statusLineText(snapshot))"
            menu.addItem(infoItem(title, weight: .semibold))
            if snapshot.fiveHourWindow != nil {
                menu.addItem(infoItem("5h Remaining: \(formatPercent(snapshot.remainingPercent)) resets \(formatReset(snapshot.fiveHourWindow?.resetsAt))"))
            }
            if let secondary = snapshot.weeklyWindow {
                menu.addItem(infoItem("Weekly used: \(formatPercent(secondary.usedPercent)) resets \(formatReset(secondary.resetsAt))"))
            }
            if let planType = snapshot.planType ?? snapshot.account?.planType {
                menu.addItem(infoItem("Plan: \(planType)"))
            }
            menu.addItem(.separator())
            if snapshotUsesStatusSession(snapshot, read: latestRead) {
                menu.addItem(infoItem("Data: Codex /status session token_count"))
                menu.addItem(infoItem("Field: payload.rate_limits.primary.used_percent"))
            } else {
                menu.addItem(infoItem("Data: account/rateLimits/read"))
                menu.addItem(infoItem("Field: rateLimitsByLimitId.codex.primary.usedPercent"))
            }
            if let latestRead {
                menu.addItem(infoItem("Source: \(latestRead.source.label), age \(formatAge(latestSnapshotDate(for: snapshot)))"))
                if isStale {
                    menu.addItem(infoItem("Menu bar: hidden because cached usage is stale"))
                }
                if let fallbackError = latestRead.fallbackError {
                    menu.addItem(infoItem("Last sync error: \(fallbackError)"))
                }
            }
            menu.addItem(infoItem("Sync: every \(Int(usageSyncInterval))s, account API first, cache TTL \(Int(usageCacheMaxAge))s"))
            menu.addItem(infoItem("Updated: \(formatSyncTime(latestSnapshotDate(for: snapshot)))"))
            menu.addItem(infoItem("Cache: \(usageService.cache.path)"))
        } else {
            menu.addItem(infoItem("Codex Usage unavailable", weight: .semibold))
            if let email = try? AccountContext.current().email {
                menu.addItem(infoItem("Account: \(email)"))
            }
            if let latestError {
                menu.addItem(infoItem(latestError))
            }
        }
        menu.addItem(.separator())
        menu.addItem(actionItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(actionItem(title: "Open Install Guide", action: #selector(openGuide)))
        menu.addItem(actionItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func infoItem(_ title: String, weight: NSFont.Weight = .regular) -> NSMenuItem {
        let item = NSMenuItem()
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 12, weight: weight)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 22))
        label.frame = NSRect(x: 14, y: 3, width: 336, height: 16)
        view.addSubview(label)
        item.view = view
        return item
    }

    private func actionItem(title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.isEnabled = true
        return item
    }

    @objc private func openGuide() {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("READ BEFORE INSTALL - Open Anyway Guide.txt"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("docs/OPEN_ANYWAY_GUIDE.txt")
        ].compactMap { $0 }

        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
            return
        }
        showAlert(title: "Guide Not Found", message: "Install guide was not found in this build.")
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = MenuBarController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if installFromDiskImageIfNeeded() {
            return
        }
        controller.start()
    }
}

enum SelfInstallError: Error, CustomStringConvertible {
    case appBundleNotFound
    case install(String)
    case launchFailed

    var description: String {
        switch self {
        case .appBundleNotFound:
            return "CodexUsage.app bundle was not found."
        case .install(let message):
            return message
        case .launchFailed:
            return "Installed CodexUsage.app, but could not launch it."
        }
    }
}

@MainActor
func installFromDiskImageIfNeeded() -> Bool {
    guard let sourceURL = currentAppBundleURL(),
          sourceURL.path.hasPrefix("/Volumes/") else {
        return false
    }

    do {
        let targetURL = try installAppFromDiskImage(sourceURL: sourceURL)
        guard NSWorkspace.shared.open(targetURL) else {
            throw SelfInstallError.launchFailed
        }
        NSApplication.shared.terminate(nil)
        return true
    } catch {
        let alert = NSAlert()
        alert.messageText = "CodexUsage Install Failed"
        alert.informativeText = String(describing: error)
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
        NSApplication.shared.terminate(nil)
        return true
    }
}

func currentAppBundleURL() -> URL? {
    let bundleURL = Bundle.main.bundleURL
    return bundleURL.pathExtension == "app" ? bundleURL : nil
}

@MainActor
func installAppFromDiskImage(sourceURL: URL) throws -> URL {
    let fm = FileManager.default
    let targetURL = URL(fileURLWithPath: "\(userHomeDirectory())/Applications/CodexUsage.app")
    let targetParent = targetURL.deletingLastPathComponent()
    let backupDir = URL(fileURLWithPath: "\(codexUsageRootDirectory())/backups/apps")

    guard sourceURL.pathExtension == "app" else {
        throw SelfInstallError.appBundleNotFound
    }
    guard targetURL.path.hasPrefix("\(userHomeDirectory())/Applications/") else {
        throw SelfInstallError.install("Refusing to install to an unexpected path: \(targetURL.path)")
    }

    terminateOtherCodexUsageApps()

    do {
        try fm.createDirectory(at: targetParent, withIntermediateDirectories: true)
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codexUsageRootDirectory())
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backupDir.path)

        if fm.fileExists(atPath: targetURL.path) {
            let backupURL = backupDir.appendingPathComponent("CodexUsage.app.\(timestampForFilename())")
            try fm.copyItem(at: targetURL, to: backupURL)
            try fm.removeItem(at: targetURL)
        }

        try fm.copyItem(at: sourceURL, to: targetURL)
        _ = runSmallCommand("/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", targetURL.path], timeout: 5)
        return targetURL
    } catch {
        throw SelfInstallError.install(error.localizedDescription)
    }
}

@MainActor
func terminateOtherCodexUsageApps() {
    let currentPID = ProcessInfo.processInfo.processIdentifier
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.ree.codexusage") {
        guard app.processIdentifier != currentPID else { continue }
        app.terminate()
    }
    Thread.sleep(forTimeInterval: 0.5)
}

func installLaunchAgentIfAppropriate() {
    guard let executable = Bundle.main.executableURL?.path else { return }
    if executable.hasPrefix("/Volumes/") {
        return
    }

    let label = "com.ree.codexusage"
    let fm = FileManager.default
    let launchAgents = "\(userHomeDirectory())/Library/LaunchAgents"
    let plistPath = "\(launchAgents)/\(label).plist"
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>\(label)</string>
        <key>ProgramArguments</key>
        <array>
            <string>\(executable)</string>
            <string>app</string>
        </array>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <false/>
    </dict>
    </plist>
    """

    do {
        try fm.createDirectory(atPath: launchAgents, withIntermediateDirectories: true)
        if let current = try? String(contentsOfFile: plistPath, encoding: .utf8),
           current == plist {
            return
        }
        try plist.write(toFile: plistPath, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plistPath)
    } catch {
        NSLog("CodexUsage failed to install launch agent: \(String(describing: error))")
    }
}

func installCLIHelperIfAppropriate() {
    guard let executable = Bundle.main.executableURL?.path else { return }
    if executable.hasPrefix("/Volumes/") {
        return
    }

    let fm = FileManager.default
    let root = codexUsageRootDirectory()
    let binDir = "\(root)/bin"
    let linkPath = "\(binDir)/codexusage"

    do {
        try fm.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binDir)
        if fm.fileExists(atPath: linkPath) || (try? fm.destinationOfSymbolicLink(atPath: linkPath)) != nil {
            try fm.removeItem(atPath: linkPath)
        }
        try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: executable)
    } catch {
        NSLog("CodexUsage failed to install CLI helper: \(String(describing: error))")
    }
}

func timestampForFilename() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
}

func printUsageHelp() {
    print("""
    CodexUsage \(appVersion)

    Usage:
      codexusage                 Start the macOS menu bar app
      codexusage app             Start the macOS menu bar app
      codexusage status          Print Codex usage as text
      codexusage status --json   Print Codex usage as JSON
      codexusage status --refresh
      codexusage status --diagnose
    """)
}

func runCLI(_ args: [String]) -> Int32 {
    guard let command = args.first else {
        printUsageHelp()
        return 0
    }

    switch command {
    case "status":
        if args.contains("--diagnose") {
            return diagnoseStatus()
        }
        do {
            let read = try UsageService().read(forceRefresh: args.contains("--refresh"))
            let snapshot = read.snapshot
            if args.contains("--json") {
                print(jsonStatus(snapshot, read: read))
            } else {
                print("Codex \(statusLineText(snapshot))")
                print("Account: \(snapshot.account?.email ?? "Email unavailable")")
                print("Plan: \(snapshot.planType ?? snapshot.account?.planType ?? "unknown")")
                if snapshot.fiveHourWindow != nil {
                    print("5h remaining: \(formatPercent(snapshot.remainingPercent))")
                    print("5h reset: \(formatReset(snapshot.fiveHourWindow?.resetsAt))")
                }
                if let secondary = snapshot.weeklyWindow {
                    print("Weekly: \(formatPercent(secondary.usedPercent)) reset: \(formatReset(secondary.resetsAt))")
                }
                if snapshotUsesStatusSession(snapshot, read: read) {
                    print("Source: \(read.source.label) Codex /status session token_count")
                    print("Field: payload.rate_limits.primary.used_percent")
                } else {
                    print("Source: \(read.source.label) Codex app-server account/rateLimits/read")
                    print("Field: rateLimitsByLimitId.codex.primary.usedPercent")
                }
                print("Synced: \(formatSyncTime(read.cacheSavedAt ?? snapshot.fetchedAt)) (age \(formatAge(read.cacheSavedAt ?? snapshot.fetchedAt)))")
                print("Cache: \(UsageCache().path)")
                print("Policy: account API first, sync every \(Int(usageSyncInterval))s, cache TTL \(Int(usageCacheMaxAge))s")
                if let fallbackError = read.fallbackError {
                    print("Last sync error: \(fallbackError)")
                }
            }
            return 0
        } catch {
            fputs("\(String(describing: error))\n", stderr)
            return 1
        }
    case "help", "--help", "-h":
        printUsageHelp()
        return 0
    default:
        printUsageHelp()
        return 2
    }
}

@MainActor
func runApp() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
    _ = delegate
}

@main
struct CodexUsageMain {
    @MainActor
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.isEmpty || args.first == "app" {
            runApp()
        } else {
            exit(runCLI(args))
        }
    }
}
