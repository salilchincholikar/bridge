# bridge — technical direction

Tags: `[done]` in repo · `[experiment]` scratch project, reported · `[unverified]` assumption · `[future]` planned. Product context is in [product.md](product.md), sequencing and spikes in [plan.md](plan.md).

## 1. Current implementation

The current runtime design is documented in [architecture.md](architecture.md) and [security-model.md](security-model.md). The detailed sections below preserve historical design reasoning and proposals; they are not a complete current-state specification.

| Module | Current role |
|---|---|
| BridgeCore | UI-independent profiles/settings, identity, operation policy, execution adapter seam, cache, workflows, investigations and transfers |
| BridgeUI | Reusable native workspace layout and hosted metric charts |
| BridgeAgents | Optional experimental Claude/Codex harnesses, MCP and private IPC, using the authorized Core client |
| BridgeApp | AppKit shell, hosted SwiftUI feature screens, navigation registry, menus and CLI |

Overview, service screens, Billing, generated read runner, investigations, command drawer and assistant integration are implemented. Offline regressions and a dedicated UI build exercise them with synthetic data. See [validation.md](validation.md) for actual evidence and limitations. UI self-tests are conditionally compiled only for the test bundle; production builds exclude them.

The AWS CLI remains the production backend. An independent in-memory adapter demonstrates library reuse; no AWS Swift SDK migration has been performed. Source publication, licensing/provenance, provider compatibility and binary distribution gates remain in [open-source-readiness.md](open-source-readiness.md).

## 2. Stack

