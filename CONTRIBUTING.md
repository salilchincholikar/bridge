# Contributing to Bridge

Bridge is licensed under [Apache-2.0](LICENSE). Contributions submitted for inclusion are under the same license, subject to any separate written agreement. Include required attribution for adapted material; see [NOTICE](NOTICE). Publication review is still in progress in [the readiness tracker](docs/open-source-readiness.md).

## Development

Use macOS 14 or later and a Swift toolchain supporting the package's Swift tools version (currently 6.2). Command Line Tools are sufficient on the tested development machine. Check `swift --version` and `xcode-select -p`; a fresh-machine/toolchain matrix is still pending.

```sh
make test
make app
make demo-app
```

Open `build/Bridge Demo.app` for invented data. Its AWS and provider executables are fixtures. Do not use a personal or company account for an issue reproduction. Core tests use synthetic configuration, subprocesses and responses; they must never require credentials, sign-in or model-provider access. IPC/process-tree tests need normal local process permissions. GUI tests additionally need an interactive macOS session (`make ui-test-app`).

For restricted local build environments, `SWIFT_FLAGS='--disable-sandbox -debug-info-format none'` can be passed to `make test`; this is a build workaround, not a required application setting.

## Design and review

- Keep identity, authorization, sensitive-result classification and caching in Core. No feature may execute AWS independently of policy.
- Use direct argument arrays for subprocesses. Never interpolate request parameters into a shell command.
- Reuse native presentation modules. UI code must not discover credentials or own execution policy.
- Keep file moves separate from behavioral changes; avoid introducing framework rewrites into feature work.
- Document caller-visible errors, cancellation, scope and pagination. See [architecture](docs/architecture.md) and the [security model](docs/security-model.md).
- Add focused regressions for behavior changes. Test denied, empty, expired, cancelled and stale-context paths where applicable. Preserve the executable-test setup until an alternative works on the supported toolchain.

## Adding AWS operations

An operation needs an explicit policy-table review, request/response models, synthetic fixtures and relevant tests. A name such as `get-*` does not establish that a response is safe. Inspect nested environments, presigned URLs and secret-returning parameters before deciding sensitivity. Feature registration does not authorize execution.

Keep fixtures fictional: use `example.com`, invented resources and clearly synthetic credentials where a redaction test requires them. Do not paste real account IDs, ARNs, bucket names, logs, emails, tokens, presigned URLs or local paths into tests, screenshots, issues or PR descriptions. Prefer demo captures.

Before proposing a change, describe the user-visible result, validation and remaining limits. Never claim live AWS/provider compatibility from fixture-only tests. Include accessibility/keyboard and light/dark checks for UI changes. Signing keys and live credentials do not belong in contribution jobs.
