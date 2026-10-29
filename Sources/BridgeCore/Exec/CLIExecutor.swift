import Foundation

/// Runs authorized requests through the AWS CLI. See docs/technical.md 4.4.
///
///  - direct subprocess, no shell: arguments are an array;
///  - the executor owns every global option (profile, region, output, pager, color); `ExecRequest` has no
///    field to set `--endpoint-url`, `--debug`, `--no-sign-request`, `--ca-bundle` or anything similar;
///  - the child's environment is built from an allowlist, so `AWS_ACCESS_KEY_ID`, `AWS_PROFILE`,
///    `AWS_ENDPOINT_URL` and friends in the launching shell cannot redirect a call;
///  - it only runs `AuthorizedRequest` values, which only `Authorizer` can create.
public struct CLIExecutor: Sendable {
    public let awsPath: String
    public let environment: [String: String]
    public let outputCapBytes: Int

    public init(awsPath: String, environment: [String: String] = ProcessInfo.processInfo.environment,
                outputCapBytes: Int = 20 * 1024 * 1024) {
        self.awsPath = awsPath
        self.environment = environment
        self.outputCapBytes = outputCapBytes
    }

    /// The first `aws` found at a fixed set of locations (never resolved from the caller's PATH per call).
    public static func discoverAwsPath() -> String? {
        ["/opt/homebrew/bin/aws", "/usr/local/bin/aws"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: Pure helpers (unit-tested without running anything)

    /// Environment variables that may pass through from the launching process. Everything else is dropped,
    /// in particular every other `AWS_*` variable.
    static let passthrough: Set<String> = [
        "HOME", "USER", "LANG", "LC_ALL", "TMPDIR",
        "AWS_CONFIG_FILE", "AWS_SHARED_CREDENTIALS_FILE", // select WHICH config is used, not what it says
        "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "https_proxy", "http_proxy", "no_proxy",
        "AWS_CA_BUNDLE", "SSL_CERT_FILE",
    ]
    /// Fixed PATH. `credential_process` commands (e.g. from Homebrew) must be findable, nothing else is added.
    static let fixedPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

    public static func sanitizedEnvironment(from source: [String: String]) -> [String: String] {
        var out = source.filter { passthrough.contains($0.key) }
        out["PATH"] = fixedPath
        out["AWS_PAGER"] = ""
        return out
    }

    public static func arguments(for r: ExecRequest, inputFile: String?) -> [String] {
        var a = [r.service, r.operation, "--profile", r.profile, "--region", r.region,
                 "--output", "json", "--no-cli-pager", "--color", "off"]
        if let m = r.maxItems { a += ["--max-items", String(m)] }
        if let t = r.startingToken { a += ["--starting-token", t] }
        if let f = inputFile { a += ["--cli-input-json", "file://" + f] }
        return a
    }

    /// A copy-pasteable command for the UI. Parameters are shown inline; the real argv passes them by file.
    public static func commandDisplay(for r: ExecRequest) -> String {
        var parts = ["aws", r.service, r.operation, "--profile", shellQuote(r.profile), "--region", r.region]
        if let m = r.maxItems { parts += ["--max-items", String(m)] }
        if let t = r.startingToken { parts += ["--starting-token", shellQuote(t)] }
        if let p = r.params, !p.isEmptyContainer { parts += ["--cli-input-json", shellQuote(p.compactString())] }
        return parts.joined(separator: " ")
    }

    static func shellQuote(_ s: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        if !s.isEmpty, s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Running

    /// Local configuration discovery only. No credential values or AWS service requests.
    public func profileNames() async throws -> [String] {
        let result = try await ProcessRunner.run(executable: awsPath,
            arguments: ["configure", "list-profiles", "--no-cli-pager"],
            environment: Self.sanitizedEnvironment(from: environment), timeout: 10, stdoutCap: 256 * 1024)
        if result.cancelled { throw CancellationError() }
        if result.timedOut { throw ExecError.timedOut(seconds: 10) }
        if result.stdoutTruncated { throw ExecError.outputTooLarge(limitBytes: 256 * 1024) }
        guard !result.signaled, result.status == 0 else {
            // CLI diagnostics can include config contents; keep discovery errors generic.
            throw ExecError.invalidRequest("AWS CLI could not list local profiles. Check your AWS configuration.")
        }
        return String(decoding: result.stdout, as: UTF8.self).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public func run(_ authorized: AuthorizedRequest) async throws -> ExecResult {
        let request = authorized.request
        if let problem = request.validate() { throw ExecError.invalidRequest(problem) }
        try CredentialProcessTrust.check(profile: request.profile, environment: environment)

        // Nested parameters travel through a 0600 file in a 0700 directory that exists only for this call.
        var tempDir: String?
        var inputFile: String?
        if let params = request.params, !params.isEmptyContainer {
            let dir = NSTemporaryDirectory() + "bridge-" + UUID().uuidString
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let file = dir + "/input.json"
            FileManager.default.createFile(atPath: file, contents: try params.data(), attributes: [.posixPermissions: 0o600])
            tempDir = dir
            inputFile = file
        }
        defer { if let d = tempDir { try? FileManager.default.removeItem(atPath: d) } }

        let outcome: ProcessOutcome
        do {
            outcome = try await ProcessRunner.run(
                executable: awsPath, arguments: Self.arguments(for: request, inputFile: inputFile),
                environment: Self.sanitizedEnvironment(from: environment),
                timeout: request.timeout, stdoutCap: outputCapBytes)
        } catch let e as ProcessError {
            switch e {
            case .spawnFailed(let n), .pipeFailed(let n): throw ExecError.spawnFailed(errno: n)
            }
        }

        if outcome.cancelled { throw CancellationError() }
        if outcome.timedOut { throw ExecError.timedOut(seconds: request.timeout) }
        if outcome.stdoutTruncated { throw ExecError.outputTooLarge(limitBytes: outputCapBytes) }

        let stderrText = String(decoding: outcome.stderr.prefix(4096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if outcome.signaled || outcome.status != 0 { throw ExecError.fromFailure(status: outcome.status, stderr: stderrText) }

        var json: JSONValue?
        if !outcome.stdout.allSatisfy({ $0 == 0x20 || $0 == 0x0a || $0 == 0x0d || $0 == 0x09 }) {
            do { json = try JSONValue.parse(outcome.stdout) } catch { throw ExecError.invalidJSON("\(error)") }
        }
        return ExecResult(request: request, commandDisplay: Self.commandDisplay(for: request), json: json,
                          nextToken: json?["NextToken"]?.stringValue, stderr: stderrText,
                          durationMs: outcome.durationMs, fetchedAt: Date(), sensitive: authorized.sensitive)
    }
}
