# Privacy

Bridge uses selected local AWS profiles. AWS requests send operation parameters to AWS under that profile. The app is a local developer tool, not a local-only AWS simulator. Demo bundles instead use invented data and fake executables.

Local files include AWS configuration owned by the user, Bridge profile/trust settings, optional assistant consent records and saved investigations. Investigations can contain resource names and profile/context information even though they do not save full AWS responses. Treat them as potentially private. Ordinary result cache and command history are memory-only; sensitive responses are excluded. Parameter/staging files are temporary and cleaned on normal completion/cancellation.

AWS CLI may maintain its own credential/SSO caches. Credential helpers execute local programs after human approval and have their own behavior. Bridge does not sandbox those programs. Local diagnostics and external tools may retain data independently; do not paste them unreviewed into public issues.

Optional assistant tools can return AWS metadata, log text and other allowed results to Claude Code or Codex and onward to their model provider. Masking, caps and redaction reduce exposure but cannot guarantee arbitrary text contains no secrets. Provider retention/training behavior and CLI configuration must be reviewed against the selected provider/version. Assistant integration remains experimental and requires provider-specific consent.

See [security-model.md](security-model.md) for enforcement and limitations. No public telemetry/retention guarantees beyond the audited implementation should be inferred from this document; publication review remains in progress.
