import Cocoa

// MARK: - Shared date parsing

private enum ISO8601Parsing {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plain = ISO8601DateFormatter()

    static func parse(_ text: String) -> Date? {
        fractional.date(from: text) ?? plain.date(from: text)
    }
}

// MARK: - Subprocess helper (reads pipes before waiting to avoid pipe-buffer deadlock)

private enum Subprocess {
    struct Output {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    static func run(_ executable: String, arguments: [String]) throws -> Output {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        // Drain both pipes BEFORE waitUntilExit. Waiting first can deadlock
        // when a child writes more than the 64 KB pipe buffer.
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Output(
            status: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}

// MARK: - Codex

private struct RateLimitSnapshot: Codable {
    let sourcePath: String?
    let readAt: Date?
    let planType: String
    let allowed: Bool
    let limitReached: Bool
    let sessionUsedPercent: Int
    let sessionWindowMinutes: Int
    let sessionResetAt: Date?
    let weekUsedPercent: Int?
    let weekWindowMinutes: Int?
    let weekResetAt: Date?
    let eventAt: Date?

    var sessionRemainingPercent: Int {
        Self.remainingPercent(fromUsedPercent: sessionUsedPercent)
    }

    var weekRemainingPercent: Int? {
        weekUsedPercent.map(Self.remainingPercent)
    }

    private static func remainingPercent(fromUsedPercent usedPercent: Int) -> Int {
        min(100, max(0, 100 - usedPercent))
    }
}

private final class RateLimitReader {
    private static let initialTailReadBytes: UInt64 = 256 * 1024
    private static let maxTailReadBytes: UInt64 = 4 * 1024 * 1024

    private let stateDbPath: String
    private var latestSourcePath: String
    private var snapshotCache: [String: CachedRolloutSnapshot] = [:]

    init(stateDbPath: String = "\(NSHomeDirectory())/.codex/state_5.sqlite") {
        self.stateDbPath = stateDbPath
        self.latestSourcePath = stateDbPath
    }

    func read() throws -> RateLimitSnapshot {
        let paths = try readRecentRolloutPaths()

        // Prune cache entries for rollouts that fell out of the recent set,
        // so long-running instances do not grow memory without bound.
        snapshotCache = snapshotCache.filter { paths.contains($0.key) }

        let candidates = paths.compactMap { path -> SnapshotCandidate? in
            guard let fileState = try? fileState(for: path) else {
                return nil
            }
            if let cached = snapshotCache[path],
               cached.fileSize == fileState.size,
               cached.modifiedAt == fileState.modifiedAt {
                return SnapshotCandidate(path: path, snapshot: cached.snapshot)
            }

            guard let content = try? readRolloutTail(from: path),
                  let snapshot = parseSnapshot(from: content, sourcePath: path) else {
                return nil
            }
            snapshotCache[path] = CachedRolloutSnapshot(
                fileSize: fileState.size,
                modifiedAt: fileState.modifiedAt,
                snapshot: snapshot
            )
            return SnapshotCandidate(path: path, snapshot: snapshot)
        }

        // Pick the newest event. Ties (including unparseable timestamps) keep
        // the earliest candidate, which is the most recently used thread.
        var newest: SnapshotCandidate?
        for candidate in candidates {
            guard let current = newest else {
                newest = candidate
                continue
            }
            let currentAt = current.snapshot.eventAt ?? .distantPast
            let candidateAt = candidate.snapshot.eventAt ?? .distantPast
            if candidateAt > currentAt {
                newest = candidate
            }
        }

        guard let winner = newest else {
            throw ReaderError.noRateLimitEvent
        }

        latestSourcePath = winner.path
        return winner.snapshot
    }

