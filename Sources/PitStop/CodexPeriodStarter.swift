import Foundation

/// Starts an unused weekly period without switching accounts or touching auth.json.
enum CodexPeriodStarter {
    static func shouldStart(usage: Codex.Usage, lastAttempt: Date?, now: Date = Date()) -> Bool {
        usage.idlePeriodSeconds != nil &&
            (lastAttempt.map { now.timeIntervalSince($0) >= SessionWarmer.attemptCooldown } ?? true)
    }

    static func greetingRequest(_ creds: Codex.Creds) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/codex/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(creds.accountId, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-6.1-sol",
            "instructions": "Reply briefly to the greeting.",
            "input": [["role": "user", "content": [["type": "input_text", "text": "Привет"]]]],
            "stream": true,
            "store": false,
            "reasoning": ["effort": "low"],
        ])
        return request
    }

    static func sendGreeting(_ creds: Codex.Creds) async throws {
        let (data, response) = try await URLSession.shared.data(for: greetingRequest(creds))
        guard let http = response as? HTTPURLResponse else { throw StartError() }
        if let error = Codex.usageResponseError(statusCode: http.statusCode,
                retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)) {
            throw error
        }
        try validateCompletion(data)
    }

    static func validateCompletion(_ data: Data) throws {
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("data: "),
                  let event = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8))
                    as? [String: Any] else { continue }
            if event["type"] as? String == "response.completed",
               let response = event["response"] as? [String: Any],
               response["status"] as? String == "completed" { return }
        }
        throw StartError()
    }

    struct StartError: LocalizedError {
        var errorDescription: String? { "Codex greeting did not complete; will retry later" }
    }
}
