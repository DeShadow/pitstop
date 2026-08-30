import AppKit

@MainActor
protocol CodexApplicationControlling {
    func applicationURL() -> URL?
    func isRunning() -> Bool
    func quitNormallyIfRunning() async throws
    func launch(at url: URL) async throws
}

/// Controls the Codex desktop app around an auth.json swap. The app's bundle
/// is currently named ChatGPT.app, so identify it by bundle ID rather than by
/// a path or display name.
@MainActor
final class CodexApplicationController: CodexApplicationControlling {
    struct LifecycleError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let bundleIdentifier = "com.openai.codex"

    func applicationURL() -> URL? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
            .first?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier)
    }

    func isRunning() -> Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.bundleIdentifier).isEmpty
    }

    func quitNormallyIfRunning() async throws {
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.bundleIdentifier)
        guard !running.isEmpty else { return }

        let accepted = running.map { $0.terminate() }
        if accepted.contains(false), isRunning() {
            throw LifecycleError(message: "Codex did not accept the quit request; the account was not changed")
        }

        // A normal quit lets Codex finish or ask about running tasks. If the
        // user cancels that quit, leave auth.json untouched and fail closed.
        let deadline = Date().addingTimeInterval(30)
        while running.contains(where: { !$0.isTerminated }) {
            guard Date() < deadline else {
                throw LifecycleError(message: "Codex is still open; the account was not changed. Finish its running tasks or close Codex, then try again")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func launch(at url: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { running, error in
                if let error { continuation.resume(throwing: error) }
                else if running != nil {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: LifecycleError(
                        message: "Codex launch returned without a running application"))
                }
            }
        }

        // Let Codex complete its initial credential read before verification.
        try await Task.sleep(nanoseconds: 500_000_000)
    }
}

/// Keeps the credential swap between a completed normal quit and the relaunch,
/// so a running Codex process cannot write its old in-memory auth back to disk.
@MainActor
struct CodexSwitchWorkflow {
    struct WorkflowError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The credential write already ran, so the caller must re-read auth.json
    /// instead of assuming either the old or requested account is live.
    struct PostSwitchError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let application: CodexApplicationControlling

    /// Returns true when an installed Codex app was reopened. Every path that
    /// can observe a running app either completes a normal quit first or
    /// aborts before the credential write.
    func run(relaunchApplication: Bool,
             switchCredentials: () async throws -> Void,
             verifyCredentials: () -> Bool) async throws -> Bool {
        let wasRunning = application.isRunning()

        guard relaunchApplication else {
            guard !wasRunning else {
                throw WorkflowError(message: "Codex is open. Close it before switching accounts, or enable Codex relaunch in Settings")
            }
            try await switchCredentials()
            guard verifyCredentials() else {
                throw PostSwitchError(message: "auth.json does not contain the selected account after switching")
            }
            return false
        }

        guard let appURL = application.applicationURL() else {
            guard !wasRunning else {
                throw WorkflowError(message: "PitStop could not locate the running Codex app; the account was not changed")
            }
            try await switchCredentials()
            guard verifyCredentials() else {
                throw PostSwitchError(message: "auth.json does not contain the selected account after switching")
            }
            return false
        }

        try await application.quitNormallyIfRunning()
        do {
            try await switchCredentials()
        } catch {
            // Restore the user's pre-switch working state when the credential
            // swap itself fails after Codex has already been stopped.
            if wasRunning { try? await application.launch(at: appURL) }
            throw error
        }

        do {
            try await application.launch(at: appURL)
        } catch {
            throw PostSwitchError(
                message: "The account was changed, but Codex could not be reopened: \(error.localizedDescription)")
        }
        guard verifyCredentials() else {
            throw PostSwitchError(message: "Codex reopened, but auth.json does not contain the selected account")
        }
        return true
    }
}