- **UI: Swift, native macOS, AppKit-first (decided).** AppKit provides `NSTableView` and `NSTextView` for the heavy screens (resource tables, logs, JSON). SwiftUI is used only as hosted islands (`NSHostingView`) where it earns its place, mainly Swift Charts for time series; if that doesn't build under Command Line Tools, charts are drawn with Core Graphics/`NSView`. macOS only. The app must read `~/.aws` and spawn `aws`, so it runs **unsandboxed**: no Mac App Store, personal or direct distribution. (The AWS SDK for Swift docs have an App Sandbox section; sandbox specifics were not checked.)
- **Core language: all-Swift (decided on my recommendation, 2026-10-28; reversible).** See "Language split" below. Third-party dependencies in Phase 1: none beyond the toolchain; the AWS SDK for Swift is added only if the latency measurements call for it.
- AWS execution engine for the MVP: the **AWS CLI as a direct subprocess**. A typed SDK is the alternative for hot paths: [AWS SDK for Swift](https://aws.amazon.com/blogs/developer/announcing-general-availability-of-the-aws-sdk-for-swift) (announced generally available; its [credential-provider docs](https://docs.aws.amazon.com/sdk-for-swift/latest/developer-guide/credential-providers.html) say IAM Identity Center settings in config are used to obtain temporary credentials), or `aws-sdk-rust` ([GA Nov 2023](https://aws.amazon.com/about-aws/whats-new/2023/11/aws-sdk-rust), one crate per service) in the Rust option. SDKs do not perform the SSO login itself: the [JS guide](https://docs.aws.amazon.com/sdk-for-javascript/v3/developer-guide/getting-your-credentials.md) says to run `aws sso login`, and the Swift/Rust equivalents are `[unverified]`. So the CLI stays in the design for login and as the raw/generic backend whatever we choose. Use explicit per-profile credential configuration, not the default provider chain, so stray environment variables cannot redirect a call. **Decision rule:** an investigation view fires several calls at once (logs, metrics, queue attributes, ECS describes), and one process per call may feel slow. CLI per-call latency is `[unverified]`. Measure the startup floor offline in plan Milestone 1 and real-call latency in Milestone 3. If a warm investigation view cannot populate in about 3 seconds with the CLI, move metrics, logs and SQS attributes to the SDK; the policy table and context model stay the same, only the execution backend changes.
- MCP server `bridge mcp`: Phase 3. The official [modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) lists stdio and HTTP transports and, per search results, requires Swift 6.0+ and Xcode 16+. Its current release and spec revision, and a server-side stdio example, are `[unverified]`.

### Toolchain (Swift)
- Swift 6.4 is installed with Command Line Tools only. Bridge builds with SwiftPM, uses AppKit for its window shell, and assembles a `.app` with `scripts/bundle.sh`. Tests use a plain executable target for compatibility with this toolchain.
- **Milestone 2 results (2026-10-28, `Spikes/ui/`, details in `Spikes/ui/RESULTS.md`)** `[experiment]`: a SwiftPM package using AppKit, SwiftUI and Swift Charts builds, bundles to a `.app` with the app bundle script, and launches under Command Line Tools only, no Xcode. **One real limitation:** SwiftUI's `@State` is a compiler macro in this SDK and the `SwiftUIMacros` plugin is not shipped with CLT (only `ObservationMacros` and `SwiftMacros`), so `@State` fails to compile. `@Observable` models work instead. Other macro-backed SwiftUI properties were not tried. Charts hosted via `NSHostingView` render. Plan for a UI that is AppKit-first with only small SwiftUI islands using `@Observable`.
- Measured (offscreen draws, release): 10k-row `NSTableView` sorts in under 8 ms; a 1.3 MB JSON in `NSTextView` lays out its first screen in about 7 ms; AppKit does **not** style Markdown headings/lists from `AttributedString` block intents, so AI answers need a custom renderer; child-process cancellation kills the whole process group in about 1 ms when the child is spawned with `posix_spawn` in its own group with an explicit signal state (details and a bug found along the way in the results file).
- **AWS SDK for Swift cost** `[experiment]`: with 8 service modules, about 24 min and 3.9 GB to download (the whole SDK repo is cloned), 132 s clean release build, 70.9 MB binary, and 92 to 133 s incremental rebuilds in release (misses the 30 s bar). This supports CLI-first. Also: markdown rendering needs a custom block renderer, and a prototype (`Spikes/ui/Sources/BridgeSpike/MarkdownRenderer.swift`) fixes both the lost block structure and the missing adaptive text color; it is visually confirmed.
- The MCP Swift SDK reportedly wants Xcode 16+ (a Phase 3 concern).
- Why not GPUI (history): its build compiles Metal shaders via `xcrun metal` unless the `runtime_shaders` feature is on; with the feature it compiled here without Xcode, but it would still have needed us to build charts, viewers and markdown ourselves. Native Swift provides those.

### Language split (core vs UI)
| Option | Pros | Cons |
|---|---|---|
| **All-Swift** (decided) | One toolchain, no FFI. Swift concurrency (actors, structured cancellation) fits per-tab context and cancel-on-close. AWS SDK for Swift and the MCP Swift SDK exist. | macOS/Apple-toolchain only; core not reusable on Linux/Windows |
| Swift UI + Rust core through FFI (C ABI or generated bindings) | Core portable to a future TUI or other OS | Two toolchains, Rust built into the Swift build, type mirroring across the boundary, harder debugging |
| Swift UI + Rust core as a separate local process (socket) | Strong isolation; core independently testable | IPC on every interaction, process lifecycle, and a second hop in front of the policy layer |

A hybrid engine would need explicit interfaces for asynchronous requests, streaming and cancellation across the C ABI, including ownership and callbacks. That extra integration cost supports the current all-Swift direction.

Why all-Swift: the core is I/O orchestration (subprocess, JSON, policy table, caching), where Rust's strengths matter little; the Rust skeleton is empty, so there is no sunk cost; and the boundary costs in the hybrids are real and permanent. Revisit if a non-macOS target is wanted, or if the Milestone 2 SDK build-time or SSO checks fail.

## 3. Final structure `[future]`
Decided 2026-10-28; package created the same day (the Rust placeholder is gone). One SwiftPM package at the repo root (no `macos/` subfolder, since there is no second language). Directories not yet created (`BridgeAI`, `bridge-mcp`, and most `BridgeCore` subfolders) arrive with their milestones.
```
bridge/
├── Package.swift               # SwiftPM; tools version and minimum macOS chosen in Milestone 2
├── Makefile                    # app, run, test, clean
├── scripts/bundle.sh           # assemble build/Bridge.app, ad-hoc codesign
├── Resources/                  # Info.plist, AppIcon.icns
├── Sources/
│   ├── BridgeCore/             # library; imports no AppKit/SwiftUI; testable headless
│   │   ├── Profiles/           # ~/.aws/config parser; profile, sso-session, role-chain types
│   │   ├── Identity/           # identity probe, ExecContext, AuthExpired
│   │   ├── Policy/             # Tier, Authorizer, Decision/deny reasons, sensitive + credential classes
│   │   ├── Exec/               # Executor; CLI backend (SDK backend only if measured); env allowlist;
│   │   │                       #   ProcessRunner; pagination; timeouts; cancellation; output caps
│   │   ├── Catalog/            # botocore model loader, CatalogEntry, overrides
│   │   ├── Transfers/          # S3 download, .bridge-part files, PathSanitizer
│   │   ├── Cache/              # keys (verified identity + window), TTL, freshness
│   │   ├── Investigations/     # Investigation, TimeWindow, discovery, links, save/load
│   │   ├── Settings/           # bridge config (max_tier, protected, expected_account, ...)
│   │   └── Resources/          # policy table and catalog overrides (data files)
│   ├── BridgeApp/              # AppKit executable; thin layer over BridgeCore
│   │   ├── App/                # main, AppDelegate, AppModel (tabs and their contexts)
│   │   ├── Shell/              # main window, sidebar, tab bar, identity header, time-range control
│   │   ├── Views/              # Logs, Lambda, Ecs, Sqs, Iam, S3, Investigation
│   │   └── Components/         # DataTableView, JSONView, LogView, ChartView, MarkdownView,
│   │                           #   ConfirmSheet, ApprovalCard
│   ├── BridgeAI/               # Phase 3: harness adapters and the app-side IPC server
│   └── bridge-mcp/             # Phase 3: stdio proxy launched by the agent harness
├── Tests/
│   └── BridgeCoreTests/        # plain executable target (no XCTest under Command Line Tools)
├── Fixtures/                   # sample aws configs, recorded JSON responses, fake `aws` shim
├── Spikes/                     # throwaway spike code; deleted or promoted when a milestone passes
└── docs/                       # product.md, technical.md, plan.md
```
Dependency direction (one way): `BridgeApp → BridgeAI → BridgeCore`; `bridge-mcp` talks to the running app over IPC and does not link `BridgeCore`'s executor.

Rules:
- `BridgeCore` imports no UI framework. Policy, identity and executor live below the UI so a view cannot bypass them.
- Adding a supported operation is a data-file edit (policy table, overrides) plus a view, not new framework code.
- Targets split only where a boundary pays off: core, app, and the two Phase 3 pieces.
- Data file format (TOML as written in this doc, or JSON to avoid a parser dependency) is decided in Milestone 3.
- Build order: `BridgeCore` plus tests first (no window needed), then `BridgeApp`.
- The word "core" below refers to `BridgeCore` (formerly `bridge-core`).

## 4. bridge-core design

### 4.1 Profiles `[future]`
Parse `~/.aws/config` read-only: `[default]`, `[profile x]`, `[sso-session x]`, `source_profile`, `role_arn`, `credential_process`, `sso_account_id`/`sso_role_name`, `region`. Never rewrite the file.

`credential_process` runs an arbitrary command from the config file; the [AWS docs](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sourcing-external.html) call that a security risk. Because the CLI will run it for us, the profile detail view shows the command, and the first use per profile (and any change to the command) needs a one-time confirm. This is intentionally small: store a hash of the command in bridge settings.

### 4.2 Settings: one model `[future]`
`~/.config/bridge/config.json` (JSON, decided in Milestone 3: no parser dependency; the example below is shown as TOML for readability, keys are identical). **No credentials, ever.** There is no separate "writes" flag; `max_tier` is the only permission knob.
```toml
[defaults]
max_tier = 2                 # 1 read · 2 + transfer to local disk · 3 + reversible change · 4 + destructive

[profiles.prod-eu]
label = "prod-eu"
color = "red"
protected = true             # display PROD marker; typed confirmation at tier >= 3
max_tier = 2
default_region = "eu-west-1"
expected_account = "123456789012"   # optional; mismatch with verified identity blocks tier >= 3

[agent]                      # Phase 3
max_tier = 1                 # hard cap for agent calls; approvals can raise one call at a time
profiles = ["dev"]           # profiles the agent may touch by default
```
Effective cap for a call = min(profile `max_tier`, caller cap). Tier-3+ calls always prompt; typed confirmation of the resource name at tier 4 or on `protected` profiles.

### 4.3 Identity and request context `[future]`
Every executor call carries a context, captured when the request is issued:
```
ExecContext { profile, region, account_id, principal_arn, aws_cli_version, tab_id, request_id }
```
- **Resolved identity:** before first use of a profile (and after any SSO login), run `sts get-caller-identity` through the same executor. The [docs](https://docs.aws.amazon.com/cli/latest/reference/sts/get-caller-identity.html) say it "returns details about the IAM user or role whose credentials are used" and requires no permissions. Show `Account` and `Arn` in the header. If `expected_account` is set and differs, block tier >= 3 and warn on all.
- **Expiry:** detect auth failure (command failure on a call that previously worked, or a failed identity probe) as a typed `AuthExpired`; offer `aws sso login` for SSO profiles; serialize logins per sso-session; retry the original request once after login.

### 4.4 Executor `[future]`
Contract: structured request in, JSON plus metadata out.
```
ExecRequest { ctx, service, operation, params: Json /* nested, API parameter names */, page: Option<PageSpec>, timeout }
ExecResult  { ctx, command_display, json, next_token, truncated, fetched_at, sensitive: bool }
```
Rules:
- **Direct subprocess, no shell.** `Command::new(<absolute aws path>)` with an argument vector. The `aws` path is resolved once at startup (or from settings) and shown in "About"; it is never re-resolved from `PATH` per call. No string interpolation of user text into a command line.
- **Executor owns global options.** `--profile`, `--region`, `--endpoint-url`, `--output json`, `--no-cli-pager`, and `--color off` are set by the executor. The request type has no field for them, and params are rejected if they try to smuggle them in. User-supplied `--endpoint-url`, `--debug` (the [docs](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-options.html) say it can add full Python logs and extra stderr diagnostics), `--no-sign-request`, `--ca-bundle` and `--no-verify-ssl` are not exposed. A dev-only custom endpoint (e.g. LocalStack) can be a per-profile setting, never a per-call argument.
- **Nested parameters** are passed as JSON via `--cli-input-json file://<0600 temp file in a bridge-owned dir>`, deleted after the call. The [docs](https://docs.aws.amazon.com/cli/latest/userguide/cli-usage-skeleton.html) say it works for most commands, references parameters "by their underlying API parameter names", can be combined with other flags (explicit flags override), and is **not supported by the custom `aws s3` commands**. The docs also say the generated *skeleton* "is not stable between versions" with "no backwards compatibility guarantees"; we do not use skeletons, only the models (see 4.7). Whether `--cli-input-json` accepts stdin is `[unverified]`, hence the temp file. The `command_display` is a faithful, copy-pasteable rendering (flags where simple, an inline JSON block where nested); the actual argv may differ.
- **Environment: allowlist, not inherit.** Documented [precedence](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-configure.html) is command-line options, then environment variables, then profile-based sources, so a stray `AWS_ACCESS_KEY_ID` or `AWS_PROFILE` in the launching shell would silently override the chosen profile. The executor builds the child environment from scratch: `HOME`, a fixed `PATH`, `LANG`/`LC_ALL`, `TMPDIR`, and, only if set, `AWS_CONFIG_FILE` and `AWS_SHARED_CREDENTIALS_FILE` (they select the config being used) plus configured proxy/CA variables. It explicitly drops every other `AWS_*` (profile, keys, session token, region vars, `AWS_ENDPOINT_URL*`, `AWS_DATA_PATH`, `AWS_PAGER`, `AWS_CLI_*`) and sets `AWS_PAGER=""`. Consequence, documented in the UI: credentials exported in your shell are ignored; bridge uses profiles only.
- **Timeouts, cancellation, size caps.** Per-call timeout; kill the child's process group on cancel or tab close; cap captured stdout (e.g. 20 MB) and mark `truncated` instead of buffering unboundedly. Cap concurrent children (see 4.9).
- **Pagination.** By default the CLI [retrieves all items](https://docs.aws.amazon.com/cli/latest/userguide/cli-usage-pagination.html), which is wrong for a UI. For operations with server-side pagination the executor uses `--max-items N` and carries the returned `NextToken` for "load more" via `--starting-token`; options only work where the service API enables pagination, and not every list-ish operation has a paginator (4.7). Hand-written views handle token flows the generic path cannot (e.g. `GetLogEvents`).

### 4.5 Action policy `[future]`
Operation-name prefixes (`List*`, `Describe*`, `Get*`) are a **heuristic only**: some `Get*` operations return secrets or credentials, and some `List*`/`Describe*`-looking calls can cost money. The authorizer never relies on a prefix.

**Authorization is an explicit table** (`policy/ops.toml`), one row per supported operation:
```
lambda.ListFunctions        = { tier = 1 }
logs.FilterLogEvents        = { tier = 1, deny_params = ["unmask"] }
logs.StartQuery             = { tier = 1, flags = ["costs_money"] }
s3api.GetObject             = { tier = 2, kind = "transfer" }
sqs.GetQueueAttributes      = { tier = 1 }
sqs.ReceiveMessage          = { tier = 3, note = "hides messages from real consumers (visibility timeout); not shipped in v1, denied to agents" }
sqs.DeleteMessage           = { tier = 4 }
sqs.PurgeQueue              = { tier = 4 }
ecs.StopTask                = { tier = 3 }
iam.DeleteRole              = { tier = 4 }
sts.GetSessionToken         = { class = "credential" }
```
The SQS rows are the standing example of why prefixes fail: `ReceiveMessage` reads like a read but changes visibility for real consumers (behavior as described in review feedback citing AWS docs; not yet checked by us).

`authorize(ctx, request) -> Allow{tier, confirm} | Deny{reason}` where reason is exactly one of:
- **Unsupported**: not in the table. This is the default for every unlisted operation; v1 is a fixed supported set. A prefix-based *suggestion* may be shown to help us write new rows, but it does not grant access.
- **Above cap**: tier exceeds profile or caller `max_tier`.
- **Identity mismatch**: verified account differs from `expected_account`, or identity not yet verified, for tier >= 3.
- **Credential/sensitive class**: gated below.

Three kinds of classified operations:
1. **Sensitive (reveal-gated)** `[future]`: returns secret material but is legitimately useful. Examples (return types per the AWS CLI reference): `secretsmanager get-secret-value` (SecretString/SecretBinary), `ssm get-parameter --with-decryption`, `lambda get-function` (`Code.Location` is a presigned download URL valid 10 minutes), Lambda environment variable **values**, `logs filter-log-events --unmask` (needs `logs:Unmask`). Default: values are masked in the UI; "reveal" is an explicit click, logged in the trace as an event without the value. Sensitive results are never cached, never written to disk or logs, and never returned to an agent unless the user approves that specific call.
2. **Credential-producing (denied)**: `sts get-session-token`, `sts assume-role`, `sts get-federation-token` (each returns an access key, secret and session token; see the [get-session-token reference](https://docs.aws.amazon.com/cli/latest/reference/sts/get-session-token.html)), `aws configure export-credentials` ([prints credentials](https://docs.aws.amazon.com/cli/latest/reference/configure/export-credentials.html); also ignores `--query`/`--output`), `ecr get-login-password`/`get-authorization-token`, `iam create-access-key`. These are **not in the table, and are listed in a deny list** with the reason "credential-producing". The profile resolution the CLI does internally (assume-role chains, SSO) is not affected. Revisit only if a real need appears.
3. **Destructive**: tier 4, typed confirmation, never available to agents without a per-call approval.

Non-service CLI commands (`aws configure`, `aws sso`, `aws s3 cp`, `aws logs tail`) are not reachable through the generic request path. Bridge invokes the few it needs (`aws sso login`, a transfer, a tail) from dedicated code paths with fixed argument shapes.

### 4.6 Transfers (tier 2) `[future]`
- **Destination:** chosen by the user in a folder picker. Agent-initiated downloads (Phase 3) go only to a fixed staging dir (`~/Downloads/bridge/<profile>/<bucket>/`) and require per-call approval.
- **Path safety:** local path is built from the chosen folder plus a sanitized key. Reject `..` segments, absolute keys, control characters, and any path that resolves (after symlink resolution) outside the chosen folder. Long or colliding names are suffixed; **no overwrite without explicit confirmation**.
- **Partial files:** the [S3 CLI docs](https://docs.aws.amazon.com/cli/latest/userguide/cli-services-s3-commands.html) describe cleanup only for failed *uploads*; temp/partial behavior for downloads is not documented in the sources read `[unverified]`. So bridge owns it: download to `<name>.bridge-part` in the destination folder, rename atomically on success, delete on cancel or failure, and sweep stale `.bridge-part` files on startup.
- **Mechanism (as built):** `aws s3api get-object --bucket=B --key=K ... <part file>` (a single API call; `--bucket=`/`--key=` as one argument each so a key starting with `-` cannot be read as a flag). The high-level `aws s3 cp` (better for very large objects) is `[unverified]` for progress and was not used. Progress is derived by polling the part file's size, not by parsing CLI output; total size from `HeadObject` is not wired yet. Cancel kills the process group, then deletes the part file.
- **Path containment (as built, with a lesson):** the final location is checked with `realpath` on the deepest existing ancestor. Foundation's `resolvingSymlinksInPath()` is NOT safe for this: it does not resolve symlinks when the final file does not exist (a test caught it). Dangling symlinks are refused.
- **Policy:** `GetObject`-class transfers are tier 2 with a `data_egress` flag: the UI shows destination, size and profile before starting when the size is above a threshold or the profile is `protected`.

### 4.7 Catalog and the generic browser (hypothesis H1) `[future]`
Discovering operation names is not enough to render a table. A usable generic browser needs, per operation: required parameters and nested input shapes, the output's result collection, pagination behavior, and how an item leads to its detail call.

**Source:** the CLI install ships the botocore service models. `[experiment]` Inspected locally (AWS CLI 2.37.9, Homebrew): `…/awscli/botocore/data/<service>/<version>/` contains `service-2.json`, `paginators-1.json`, `waiters-2.json`, `endpoint-rule-set-1.json`, `completions-1.json`; 438 service directories. Official docs fetched do **not** say this directory is a stable public interface or that it is part of the install `[unverified]`; the only related documented hook is `AWS_DATA_PATH`. Therefore: locate it at runtime (candidates: Homebrew prefix, `/usr/local/aws-cli/v2/*/dist/awscli/botocore/data`), key a derived catalog cache by CLI version, parse defensively, and fail with a clear message if not found.

**What the models supply** `[experiment]`, measured on the five target services (operation-name prefix is a rough bucket, not a classification):

| Service | ops | List/Describe/Get ops | no required input | required input | have a paginator |
|---|---|---|---|---|---|
| lambda | 88 | 38 | 6 | 32 | 16 |
| ecs | 77 | 29 | 11 | 18 | 9 |
| iam | 180 | 67 | 25 | 42 | 32 |
| s3 (s3api) | 116 | 47 | 2 | 45 | 8 |
| logs | 118 | 48 | 22 | 26 | 19 |

Takeaways from the models: most read-ish operations need a parent identifier first, so "pick an operation and see a table" works only for a minority of roots. Paginators give the result key (e.g. `Functions`, `clusterArns`, `Roles`, `logGroups`); `logs.FilterLogEvents` has two result keys. `GetFunction`, `GetRole`, `DescribeServices` have no paginator. `ecs.ListClusters/ListServices/ListTasks` return **ARN lists only**, so list-to-detail needs a follow-up `Describe*` call with the ARNs; Lambda, IAM and Logs lists return full items. The high-level `aws s3` commands and `aws logs tail` are custom CLI commands and are **not in the models**.

**Catalog entry we generate per operation:**
```
{ service, operation, cli_name, params: tree of {name, type, required, members…},
  output: { collection_path, item_id_path, is_arn_list },
  paginated: { input_token, output_token, result_key, limit_key } | none,
  tier: from policy table }
```
**Hand-written overrides** (small file, `catalog/overrides.toml`): list-to-detail links (e.g. `ecs.ListServices.serviceArns -> ecs.DescribeServices {cluster, services:[arn]}`), default columns, parent-parameter pickers (e.g. `RoleName` from `ListRoles`), cross-links (Lambda to log group `/aws/lambda/<name>`).

**H1 — "any service via the generic runner" is a hypothesis.** It is accepted only if the offline spike in `plan.md` (Milestone 1) passes. Fallback if it fails, with no change to the five-workflow commitment: ship **curated** definitions for the ~37 operations the workflows need, plus a raw operation runner that takes a form (or raw JSON) and shows a JSON tree without table derivation, for read-tier operations present in the policy table only.

#### Milestone 1 results (run 2026-10-28; `Spikes/catalog/`, full output in `Spikes/catalog/RESULTS.md`) `[experiment]`
Offline run against CLI 2.37.9's models for lambda, sqs, logs, ecs, iam, s3, sts, cloudwatch (37 operations). Only 8 of 438 services were exercised, so "any service" is **still a hypothesis**; this supports it for the six target services.
- **Entries:** 37 of 37 built; no recursive or union input shapes in the set; 22 operations have required input (216 input fields walked).
- **Collection paths:** 13 of 16 matched my hand expectations literally. The 3 differences are extra result keys present in the paginator data (`DescribeAlarms` also returns `LogAlarms`; `ListMetrics` also `OwningAccounts`; `ListObjectsV2` also `CommonPrefixes`). The derivation is right and my expectations were incomplete, but the criterion as written was not met without that correction.
- **Findings that change the design:**
  1. A paginator can list several result keys. **Rule: the first key is the primary table; the others are secondary or merged** (e.g. `FilterLogEvents`: `events`, then `searchedLogStreams`; `DescribeAlarms`: metric, composite and log alarms are parallel lists to merge).
  2. **Only trust paginators for table derivation.** The fallback "single top-level list member" heuristic misfired on `ecs.DescribeTaskDefinition` (picked `tags`). Non-paginated operations default to a detail view, and the few real list-shaped ones (`logs.GetLogEvents`, `logs.GetQueryResults`) are overrides.
- **List-to-detail links.** The heuristic produced 19 candidates. By hand: 7 are user-supplied inputs (times, query string, queue name, metric queries), and the rest reduce to **8 distinct links**: ECS clusters, services, tasks (ID lists to their `Describe*`) and service to task definition; IAM `ListRolePolicies` to `GetRolePolicy`; SQS `ListQueues` to `GetQueueAttributes` (QueueUrl); `DescribeLogGroups` to `StartLiveTail` (log group identifier); S3 `ListBuckets` to `Bucket` for object calls. The investigation cross-links the heuristic cannot see add about 4 more (Lambda to log group by name rule; event source mapping to queue; ECS task definition to log group via `logConfiguration`; role ARN to role name), so **about 12 if counted together**, which is over the stated bar of 10 but is a count by my hand classification, not computed.
- **Performance:** discovery plus load plus build took 40 ms. Model discovery worked on the Homebrew install (first candidate); the official-installer path `/usr/local/aws-cli/v2/<ver>/dist/awscli/botocore/data` is untested because that install is not present.
- **Engine startup floor (`aws --version`, no network):** sequential p50 197 ms, p95 202 ms; 6 parallel p50 203 ms, p95 211 ms. Real calls add network and credential resolution, so this is a lower bound; but it is far from the 1-second worry line, so there is no reason to move to the SDK yet.
- **Toolchain side effect:** `swiftc -O` compiled and ran this Foundation program under Command Line Tools only (about 2 s compile).

### 4.8 Context binding and stale results `[future]`
- Every request gets its `ExecContext` at dispatch; every result carries it back. The UI view stores the context it is currently showing. **On arrival, compare**; a result whose context differs from the view's current context (profile, region, account id) is discarded from display and, if safe, stored only in the cache under its own key. Nothing is ever rendered under a header from a different context.
- **Tabs have independent context.** Each tab holds its own profile and region; the sidebar selection only sets the default for *new* tabs. This is also how two accounts are compared side by side in the MVP, since fan-out is Phase 2. Changing a tab's profile or region cancels that tab's in-flight requests (kills children) before issuing new ones.
- Closing a tab cancels its requests.
- **Time range is part of the tab's context** (see 4.10). A request captures the *resolved absolute window* `{start, end}` at dispatch; a relative range like "last 15 min" is resolved once per refresh, never re-resolved when the result arrives. A result whose window differs from the tab's current window is discarded from display, same as a profile or region mismatch.

### 4.9 Cache, freshness, concurrency `[future]`
- **Cache key:** `(account_id, principal_arn, region, service, operation, canonical_params_hash, resolved_window, aws_cli_version)`. For relative ranges the window is rounded to the minute, so a refresh produces a new key while rapid repeats within the minute hit the cache. Keyed on the *verified* account/principal, not the profile name, because a profile can be re-pointed. No verified identity means no cache.
- **TTL by class:** list/describe 30–60 s; logs and tails: not cached; sensitive: never cached; transfers: n/a. Memory-only in the MVP (nothing written to disk).
- **Freshness is visible:** each table shows "fetched 14 s ago" and a refresh control; cached results are shown immediately with their age while a refresh runs (stale-while-revalidate).
- **Concurrency:** global cap on concurrent `aws` children (start at 4 to 6), a lower cap per profile, cancellation as above, one SSO login at a time per sso-session. Each child has a timeout.

### 4.10 Investigations `[future]`
Model (core, UI-independent):
```
Investigation { name, profile, region, anchor: String, window: TimeSpec /* relative preset or absolute */ }
Panel         { kind: Logs | Ecs | Lambda | Sqs | Alarms | Metrics, matches: Vec<ResourceRef>, state }
```
- **Discovery (MVP):** apply the anchor as a substring to each panel's list call (`ecs list-services` + describe, Lambda `ListFunctions`, SQS `ListQueues`, `DescribeLogGroups`, `DescribeAlarms`); show matches, let the user include or exclude each. Tag-based discovery is `[future]`.
- **Deterministic links:** ECS task definition `logConfiguration` to log group; Lambda name to `/aws/lambda/<name>`; Lambda `ListEventSourceMappings` to its SQS queues; resource to IAM role from its config.
- **Panels share the tab's window.** Changing it re-dispatches every panel's request (each tagged with the new window; old in-flight requests are cancelled).
- **Persistence:** saved as small TOML/JSON in the bridge config dir. Contains anchor, profile, region, window preset, included/excluded matches. No AWS response data, no credentials.
- **Comparison (Phase 2):** run the same saved investigation in two tabs with different profiles and diff configuration fields; secret-class values are excluded by policy.

### 4.11 Facts used from official docs (fetched 2026-10-28; CLI reference pages were for 2.38.6)
- [`--cli-input-json` / skeleton](https://docs.aws.amazon.com/cli/latest/userguide/cli-usage-skeleton.html), [pagination](https://docs.aws.amazon.com/cli/latest/userguide/cli-usage-pagination.html), [global options](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-options.html), [environment variables](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-envvars.html), [credential precedence](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-configure.html), [SSO profiles](https://docs.aws.amazon.com/cli/latest/userguide/sso-configure-profile-token.html), [`credential_process`](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sourcing-external.html), [S3 commands](https://docs.aws.amazon.com/cli/latest/userguide/cli-services-s3-commands.html), [`logs tail`](https://docs.aws.amazon.com/cli/latest/reference/logs/tail.html), [`logs filter-log-events`](https://docs.aws.amazon.com/cli/latest/reference/logs/filter-log-events.html), [`logs start-live-tail`](https://docs.aws.amazon.com/cli/latest/reference/logs/start-live-tail.html), [`logs start-query`](https://docs.aws.amazon.com/cli/latest/reference/logs/start-query.html).
- The CLI [output docs](https://docs.aws.amazon.com/cli/latest/userguide/cli-usage-output.html) warn some operations "might return information that could be considered sensitive". Treat all output as potentially sensitive.

## 5. UI (SwiftUI / AppKit) `[future]`
- Layout: sidebar (profiles), tabs (each with profile/region/identity header), main (table or detail), right panel (agent, Phase 3).
- Building blocks, all `[unverified]` until the Milestone 2 spike: SwiftUI `Table` (with an `NSTableView` wrapper if 10,000+ rows hitch), `NSTextView`/TextKit for JSON, policy and log viewers, `AttributedString` for markdown, and Swift Charts for time series (Lambda duration/errors, queue depth and age, a shared time axis across panels). If Swift Charts falls short (zoom, large series), draw with `Canvas`.
- State: one app model holding tabs and their contexts. Async results are delivered with their `ExecContext` and routed per 4.8.

## 6. Phase 3: agent integration `[future]`

### 6.1 Process boundary
Per the [MCP spec](https://modelcontextprotocol.io/specification/latest/basic/transports/stdio), with stdio the *client launches the MCP server as a subprocess*, so `bridge mcp` is a separate process started by the agent harness, with no shared memory with the running GUI.

Decision: **`bridge mcp` is a thin proxy; the GUI process is the single enforcement point.**
- GUI listens on a local IPC endpoint: a Unix domain socket in a bridge-owned directory with 0700/0600 permissions, plus peer-credential check (same user). No TCP listener. (If a localhost HTTP transport is ever used, the [spec requires](https://modelcontextprotocol.io/specification/latest/basic/transports/streamable-http) Origin validation and recommends binding to localhost with authentication.)
- `bridge mcp` forwards each tool call to the GUI and relays the result. The GUI runs the call through the same executor and policy as any click.
- If the GUI is not running, `bridge mcp` returns an error ("bridge is not running"). There is no standalone mode in v1.

### 6.2 Session identity and live context
- When the user opens the agent panel, the GUI creates an `agent_session_id` and a random per-session token, and passes both to the harness through the MCP server launch configuration (mechanism is harness-specific, `[unverified]`). Every IPC request carries them; the GUI rejects anything else, so a globally registered `bridge mcp` used outside a bridge-launched session gets nothing. Closing the panel invalidates the token.
- **Prompt-time snapshot:** the active tab's context (profile, region, account, selected resource) is written into the prompt as text when the user sends it. Tool calls must name `profile` and `region` explicitly; they do not rely on "whatever is currently selected". A `get_ui_context` tool exists for the agent to read the *current* view, with the snapshot time included.
- Each session has a profile allowlist (default from `[agent].profiles`); calls to other profiles are denied.

### 6.3 Approvals
- Agent cap is `[agent].max_tier` (default 1). A call above the cap, a sensitive reveal, or an agent-initiated transfer **blocks** while the GUI shows an approval card (profile, verified account, operation, parameters, equivalent command). The user approves *that exact call* (hash of context plus params) once, or denies. Timeout (e.g. 120 s) returns "denied" to the agent.
- Approvals happen in the GUI, not through MCP elicitation, because the harness UI is not ours. The spec says there [should always be a human in the loop](https://modelcontextprotocol.io/specification/latest/server/tools), and that tool annotations (`readOnlyHint`, `destructiveHint`) are untrusted hints. We therefore set annotations for the benefit of well-behaved clients but **never rely on them** for enforcement.

### 6.4 Data egress (important)
"Local" describes where commands run and where credentials live. It does **not** mean AWS data stays on the machine once an agent is involved: any tool result returned to the harness becomes part of that session's context and is sent to the harness's model provider. Log lines, IAM policies, resource names, ARNs and account IDs can all appear. Mitigations (reduce, not eliminate): the credential and sensitive classes in 4.5 are excluded from agent tools by default; output size caps; a best-effort secret-pattern redaction pass; a per-session profile allowlist; a trace showing exactly what was returned to the agent; and a first-use notice in the panel naming the provider in use. Provider retention and training terms are a **verification task, not a claim**.

### 6.5 Harness adapters
**Built (Claude Code only; see `plan.md` Milestone 7 for the full status).** Command line used, each flag confirmed to exist in the installed CLI's `--help` (v2.1.312): `claude -p <prompt> --output-format stream-json --verbose --include-partial-messages --mcp-config <file> --strict-mcp-config --tools "" --allowedTools "mcp__bridge__*" --setting-sources user --append-system-prompt <text> --session-id <uuid>` (later turns `--resume <uuid>`). The documentation says `-p` runs start in Manual mode where a call needing approval is denied, hence the pre-approval of our tools; that `ANTHROPIC_API_KEY` is always used in `-p` when present (so Bridge strips it by default to keep the subscription login); and that `-p` loads project settings, hooks and `.mcp.json` from the working directory unless told otherwise (so Bridge runs it in an empty private directory). **Codex** (`CodexSession`, 0.164.0): `codex exec --json --ignore-user-config --ignore-rules --skip-git-repo-check` plus `--disable shell_tool unified_exec apps view_image plugins hooks memories image_generation computer_use browser_use browser_use_external in_app_browser standalone_web_search`, `-c web_search="disabled"`, `-c sandbox_mode="read-only"` (a `-c`, not `-s`, because `exec resume` takes `-c` but not `-s`), the `-c mcp_servers.bridge.command/args/env` overrides and `-c mcp_servers.bridge.default_tools_approval_mode="approve"`, run in an empty private directory with stdin from /dev/null (otherwise Codex waits to read piped input) and an environment allowlist (no `AWS_*`, no `OPENAI_API_KEY` unless the user opts in). Later turns use `exec resume <thread id>`. Event shapes (captured live): `thread.started`, `turn.started`, `item.completed`/`agent_message`, `item.started`/`item.completed` for `mcp_tool_call` (`server`, `tool`, `arguments`, `result`, `error`, `status`), `turn.completed`; no partial text. Three independent safeguards: (1) the flags above; (2) `CodexLockdown.verify` renders the model-visible tool list with the same flags (no model call) and refuses Codex if it contains the shell, web access or any tool not on the allowlist; (3) a watchdog kills the run the moment an event shows a command, file change or web search. Residual capabilities and the unverified JavaScript runner are in the ledger. The original candidate text follows for history. `[unverified]` items remain exactly as the ledger lists them.

#### Original candidate text (superseded)
Candidate approach: launch the user's installed, already-signed-in coding-agent CLI non-interactively and read a streamed output format, with only bridge's tools allowed and shell access denied. For both Claude Code and Codex, the following must be verified from current official docs at implementation time, and none is assumed validated here: exact non-interactive invocation and flags; how an MCP server is registered per session; how tool allow/deny and permission modes work; streaming output format; whether subscription-based sign-in is supported and permitted for this kind of programmatic use; provider terms for automated use and data handling. Adapter interface (`detect`, `spawn`, `resume`, normalized events) stays an idea until then.

## 7. Risks

| Risk | Mitigation |
|---|---|
| Swift toolchain surprises: SwiftPM-only app under Command Line Tools, `.app` bundling, likely need for full Xcode | Milestone 2 records exact commands; install Xcode if required; UI kept thin over `BridgeCore` |
| AWS SDK for Swift build time/size across ~8 service modules; SSO behavior | Measure in Milestone 2 (no AWS calls); keep the CLI backend as fallback |
| Generic browser infeasible for "any service" | H1 spike with measurable pass/fail; curated fallback; the six-service scope does not depend on it |
| CLI process-per-call latency under multi-panel investigation views (unmeasured) | Measure startup floor (Milestone 1) and real calls (Milestone 3); concurrency cap; cache; switch hot paths to the SDK per the rule in section 2 |
| Chart needs exceed Swift Charts | Line-chart item in the Milestone 2 spike; `Canvas` drawing as fallback |
| Anchor-name matching finds the wrong or too many resources | User confirms matches; saved include/exclude; tags later |
| Botocore model path not a documented interface | Runtime discovery, version-keyed cache, defensive parsing, clear failure |
| Wrong-account actions | Resolved-identity header, `expected_account`, env allowlist, tier gating |
| Secrets via "read" operations | Explicit policy table; sensitive/credential classes; no caching, logging or agent exposure |
| Env or flag injection altering the target | No shell; executor-owned global options; allowlisted env |
| Partial files and path traversal in downloads | Part-file + atomic rename; sanitized paths; confirm overwrite |
| Stale results under wrong context | Context captured per request and compared on arrival; per-tab context |
| AI data egress | 6.4 mitigations and explicit user notice; terms verification task |
| Harness CLIs change flags and terms | Adapters verified per version later; nothing assumed now |
| Overlap with existing tools | Milestone 0 trial; build only for the gap that remains |

## 8. Testing
- core: config-parser fixtures (SSO session, role chain, `credential_process`, static keys); policy table tests (allow, each deny reason, unlisted operation, credential class, arg-level rules); env-allowlist test (inject hostile `AWS_*` and confirm they are stripped); path-sanitizer and part-file tests; context-mismatch tests (late result discarded); executor against a fake `aws` shim script so CI makes **no AWS calls**.
- catalog: golden tests per target operation from the local models.
- mcp/ai (Phase 3): protocol tests against a stub GUI endpoint; approval-timeout test.
- ui: manual smoke for MVP.

## Billing implementation (2026-10-29)

`BillingWorkflow` uses Cost Explorer's [GetCostAndUsage](https://docs.aws.amazon.com/cli/latest/reference/ce/get-cost-and-usage.html) request/response shape, `DAILY` granularity, `UnblendedCost`, `SERVICE` grouping and explicit `NextPageToken` handling. Period ends are exclusive. Calendar math uses Gregorian UTC and monetary totals use Decimal. Requests target us-east-1 and filter `LINKED_ACCOUNT` to the verified identity; the view explicitly labels all-region scope.

The [GetCostForecast](https://docs.aws.amazon.com/cli/latest/reference/ce/get-cost-forecast.html) call uses `UNBLENDED_COST` (the forecast API uses a different metric enum) for today through next month. Its `Total` represents the remaining forecast period, so the UI labels it Remaining month forecast. Forecast and comparison failures preserve current costs. Both CE operations have explicit read-tier, costsMoney policy entries.

The tab fetch path supports global endpoints while retaining the issuing tab's display region for stale-result checks. Cache identity and executor authorization still use the actual request region. Billing adds a per-load generation guard on top and clears all costs on a context change. No real AWS call has verified the integration yet.
