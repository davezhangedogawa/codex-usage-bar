import Cocoa

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
        let candidates = try readRecentRolloutPaths().compactMap { path -> SnapshotCandidate? in
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

        guard let newest = candidates.max(by: { lhs, rhs in
            (lhs.snapshot.eventAt ?? .distantPast) < (rhs.snapshot.eventAt ?? .distantPast)
        }) else {
            throw ReaderError.noRateLimitEvent
        }

        latestSourcePath = newest.path
        return newest.snapshot
    }

    private func parseSnapshot(from content: String, sourcePath: String) -> RateLimitSnapshot? {
        let decoder = JSONDecoder()
        let isoFormatter = ISO8601DateFormatter()

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
            let eventAt = event.timestamp.flatMap { isoFormatter.date(from: $0) }

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

        let paths = try runSQLite(dbPath: stateDbPath, sql: sql)
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

    private func runSQLite(dbPath: String, sql: String) throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "-separator", "\t", dbPath, sql]
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw ReaderError.sqlite(error.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return output
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

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let maxLogBytes: UInt64 = 1 * 1024 * 1024
    private static let repeatedErrorLogInterval: TimeInterval = 15 * 60
    private static let cachedSnapshotKey = "lastGoodRateLimitSnapshot"
    private static let maxSnapshotAge: TimeInterval = 6 * 60 * 60

    private let reader = RateLimitReader()
    private let statusItem = NSStatusBar.system.statusItem(withLength: 136)
    private var timer: Timer?
    private var latestSnapshot: RateLimitSnapshot?
    private var latestSnapshotIsStale = false
    private var latestError: Error?
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
            button.title = "S -- W --"
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "Codex usage")
            button.imagePosition = .imageLeading
            button.toolTip = "Codex usage remaining"
            log("status item button configured")
        } else {
            log("status item button was nil")
        }

        restoreCachedSnapshot()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func refresh() {
        do {
            let snapshot = try reader.read()
            guard isSnapshotDisplayable(snapshot) else {
                throw DisplayError.snapshotExpired
            }
            latestSnapshot = snapshot
            latestSnapshotIsStale = false
            latestError = nil
            cacheSnapshot(snapshot)
            updateStatusItem(with: snapshot, isStale: false)
        } catch {
            latestError = error
            if let snapshot = latestSnapshot, isSnapshotDisplayable(snapshot) {
                latestSnapshotIsStale = true
                updateStatusItem(with: snapshot, isStale: true)
            } else {
                latestSnapshot = nil
                latestSnapshotIsStale = false
                statusItem.button?.title = "S -- W --"
                statusItem.button?.toolTip = "Codex usage is not available yet: \(error.localizedDescription)"
            }
            logErrorIfNeeded(error.localizedDescription)
        }

        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        if let snapshot = latestSnapshot {
            addHeader(latestSnapshotIsStale ? "Usage Remaining (Last Known)" : "Usage Remaining", to: menu)
            addValue("Current session", value: "\(snapshot.sessionRemainingPercent)% remaining", to: menu)
            addValue("This week", value: formatRemaining(snapshot.weekRemainingPercent), to: menu)

            menu.addItem(.separator())
            addHeader("Details", to: menu)
            addValue("Freshness", value: latestSnapshotIsStale ? "last known value" : "live", to: menu)
            if let readAt = snapshot.readAt {
                addValue("Read age", value: formatAge(since: readAt), to: menu)
            }
            addValue("Current session used", value: "\(snapshot.sessionUsedPercent)%", to: menu)
            addValue("This week used", value: formatPercent(snapshot.weekUsedPercent), to: menu)
            addValue("Plan", value: snapshot.planType, to: menu)
            addValue("Status", value: snapshot.limitReached ? "limit reached" : (snapshot.allowed ? "allowed" : "not allowed"), to: menu)

            if let sessionReset = snapshot.sessionResetAt {
                addValue("Session resets", value: Self.dateFormatter.string(from: sessionReset), to: menu)
            }
            if let weekReset = snapshot.weekResetAt {
                addValue("Week resets", value: Self.dateFormatter.string(from: weekReset), to: menu)
            }
            if let eventAt = snapshot.eventAt {
                addValue("Last updated", value: Self.dateFormatter.string(from: eventAt), to: menu)
            }
            if let sourcePath = snapshot.sourcePath {
                addValue("Source", value: sourcePath, to: menu)
            }
        } else {
            addHeader("Usage Pending", to: menu)
            addValue("Status", value: "waiting for first rate_limits payload", to: menu)
        }

        if let error = latestError {
            addHeader("Read Error", to: menu)
            addValue("Message", value: error.localizedDescription, to: menu)
        }

        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshFromMenu), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let copyItem = NSMenuItem(title: "Copy Summary", action: #selector(copySummary), keyEquivalent: "c")
        copyItem.target = self
        copyItem.isEnabled = latestSnapshot != nil
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
        refresh()
    }

    @objc private func copySummary() {
        guard let snapshot = latestSnapshot else { return }

        let text = """
        Codex current session remaining: \(snapshot.sessionRemainingPercent)%\(latestSnapshotIsStale ? " (last known)" : "")
        Codex this week remaining: \(formatPercent(snapshot.weekRemainingPercent))\(latestSnapshotIsStale ? " (last known)" : "")
        Current session used: \(snapshot.sessionUsedPercent)%
        This week used: \(formatPercent(snapshot.weekUsedPercent))
        Source: \(snapshot.sourcePath ?? reader.sourceDescription)
        """

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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

    private func restoreCachedSnapshot() {
        guard let data = UserDefaults.standard.data(forKey: Self.cachedSnapshotKey),
              let snapshot = try? JSONDecoder().decode(RateLimitSnapshot.self, from: data) else {
            return
        }
        guard isSnapshotDisplayable(snapshot) else {
            UserDefaults.standard.removeObject(forKey: Self.cachedSnapshotKey)
            return
        }

        latestSnapshot = snapshot
        latestSnapshotIsStale = true
        updateStatusItem(with: snapshot, isStale: true)
    }

    private func cacheSnapshot(_ snapshot: RateLimitSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: Self.cachedSnapshotKey)
    }

    private func updateStatusItem(with snapshot: RateLimitSnapshot, isStale: Bool) {
        statusItem.button?.title = "S \(snapshot.sessionRemainingPercent)% W \(formatPercent(snapshot.weekRemainingPercent))"
        let prefix = isStale ? "Codex remaining (last known)" : "Codex remaining"
        let age = isStale ? ", read \(formatAge(since: snapshot.readAt))" : ""
        statusItem.button?.toolTip = "\(prefix): session \(snapshot.sessionRemainingPercent)%, week \(formatPercent(snapshot.weekRemainingPercent))\(age)"
    }

    private func isSnapshotDisplayable(_ snapshot: RateLimitSnapshot) -> Bool {
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
        log("refresh error \(message)")
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
            "The last Codex usage snapshot has expired and no fresh rate_limits payload is available yet."
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
