import Foundation

/// Backend seam used by the authorized client. Adapters execute only authorized requests and must
/// honor cancellation and response bounds. A credential-using adapter checks helper trust before spawning.
/// Implementations are injected at composition time, never selected by request parameters.
public protocol ExecutionBackend: Sendable {
    func checkCredentialTrust(profile: String) throws
    func run(_ request: AuthorizedRequest) async throws -> ExecResult
    func version() async -> String
}

extension CLIExecutor: ExecutionBackend {
    public func checkCredentialTrust(profile: String) throws {
        try CredentialProcessTrust.check(profile: profile, environment: environment)
    }
}
