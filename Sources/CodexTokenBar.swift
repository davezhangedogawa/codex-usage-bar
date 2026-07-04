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

// MARK: - Subprocess helper

private enum Subprocess {
    struct Output {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Runs a child process with a hard wall-clock timeout.
    ///
    /// Both pipes are drained concurrently with the battle-tested
    /// readDataToEndOfFile pattern (each on its own thread, so neither pipe
    /// can fill its 64 KB buffer and block the child). The timeout matters:
    /// `security` can block indefinitely on a Keychain authorization prompt,
    /// and without a timeout that would permanently wedge the refresh cycle.
    static func run(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval,
        currentDirectoryPath: String? = nil
    ) throws -> Output {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let drainGroup = DispatchGroup()
        let exitSemaphore = DispatchSemaphore(value: 0)
        var stdoutData = Data()
        var stderrData = Data()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if let currentDirectoryPath {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectoryPath, isDirectory: true)
        }
        process.terminationHandler = { _ in exitSemaphore.signal() }

        try process.run()

        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            drainGroup.leave()
        }
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            drainGroup.leave()
        }

        if exitSemaphore.wait(timeout: .now() + timeout) != .success {
            process.terminate()
            if exitSemaphore.wait(timeout: .now() + 2) != .success {
                kill(process.processIdentifier, SIGKILL)
                _ = exitSemaphore.wait(timeout: .now() + 2)
            }
            _ = drainGroup.wait(timeout: .now() + 2)
            throw SubprocessError.timeout(executable)
        }

        // EOF follows exit almost immediately for these tools; the wait bounds
        // the pathological case instead of hanging the caller.
        _ = drainGroup.wait(timeout: .now() + 5)

        return Output(
            status: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    enum SubprocessError: LocalizedError {
        case timeout(String)

        var errorDescription: String? {
            switch self {
            case .timeout(let executable):
                return "\(executable) did not finish in time (possibly waiting for a Keychain prompt)."
            }
        }
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

    // Codex has moved its state database between versions (newer builds keep
    // it under ~/.codex/sqlite/). Both locations are tried in order and the
    // first one that answers wins; a stale file left at the old path fails
    // every query with SQLITE_CANTOPEN (14).
    private let stateDbPaths: [String]
    private let sessionsRootPath: String
    private var latestSourcePath: String
    private var snapshotCache: [String: CachedRolloutSnapshot] = [:]

    init(
        stateDbPaths: [String] = [
            "\(NSHomeDirectory())/.codex/sqlite/state_5.sqlite",
            "\(NSHomeDirectory())/.codex/state_5.sqlite"
        ],
        sessionsRootPath: String = "\(NSHomeDirectory())/.codex/sessions"
    ) {
        self.stateDbPaths = stateDbPaths
        self.sessionsRootPath = sessionsRootPath
        self.latestSourcePath = stateDbPaths.first ?? sessionsRootPath
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
        var paths: [String] = []
        var sqliteError: Error? = ReaderError.databaseMissing(stateDbPaths.first ?? "~/.codex")

        for dbPath in stateDbPaths where FileManager.default.fileExists(atPath: dbPath) {
            do {
                paths.append(contentsOf: try readRecentRolloutPathsFromStateDatabase(dbPath: dbPath))
                sqliteError = nil
                break
            } catch {
                sqliteError = error
            }
        }

        paths.append(contentsOf: recentRolloutPathsFromFilesystem(limit: 24))

        var seen = Set<String>()
        let uniquePaths = paths.filter { path in
            guard !path.isEmpty, FileManager.default.fileExists(atPath: path), !seen.contains(path) else {
                return false
            }
            seen.insert(path)
            return true
        }

        guard !uniquePaths.isEmpty else {
            if let sqliteError {
                throw sqliteError
            }
            throw ReaderError.noRolloutPath
        }

        return uniquePaths
    }

    private func readRecentRolloutPathsFromStateDatabase(dbPath: String) throws -> [String] {
        let sql = """
        SELECT rollout_path
        FROM threads
        WHERE rollout_path <> ''
        ORDER BY recency_at_ms DESC, updated_at_ms DESC, updated_at DESC
        LIMIT 8;
        """

        let output = try Subprocess.run(
            "/usr/bin/sqlite3",
            arguments: ["-readonly", "-separator", "\t", dbPath, sql],
            timeout: 10
        )
        guard output.status == 0 else {
            let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ReaderError.sqlite(message)
        }

        let paths = output.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        return paths
    }

    private func recentRolloutPathsFromFilesystem(limit: Int) -> [String] {
        let rootURL = URL(fileURLWithPath: sessionsRootPath, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var candidates: [(path: String, modifiedAt: Date)] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("rollout-"),
                  url.pathExtension == "jsonl",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            candidates.append((url.path, modifiedAt))
        }

        return candidates
            .sorted { lhs, rhs in lhs.modifiedAt > rhs.modifiedAt }
            .prefix(limit)
            .map(\.path)
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
                return "No recent Codex rollout files were found in the state database or sessions folder."
            case .noRateLimitEvent:
                return "No rate_limits payload was found in recent Codex session files yet."
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

    // Candidate install locations for the Claude Code CLI. A GUI app launched
    // by LaunchServices does not inherit the user's shell PATH, so absolute
    // paths are tried directly before falling back to a login-shell lookup.
    private static let claudeBinaryCandidates = [
        "\(NSHomeDirectory())/.local/bin/claude",
        "\(NSHomeDirectory())/.claude/local/claude",
        "/usr/local/bin/claude",
        "/opt/homebrew/bin/claude"
    ]

    private var cachedToken: (value: String, expiresAt: Date)?

    /// Forget the cached token so the next read re-reads the Keychain. Called
    /// after a login refresh so a freshly minted token is picked up at once.
    func invalidateCachedToken() {
        cachedToken = nil
    }

    /// Runs the Claude Code CLI once in headless mode. On startup the CLI
    /// exchanges the stored refresh token for a new access token and writes it
    /// back to the Keychain, which is exactly what an idle machine needs. This
    /// uses the user's own official client (no impersonation) and costs a
    /// negligible sliver of usage for the one-word prompt.
    func refreshLogin() throws {
        guard let binary = Self.locateClaudeBinary() else {
            throw ReaderError.cliNotFound
        }

        let output = try Subprocess.run(
            binary,
            arguments: ["-p", "ping"],
            timeout: 90,
            currentDirectoryPath: NSHomeDirectory()
        )
        guard output.status == 0 else {
            let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ReaderError.cliFailed(message.isEmpty ? "exit code \(output.status)" : message)
        }
        invalidateCachedToken()
    }

    private static func locateClaudeBinary() -> String? {
        if let direct = claudeBinaryCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return direct
        }
        // Last resort: ask a login shell, which sources the user's PATH.
        guard let output = try? Subprocess.run(
            "/bin/zsh",
            arguments: ["-lc", "command -v claude"],
            timeout: 10
        ), output.status == 0 else {
            return nil
        }
        let path = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

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

        // Generous timeout: the first call can show a Keychain authorization
        // prompt that the user needs time to approve ("Always Allow" stops it
        // from reappearing). A hard cap still prevents a permanent hang when
        // the prompt is dismissed to the background or ignored.
        let output = try Subprocess.run(
            "/usr/bin/security",
            arguments: ["find-generic-password", "-s", Self.keychainService, "-w"],
            timeout: 120
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

        // expiresAt has been observed in milliseconds; tolerate seconds too
        // (values above ~5138 AD in seconds must be milliseconds).
        let expiresAt = oauth.expiresAt.map { raw in
            Date(timeIntervalSince1970: raw > 1e11 ? raw / 1000 : raw)
        }

        // Do NOT reject a locally "expired" token: the server is the source
        // of truth (a unit mismatch or clock skew would otherwise wedge the
        // reader forever). An actually dead token comes back as HTTP 401.
        // Only cache while the local expiry still looks valid, so a token
        // refreshed by Claude Code is picked up on the next cycle.
        if let expiresAt, expiresAt > Date().addingTimeInterval(Self.tokenExpiryMargin) {
            cachedToken = (token, expiresAt)
        }
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
        case unauthorized
        case badResponse
        case timeout
        case httpStatus(Int)
        case missingUsageData
        case cliNotFound
        case cliFailed(String)

        var errorDescription: String? {
            switch self {
            case .keychainUnavailable(let message):
                return message.isEmpty
                    ? "Claude Code credentials were not found in the Keychain."
                    : "Keychain read failed: \(message)"
            case .credentialsUnreadable:
                return "Claude Code Keychain item could not be parsed."
            case .unauthorized:
                return "Anthropic rejected the token (401): it has likely expired. Use \"Refresh Claude Login\" from the menu, or run Claude Code once; the bar recovers within 3 minutes."
            case .cliNotFound:
                return "The claude command was not found. Install Claude Code, or refresh by running it once yourself."
            case .cliFailed(let message):
                return "Refreshing the Claude login failed: \(message)"
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

/// Colors for the status-bar text, resolved per menu bar appearance.
private struct MenuBarPalette {
    let base: NSColor
    let dimmed: NSColor
    let shadow: NSShadow?

    init(isDark: Bool) {
        if isDark {
            base = .white
            dimmed = NSColor.white.withAlphaComponent(0.65)
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.8)
            s.shadowOffset = NSSize(width: 0, height: -1)
            s.shadowBlurRadius = 1.5
            shadow = s
        } else {
            base = .black
            dimmed = NSColor.black.withAlphaComponent(0.6)
            shadow = nil
        }
    }

    func color(forRemaining value: Int?) -> NSColor {
        guard let value else { return dimmed }
        if value < 10 { return .systemRed }
        if value < 25 { return .systemOrange }
        return base
    }

    func attributes(font: NSFont, color: NSColor) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        if let shadow {
            attributes[.shadow] = shadow
        }
        return attributes
    }
}

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
    // Reads run away from the main thread. Codex and Claude use separate
    // queues so a slow network request cannot delay local Codex updates.
    private let codexRefreshQueue = DispatchQueue(label: "codex-token-bar.codex-refresh", qos: .utility)
    private let claudeRefreshQueue = DispatchQueue(label: "codex-token-bar.claude-refresh", qos: .utility)

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
    private var claudeLoginRefreshInProgress = false
    private var claudeLoginRefreshStatus: String?

    // Throttle state is kept per source: Codex and Claude errors alternate
    // in the log, and a single "last message" slot would see every entry as
    // "new" and never throttle anything.
    private var lastLoggedErrors: [String: (message: String, at: Date)] = [:]
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
            button.imagePosition = .imageOnly
            button.toolTip = "Codex and Claude usage remaining: S=session, W=weekly"
            log("status item button configured")
        } else {
            log("status item button was nil")
        }

        // Re-render the two-line image when the system theme flips, so the
        // resolved label colors match the new appearance immediately.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateStatusItem()
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

        codexRefreshQueue.async { [weak self] in
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

        claudeRefreshQueue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.claudeReader.read() }
            DispatchQueue.main.async {
                self.claudeRefreshInFlight = false
                self.applyClaudeResult(result)
            }
        }
    }

    /// Runs the official Claude Code CLI once to refresh the OAuth token, then
    /// immediately re-reads usage. Serialized on the same queue as reads so it
    /// cannot overlap a normal Claude refresh.
    private func refreshClaudeLogin() {
        guard !claudeLoginRefreshInProgress else { return }
        claudeLoginRefreshInProgress = true
        claudeLoginRefreshStatus = "Refreshing Claude login…"
        rebuildMenu()

        claudeRefreshQueue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.claudeReader.refreshLogin() }
            DispatchQueue.main.async {
                self.claudeLoginRefreshInProgress = false
                switch result {
                case .success:
                    self.claudeLoginRefreshStatus = "Login refreshed"
                    self.logErrorIfNeeded(source: "claude-login", "refreshed")
                case .failure(let error):
                    self.claudeLoginRefreshStatus = "Refresh failed: \(error.localizedDescription)"
                    self.logErrorIfNeeded(source: "claude-login", error.localizedDescription)
                }
                self.rebuildMenu()
                // Pull fresh usage regardless; on success it now succeeds, on
                // failure it restores the normal error text.
                self.refreshClaude()
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
        logErrorIfNeeded(source: "codex", error.localizedDescription)
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
        logErrorIfNeeded(source: "claude", error.localizedDescription)
    }

    // MARK: Status item

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = renderStatusImage()
        button.imagePosition = .imageOnly
        button.title = ""
        button.toolTip = tooltipText()
    }

    /// Draws the four remaining-percent values as two tiny stacked lines.
    /// Provider names are included because ambiguous one-letter prefixes make
    /// it too easy to confuse Codex, Claude, session, and weekly windows.
    /// Text color follows the menu bar appearance: white with a subtle dark
    /// shadow on a dark/translucent bar (readable over busy wallpaper), plain
    /// dark text on a light bar (forced white would vanish there).
    /// Values below 25% remaining turn orange, below 10% red.
    private func renderStatusImage() -> NSImage {
        let font = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
        let appearance = statusItem.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        let palette = MenuBarPalette(isDark: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)

        let top = providerStatusLine(
            provider: "Codex",
            session: effectiveValue(latestCodexSnapshot?.sessionRemainingPercent, resetAt: latestCodexSnapshot?.sessionResetAt),
            week: effectiveValue(latestCodexSnapshot?.weekRemainingPercent, resetAt: latestCodexSnapshot?.weekResetAt),
            font: font,
            palette: palette
        )
        let bottom = providerStatusLine(
            provider: "Claude",
            session: effectiveValue(latestClaudeSnapshot?.sessionRemainingPercent, resetAt: latestClaudeSnapshot?.sessionResetAt),
            week: effectiveValue(latestClaudeSnapshot?.weekRemainingPercent, resetAt: latestClaudeSnapshot?.weekResetAt),
            font: font,
            palette: palette
        )

        let lineHeight: CGFloat = 10
        let width = ceil(max(top.size().width, bottom.size().width)) + 2
        let image = NSImage(size: NSSize(width: width, height: lineHeight * 2))

        appearance.performAsCurrentDrawingAppearance {
            image.lockFocus()
            top.draw(at: NSPoint(x: 1, y: lineHeight))
            bottom.draw(at: NSPoint(x: 1, y: 0))
            image.unlockFocus()
        }
        image.isTemplate = false
        return image
    }

    private func providerStatusLine(provider: String, session: Int?, week: Int?, font: NSFont, palette: MenuBarPalette) -> NSAttributedString {
        // Pad provider names to equal length so the S/W columns of the two
        // monospaced lines align vertically.
        let paddedProvider = provider.padding(toLength: 6, withPad: " ", startingAt: 0)
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: paddedProvider, attributes: palette.attributes(font: font, color: palette.dimmed)))
        result.append(statusToken(label: " S", value: session, font: font, palette: palette))
        result.append(statusToken(label: " W", value: week, font: font, palette: palette))
        return result
    }

    private func statusToken(label: String, value: Int?, font: NSFont, palette: MenuBarPalette) -> NSAttributedString {
        let result = NSMutableAttributedString(string: label, attributes: palette.attributes(font: font, color: palette.dimmed))
        result.append(NSAttributedString(
            string: value.map(String.init) ?? "--",
            attributes: palette.attributes(font: font, color: palette.color(forRemaining: value))
        ))
        return result
    }

    private func tooltipText() -> String {
        var lines: [String] = []
        if let snapshot = latestCodexSnapshot {
            let session = effectiveValue(snapshot.sessionRemainingPercent, resetAt: snapshot.sessionResetAt)
            let week = effectiveValue(snapshot.weekRemainingPercent, resetAt: snapshot.weekResetAt)
            let suffix = codexSnapshotIsStale ? " (last known, read \(formatAge(since: snapshot.readAt)))" : ""
            lines.append("Codex: session (S) \(formatPercent(session)), weekly (W) \(formatPercent(week)) remaining\(suffix)")
            if session == nil {
                lines.append("Codex session window has reset; waiting for the next Codex activity.")
            }
        } else {
            lines.append("Codex usage is not available yet\(latestCodexError.map { ": \($0.localizedDescription)" } ?? "")")
        }
        if let snapshot = latestClaudeSnapshot {
            let session = effectiveValue(snapshot.sessionRemainingPercent, resetAt: snapshot.sessionResetAt)
            let week = effectiveValue(snapshot.weekRemainingPercent, resetAt: snapshot.weekResetAt)
            let suffix = claudeSnapshotIsStale ? " (last known, read \(formatAge(since: snapshot.readAt)))" : ""
            lines.append("Claude: session (S) \(formatPercent(session)), weekly (W) \(formatPercent(week)) remaining\(suffix)")
        } else {
            lines.append("Claude usage is not available yet\(latestClaudeError.map { ": \($0.localizedDescription)" } ?? "")")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Menu

    private func rebuildMenu() {
        let menu = NSMenu()

        addHeader(codexSnapshotIsStale ? "Codex Usage (Last Known)" : "Codex Usage", to: menu)
        if let snapshot = latestCodexSnapshot {
            let session = effectiveValue(snapshot.sessionRemainingPercent, resetAt: snapshot.sessionResetAt)
            let week = effectiveValue(snapshot.weekRemainingPercent, resetAt: snapshot.weekResetAt)
            addValue("Session remaining (S)", value: session.map { "\($0)%" } ?? "window reset, waiting for new Codex activity", to: menu)
            addValue("Weekly remaining (W)", value: formatPercent(week), to: menu)
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
        addHeader(claudeSnapshotIsStale ? "Claude Usage (Last Known)" : "Claude Usage", to: menu)
        if let snapshot = latestClaudeSnapshot {
            let session = effectiveValue(snapshot.sessionRemainingPercent, resetAt: snapshot.sessionResetAt)
            let week = effectiveValue(snapshot.weekRemainingPercent, resetAt: snapshot.weekResetAt)
            addValue("Session remaining (S)", value: session.map { "\($0)%" } ?? "window reset, waiting for fresh data", to: menu)
            addValue("Weekly remaining (W)", value: formatPercent(week), to: menu)
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
        if let status = claudeLoginRefreshStatus {
            addValue("Login refresh", value: status, to: menu)
        }

        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshFromMenu), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let refreshLoginItem = NSMenuItem(
            title: claudeLoginRefreshInProgress ? "Refreshing Claude Login…" : "Refresh Claude Login",
            action: #selector(refreshClaudeLoginFromMenu),
            keyEquivalent: ""
        )
        refreshLoginItem.target = self
        refreshLoginItem.isEnabled = !claudeLoginRefreshInProgress
        menu.addItem(refreshLoginItem)

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

    @objc private func refreshClaudeLoginFromMenu() {
        refreshClaudeLogin()
    }

    @objc private func copySummary() {
        var lines: [String] = []
        if let snapshot = latestCodexSnapshot {
            let suffix = codexSnapshotIsStale ? " (last known)" : ""
            lines.append("Codex session (S) remaining: \(formatPercent(effectiveValue(snapshot.sessionRemainingPercent, resetAt: snapshot.sessionResetAt)))\(suffix)")
            lines.append("Codex weekly (W) remaining: \(formatPercent(effectiveValue(snapshot.weekRemainingPercent, resetAt: snapshot.weekResetAt)))\(suffix)")
            lines.append("Codex source: \(snapshot.sourcePath ?? codexReader.sourceDescription)")
        }
        if let snapshot = latestClaudeSnapshot {
            let suffix = claudeSnapshotIsStale ? " (last known)" : ""
            lines.append("Claude session (S) remaining: \(formatPercent(effectiveValue(snapshot.sessionRemainingPercent, resetAt: snapshot.sessionResetAt)))\(suffix)")
            lines.append("Claude weekly (W) remaining: \(formatPercent(effectiveValue(snapshot.weekRemainingPercent, resetAt: snapshot.weekResetAt)))\(suffix)")
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

    // Expiry is judged PER WINDOW, not per snapshot. A lapsed 5-hour session
    // window only invalidates the session value (the window has reset and no
    // fresh event exists yet); the weekly window usually resets much later
    // and stays perfectly valid. Discarding the whole snapshot used to blank
    // the entire bar every time Codex sat idle past one session window.
    // Only overall age still expires a snapshot as a whole.

    private func isCodexSnapshotDisplayable(_ snapshot: RateLimitSnapshot) -> Bool {
        guard let basis = snapshot.readAt ?? snapshot.eventAt else { return false }
        return Date().timeIntervalSince(basis) <= Self.maxSnapshotAge
    }

    private func isClaudeSnapshotDisplayable(_ snapshot: ClaudeUsageSnapshot) -> Bool {
        guard let basis = snapshot.readAt else { return false }
        return Date().timeIntervalSince(basis) <= Self.maxSnapshotAge
    }

    /// Returns nil for a window whose reset time has already passed.
    private func effectiveValue(_ value: Int?, resetAt: Date?) -> Int? {
        guard let value else { return nil }
        if let resetAt, resetAt <= Date() {
            return nil
        }
        return value
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

    private func logErrorIfNeeded(source: String, _ message: String) {
        let now = Date()
        if let last = lastLoggedErrors[source],
           last.message == message,
           now.timeIntervalSince(last.at) < Self.repeatedErrorLogInterval {
            return
        }

        lastLoggedErrors[source] = (message, now)
        log("\(source) refresh error \(message)")
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