    private func parseSnapshot(from content: String, sourcePath: String) -> RateLimitSnapshot? {
        let decoder = JSONDecoder()

        for line in content.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard line.contains("\"rate_limits\"") else { continue }
            guard let data = String(line).data(using: .utf8),
                  let event = try? decoder.decode(SessionRolloutLine.self, from: data),
                  event.type == "event_msg",
                  let rateLimits = event.payload.rateLimits else {
                continue
            }

            let primary = rateLimits.primary
            let secondary = rateLimits.secondary
            let limitReached = rateLimits.rateLimitReachedType != nil
            let eventAt = event.timestamp.flatMap { ISO8601Parsing.parse($0) }

            return RateLimitSnapshot(
                sourcePath: sourcePath,
                readAt: Date(),
                planType: rateLimits.planType ?? "unknown",
                allowed: !limitReached,
                limitReached: limitReached,
                sessionUsedPercent: Self.clampedRoundedPercent(primary.usedPercent),
                sessionWindowMinutes: primary.windowMinutes,
                sessionResetAt: primary.resetsAt.map(Date.init(timeIntervalSince1970:)),
                weekUsedPercent: secondary.map { Self.clampedRoundedPercent($0.usedPercent) },
                weekWindowMinutes: secondary?.windowMinutes,
                weekResetAt: secondary?.resetsAt.map(Date.init(timeIntervalSince1970:)),
                eventAt: eventAt
            )
        }

        return nil
    }

    private func readRecentRolloutPaths() throws -> [String] {
        guard FileManager.default.fileExists(atPath: stateDbPath) else {
            throw ReaderError.databaseMissing(stateDbPath)
        }

        let sql = """
        SELECT rollout_path
        FROM threads
        WHERE rollout_path <> ''
        ORDER BY recency_at_ms DESC, updated_at_ms DESC, updated_at DESC
        LIMIT 8;
        """

        let output = try Subprocess.run(
            "/usr/bin/sqlite3",
            arguments: ["-readonly", "-separator", "\t", stateDbPath, sql]
        )
        guard output.status == 0 else {
            let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ReaderError.sqlite(message)
        }

        let paths = output.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }

        guard !paths.isEmpty else {
            throw ReaderError.noRolloutPath
        }

        return paths
    }

    private func readRolloutTail(from path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        var bytesToRead = min(Self.initialTailReadBytes, fileSize)

        while bytesToRead <= min(Self.maxTailReadBytes, fileSize) {
            let offset = fileSize - bytesToRead
            try handle.seek(toOffset: offset)
            guard var data = try handle.read(upToCount: Int(bytesToRead)) else {
                throw ReaderError.noRateLimitEvent
            }

            if offset > 0, let firstNewline = data.firstIndex(of: 0x0A) {
                data.removeSubrange(...firstNewline)
            }

            guard let content = String(data: data, encoding: .utf8) else {
                throw ReaderError.invalidRolloutEncoding(path)
            }
            if content.contains("\"rate_limits\"") {
                return content
            }
            if bytesToRead == fileSize || bytesToRead == Self.maxTailReadBytes {
                break
            }

            bytesToRead = min(bytesToRead * 2, Self.maxTailReadBytes, fileSize)
        }

        throw ReaderError.noRateLimitEvent
    }

    private func fileState(for path: String) throws -> FileState {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modifiedAt = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return FileState(size: size, modifiedAt: modifiedAt)
    }

    private static func clampedRoundedPercent(_ value: Double) -> Int {
        min(100, max(0, Int(value.rounded())))
    }

    var sourceDescription: String {
        latestSourcePath
    }

    enum ReaderError: LocalizedError {
        case databaseMissing(String)
        case noRolloutPath
        case noRateLimitEvent
        case invalidRolloutEncoding(String)
        case sqlite(String)

        var errorDescription: String? {
            switch self {
            case .databaseMissing(let path):
                return "Codex usage source was not found at \(path)."
            case .noRolloutPath:
                return "No current Codex rollout path was found in the local state database."
            case .noRateLimitEvent:
                return "No rate_limits payload was found in the current Codex session file yet."
            case .invalidRolloutEncoding(let path):
                return "The Codex session file could not be read as UTF-8: \(path)."
            case .sqlite(let message):
                return message.isEmpty ? "SQLite could not read the Codex state database." : message
            }
        }
    }
}

private struct SnapshotCandidate {
    let path: String
    let snapshot: RateLimitSnapshot
}

private struct CachedRolloutSnapshot {
    let fileSize: UInt64
    let modifiedAt: TimeInterval
    let snapshot: RateLimitSnapshot
}

private struct FileState {
    let size: UInt64
    let modifiedAt: TimeInterval
}

private struct SessionRolloutLine: Decodable {
    let timestamp: String?
    let type: String
    let payload: SessionPayload
}

private struct SessionPayload: Decodable {
    let type: String
    let rateLimits: SessionRateLimits?

