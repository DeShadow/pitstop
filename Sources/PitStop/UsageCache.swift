import Foundation

/// Persists the transient display state across launches so a relaunch whose
/// first fetch hits a rate limit degrades to stale bars (the existing
/// "showing HH:MM data" treatment) instead of a blank panel, and honors any
/// still-running backoff instead of re-hammering the endpoint.
enum UsageCache {
    static let file = ProfileStore.directory.appendingPathComponent("usage-cache.json")

    /// Usage entries older than this are dropped on load — bars that stale
    /// mislead more than they inform, and the time-only "showing HH:MM data"
    /// stamp stops making sense across days.
    static let maxAge: TimeInterval = 24 * 3600
    /// Restored backoffs are clamped to the live maximum (recordFetchError's
    /// cap) so a corrupt future date can't freeze an account's fetches
    /// across every subsequent launch.
    static let maxBackoff: TimeInterval = 900

    /// The dictionaries AppDelegate keeps per account key, verbatim.
    struct Snapshot: Codable, Equatable {
        var usage: [String: UsageReport] = [:]
        var codexUsage: [String: Codex.Usage] = [:]
        var geminiUsage: [String: Gemini.Usage] = [:]
        var openCodeUsage: [String: OpenCode.Usage] = [:]
        var fetchError: [String: String] = [:]
        var failureCount: [String: Int] = [:]
        var nextFetchAllowed: [String: Date] = [:]
        var needsAction: Set<String> = []
        var desktopAccount: ClaudeDesktop.Account?

        init(usage: [String: UsageReport] = [:],
             codexUsage: [String: Codex.Usage] = [:],
             geminiUsage: [String: Gemini.Usage] = [:],
             openCodeUsage: [String: OpenCode.Usage] = [:],
             fetchError: [String: String] = [:],
             failureCount: [String: Int] = [:],
             nextFetchAllowed: [String: Date] = [:],
             needsAction: Set<String> = [],
             desktopAccount: ClaudeDesktop.Account? = nil) {
            self.usage = usage
            self.codexUsage = codexUsage
            self.geminiUsage = geminiUsage
            self.openCodeUsage = openCodeUsage
            self.fetchError = fetchError
            self.failureCount = failureCount
            self.nextFetchAllowed = nextFetchAllowed
            self.needsAction = needsAction
            self.desktopAccount = desktopAccount
        }

        private enum CodingKeys: String, CodingKey {
            case usage, codexUsage, geminiUsage, openCodeUsage, fetchError,
                 failureCount, nextFetchAllowed, needsAction, desktopAccount
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            usage = try container.decodeIfPresent([String: UsageReport].self, forKey: .usage) ?? [:]
            codexUsage = try container.decodeIfPresent([String: Codex.Usage].self, forKey: .codexUsage) ?? [:]
            geminiUsage = try container.decodeIfPresent([String: Gemini.Usage].self, forKey: .geminiUsage) ?? [:]
            openCodeUsage = try container.decodeIfPresent([String: OpenCode.Usage].self, forKey: .openCodeUsage) ?? [:]
            fetchError = try container.decodeIfPresent([String: String].self, forKey: .fetchError) ?? [:]
            failureCount = try container.decodeIfPresent([String: Int].self, forKey: .failureCount) ?? [:]
            nextFetchAllowed = try container.decodeIfPresent([String: Date].self, forKey: .nextFetchAllowed) ?? [:]
            needsAction = try container.decodeIfPresent(Set<String>.self, forKey: .needsAction) ?? []
            desktopAccount = try container.decodeIfPresent(ClaudeDesktop.Account.self, forKey: .desktopAccount)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(usage, forKey: .usage)
            try container.encode(codexUsage, forKey: .codexUsage)
            try container.encode(geminiUsage, forKey: .geminiUsage)
            try container.encode(openCodeUsage, forKey: .openCodeUsage)
            try container.encode(fetchError, forKey: .fetchError)
            try container.encode(failureCount, forKey: .failureCount)
            try container.encode(nextFetchAllowed, forKey: .nextFetchAllowed)
            try container.encode(needsAction, forKey: .needsAction)
            try container.encodeIfPresent(desktopAccount, forKey: .desktopAccount)
        }
    }

    static func save(_ snapshot: Snapshot, to url: URL = file) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try AtomicFile.write(JSONEncoder().encode(snapshot), to: url)
    }

    /// nil when the file is missing or unreadable — the caller starts empty,
    /// exactly like a pre-cache launch. Errors and needs-action gates are
    /// kept regardless of age (an expired session stays expired); only the
    /// usage bars age out.
    static func load(from url: URL = file, now: Date = Date()) -> Snapshot? {
        guard let data = try? Data(contentsOf: url),
              var snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
        snap.usage = snap.usage.filter { now.timeIntervalSince($0.value.fetchedAt) < maxAge }
        snap.codexUsage = snap.codexUsage.filter { now.timeIntervalSince($0.value.fetchedAt) < maxAge }
        snap.geminiUsage = snap.geminiUsage.filter { now.timeIntervalSince($0.value.fetchedAt) < maxAge }
        snap.openCodeUsage = snap.openCodeUsage.filter { now.timeIntervalSince($0.value.fetchedAt) < maxAge }
        snap.nextFetchAllowed = snap.nextFetchAllowed.mapValues {
            min($0, now.addingTimeInterval(maxBackoff))
        }
        return snap
    }
}
