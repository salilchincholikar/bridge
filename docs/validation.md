# Local validation — 2026-10-29

The open-source implementation pass was checked locally with Apple Swift 6.4, Swift 5 language mode, an arm64 macOS toolchain and Command Line Tools. The deployment target is macOS 14; that minimum OS and Intel have not been verified on this machine.

| Check | Evidence |
|---|---|
| Core/assistant integration regressions | 723 checks, zero failures, with invented config/responses and fake subprocess/provider executables |
| Independent Core consumer | `make example` prints the synthetic function and verified synthetic account using an in-memory adapter; no AWS execution |
| Dedicated macOS UI harness | 179 checks, zero failures after module extraction and fictional-fixture renaming |
| Curated source assets | 32 JSON/plist assets parsed; fake executable permissions and shell syntax checked |
| Production/demo bundles | Rebuilt and locally ad-hoc signed; production signature/metadata checks pass, demo fixtures and UI-test entry point excluded; bundled LICENSE and NOTICE match repository copies |
| Direct CLI helper-review flow | Synthetic smoke checks pass: review, wrong-hash refusal, exact approval, fake identity and changed-command refusal |

Regressions added during this pass cover helper approval before STS/request/download spawning, role chains, changed commands, cached requests, corrupt/unreadable settings, case-insensitive/indented AWS options, shared-credentials overrides and literal profile names, safe assistant diagnostics, full Lambda response sensitivity, adapter policy enforcement, destination races and concurrent transfer staging.

The GUI run includes all destinations, details, context switches, drawer geometry/toggling, table fitting, Billing light/dark resizing and fake assistant harnesses. Offscreen hosted SwiftUI captures can be incomplete; the captures are not suitable public screenshots and do not prove visual acceptance. Broader native visual, accessibility and OS/architecture review remains pending.

The initial restricted-shell test run could not inspect process trees or create required local IPC sockets. Complete core/GUI checks used an approved local test session with the same offline fake executables. Such restrictions are not counted as passes. Compiler concurrency warnings remain inventoried work; no global suppression or Swift 6 language migration was introduced.

No real AWS or model-provider calls were made in this implementation/validation pass. Hosted CI has been prepared but has not run because the GitHub repository does not exist yet. Apache-2.0 was separately selected by the owner and is included with NOTICE in app bundles. No source publication, Developer ID/notarization or production-readiness claim follows from these checks. See [the readiness tracker](open-source-readiness.md) and [release gates](releases.md).