    enum CodingKeys: String, CodingKey {
        case type
        case rateLimits = "rate_limits"
    }
}

private struct SessionRateLimits: Decodable {
    let primary: SessionRateLimitWindow
    let secondary: SessionRateLimitWindow?
    let planType: String?
    let rateLimitReachedType: String?

    enum CodingKeys: String, CodingKey {
        case primary
        case secondary
        case planType = "plan_type"
        case rateLimitReachedType = "rate_limit_reached_type"
    }
}

private struct SessionRateLimitWindow: Decodable {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case windowMinutes = "window_minutes"
        case resetsAt = "resets_at"
    }
}

// MARK: - Claude

private struct ClaudeUsageSnapshot: Codable {
    let readAt: Date?
    let sessionUsedPercent: Int
    let sessionResetAt: Date?
    let weekUsedPercent: Int?
    let weekResetAt: Date?

    var sessionRemainingPercent: Int {
        min(100, max(0, 100 - sessionUsedPercent))
    }

    var weekRemainingPercent: Int? {
        weekUsedPercent.map { min(100, max(0, 100 - $0)) }
    }
}

/// Reads the Claude Code OAuth token from the macOS Keychain and asks
/// Anthropic's usage endpoint (the same source that powers Claude Code's
/// /usage command) for the 5-hour and 7-day utilization windows.
/// Read-only; nothing is written to Claude state.
private final class ClaudeUsageReader {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let keychainService = "Claude Code-credentials"
    private static let userAgent = "claude-code/2.0.0"
    private static let tokenExpiryMargin: TimeInterval = 60

    private var cachedToken: (value: String, expiresAt: Date)?

