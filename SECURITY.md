# Security reporting

Bridge is pre-release software. Its publication review is in progress; no stable supported release or security response-time commitment is established yet.

Do not open a public issue containing credentials, sensitive AWS responses or exploit details. GitHub private vulnerability reporting is managed by the maintainer and is currently pending setup. It is separate from source publication. Until a private reporting route is enabled, do not post sensitive reports publicly.

For now, report concerns privately to the maintainer through an already established private channel. Do not include live keys or full account dumps. Describe the affected version, operation, expected/actual behavior and a synthetic reproduction where possible.

See [security-model.md](docs/security-model.md) for the enforcement model and its limits, and [open-source-readiness.md](docs/open-source-readiness.md) for unresolved release gates. Tests against fake executables do not establish isolation against every external CLI or provider version.
