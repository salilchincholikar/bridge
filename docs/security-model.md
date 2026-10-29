# Security and data handling

Bridge runs as the signed-in macOS user, outside App Sandbox. It can read local configuration, launch installed tools and download files. The AWS account's IAM policy remains the authoritative permission limit; Bridge adds application restrictions.

## Requests and credential helpers

Core uses an explicit operation table. Unsupported operations and credential-producing operations are denied. Tiers, protected profiles, account verification and caller type constrain allowed operations. The assistant tool set is read-only and excludes sensitive responses.

AWS CLI execution uses a fixed executable and argument array, private parameter files and an environment allowlist. Shell-exported AWS keys/profile/endpoint options are stripped. Selected config/credentials file paths and configured proxy/CA variables may pass through. Bridge itself does not parse shared credential values.

Before credential-using CLI requests and S3 downloads, Bridge re-reads AWS config, helper/role-chain metadata in the shared credentials file, and local trust settings. Credential values are discarded from the trust parser's input. An unapproved `credential_process` in the selected profile or its source-profile chain prevents spawning the CLI. Approval stores the SHA-256 of the exact command per profile. A changed command needs approval again. The app shows the command for human review; noninteractive calls fail closed. To review from the CLI:

```sh
bridge trust-credential-process my-profile
bridge trust-credential-process my-profile --approve-sha256 HASH_FROM_REVIEW
```

Approval does not execute the command. Treat helper commands as executable local code, not ordinary credentials metadata. The check includes the [AWS loader's credentials-file overrides](https://raw.githubusercontent.com/boto/botocore/develop/botocore/session.py), including helpers on credentials-only profiles. It does not sandbox helpers or defend against another process modifying configuration between the check and CLI resolution. Modified or unsupported CLI installations and arbitrary local configuration extensions are outside this guarantee. See AWS's [external-process configuration guidance](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sourcing-external.html).

Backslash-escaped AWS config section headers are currently rejected because Bridge cannot resolve them exactly like the CLI. Common quoted/spaced names are supported; literal names in the shared credentials file are preserved. Repair unsupported headers before using that configuration.

## Sensitive responses

Sensitive responses are excluded from the ordinary result cache, assistant tools and command history. Full Lambda function and configuration responses are sensitive because they may contain environment values and presigned code URLs. Authorized human inspectors can retain data in memory for explicit reveal; this is not secure-memory erasure. The CLI's human `run` command prints authorized results, so avoid redirecting sensitive output into logs.

Masking and pattern redaction reduce accidental exposure; they cannot identify every secret inside arbitrary log text or metadata. Never describe their output as guaranteed secret-free.

## Downloads

The remote S3 key is kept distinct from the local chosen filename. Path sanitization rejects traversal. Transfers stage output and rename after success; default no-clobber finalization refuses destinations created during a download. Replacing an existing destination requires explicit human or CLI `--overwrite` intent. Cancellation/failure cleans staging output. The GUI starts without replacement permission even after a save dialog and uses an explicit Replace action if the destination exists.

## Optional assistants

Assistant responses can send AWS resource names, log text, policies and account metadata to the selected model provider. Local execution does not imply local-only data. Consent is provider-specific, and sensitive/credential operations are excluded by policy. Provider versions, configuration/hooks and retention terms require separate verification. Assistant support remains experimental; do not infer security isolation or subscription compatibility from fake-harness tests.

## Publication gates

Private reporting, provenance/privacy review, provider compatibility review, representative real-account validation and release signing/distribution checks remain tracked in the [readiness plan](open-source-readiness.md). A successful build or offline test suite does not complete those gates.