    func read() throws -> ClaudeUsageSnapshot {
        let token = try accessToken()

        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try synchronousData(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ReaderError.badResponse
        }
        if http.statusCode == 401 {
            cachedToken = nil
            throw ReaderError.unauthorized
        }
        guard http.statusCode == 200 else {
            throw ReaderError.httpStatus(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        guard let fiveHour = decoded.fiveHour, let utilization = fiveHour.utilization else {
            throw ReaderError.missingUsageData
        }

        return ClaudeUsageSnapshot(
            readAt: Date(),
            sessionUsedPercent: Self.clampedRoundedPercent(utilization),
            sessionResetAt: fiveHour.resetsAt?.date,
            weekUsedPercent: decoded.sevenDay?.utilization.map(Self.clampedRoundedPercent),
            weekResetAt: decoded.sevenDay?.resetsAt?.date
        )
    }

    private func accessToken() throws -> String {
        if let cached = cachedToken, cached.expiresAt > Date().addingTimeInterval(Self.tokenExpiryMargin) {
            return cached.value
        }
        cachedToken = nil

        let output = try Subprocess.run(
            "/usr/bin/security",
            arguments: ["find-generic-password", "-s", Self.keychainService, "-w"]
        )
        guard output.status == 0 else {
            throw ReaderError.keychainUnavailable(output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let json = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = json.data(using: .utf8),
              let credentials = try? JSONDecoder().decode(ClaudeCredentialsFile.self, from: data),
              let oauth = credentials.claudeAiOauth,
              let token = oauth.accessToken, !token.isEmpty else {
            throw ReaderError.credentialsUnreadable
        }

        // expiresAt is stored as milliseconds since the epoch.
        let expiresAt = oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantFuture
        guard expiresAt > Date().addingTimeInterval(Self.tokenExpiryMargin) else {
            throw ReaderError.tokenExpired
        }

        cachedToken = (token, expiresAt)
        return token
    }

    private func synchronousData(for request: URLRequest) throws -> (Data, URLResponse) {
        var received: (data: Data?, response: URLResponse?, error: Error?) = (nil, nil, nil)
        let semaphore = DispatchSemaphore(value: 0)

        URLSession.shared.dataTask(with: request) { data, response, error in
            received = (data, response, error)
            semaphore.signal()
        }.resume()

        guard semaphore.wait(timeout: .now() + 30) == .success else {
            throw ReaderError.timeout
        }
        if let error = received.error {
            throw error
        }
        guard let data = received.data, let response = received.response else {
            throw ReaderError.badResponse
        }
        return (data, response)
    }

    private static func clampedRoundedPercent(_ value: Double) -> Int {
        min(100, max(0, Int(value.rounded())))
    }

    enum ReaderError: LocalizedError {
        case keychainUnavailable(String)
        case credentialsUnreadable
        case tokenExpired
        case unauthorized
        case badResponse
        case timeout
        case httpStatus(Int)
        case missingUsageData

        var errorDescription: String? {
            switch self {
            case .keychainUnavailable(let message):
                return message.isEmpty
                    ? "Claude Code credentials were not found in the Keychain."
                    : "Keychain read failed: \(message)"
            case .credentialsUnreadable:
                return "Claude Code Keychain item could not be parsed."
            case .tokenExpired:
                return "Claude Code OAuth token has expired. Run Claude Code once to refresh it."
            case .unauthorized:
                return "Anthropic rejected the token (401). Run Claude Code once to refresh it."
            case .badResponse:
                return "The Anthropic usage endpoint returned an unreadable response."
            case .timeout:
                return "The Anthropic usage request timed out."
            case .httpStatus(let code):
                return "The Anthropic usage endpoint returned HTTP \(code)."
            case .missingUsageData:
                return "The Anthropic usage response did not include five_hour utilization."
            }
        }
    }
}

private struct ClaudeCredentialsFile: Decodable {
    let claudeAiOauth: ClaudeOAuthCredentials?
}

private struct ClaudeOAuthCredentials: Decodable {
    let accessToken: String?
    let expiresAt: Double?
}

private struct ClaudeUsageResponse: Decodable {
    let fiveHour: ClaudeUsageWindow?
    let sevenDay: ClaudeUsageWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

private struct ClaudeUsageWindow: Decodable {
    let utilization: Double?
    let resetsAt: FlexibleDate?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

/// Accepts either an epoch-seconds number or an ISO 8601 string.
private struct FlexibleDate: Decodable {
    let date: Date?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let seconds = try? container.decode(Double.self) {
            date = Date(timeIntervalSince1970: seconds)
        } else if let text = try? container.decode(String.self) {
            date = ISO8601Parsing.parse(text)
        } else {
            date = nil
        }
    }
}

// MARK: - App

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let maxLogBytes: UInt64 = 1 * 1024 * 1024
    private static let repeatedErrorLogInterval: TimeInterval = 15 * 60
    private static let cachedCodexSnapshotKey = "lastGoodRateLimitSnapshot"
    private static let cachedClaudeSnapshotKey = "lastGoodClaudeUsageSnapshot"
    private static let maxSnapshotAge: TimeInterval = 6 * 60 * 60
    private static let codexRefreshInterval: TimeInterval = 5
    private static let claudeRefreshInterval: TimeInterval = 180

    private let codexReader = RateLimitReader()
    private let claudeReader = ClaudeUsageReader()
    // All reads (file IO, subprocesses, network) run on this serial queue so
    // the main thread never blocks; results are applied back on main.
    private let refreshQueue = DispatchQueue(label: "codex-token-bar.refresh", qos: .utility)

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var codexTimer: Timer?
    private var claudeTimer: Timer?
    private var codexRefreshInFlight = false
    private var claudeRefreshInFlight = false

    private var latestCodexSnapshot: RateLimitSnapshot?
    private var codexSnapshotIsStale = false
    private var latestCodexError: Error?

    private var latestClaudeSnapshot: ClaudeUsageSnapshot?
    private var claudeSnapshotIsStale = false
    private var latestClaudeError: Error?

    private var lastLoggedErrorMessage: String?
    private var lastLoggedErrorAt: Date?
    private lazy var logURL: URL = {
        let logDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CodexUsageBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        return logDirectory.appendingPathComponent("codex-token-bar-runtime.log")
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        log("applicationDidFinishLaunching")

        if let button = statusItem.button {
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            button.toolTip = "Codex and Claude usage remaining"
            log("status item button configured")
        } else {
            log("status item button was nil")
        }

        restoreCachedSnapshots()
        updateStatusItem()
        rebuildMenu()

        refreshCodex()
        refreshClaude()

        codexTimer = Timer.scheduledTimer(withTimeInterval: Self.codexRefreshInterval, repeats: true) { [weak self] _ in
            self?.refreshCodex()
        }
        claudeTimer = Timer.scheduledTimer(withTimeInterval: Self.claudeRefreshInterval, repeats: true) { [weak self] _ in
            self?.refreshClaude()
        }
        RunLoop.main.add(codexTimer!, forMode: .common)
        RunLoop.main.add(claudeTimer!, forMode: .common)
    }

    // MARK: Refresh

    private func refreshCodex() {
        guard !codexRefreshInFlight else { return }
        codexRefreshInFlight = true

        refreshQueue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.codexReader.read() }
            DispatchQueue.main.async {
                self.codexRefreshInFlight = false
                self.applyCodexResult(result)
            }
        }
    }

    private func refreshClaude() {
        guard !claudeRefreshInFlight else { return }
        claudeRefreshInFlight = true

        refreshQueue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.claudeReader.read() }
            DispatchQueue.main.async {
                self.claudeRefreshInFlight = false
                self.applyClaudeResult(result)
            }
        }
    }

