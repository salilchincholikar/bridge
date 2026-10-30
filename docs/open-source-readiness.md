# Bridge — open-source preparation plan

Status: initial source publication preparation, following the local source audit on 2026-10-29. Apache-2.0 has been adopted with LICENSE and NOTICE included in app bundles. The initial source was published to [salilchincholikar/bridge](https://github.com/salilchincholikar/bridge) on `main` as commit `94bd404`; its [hosted CI run](https://github.com/salilchincholikar/bridge/actions/runs/40872287204) passed. See [publication-review.md](publication-review.md) for the reviewed scope and [validation.md](validation.md) for the distinction between hosted build checks and local GUI evidence.

## Implementation update — 2026-10-29

- Implemented credential-helper approval in the shared execution/download paths, source-profile traversal, changed-command checks, safe diagnostics, human UI review and hash-based CLI approval. Parsing handles indented sibling settings, case-insensitive options, shared-credentials overrides and literal profile names. Credential values are discarded from trust metadata; unsupported escaped config headers fail closed. Regression checks cover probes, cache hits, transfers and assistant denial.
- Classified full Lambda function responses as sensitive; regressions cover cache exclusion, human reveal data, masking and agent refusal. Core owns sensitivity even with injected execution adapters.
- Changed GUI downloads to no-clobber by default with explicit Replace; isolated concurrent transfers in private staging directories and added destination-race tests.
- Exposed experimental Core/UI/Agents library products. Extracted native layout/charts and optional assistant code. Added an execution adapter interface, an in-memory adapter contract suite and independent offline consumer example.
- Organized app screens under `BridgeApp/Features` and centralized navigation metadata/factories in `Navigation/FeatureRegistry.swift`. Features remain internal to the app target until their session interface warrants a separate library.
- Excluded UI self-tests from production via a dedicated build flag; added synthetic demo/test operation models. Production bundle signing now fails on errors, with a separate bundle-integrity/exclusion check.
- Added contributor/security/conduct docs, architecture/privacy/SDK/UI/release guides, templates, ownership routing, ignores and source checks. Prepared a credentials-free GitHub workflow; hosted execution remains unverified until the repository exists.
- Neutralized company-derived fixture/demo names. This is not a complete secret/provenance clearance.

See [validation.md](validation.md) for final check evidence. Remaining work includes typed table/inspector extraction, a full visual state catalog, test-runner decomposition, concurrency warning review, clean-machine/hosted CI evidence, provider compatibility review, full source/asset provenance clearance, a working private reporting contact and signed distribution setup. Incomplete offscreen SwiftUI captures must not be used as public screenshots.

## 1. Direction and release boundaries

Prepare Bridge as a native macOS application with reusable Swift libraries. Keep the existing AppKit shell, hosted SwiftUI/Charts, and centralized execution policy. Improve the seams and organization incrementally rather than rewriting the interface around a different framework.

“SDK-style” has two independent meanings:

1. **Reusable Bridge libraries:** a documented client interface, native UI modules, and features composed from injected dependencies. This is the recommended first step.
2. **AWS SDK for Swift as the backend:** an alternative to the AWS CLI. Put it behind the same execution interface and evaluate it separately. The owner's preference is pending; this plan does not assume a backend migration is approved.

Use three separate gates:

| Gate | Required outcome |
|---|---|
| Public source preview | Ownership/license confirmed; privacy sweep complete; known security blockers fixed; clean-checkout build and offline tests reproducible; limitations documented |
| Downloadable app beta | Source gate plus supported-platform QA, deliberate versioning, production/demo separation, release verification, and a tested distribution/signing path |
| Stable release | Representative real-account workflows and performance measured, compatibility policy established, and support expectations sustainable |

Developer ID/notarization work belongs to downloadable app distribution; it need not prevent publishing a clean source repository. Apple's [macOS distribution guidance](https://developer.apple.com/macos/distribution) describes that distribution path.

Current local evidence is recorded in [validation.md](validation.md). Passing offline/UI checks is a regression baseline, not a security certification or proof of broad AWS compatibility.

## 2. Audit findings and publication blockers

At the initial audit, the repository had two production SwiftPM targets, an executable core-test target, no third-party SwiftPM dependencies, no Git metadata, a four-line `.gitignore`, and no license, contribution/security policy or GitHub workflows. The app's UI directory mixed shell, features, shared controls, presentation models and a 485-line UI test harness. The core test entry file mixed orchestration and many test groups. The update above records implementation since that baseline; findings below retain the audit context and acceptance criteria.

### P0: fix or explicitly resolve before public release

| Finding | Required change | Acceptance evidence |
|---|---|---|
| Credential-process approval is described and has hash helpers, but execution does not call them | Enforce trust checks before identity probes and subsequent requests, including `source_profile` chains; handle new/changed commands; define a noninteractive CLI outcome | Tests prove an unapproved or changed command cannot start a child process, and approved unchanged commands work |
| `lambda get-function` is not classified sensitive, while responses can contain `Configuration.Environment.Variables`; the normal cache receives the raw response | Audit response sensitivity before caching, history, agent exposure, and reveal actions. Choose a consistent classification/masking design; signed download URLs also need treatment | Regression fixtures prove environment values and presigned URLs cannot enter ordinary cached/history/agent representations; explicit human reveal still behaves correctly |
| Download overwrite intent needs a race review | The Save dialog currently derives `overwrite` from file existence after it returns. Preserve explicit replacement intent rather than treating existence alone as authorization | A file appearing after a new-name selection cannot be overwritten without replacement consent; confirmed replacement remains atomic |
| Assistant integration relies on version-sensitive CLI flags and unresolved provider assumptions | Review current provider documentation/terms, configuration/hooks, tool isolation, residual tools, transcript behavior, and supported versions. Keep the feature disabled/experimental if unresolved | Documented compatibility matrix and fail-closed tests; no broad claims about subscription compatibility or guaranteed isolation |
| Publication contents have not had a full privacy/provenance review | Audit the intended initial commit, fixtures, source archive, screenshots, generated assets, and release bundle | Reviewed file manifest and secret/privacy scan; only intentional synthetic credentials are narrowly allowlisted |

The first two findings come from reading `Settings/Settings.swift`, the execution/identity paths, `Policy/PolicyTable.swift`, `Data/DataService.swift`, and `Cache/ResultCache.swift`. The cache correctly refuses results marked sensitive; the gap is classifying and representing the Lambda response before it reaches that safeguard.

Also review cancellation races, `@unchecked Sendable` synchronization, IPC permissions/token handling, subprocess environments, redaction limits, temporary-file cleanup, and configuration corruption behavior. Keep fixes behind the common execution path so GUI, CLI, and assistant callers receive the same protections.

### Privacy and provenance sweep

- Replace company-derived demo profile/resource names with a consistent fictional dataset. Preserve Salil Chincholikar and `@salilchincholikar` as the intentional public creator identity.
- Review account IDs, ARNs, emails, bucket names, logs, local paths, presigned URLs, and captured responses. A targeted scan so far found matches in test/fixture material; that is not a complete clearance.
- Use only demo data for screenshots and recordings. Never copy the real-account screenshots from this development conversation into public assets.
- Inspect `Spikes/` before including it. Move useful sanitized research into an explicitly historical area, or exclude experiments from the initial public import without deleting the local work.
- Confirm ownership/attribution of adapted code, Record the icon generator and asset provenance. Audit dependencies again when packages are introduced.
- Expand ignore rules for local credentials/configuration, logs, test captures, signing material and generated artifacts. Keep curated example configuration and synthetic fixtures explicitly included. Ignore rules complement review; they are not a secret scanner.

## 3. Proposed repository and module structure

Start with one repository and one Swift package. Avoid separate repositories or a package per AWS service while the interfaces are still changing.

```text
Bridge/
├── Package.swift
├── README.md
├── LICENSE                         # Apache-2.0 adopted
├── CONTRIBUTING.md
├── SECURITY.md
├── CODE_OF_CONDUCT.md
├── CHANGELOG.md
├── .github/
│   ├── workflows/                 # checks and controlled releases
│   ├── ISSUE_TEMPLATE/
│   ├── PULL_REQUEST_TEMPLATE.md
│   └── CODEOWNERS
├── Sources/
│   ├── BridgeCore/                # reusable, UI-independent client/runtime
│   │   ├── Models/
│   │   ├── Configuration/         # profiles/settings/discovery
│   │   ├── Security/              # policy, identity, safe result handling
│   │   ├── Execution/             # backend interface + CLI adapter initially
│   │   ├── Data/                  # orchestration, cache, provenance
│   │   ├── Workflows/             # typed service operations and parsers
│   │   ├── Transfers/
│   │   └── Investigations/
│   ├── BridgeUI/                  # reusable native UI building blocks
│   │   ├── Tables/
│   │   ├── Inspectors/
│   │   ├── Charts/
│   │   ├── Layout/
│   │   ├── Feedback/
│   │   └── Formatting/
│   ├── BridgeFeatures/            # app features, organized by destination
│   │   ├── Overview/
│   │   ├── Investigation/
│   │   ├── Billing/
│   │   ├── Lambda/ Logs/ ECS/ SQS/ IAM/ S3/ Alarms/
│   │   └── OperationRunner/
│   ├── BridgeAgents/              # optional, experimental provider integration
│   └── BridgeApp/                 # composition root, shell, menus and CLI
│       ├── Application/
│       ├── Shell/
│       └── CLI/
├── Tests/
│   ├── Core/                      # profiles, policy, parsers, cache, paths
│   ├── Integration/               # fake subprocess/IPC/download chains
│   ├── UI/                        # component and complete-window behavior
│   └── Support/                   # fixture builders, clocks, temporary dirs
├── Fixtures/
│   ├── Profiles/
│   ├── Responses/
│   ├── Catalog/                   # minimal synthetic service models
│   └── Executables/               # fake aws/claude/codex
├── Resources/                     # app metadata, icon, help, credits
├── scripts/                       # build, test, package, verify
├── docs/
│   ├── getting-started.md
│   ├── architecture.md
│   ├── security-model.md
│   ├── privacy.md
│   ├── adding-a-service.md
│   ├── ui-components.md
│   ├── development.md
│   ├── releases.md
│   └── research/                  # optional sanitized historical notes
└── examples/                      # small SDK/UI usage examples
```

This is a target layout, not a requirement to move every file in one change. The existing core folders already express several useful responsibilities; retain them when renaming provides no benefit. The local folder can remain `myaws` until a deliberate rename is convenient.

### Dependency rules

- `BridgeCore` has no AppKit/SwiftUI dependency and never imports an application feature.
- `BridgeUI` owns native presentation behavior; it never discovers credentials, launches AWS commands, or knows the app's singleton.
- `BridgeFeatures` depends on Core and UI and receives a session/client through a small interface. Features do not reach through `AppModel.shared` for dependencies.
- `BridgeAgents` uses the common authorized client; provider code does not enter the UI library or bypass policy.
- `BridgeApp` composes these modules, owns windows/menus, and chooses adapters.
- Keep a shared process-execution implementation rather than duplicating it in CLI and provider adapters.

Initially expose Core and UI as SwiftPM library products with an explicitly experimental API. Keep feature implementation details internal until reuse justifies a public interface. Isolate agent code as optional rather than making every SDK consumer depend on provider harnesses.

Move UI tests out of the shipped app. First separate their source and build flags; then use a dedicated executable/test target once the UI module can be linked cleanly. Do not make every controller public merely to satisfy tests. Preserve the current CLT-compatible executable tests until a standard test-framework migration has been proved on the supported toolchain.

### Current-to-target moves

| Current cluster | Planned destination/change |
|---|---|
| `main.swift` with bootstrap, demo setup and test mode | `Application/` composition root; separate demo/test bootstrap |
| `TabWindowController.swift` | Thin window coordinator plus sidebar/toolbar/account presenters in `Shell/` |
| `AppModel.swift` | Application state and a session/client interface; isolate user-facing error presentation |
| `Components.swift` | Tables, text inspectors, feedback and formatting modules by responsibility |
| `Views/*ViewController.swift` | Feature folders with their presentation state and navigation contracts |
| `BillingDashboard.swift` | Billing model and coherent view sections; extract reusable chart/card presentation only where it has a real second use |
| `AWSCommandDrawer` and `CommandActivity` | Shell utility backed by common request activity; separate presentation from trace/redaction state |
| Core `Agent/` | Optional provider module with a documented dependency on the authorized client |
| Mixed test entry files | Small runners invoking named Core/Integration/UI suites and shared support |

## 4. Reusable UI and feature design

### UI building blocks

Provide a small documented catalog, exercised with synthetic data:

| Building block | Reusable behavior |
|---|---|
| Resource table | Typed row identity and columns, numeric sorting, selection, copy/context actions, loading/empty states, correct fitting and keyboard behavior |
| Resource inspector | Label/value metadata, selectable long values, masked/reveal presentation and progressive actions |
| JSON/text viewer | Find, wrapping, copy, bounded preview, visible truncation and usable scrolling |
| Metric summary | Consistent type scale, currency/digits, explicit period, optional meaningful delta |
| Time-series chart | UTC/domain handling, truthful scale, hover/pinned/keyboard inspection, units and accessibility |
| Split workspace | Resizable list/detail regions and controlled minimum dimensions |
| Request feedback | Loading, retry, sign-in required, permission denied, unsupported and partial-data states |
| Account context | Verified identity/protection display with accessible compact and detailed presentations |
| Utility drawer | Explicit open/closed state, remembered size, correct native divider geometry and visible content |

Use system semantic colors and native materials. Put shared spacing/type conventions in one modest place; do not build a second widget toolkit. Retain AppKit adapters behind the reusable interface so consumers do not need to manage table delegates, cell reuse or split-view geometry.

Replace broad `Any` payload casts at reusable table interfaces with typed models/identifiers where practical. Keep redaction and authorization decisions in Core; a reusable reveal control only presents the authorized state it receives.

A demo/showcase mode should display every reusable state without AWS credentials. Include long names, zero/negative costs, large tables, denied requests, missing forecasts, empty history and small windows.

### Feature registration

Create one feature registry used by sidebar navigation, Overview links, menu shortcuts and the command palette. Each descriptor supplies stable ID, title, symbol, group, factory and UI capabilities. Model account-global versus regional scope and supported time controls explicitly instead of hardcoding Billing or service arrays throughout the shell.

A new service should require:

1. Typed request/response models and defensive parsing.
2. Explicit centrally reviewed policy entries; registration alone cannot authorize an operation.
3. A small feature view/model using shared UI and an injected session.
4. Synthetic fixtures and contract tests for empty, denied, stale and paginated results.
5. One registry entry and user-facing documentation.

Use compiled-in features first. Third-party runtime plugins and arbitrary terminal execution are separate future designs, not prerequisites for an SDK-style architecture.

## 5. SDK-style client and backend evolution

The reusable client should own identity verification, authorization, caching, cancellation, stale-result checks and activity provenance. Features request typed operations; they do not duplicate AWS JSON parsing or construct shell strings.

Define a small execution-backend interface and keep the current CLI implementation as an adapter. The existing `DataService` is a useful starting seam, but its concrete `CLIExecutor` coupling needs to be removed deliberately. Prefer typed results/pages, structured errors and cancellation-aware progress/streams. Keep mutable process handles and provider internals out of the public interface.

Examples should demonstrate listing resources, following logs, loading billing and downloading to a user-selected destination with the same policy behavior as the app. Document which interfaces are experimental; stabilize only after another real consumer or example exposes the interface's rough edges.

If the AWS Swift SDK is selected:

- Add it as a separate backend target; keep the UI and policy interfaces unchanged.
- Measure clean/incremental build cost, binary size, real request latency and SSO/role-chain behavior on the current SDK. The historical SDK spike is evidence to revisit, not a permanent verdict.
- Run the same contract tests against CLI and SDK adapters, especially identity/account scope, global Billing, pagination, cancellation, typed errors and sensitive responses.
- Migrate one bounded workflow first, then hot paths if measurements justify it. Keep a documented fallback for unsupported operations/catalog behavior.
- Distinguish actual CLI execution from SDK requests in the activity drawer. A copyable CLI equivalent must be labelled an equivalent, not presented as a command that ran.
- Pin and review dependencies and licenses; account for model discovery currently depending on the installed CLI's internal files.

## 6. Reproducible development, tests and CI

Create reliable entry points such as `make app`, `make demo`, `make test-core`, `make test-integration`, `make test-ui`, `make lint` and `make verify-release`, with an aggregate command for contributors. Keep local sandbox/cache workarounds optional rather than the only documented happy path.

- Pin a tested Swift/Xcode or CLT toolchain and document macOS 14+ as the current deployment target. Verify it on fresh machines.
- Inventory compile warnings and unsafe concurrency annotations. Resolve genuine synchronization issues; do not silence warnings globally or mix a full Swift 6 migration into file moves.
- Decouple pure Core checks from building the UI app. Integration checks may build the executable they exercise.
- Make fixtures hermetic: the UI runner currently discovers service models from the installed AWS CLI. Provide minimal synthetic catalog fixtures or a documented explicit dependency so a clean runner behaves predictably.
- Isolate HOME/config/credentials/provider paths in tests. Refuse live AWS/model-provider calls, and keep CI credentials-free.
- Run GUI checks on a verified GUI-capable macOS environment. Establish what hosted runners can actually support; document any separate interactive smoke gate rather than silently treating skipped UI checks as passes.
- Add policy/trust/cache regressions from P0, schema/parser edge cases, download races, cancellation, context changes, public client contracts and API examples.
- Retain tests for the recent drawer failures: repeated toggles, supported window sizes, navigation, empty/populated history, visible preview bounds and the native divider's actual draw position. Pixel-difference smoke checks alone are insufficient.
- Test light/dark, larger text/long labels, keyboard focus, accessibility descriptions and multiple independent tabs. Use a pinned OS for image comparisons and review native captures for compositor artifacts.

Prepare local workflow files before the repository exists. Once connected, run PR checks without signing credentials, minimize token permissions, pin external actions to reviewed commit SHAs, and separate privileged release jobs from untrusted contribution jobs. See GitHub's [secure-use guidance](https://docs.github.com/en/actions/reference/security/secure-use).

## 7. Public documentation, license and releases

### Required repository additions

- **README:** purpose, demo screenshot, actual supported workflows, prerequisites, install/build/run, privacy/security summary, known limitations and roadmap. Use CI evidence rather than repeatedly hardcoding test counts as a quality claim.
- **LICENSE and NOTICE:** Apache-2.0 adopted by the owner; the full text and Bridge's copyright notice are included in app bundles. See [licensing.md](licensing.md) for evidence and remaining provenance work.
- **CONTRIBUTING:** setup, module rules, test commands, adding services/UI behavior, fixture hygiene and review expectations.
- **SECURITY:** private reporting route, supported versions, threat model link and no real secrets/account dumps in public issues. Enable GitHub [private vulnerability reporting](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/configure-vulnerability-reporting/configure-for-a-repository) after the repository exists.
- **Privacy/security model:** AWS calls, optional provider egress, local files/cache/history, external CLI behavior, credential processes and redaction limitations. Make statements match implementation and current authoritative provider documentation.
- **Issue/PR templates:** reproducible steps, platform/tool versions, demo reproduction, expected behavior and sanitized diagnostics; feature requests and new-operation reviews.
- **CHANGELOG, roadmap and support policy:** define an experimental beta scope and what the maintainer can realistically support. Contributor conduct and maintainership files should have working contact/reporting paths.

Rewrite contradictory current-state claims in the existing technical/product/plan documents. Preserve useful design decisions separately from historical experiments and conversational notes. GitHub documents the supported placement of [community health files](https://docs.github.com/en/enterprise-cloud%40latest/communities/setting-up-your-project-for-healthy-contributions/creating-a-default-community-health-file).

### Packaging and distribution

- Decide the final repository name, bundle identifier and initial architecture support. Current local builds prove Apple Silicon; do not advertise Intel/universal support until verified.
- Separate production, demo and test artifacts. Confirm the production app excludes fake executables, fixture credentials, UI self-test entry points, captures and local configuration.
- Make release signing fail on errors; the current bundle script can print “codesign skipped” and continue. Keep ad-hoc developer builds distinct from distributable releases.
- Establish tag/version/build-number mapping, changelog generation, reproducible package inputs, checksums and release verification. Include license/notices with distributed artifacts.
- For downloadable binaries, configure Developer ID signing, required runtime settings, notarization/stapling and Gatekeeper checks on a fresh/quarantined download. Follow Apple's [notarization workflow](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution). Store signing credentials only through the chosen release secret-management process.
- Validate Homebrew and official AWS CLI installations, missing CLI, expired SSO, denied access, corrupted settings, read-only filesystem locations and supported provider versions.
- Measure representative W1–W7 workflows against explicitly chosen test accounts before claiming production readiness. Record permitted response shapes as sanitized fixtures; never import real data wholesale.
- Homebrew distribution, automatic updates, broader SDK coverage, CloudTrail and cross-account comparison are later additions after the initial release path is reliable.

## 8. Ordered work packages and completion gates

| Order | Work package | Definition of done |
|---|---|---|
| 1 | Freeze baseline and resolve P0 | Current tests reproducible; trust/cache/overwrite findings resolved with regressions; assistant release posture explicit |
| 2 | Repository hygiene and public docs | Reviewed source manifest, sanitized demo/research/assets, expanded ignores, license decision, contributor/security/privacy drafts |
| 3 | Reusable modules and feature registry | Core/UI/Features/App responsibilities separated in small changes; no feature bypasses policy; navigation metadata has one source; existing behavior preserved |
| 4 | SDK interface and examples | Small documented client interface, replaceable backend seam, at least one independent usage example and contract tests |
| 5 | UI catalog and test separation | Reusable native states demonstrated; UI tests absent from production; consistent component/window acceptance checks |
| 6 | CI and clean-machine validation | Reproducible offline jobs, fresh-clone setup, verified platform matrix, explicit GUI test evidence and no live credentials |
| 7 | Release candidate | Production/demo separation, metadata and notices verified; source gate satisfied; binary gate satisfied if shipping an app |
| 8 | GitHub setup and publication | Provided repository connected; private reporting/protection/checks configured; initial commit/release contents reviewed before publishing |

Make structural moves separately from behavior changes, run relevant tests after each move, and avoid simultaneous backend, concurrency and UI rewrites. The first public milestone should be a reliable read/download workbench; new write operations are outside this readiness effort.

### Can be prepared locally before GitHub exists

Code fixes, module organization, fixtures, documentation, examples, workflow drafts, issue templates, packaging scripts and local test artifacts can be prepared without GitHub. The implementation update above separates completed groundwork from remaining gates.

### Needs the owner or repository later

1. Completion of the source/asset provenance review; the license choice is settled as Apache-2.0.
2. GitHub repository/name and preferred public project identity.
3. SDK direction: reusable libraries first, AWS Swift SDK backend, or both.
4. Whether the first publication is source-only or includes a signed app; Apple signing access if applicable.
5. Security-reporting/support contact and assistant integration release posture.

The author identity is already settled: Salil Chincholikar, GitHub `salilchincholikar`. No repository, provider account, signing certificate or AWS credentials need to be supplied in chat for this plan.
