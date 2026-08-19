import Foundation

/// OpenCode Go's local API credential and subscription quota endpoint.
/// OpenCode stores provider credentials in ~/.local/share/opencode/auth.json;
/// the official Go endpoint reports rolling, weekly, and monthly percentages.
enum OpenCode {
    struct Usage: Codable, Equatable {
        struct Window: Codable, Equatable {
            var label: String
            var usedPercent: Double
            var resetsAt: Date?
        }

        var windows: [Window]
        var useBalance = false
        var fetchedAt = Date()

        var maxUtilization: Double { windows.map(\.usedPercent).max() ?? 0 }

        func maxUtilization(kinds: Set<LimitKind>) -> Double? {
            // OpenCode Go has the same account-wide short and long windows as
            // Codex, plus a monthly long window.
            windows.filter { window in
                switch window.label {
                case "5h": return kinds.contains(.session)
                default: return kinds.contains(.weekly)
                }
            }.map(\.usedPercent).max()
        }
    }

    enum OpenCodeError: LocalizedError {
        case unauthorized
        case noSubscription
        case malformed
        case notSignedIn
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .unauthorized: return "OpenCode Go token rejected — reconnect OpenCode Go"
            case .noSubscription: return "OpenCode Go subscription required"
            case .malformed: return "Unexpected OpenCode Go usage response"
            case .notSignedIn: return "Not connected to OpenCode Go"
            case .http(let code): return "HTTP \(code) from OpenCode Go"
            }
        }
    }

    static let authURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/opencode/auth.json")
    static let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!

    static var isPresent: Bool {
        apiKey() != nil
    }

    /// The OpenCode auth file contains one object per provider ID. Only the
    /// OpenCode Go API key is relevant to this provider integration.
    static func apiKey(from data: Data? = try? Data(contentsOf: authURL)) -> String? {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = root["opencode-go"] as? [String: Any],
              auth["type"] as? String == "api",
              let key = auth["key"] as? String,
              !key.isEmpty else { return nil }
        return key
    }

    static func liveUsage() async throws -> Usage {
        guard let key = apiKey() else { throw OpenCodeError.notSignedIn }
        var request = URLRequest(url: usageURL)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("PitStop", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenCodeError.malformed }
        if http.statusCode == 401 { throw OpenCodeError.unauthorized }
        if http.statusCode == 403 { throw OpenCodeError.noSubscription }
        guard http.statusCode == 200 else { throw OpenCodeError.http(http.statusCode) }
        return try parseUsage(data)
    }

    /// Parse the endpoint's usage objects. The endpoint has returned both the
    /// original rollingUsage/usagePercent/resetInSec shape and the current
    /// usage/percent/resetsAt shape, so accept both during the API transition.
    static func parseUsage(_ data: Data, now: Date = Date()) throws -> Usage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenCodeError.malformed
        }
        let windows: [(String, String, String)] = [
            ("5h", "rollingUsage", "rolling"),
            ("7d", "weeklyUsage", "weekly"),
            ("30d", "monthlyUsage", "monthly"),
        ]
        let current = root["usage"] as? [String: Any]
        let parsed = windows.compactMap { label, legacyKey, currentKey -> Usage.Window? in
            let value = (current?[currentKey] as? [String: Any]) ??
                (root[legacyKey] as? [String: Any])
            guard let value,
                  let percent = (value["percent"] as? NSNumber)?.doubleValue
                    ?? (value["usagePercent"] as? NSNumber)?.doubleValue else { return nil }
            let reset: Date?
            if let resetString = value["resetsAt"] as? String {
                reset = iso8601.date(from: resetString)
            } else if let seconds = (value["resetInSec"] as? NSNumber)?.doubleValue {
                reset = now.addingTimeInterval(seconds)
            } else {
                reset = nil
            }
            return Usage.Window(label: label,
                                usedPercent: max(0, min(100, percent)),
                                resetsAt: reset)
        }
        guard !parsed.isEmpty else { throw OpenCodeError.malformed }
        return Usage(windows: parsed,
                     useBalance: (root["useBalance"] as? Bool)
                         ?? ((root["usage"] as? [String: Any])?["useBalance"] as? Bool)
                         ?? false,
                     fetchedAt: now)
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