    private func applyCodexResult(_ result: Result<RateLimitSnapshot, Error>) {
        switch result {
        case .success(let snapshot) where isCodexSnapshotDisplayable(snapshot):
            latestCodexSnapshot = snapshot
            codexSnapshotIsStale = false
            latestCodexError = nil
            cacheSnapshot(snapshot, forKey: Self.cachedCodexSnapshotKey)
        case .success:
            handleCodexFailure(DisplayError.snapshotExpired)
        case .failure(let error):
            handleCodexFailure(error)
        }

        updateStatusItem()
        rebuildMenu()
    }

    private func handleCodexFailure(_ error: Error) {
        latestCodexError = error
        if let snapshot = latestCodexSnapshot, isCodexSnapshotDisplayable(snapshot) {
            codexSnapshotIsStale = true
        } else {
            latestCodexSnapshot = nil
            codexSnapshotIsStale = false
        }
        logErrorIfNeeded("codex refresh error \(error.localizedDescription)")
    }

    private func applyClaudeResult(_ result: Result<ClaudeUsageSnapshot, Error>) {
        switch result {
        case .success(let snapshot) where isClaudeSnapshotDisplayable(snapshot):
            latestClaudeSnapshot = snapshot
            claudeSnapshotIsStale = false
            latestClaudeError = nil
            cacheSnapshot(snapshot, forKey: Self.cachedClaudeSnapshotKey)
        case .success:
            handleClaudeFailure(DisplayError.snapshotExpired)
        case .failure(let error):
            handleClaudeFailure(error)
        }

        updateStatusItem()
        rebuildMenu()
    }

    private func handleClaudeFailure(_ error: Error) {
        latestClaudeError = error
        if let snapshot = latestClaudeSnapshot, isClaudeSnapshotDisplayable(snapshot) {
            claudeSnapshotIsStale = true
        } else {
            latestClaudeSnapshot = nil
            claudeSnapshotIsStale = false
        }
        logErrorIfNeeded("claude refresh error \(error.localizedDescription)")
    }

    // MARK: Status item

    private func updateStatusItem() {
        let codexPart: String
        if let snapshot = latestCodexSnapshot {
            codexPart = "S \(snapshot.sessionRemainingPercent)% W \(formatPercent(snapshot.weekRemainingPercent))"
        } else {
            codexPart = "S -- W --"
        }

        let claudePart: String
        if let snapshot = latestClaudeSnapshot {
            claudePart = "C \(snapshot.sessionRemainingPercent)%"
        } else {
            claudePart = "C --"
        }

        statusItem.button?.title = "\(codexPart) \(claudePart)"
        statusItem.button?.toolTip = tooltipText()
    }

