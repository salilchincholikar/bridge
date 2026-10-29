import Foundation
import Darwin

public enum TransferError: Error, Equatable, Sendable {
    case notATransfer
    case invalidParams(String)
    case path(PathError)
    case destinationMissing
    case destinationExists(String)
    case timedOut(seconds: Double)
    case authExpired(stderr: String)
    case failed(status: Int32, stderr: String)
    case spawnFailed(errno: Int32)
}

public struct DownloadResult: Equatable, Sendable {
    public var finalPath: String
    public var bytes: Int64
    public var durationMs: Double
    public var commandDisplay: String
}

/// Downloads one S3 object to a local folder (tier 2). docs/technical.md 4.6:
///  - the destination is chosen by the caller (a folder picker); the file name comes from the sanitized key or the caller’s explicit save-panel name;
///  - each transfer has a private staging directory on the destination volume; final rename happens only on success;
///  - cancel, timeout or failure delete the part file, so no partial file is ever left under the final name;
///  - an existing file is never overwritten unless `overwrite` is true (and then the swap is a single rename).
public struct S3Downloader: Sendable {
    public static let partSuffix = ".bridge-part"
    public static let stagingPrefix = ".bridge-transfer-"
    public let awsPath: String
    public let environment: [String: String]

    public init(awsPath: String, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.awsPath = awsPath
        self.environment = environment
    }

    /// `progress` receives the number of bytes written so far, polled about four times a second.
    public func download(_ authorized: AuthorizedRequest, to folder: URL, overwrite: Bool = false, fileName: String? = nil,
                         progress: (@Sendable (Int64) -> Void)? = nil) async throws -> DownloadResult {
        let r = authorized.request
        guard r.service == "s3api", r.operation == "get-object", authorized.tier == .transfer else { throw TransferError.notATransfer }
        guard case .object(let p)? = r.params, let bucket = p["Bucket"]?.stringValue, let key = p["Key"]?.stringValue,
              !bucket.isEmpty, !key.isEmpty else { throw TransferError.invalidParams("Bucket and Key are required") }
        if let problem = r.validate() { throw TransferError.invalidParams(problem) }
        try CredentialProcessTrust.check(profile: r.profile, environment: environment)

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { throw TransferError.destinationMissing }

        let finalURL: URL
        do {
            let keyName = try PathSanitizer.fileName(forKey: key)
            if let fileName, fileName.contains("/") || fileName.contains("\\") { throw PathError.traversal(fileName) }
            let name = try fileName.map { try PathSanitizer.fileName(forKey: $0) } ?? keyName
            finalURL = try PathSanitizer.destinationURL(folder: folder, relativePath: name)
        } catch let e as PathError { throw TransferError.path(e) }
        if !overwrite, FileManager.default.fileExists(atPath: finalURL.path) { throw TransferError.destinationExists(finalURL.path) }

        let staging = folder.appendingPathComponent(Self.stagingPrefix + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let partPath = staging.appendingPathComponent("payload" + Self.partSuffix).path
        defer { try? FileManager.default.removeItem(at: staging) }

        // `--bucket=B --key=K` (one argument each) so a key starting with "-" cannot be read as a flag.
        let args = ["s3api", "get-object", "--bucket=\(bucket)", "--key=\(key)", "--profile", r.profile, "--region", r.region,
                    "--output", "json", "--no-cli-pager", "--color", "off", partPath]
        let env = CLIExecutor.sanitizedEnvironment(from: environment)

        let poller: Task<Void, Never>? = progress.map { report in
            Task {
                while !Task.isCancelled {
                    if let size = (try? FileManager.default.attributesOfItem(atPath: partPath))?[.size] as? NSNumber { report(size.int64Value) }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
        }
        defer { poller?.cancel() }

        let outcome: ProcessOutcome
        do {
            outcome = try await ProcessRunner.run(executable: awsPath, arguments: args, environment: env,
                                                  timeout: r.timeout, stdoutCap: 1_000_000)
        } catch let e as ProcessError {
            switch e { case .spawnFailed(let n), .pipeFailed(let n): throw TransferError.spawnFailed(errno: n) }
        }

        if outcome.cancelled { throw CancellationError() }
        if outcome.timedOut { throw TransferError.timedOut(seconds: r.timeout) }
        let stderr = String(decoding: outcome.stderr.prefix(4096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if outcome.signaled || outcome.status != 0 {
            switch ExecError.fromFailure(status: outcome.status, stderr: stderr) {
            case .authExpired(let s): throw TransferError.authExpired(stderr: s)
            default: throw TransferError.failed(status: outcome.status, stderr: stderr)
            }
        }

        // Move into place. Without `overwrite`, RENAME_EXCL refuses to clobber a file that appeared meanwhile.
        let rc: Int32 = overwrite ? rename(partPath, finalURL.path) : renamex_np(partPath, finalURL.path, UInt32(RENAME_EXCL))
        if rc != 0 {
            if errno == EEXIST { throw TransferError.destinationExists(finalURL.path) }
            throw TransferError.failed(status: errno, stderr: "could not move the finished download into place")
        }
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: finalURL.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let display = "aws s3api get-object --bucket \(CLIExecutor.shellQuote(bucket)) --key \(CLIExecutor.shellQuote(key)) "
            + "--profile \(CLIExecutor.shellQuote(r.profile)) --region \(r.region) \(CLIExecutor.shellQuote(finalURL.path))"
        return DownloadResult(finalPath: finalURL.path, bytes: bytes, durationMs: outcome.durationMs, commandDisplay: display)
    }

    /// Removes `*.bridge-part` files older than `olderThan` seconds. Call at startup for folders you download into.
    @discardableResult
    public static func sweepStaleParts(in folder: URL, olderThan: TimeInterval = 24 * 3600, now: Date = Date()) -> Int {
        let fm = FileManager.default
        var removed = 0
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(partSuffix) || name.hasPrefix(stagingPrefix) {
            let path = folder.appendingPathComponent(name).path
            if let m = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date, now.timeIntervalSince(m) > olderThan {
                if (try? fm.removeItem(atPath: path)) != nil { removed += 1 }
            }
        }
        return removed
    }
}
