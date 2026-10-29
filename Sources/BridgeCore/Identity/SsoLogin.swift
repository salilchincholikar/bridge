import Foundation

/// What the user must do to finish an IAM Identity Center login.
public struct SsoLoginPrompt: Equatable, Sendable {
    public var url: String?
    public var userCode: String?

    public init(url: String?, userCode: String?) { self.url = url; self.userCode = userCode }

    /// Best-effort extraction from the CLI's text. The exact wording of `aws sso login` output is
    /// `[unverified]` here, so this only looks for an https URL and a code shaped like `ABCD-EFGH`, and the
    /// caller should always also show the raw text.
    public static func parse(_ text: String) -> SsoLoginPrompt {
        var url: String?
        if let r = text.range(of: #"https://[^\s"'<>]+"#, options: .regularExpression) { url = String(text[r]) }
        var code: String?
        if let r = text.range(of: #"\b[A-Z0-9]{4}-[A-Z0-9]{4}\b"#, options: .regularExpression) { code = String(text[r]) }
        return SsoLoginPrompt(url: url, userCode: code)
    }
}

public enum SsoLoginError: Error, Equatable, Sendable {
    case invalidProfile
    case timedOut(seconds: Double)
    case failed(status: Int32, stderr: String)
    case spawnFailed(errno: Int32)
}

/// Runs `aws sso login --profile P` (docs/technical.md 4.3). This is not an AWS API call, so it does not go
/// through `Authorizer`; it has its own fixed argument shape. Browser sign-in happens outside Bridge.
/// After it succeeds, call `IdentityStore.invalidate(profile)` so the next use re-verifies the identity.
public struct SsoLogin: Sendable {
    public let awsPath: String
    public let environment: [String: String]

    public init(awsPath: String, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.awsPath = awsPath
        self.environment = environment
    }

    public static func arguments(profile: String, noBrowser: Bool) -> [String] {
        ["sso", "login", "--profile", profile] + (noBrowser ? ["--no-browser"] : [])
    }

    /// `onText` gets the CLI's output as it arrives; `onPrompt` gets the parsed URL/code whenever they change.
    public func login(profile: String, noBrowser: Bool = false, timeout: TimeInterval = 300,
                      onText: (@Sendable (String) -> Void)? = nil,
                      onPrompt: (@Sendable (SsoLoginPrompt) -> Void)? = nil) async throws {
        guard ExecRequest.isSafeProfileName(profile) else { throw SsoLoginError.invalidProfile }

        let collected = TextBox()
        let outcome: ProcessOutcome
        do {
            outcome = try await ProcessRunner.run(
                executable: awsPath, arguments: Self.arguments(profile: profile, noBrowser: noBrowser),
                environment: CLIExecutor.sanitizedEnvironment(from: environment),
                timeout: timeout, stdoutCap: 256 * 1024) { data, _ in
                    let chunk = String(decoding: data, as: UTF8.self)
                    onText?(chunk)
                    if let onPrompt {
                        let (before, after) = collected.append(chunk)
                        if before != after { onPrompt(after) }
                    }
                }
        } catch let e as ProcessError {
            switch e { case .spawnFailed(let n), .pipeFailed(let n): throw SsoLoginError.spawnFailed(errno: n) }
        }
        if outcome.cancelled { throw CancellationError() }
        if outcome.timedOut { throw SsoLoginError.timedOut(seconds: timeout) }
        if outcome.signaled || outcome.status != 0 {
            let err = String(decoding: outcome.stderr.prefix(4096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw SsoLoginError.failed(status: outcome.status, stderr: err)
        }
    }

    private final class TextBox: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        private var prompt = SsoLoginPrompt(url: nil, userCode: nil)
        /// Appends, re-parses, and returns the prompt before and after.
        func append(_ s: String) -> (SsoLoginPrompt, SsoLoginPrompt) {
            lock.lock(); defer { lock.unlock() }
            let before = prompt
            text += s
            prompt = SsoLoginPrompt.parse(text)
            return (before, prompt)
        }
    }
}