    private func tooltipText() -> String {
        var lines: [String] = []
        if let snapshot = latestCodexSnapshot {
            let suffix = codexSnapshotIsStale ? " (last known, read \(formatAge(since: snapshot.readAt)))" : ""
            lines.append("Codex: session \(snapshot.sessionRemainingPercent)%, week \(formatPercent(snapshot.weekRemainingPercent)) remaining\(suffix)")
        } else {
            lines.append("Codex usage is not available yet\(latestCodexError.map { ": \($0.localizedDescription)" } ?? "")")
        }
        if let snapshot = latestClaudeSnapshot {
            let suffix = claudeSnapshotIsStale ? " (last known, read \(formatAge(since: snapshot.readAt)))" : ""
            lines.append("Claude: session \(snapshot.sessionRemainingPercent)%, week \(formatPercent(snapshot.weekRemainingPercent)) remaining\(suffix)")
        } else {
            lines.append("Claude usage is not available yet\(latestClaudeError.map { ": \($0.localizedDescription)" } ?? "")")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Menu

    private func rebuildMenu() {
        let menu = NSMenu()

        addHeader(codexSnapshotIsStale ? "Codex (Last Known)" : "Codex", to: menu)
        if let snapshot = latestCodexSnapshot {
            addValue("Current session", value: "\(snapshot.sessionRemainingPercent)% remaining", to: menu)
            addValue("This week", value: formatRemaining(snapshot.weekRemainingPercent), to: menu)
            addValue("Plan", value: snapshot.planType, to: menu)
            addValue("Status", value: snapshot.limitReached ? "limit reached" : (snapshot.allowed ? "allowed" : "not allowed"), to: menu)
            if let sessionReset = snapshot.sessionResetAt {
                addValue("Session resets", value: Self.dateFormatter.string(from: sessionReset), to: menu)
            }
            if let weekReset = snapshot.weekResetAt {
                addValue("Week resets", value: Self.dateFormatter.string(from: weekReset), to: menu)
            }
            if let readAt = snapshot.readAt {
                addValue("Read age", value: formatAge(since: readAt), to: menu)
            }
            if let sourcePath = snapshot.sourcePath {
                addValue("Source", value: sourcePath, to: menu)
            }
        } else {
            addValue("Status", value: "waiting for first rate_limits payload", to: menu)
        }
        if let error = latestCodexError {
            addValue("Error", value: error.localizedDescription, to: menu)
        }

        menu.addItem(.separator())
        addHeader(claudeSnapshotIsStale ? "Claude (Last Known)" : "Claude", to: menu)
        if let snapshot = latestClaudeSnapshot {
            addValue("Current session", value: "\(snapshot.sessionRemainingPercent)% remaining", to: menu)
            addValue("This week", value: formatRemaining(snapshot.weekRemainingPercent), to: menu)
            if let sessionReset = snapshot.sessionResetAt {
                addValue("Session resets", value: Self.dateFormatter.string(from: sessionReset), to: menu)
            }
            if let weekReset = snapshot.weekResetAt {
                addValue("Week resets", value: Self.dateFormatter.string(from: weekReset), to: menu)
            }
            if let readAt = snapshot.readAt {
                addValue("Read age", value: formatAge(since: readAt), to: menu)
            }
        } else {
            addValue("Status", value: "waiting for first usage response", to: menu)
        }
        if let error = latestClaudeError {
            addValue("Error", value: error.localizedDescription, to: menu)
        }

        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshFromMenu), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let copyItem = NSMenuItem(title: "Copy Summary", action: #selector(copySummary), keyEquivalent: "c")
        copyItem.target = self
        copyItem.isEnabled = latestCodexSnapshot != nil || latestClaudeSnapshot != nil
        menu.addItem(copyItem)

        let openItem = NSMenuItem(title: "Open Codex State Folder", action: #selector(openCodexFolder), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func addHeader(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        item.attributedTitle = NSAttributedString(string: title, attributes: attributes)
        menu.addItem(item)
    }

    private func addValue(_ label: String, value: String, to menu: NSMenu) {
        let item = NSMenuItem(title: "\(label): \(value)", action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @objc private func refreshFromMenu() {
        refreshCodex()
        refreshClaude()
    }

    @objc private func copySummary() {
        var lines: [String] = []
        if let snapshot = latestCodexSnapshot {
            let suffix = codexSnapshotIsStale ? " (last known)" : ""
            lines.append("Codex session remaining: \(snapshot.sessionRemainingPercent)%\(suffix)")
            lines.append("Codex week remaining: \(formatPercent(snapshot.weekRemainingPercent))\(suffix)")
            lines.append("Codex source: \(snapshot.sourcePath ?? codexReader.sourceDescription)")
        }
        if let snapshot = latestClaudeSnapshot {
            let suffix = claudeSnapshotIsStale ? " (last known)" : ""
            lines.append("Claude session remaining: \(snapshot.sessionRemainingPercent)%\(suffix)")
            lines.append("Claude week remaining: \(formatPercent(snapshot.weekRemainingPercent))\(suffix)")
        }
        guard !lines.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    @objc private func openCodexFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "\(NSHomeDirectory())/.codex"))
    }

    @objc private func quit() {
        log("quit")
        NSApp.terminate(nil)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    // MARK: Snapshot caching

    private func restoreCachedSnapshots() {
        if let data = UserDefaults.standard.data(forKey: Self.cachedCodexSnapshotKey),
           let snapshot = try? JSONDecoder().decode(RateLimitSnapshot.self, from: data) {
            if isCodexSnapshotDisplayable(snapshot) {
                latestCodexSnapshot = snapshot
                codexSnapshotIsStale = true
            } else {
                UserDefaults.standard.removeObject(forKey: Self.cachedCodexSnapshotKey)
            }
        }
        if let data = UserDefaults.standard.data(forKey: Self.cachedClaudeSnapshotKey),
           let snapshot = try? JSONDecoder().decode(ClaudeUsageSnapshot.self, from: data) {
            if isClaudeSnapshotDisplayable(snapshot) {
                latestClaudeSnapshot = snapshot
                claudeSnapshotIsStale = true
            } else {
                UserDefaults.standard.removeObject(forKey: Self.cachedClaudeSnapshotKey)
            }
        }
    }

    private func cacheSnapshot<T: Encodable>(_ snapshot: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func isCodexSnapshotDisplayable(_ snapshot: RateLimitSnapshot) -> Bool {
        let now = Date()
        if let sessionResetAt = snapshot.sessionResetAt, sessionResetAt <= now {
            return false
        }
        if let basis = snapshot.readAt ?? snapshot.eventAt,
           now.timeIntervalSince(basis) > Self.maxSnapshotAge {
            return false
        }
        return true
    }

    private func isClaudeSnapshotDisplayable(_ snapshot: ClaudeUsageSnapshot) -> Bool {
        let now = Date()
        if let sessionResetAt = snapshot.sessionResetAt, sessionResetAt <= now {
            return false
        }
        if let basis = snapshot.readAt, now.timeIntervalSince(basis) > Self.maxSnapshotAge {
            return false
        }
        return true
    }

    // MARK: Formatting and logging

    private func formatAge(since date: Date?) -> String {
        guard let date else { return "unknown" }

        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 {
            return "<1m ago"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m ago"
        }
        return "\(minutes / 60)h ago"
    }

    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        rotateLogIfNeeded(incomingBytes: UInt64(data.count))

        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            _ = try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
    }

    private func logErrorIfNeeded(_ message: String) {
        let now = Date()
        let shouldLog = message != lastLoggedErrorMessage
            || lastLoggedErrorAt.map { now.timeIntervalSince($0) >= Self.repeatedErrorLogInterval } ?? true

        guard shouldLog else { return }

        lastLoggedErrorMessage = message
        lastLoggedErrorAt = now
        log(message)
    }

    private func rotateLogIfNeeded(incomingBytes: UInt64) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attributes[.size] as? NSNumber,
              let currentSize = UInt64(exactly: size),
              currentSize + incomingBytes > Self.maxLogBytes else {
            return
        }

        try? Data().write(to: logURL)
    }

    private func formatPercent(_ value: Int?) -> String {
        value.map { "\($0)%" } ?? "--"
    }

    private func formatRemaining(_ value: Int?) -> String {
        value.map { "\($0)% remaining" } ?? "unavailable"
    }

    private enum DisplayError: LocalizedError {
        case snapshotExpired

        var errorDescription: String? {
            "The last usage snapshot has expired and no fresh data is available yet."
        }
    }
}

@main
private enum CodexTokenBarMain {
    private static var delegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let appDelegate = AppDelegate()
        delegate = appDelegate
        app.delegate = appDelegate
        app.run()
    }
}
