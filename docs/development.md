# Development and checks

Use macOS 14+ with Swift tools 6.2 or newer. The current local setup uses Command Line Tools; the package stays in Swift 5 language mode while concurrency warnings are reviewed. See CONTRIBUTING.md and validation.md for evidence and limits.

| Command | Purpose |
|---|---|
| `make app` | Production app, ad-hoc signed for local development |
| `make demo-app` | Separate synthetic-data bundle with fake AWS/provider executables and catalog |
| `make demo` | Run the demo bundle |
| `make test` | Build app required by IPC tests, then offline Core/integration regressions |
| `make example` | Independent Core consumer, in-memory adapter only |
| `make lint` | Curated JSON/plist parsing, fixture permissions and shell syntax |
| `make verify-bundle` | Check the existing production bundle for signature integrity and demo/test exclusions |
| `make ui-test-app` | Dedicated fake-data GUI test bundle; logs/captures in `/private/tmp` |
| `make ui-test` | Build and execute that test app in an interactive macOS session |
| `make check` | Local non-GUI aggregate checks |

Do not run builds concurrently in the same `.build` directory. The UI harness uses a compilation flag; bundle scripts rebuild the correct variant so ordinary app/demo binaries exclude it. GUI execution needs an actual user session. Hosted CI builds the harness but does not claim GUI acceptance.

`.github/workflows/checks.yml` is prepared for `macos-15` with Xcode 26.2 selected explicitly. This combination is based on the [published runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md); it has not run on GitHub for this project. Keep toolchain updates deliberate. The workflow uses a pinned checkout action, read-only contents permission, no persisted Git credentials and no AWS/provider/signing secrets.

The full suite is offline but includes process creation, local sockets and process-tree inspection. Restricted shells may block those checks; report that restriction instead of treating skipped checks as passes. Compiler-cache overrides and `SWIFT_FLAGS` are optional local workarounds, not application authorization settings.

The current screenshot capture mechanism can produce incomplete hosted SwiftUI surfaces. Those captures are not publication-ready and do not replace native on-screen review. Use fictional data for all eventual screenshots.
