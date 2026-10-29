# Changelog

## Unreleased — open-source preparation

App metadata: version 0.1.0, build 2 (pre-release review build).

- Adopt Apache-2.0, retain Waffle build-script attribution and include LICENSE/NOTICE in app bundles.

- Enforce credential-helper approval before identity probes, requests and S3 transfers, including source-profile chains and changed commands.
- Add human review of credential helpers and an explicit hash-based CLI approval command.
- Treat full Lambda function responses as sensitive: exclude from result caching, assistant reads and command history.
- Default GUI downloads to no-clobber, with an explicit Replace flow for existing destinations.
- Expose experimental Core and native UI library products; extract shared workspace layout and metric charts.
- Add an execution-backend interface, an offline library-consumer example and adapter contract checks.
- Compile UI self-tests only into the dedicated test build; verify ad-hoc bundle signing and fail on signing errors.
- Add contributor, security, architecture and SDK/UI documentation and local artifact ignore rules.

No public release or production-readiness claim is implied. See `docs/open-source-readiness.md` for remaining gates.
