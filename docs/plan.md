# bridge — implementation plan

Implementation is in progress; the detailed status notes take precedence over historical spike checklists. See [product.md](product.md) (what and why) and [technical.md](technical.md) (how). Tags: `[done]` · `[experiment]` · `[unverified]` · `[future]`.

## Open-source preparation

See [open-source-readiness.md](open-source-readiness.md) for implemented groundwork, remaining publication blockers, reusable module structure, SDK options, CI and release gates. See [validation.md](validation.md) for current evidence. Public release readiness is not yet claimed.

## Update — 2026-10-29

Implemented the product navigation and remaining offline MVP work: service overview, persistent grouped sidebar, labelled profile/region/time controls, service headers, Cmd-K palette, model-derived read-operation forms and table/JSON results with paging, profile settings editor, and CloudWatch Logs Follow (five-second polling, bounded deduplication, cancelled on navigation/context changes).

Added Billing: verified-account scope across all regions, month-to-date unblended cost, UTC daily chart, costs by service with explicit CE pagination, same-days previous-month comparison and remaining-month forecast. Queries are explicit clicks with a cost notice. Cost Explorer API shapes were checked against the AWS CLI reference; real account behavior remains unverified.

Completed an app-wide native design audit: system sidebar/toolbar, consistent resource panes, readable metadata, compact action rows, separate settings window, native assistant inspector and redesigned Billing. Fixed table-width feedback, stale details on context switches and duplicate IAM policy-load races. See [ui.md](ui.md) for the page-by-page composition.

`make demo-app` produces a Finder-launchable `build/Bridge Demo.app` with bundled fake AWS data and isolated settings/consent. The screenshot with Table/JSON/Markdown/Charts belongs to `BridgeSpike.app`, not the product.

Release build succeeds using writable compiler caches and `--disable-sandbox -debug-info-format none` in the restricted environment. Latest offline core run: **678 checks, zero failures**, including transfer and IPC regressions. The earlier restricted-shell run had five environment-related failures. The new billing/catalog/log-buffer checks pass. The full native GUI suite now passes **179 checks with zero failures**, including every screen, populated details, Billing resize/appearance, table fitting, context changes, native include checkboxes, transfers and both fake assistant providers. The fake-agent IPC chains also pass within the GUI application session.

Remaining acceptance: real AWS profiles/response shapes, real-call latency, complete real-account W1–W7 workflows, real Claude/Codex integration. Later phases (CloudTrail, comparison, fan-out) remain future work. Folder rename remains deferred.

## Where things stand (2026-10-28)

| Area | State |
|---|---|
| Real Swift package created (`BridgeCore`, `BridgeApp`, `BridgeCoreTests`, Makefile, `bundle.sh`); Rust placeholder removed; `make test` passes 54 checks; `make app` builds `build/Bridge.app` | `[done]` |
| Project/package rename from `myaws` to `bridge` (folder still `myaws`; you chose "later") | `[done]` (folder rename `[future]`, between sessions) |
| Product/technical/plan docs | `[done]`, revised this round |
| UI direction: native Swift. GPUI dropped | decided 2026-10-28 |
| Core language: all-Swift, AppKit-first (decided on my recommendation; reversible) | decided 2026-10-28; final structure in `technical.md` section 3 |
| SDK dependency | `[future]`: none (CLI-first) |
| (History) `gpui 0.2.2` + `runtime_shaders` compiled with Command Line Tools only | `[experiment]`, off the critical path |
| Swift 6.4 present with Command Line Tools only | observed |
| Precedent: `../waffle` (Swift/AppKit + Rust engine) built with SwiftPM and a `bundle.sh`, "No Xcode required" | read by me, not built or run |
| AppKit + SwiftUI + Swift Charts via SwiftPM under CLT: builds, bundles, launches. `@State` does not compile (no SwiftUIMacros plugin); `@Observable` works. SwiftUI `Table` itself was not tried (AppKit `NSTableView` used) | `[experiment]` |
| Local AWS CLI service models inspected for the five target services (counts in `technical.md` 4.7) | `[experiment]` |
| Machine: aws-cli 2.37.9, rustc/cargo 1.95.0, claude 2.1.311, codex 0.164.0; only Command Line Tools (no full Xcode) | observed |

## Milestones

### Milestone 0 — Positioning trial (about 1–2 hours, done by you, not by me)
Purpose: check the overlap found in `product.md` before building. Install and try **claws** (primary candidate) and **Mercek** (for ECS) against your own profiles, read-only. I will not touch your AWS accounts.
Run the workflows W1–W6 (`product.md`) and note, per workflow: fully supported, partly, or not.
- **Pass (proceed as planned):** at least two of W1–W6 are clearly poor or missing in both tools, or a GUI/log-viewer difference (D1) is something you'd actually pay in daily friction for.
- **Fail (rethink scope):** claws or Mercek already covers W1–W6 well enough that you would stop there. Then reduce bridge to the parts they lack (likely the safety model D3 or specific views), or don't build.

### Milestone 1 — Catalog feasibility spike (smallest next spike; offline; about a day)
Tests hypothesis H1 (`technical.md` 4.7). **No AWS calls, no credentials, no UI, no dependencies in the main repo** (a throwaway program outside it, or a test in `bridge-core` once approved).

Inputs: the target services' models in the installed CLI (`lambda`, `ecs`, `iam`, `s3`→`s3api`, `logs`, `sqs`) plus `sts` and `cloudwatch`.

Workflow operation set (~37) the catalog must handle:
- lambda: `ListFunctions`, `GetFunction`, `GetFunctionConfiguration`, `ListVersionsByFunction`, `ListEventSourceMappings`
- sqs: `ListQueues`, `GetQueueUrl`, `GetQueueAttributes`
- logs: `DescribeLogGroups`, `DescribeLogStreams`, `FilterLogEvents`, `GetLogEvents`, `StartLiveTail`, `StartQuery`, `GetQueryResults`
- ecs: `ListClusters`, `DescribeClusters`, `ListServices`, `DescribeServices`, `ListTasks`, `DescribeTasks`, `DescribeTaskDefinition`
- iam: `ListRoles`, `GetRole`, `ListAttachedRolePolicies`, `ListRolePolicies`, `GetRolePolicy`, `GetPolicy`, `GetPolicyVersion`
- s3api: `ListBuckets`, `ListObjectsV2`, `HeadObject`, `GetObject`
- sts: `GetCallerIdentity` · cloudwatch: `DescribeAlarms`, `GetMetricData`, `ListMetrics`
- Custom CLI commands not in the models, hand-defined: `aws s3 cp`, `aws logs tail`.

Pass criteria (all must hold):
1. The program emits a complete catalog entry (params tree with required flags, output shape, paginator info) for **100%** of the operation set above, with recursive or union shapes either handled or explicitly marked "raw JSON field".
2. For every paginated list operation in the set, the derived result collection path matches a hand-checked expectation (**100%**; expected examples: `Functions`, `clusterArns`, `Roles`, `logGroups`; `FilterLogEvents` has two result keys).
3. The number of **manual overrides** needed so every workflow in `product.md` has a path from list to detail is **10 or fewer** across all six services (ECS ARN-list to `Describe*` links and SQS queue-URL links are expected to be most of them).
4. A form schema can be generated for every operation with required input (fields, types, nesting).
5. Cold catalog build for the six services takes **under 2 seconds** (or the cache hit path does).
6. Model directory discovery works on this machine's Homebrew install, with a documented candidate list for the official installer path and a clear error if neither is found.
7. **Engine startup floor (offline, no network):** time 30 runs of `aws --version` sequentially and 6 in parallel; record p50 and p95. This is a lower bound on CLI per-call cost, not the real-call latency. Informational: no pass/fail, but if the parallel p95 is already near 1 second, plan the SDK path for hot calls now (rule in `technical.md` section 2).

Fail path: adopt the curated fallback in `technical.md` 4.7 (curated definitions for the ~37 operations plus a raw JSON runner). The six-workflow scope is unaffected. Record which criteria failed.

Output: a short results note appended to `technical.md` with the numbers.

**Status: run 2026-10-28.** Verdict: **supports H1 for the six target services, with caveats; not a clean sweep.** Criteria 1, 4, 5 and 6 pass (6 on Homebrew only). Criterion 2 was 13 of 16 as written (the 3 misses are gaps in my own expectations, not derivation errors, but the bar was not met literally). Criterion 3 is 8 distinct list-to-detail links by hand (pass), about 12 if investigation cross-links are included (over 10). Criterion 7: startup floor about 200 ms, no degradation at 6 parallel. Details and two design findings (first paginator key is primary; trust paginators only) in `technical.md` section 4.7. The curated-plus-generic design stands: generic derivation for paginated list operations, a small overrides file for links, hand-defined views for the rest. "Any service" beyond these 8 remains unproven.

### Milestone 2 — Swift feasibility spike (go/no-go; about a weekend)
Settles the toolchain and the core-language question with evidence. This is where the Swift package first appears (a throwaway spike package, not the real layout yet).
- [ ] **Toolchain:** start from `../waffle`'s proven setup (SwiftPM + AppKit, tests as an executable target). Check whether SwiftUI `Table` and Swift Charts also build and run via `swift build` under Command Line Tools, directly or hosted in AppKit with `NSHostingView`. Record the exact working commands; Xcode only if truly needed.
- [ ] **App bundle:** produce a double-clickable `.app` with a `bundle.sh` adapted from `../waffle`.
- [ ] Sidebar with hard-coded profiles; selecting one changes a header; two tabs holding independent state.
- [ ] Table with 10,000 rows: scrolling shows no visible hitching; sorting a column completes in under 200 ms. Try SwiftUI `Table` first; wrap `NSTableView` if it hitches.
- [ ] JSON viewer renders a ~1 MB document and opens in under 500 ms, with search; markdown view (`AttributedString`) renders headings, lists, code blocks.
- [ ] Two Swift Charts line charts, 1,000 points each, sharing one labelled time axis, with a hover tooltip.
- [ ] **Subprocess:** run `aws --version` through `Process` with an allowlisted environment; cancelling the Swift task kills the child.
- [ ] **AWS SDK for Swift (no AWS calls):** add modules for STS, Lambda, ECS, IAM, S3, CloudWatch Logs, CloudWatch and SQS; record clean-build time, incremental-build time and binary size. Proposed bar: incremental build under 30 seconds.
- **Pass:** all items hold. The Xcode requirement is acceptable if it is only a one-time install.
- **Fail/partial:** SDK build times or SSO behavior unworkable means CLI-only backend for now; UI items unworkable means reconsider (web UI with a local server, or a Rust-based UI).

**Status: mostly run 2026-10-28** (`Spikes/ui/`, numbers and caveats in `Spikes/ui/RESULTS.md`).
- **Done and passing:** toolchain (AppKit + SwiftUI + Swift Charts build, bundle to `.app` and launch under Command Line Tools only); 10k-row table (sorts in under 8 ms); JSON in `NSTextView` (about 7 ms to first screen); charts render via `NSHostingView`; `aws --version` through `posix_spawn` with an allowlisted env; task cancellation kills the child's whole process group in about 1 ms.
- **Findings:** SwiftUI `@State` does not compile under CLT (no `SwiftUIMacros` plugin); use `@Observable`. AppKit does not style Markdown from `AttributedString` block intents, so a custom renderer is needed. The first cancel implementation did not work until the child's signal state was made explicit.
- **Visually confirmed (your screenshots and report):** window renders; table and JSON scrolling are smooth; both charts render with a shared time axis and a synchronized hover rule and readout on both. **Markdown loses all block structure** (paragraphs, headings, lists and the code block run together; only inline bold/code/link survive), so a custom Markdown block renderer is a real work item for the AI panel.
- **AWS SDK for Swift build cost (measured, scratch package):** about 24 min and 3.9 GB to download, 132 s clean release build, 70.9 MB binary, and an incremental rebuild of about 92 to 133 s, which **misses the 30 s bar** (release configuration only; debug not measured). Feasible but heavy, so **CLI-first stands**; revisit the SDK only if Milestone 3's real-call latency is unacceptable. SDK SSO behavior untested.
- **Not done:** tab-independence check by eye; JSON jump to the very end.
- **Milestone 2 verdict:** the Swift/AppKit approach passes on this machine (see `Spikes/ui/RESULTS.md`), with two constraints carried forward: no `@State` under Command Line Tools (use `@Observable` islands), and a custom Markdown renderer is part of the AI-panel work (a working prototype exists in the spike). The table's whole-page redraw averaged 20.5 ms against a 16.7 ms bar, which is not conclusive for real scrolling.

### Milestone 3 — Core v0 (headless, no AWS calls in tests)
- [x] Config parser and fixtures (SSO session, role chain, `credential_process`, static keys): done 2026-10-28, 54 checks. Secret keys are dropped at parse time and a test asserts they appear nowhere in the model. The tests also caught and fixed a CRLF bug (Swift treats `\r\n` as one Character).
- [x] Executor (`CLIExecutor`, `ProcessRunner`): direct `posix_spawn` with no shell, own process group, explicit signal state, only fds 0-2 inherited, executor-owned options, validated tokens (a hostile profile name arrives as one literal argument), env allowlist enforced in the child, 0600/0700 temp file for `--cli-input-json`, timeout, cancellation and output cap that kill the whole process tree (tested: no leaked grandchild). Only runs `AuthorizedRequest` values that only `Authorizer` can create.
- [x] Resolved identity: `IdentityProbe` and `IdentityStore` (concurrent probes share one call; invalidate forces re-verification); `ExecError.authExpired` classification (patterns from memory, `[unverified]`). `SsoLogin` runs `aws sso login --profile P`, streams the device URL and code while it runs, and cancels cleanly (the CLI's exact output wording is `[unverified]`; the parser only looks for an https URL and an `ABCD-EFGH`-shaped code).
- [x] Policy table (`PolicyTable.standard`, explicit rows, unlisted = unsupported), `Authorizer` with caps, tiers, verified-identity and `expected_account` checks, confirmation levels, credential-class deny list, sensitive class hidden from agents, denied parameters (`Unmask`). Settings file: `BridgeSettings`/`SettingsStore` (JSON at `~/.config/bridge/config.json`, decided against TOML to avoid a dependency): `max_tier`, `protected`, `expected_account`, agent caps; tolerant decoding, out-of-range values fall back to defaults and never fail open, corrupt files are never overwritten, `credential_process` trust stored as a SHA-256 hash.
- [x] Transfers: `S3Downloader` (part file, atomic rename with `RENAME_EXCL`, cancel/failure/timeout cleanup, no silent overwrite, stale-part sweep) and `PathSanitizer`. Real bug found by a test and fixed: Foundation's `resolvingSymlinksInPath()` does not resolve symlinks when the final file does not exist, so a symlink inside the destination folder could have led a download outside it; now `realpath` on the deepest existing ancestor, with dangling symlinks refused.
- [x] Context-tagged results and stale-result discard (`RequestContext`, `ViewContext`, `TimeWindow`); `ResultCache` keyed by verified account, principal, region, operation, params, resolved window and CLI version; sensitive and live operations never cached.
- [ ] **Real-call latency measurement** on one profile you choose (tier-1 calls only: identity, a log-group list, a metric query): sequential and 6 in parallel, p50/p95. Needs your explicit go-ahead. Apply the CLI-versus-SDK rule in `technical.md` section 2.
- [x] Investigation model (anchor, discovery by case-insensitive match, user exclusions and hand-added resources, deterministic links, retargeting for UAT-vs-prod, saved files with no AWS data) with unit tests.
- [x] Workflow layer for W1 to W6 (`Workflows/`): request builders (exact AWS parameter shapes, chunking for the describe limits) and defensive parsers, plus `DataService` (identity + policy + cache + execution as the single entry point) and a canned-response fake `aws` (`Fixtures/fake-aws/responses/`). **Parsers are from memory of AWS response shapes, tested only against invented fixtures** `[unverified]`: the first real run on your profiles is the real test.
- [x] Command line in the same binary: `bridge profiles | identity | run | download | sso-login | policy`, same policy path as the app (exit code 3 = denied).
- Done when: the env-injection, deny-reason, path-traversal and late-result tests pass against a fake `aws` shim. **Met:** 438 checks pass (`make test`), none touching the network, AWS or your real `~/.aws`. Remaining in this milestone: the real-call latency measurement, which needs you: run `bridge identity <profile>` and `bridge run <profile> logs describe-log-groups --max-items 50` yourself on a profile you pick (read-only), and send me the timings, or tell me to run them.

### Milestone 4 — Six workflows and the investigation view (MVP)
Order by value to you: W5 (CloudWatch Logs, the base for everything else), W1 (Lambda), W2 (ECS), W6 (SQS), W3 (IAM, linked from the others), W4 (S3). Then the investigation view composing them. Each workflow is accepted against its target in `product.md`, which are still unmeasured targets.
- [x] Service sidebar, profile/region controls, verified-identity header, independent tabs, shared time-range control.
- [x] Curated views W1–W6 and cross-links; metric charts (real AWS acceptance pending).
- [x] Investigation view: anchor discovery, panels sharing the tab's window, save and reopen (real AWS acceptance pending).
- [x] Command display and Copy command button; freshness label and refresh.
- [x] Settings file and profile editor with labels, colors, `protected`.
- Done when: you can complete W1–W6 on your real profiles, and run one saved investigation across logs, ECS, Lambda, SQS and alarms, without opening the console.

**Status (2026-10-28): the app is built and passes its headless checks, not yet run against real AWS.** `Bridge.app` has the toolbar (profile, region, time range, refresh with "updated N s ago"), identity strip with a PROD/protected cue, source-list sidebar, native window tabs (each tab its own context), and all views from `docs/ui.md`: Lambda (masked environment, links to logs and role), CloudWatch Logs (pattern search over the tab's window, level colours), ECS (health, deployments, events, stopped-task reasons, log link), SQS (attributes, DLQ, consumers, charts; never reads messages), IAM (trust policy, attached/inline policies, decoded documents), S3 (browse, metadata, download through the policy with progress, cancel, no partial files), Alarms, and the Investigation view (anchor discovery across five services, status per resource, charts, exclusions, saved investigations, "open in another profile" for UAT-vs-prod). `make ui-test` drives all of it against the fake `aws` (**64 checks**, plus **439 core checks** from `make test`); `make demo` opens it on fake data. A real bug found on the way: Swift type inference let `flatMap{...}.compactMap{ $0.split(...) }` compile with an array where a String was meant, which sent a nonsense cluster name; the test now asserts real cluster names. **Not verified:** everything against real AWS (parsers are from memory of response shapes), real-call latency, and how it looks and feels (I cannot see the screen; the earlier spike was checked by your screenshots). Acceptance targets W1-W6 in `product.md` are still unmeasured.

### Milestone 5 — Generic runner (only if H1 passed)
- [x] Operation picker and model-derived parameter form, table and searchable JSON text, primary paginator collection and Next page. Explicit policy reads only; sensitive reads and event streams excluded.
- [x] Cmd-K palette for services and tools.

### Milestone 6 — Productive (Phase 2)
CloudTrail "what changed" panel; UAT-vs-prod investigation comparison; saved views and history; multi-profile and multi-region fan-out; RDS/ALB/EventBridge/ECR as usage says; cache polish.

### Milestone 7 — AI (Phase 3)
**Status (2026-10-28): built for Claude Code and Codex, tested against fake harnesses; Claude Code was never run for real, and Codex had two live checks with a stub tool and no AWS data.** Done: `Redactor` (best-effort secret removal, JSON path masking), `McpServer` (stdio JSON-RPC: initialize, ping, tools/list, tools/call), `AgentIPCServer`/`AgentIPCClient` (Unix socket in a 0700 directory, 0600 socket, 256-bit per-session token, same-user check), `AgentBackend` (the single enforcement point: profile allowlist defaulting to the tab's profile only, tier cap, sensitive and credential operations refused, masked paths, redaction, output cap, a trace of every call), `ClaudeStream` parser, `AgentSession` (launches `claude -p` with `--tools ""`, `--strict-mcp-config`, a one-server MCP config, `--allowedTools mcp__bridge__*`, `--setting-sources user`, an empty working directory, and an environment allowlist that strips every `AWS_*` variable and `ANTHROPIC_API_KEY`), `bridge mcp` in the same binary, an informed-consent gate stored in `~/.config/bridge/agent-consent.json`, and the assistant panel (consent screen, streaming chat with Markdown rendering, trace of what was read, a new conversation whenever the profile changes, Cmd-Shift-A). **Off until the user accepts the disclosure.** Verified against the real installed CLI (v2.1.312) only through `--help`: every flag used exists and `--tools ""` is documented there as disabling all tools. **Not verified:** a real turn with the real `claude` (no prompt has been sent to any provider), the real stream-json event shapes (only the SDK types are documented, so the parser is tolerant), the MCP handshake with the real client (spec 2025-11-25; the 2026-07-28 revision describes a handshake-less flow that was not read), and whether a personal app like this is permitted on your Claude plan (see below). **Codex is also supported** (added the same day after checking the installed CLI, 0.164.0; see `technical.md` 6.5). **Deliberately not built:** approval cards for tier 2+ (agent tools are read-tier only, so nothing needs approval), and an agent download tool.

Implementation checklist (real provider/account verification remains pending):
- [x] Harness details verified from official docs (Claude Code only) and the installed CLI's `--help`; see the ledger for what remains unverified.
- [x] `bridge mcp` proxy, local IPC with session token and trace. Approval cards are intentionally omitted while agents remain read-only.
- [x] Claude Code and Codex adapters; real Claude turn remains unverified.
- [x] Data-egress notice and redaction pass.
- [ ] Provider-terms review before any open-sourcing.

## Order of work and why
Milestone 0 is cheap and can end the project early, so it comes first. Milestone 1 is offline and decides the architecture of everything that follows. Milestone 2 de-risks the UI framework. Core before screens, because policy, identity and executor correctness are what keep the tool safe.

## Open decisions
1. After Milestone 0: build as planned, narrow the scope, or stop?
2. Tier-3 actions to support first, if any (Lambda invoke, ECS stop task / force deployment, S3 upload).
3. `max_tier` default for new profiles (proposed 2) and whether `protected` should be auto-suggested from profile names containing "prod".
4. Personal tool or open source? (affects licensing, terms review, redaction rigor)
5. Distribution: run from the build, or a signed/notarized `.app` eventually? (Unsandboxed, so not the Mac App Store; notarization details `[unverified]`.)
6. Rename the folder `myaws` to `bridge`: **deferred by you ("later")**; do it between sessions.
7. ~~Core language~~ Decided: all-Swift, AppKit-first. Still open: CLI-versus-SDK engine, settled by the latency measurements (Milestones 1 and 3).
8. ~~Anchor-name matching versus tags~~ Decided: name matching for the MVP; tags later.

## Verification ledger: claims not verified

External claims that rest on a source are linked in the docs. These are **not** verified, and the docs treat them as assumptions:

| Claim | Why unverified | How to resolve |
|---|---|---|
| Other macro-backed SwiftUI features (beyond `@State`) under Command Line Tools; SwiftUI `Table` | Only `@State` failure and Swift Charts hosting were exercised | Avoid SwiftUI beyond small `@Observable` islands, or test when needed |
| Real on-screen feel: table scrolling, chart hover tooltip, tab independence, JSON far jumps | Headless draws only; no screenshots possible in this session | You, running `open Spikes/ui/build/BridgeSpike.app` |
| Hybrid boundary can handle async, streaming, cancellable calls cleanly | waffle's engine is synchronous; ours would not be | Only if the core-language question reopens |
| AWS SDK for Swift: SSO profile handling in practice, App Sandbox specifics, build time across modules; its GitHub README still says developer preview while AWS announced GA | Only blog/docs snippets read | Milestone 2; read the developer guide |
| MCP Swift SDK: current release, spec revision, server-side stdio support, Xcode 16+ requirement | Search results disagree on versions | Check the modelcontextprotocol/swift-sdk repo at Milestone 7 |
| Swift UI + Rust core hybrid (FFI or socket) costs | Reasoned, not prototyped | Only if the core-language question reopens |
| Botocore model directory is a stable, supported interface | Official docs fetched do not say so; only `AWS_DATA_PATH` is documented | Milestone 1 discovery + version-keyed cache |
| CLI backward-compatibility/versioning policy | The versioning docs page did not render when fetched | Read the aws-cli changelog/versioning docs before depending on output shapes |
| Whether pagination options apply only to operations with paginator definitions | Docs say they work "only if the service API enables them" and point to per-command reference | Milestone 1 against the paginator files |
| `--cli-input-json` accepting stdin | Not documented in the pages read | Test locally, or keep the temp file |
| Download interruption and temp-file behavior of `aws s3 cp` / `get-object` | CLI docs only describe upload cleanup | Own part-file design; test locally |
| Progress output usable for parsing | Not checked | Use size polling; test if wanted |
| Other `logs` operations' sensitivity (e.g. `get-log-events`) | Only `filter-log-events --unmask` was checked | Review when adding rows to the policy table |
| AWS Toolkit for VS Code explorer coverage, multi-profile display, actions, AI | Explorer docs page did not render | Read it directly, or leave Toolkit out of positioning claims |
| claws/Mercek/taws: S3 object download, Lambda invoke, confirmation prompts, telemetry | Not stated on pages read | Milestone 0 trial; read their issues and docs |
| Dates for tool releases | Pages show day and month only | Treat as approximate |
| Mercek's "connects to AWS and nothing else" versus its documented auto-update | Update endpoint not documented | Irrelevant to our design; do not repeat the claim |
| Leapp, Granted, aws-vault, Steampipe, CloudQuery, Komiser descriptions | Earlier research used search snippets, not primary sources | Not relied on for positioning |
| **Anthropic terms vs this app (important)**: official docs say "Developers building products or services that interact with Claude's capabilities ... should use API key authentication", that third parties may not "route requests through Free, Pro, or Max plan credentials on behalf of their users", and that this does not prevent "an end user from signing in to the unmodified Claude Code binary with their own Claude subscription". The Consumer Terms (effective Oct 8, 2025) bar automated access "except when you are accessing our Services via an Anthropic API Key or where we otherwise explicitly permit it". Whether a personal local app that starts your own logged-in `claude` is permitted is **not documented** | Official pages read via a research agent on 2026-10-28; the Usage Policy and Commercial Terms text were not fetched | You decide, with your plan's terms in hand; the assistant is off until you accept the disclosure; re-check before open-sourcing |
| Claude Code stream-json event shapes from the CLI itself (only the Agent SDK message types are documented), `--tools ""` and `--strict-mcp-config` semantics beyond `--help`, whether `-p` works without a TTY, `claude auth status` output | Docs summaries and `--help` only | First real run by you; the parser ignores unknown shapes |
| Claude Code retention and telemetry facts: transcripts stored locally in plaintext under `~/.claude/projects/` for 30 days; commercial-terms retention 30 days; `DISABLE_TELEMETRY` etc. | Quoted by a research agent from official pages (some from page summaries) | Re-read the pages before relying on exact wording |
| Codex lockdown: `--disable shell_tool --disable unified_exec` removes the shell, `--disable view_image` image reading, `--disable apps` connectors, `-c web_search="disabled"` web access, `--ignore-user-config` your own config, `-c mcp_servers.bridge.*` registers our server and `default_tools_approval_mode="approve"` pre-approves it | **Verified on the installed CLI (0.164.0, 2026-10-28)** by rendering the tool list with `codex debug prompt-input` (local, no model call) and by two live turns with a stub tool and no AWS data (the model itself reported no shell or web tool; the MCP call succeeded). The official docs do NOT document most of these flags | `CodexLockdown.verify` re-renders the tool list every time the panel opens and refuses Codex if anything unexpected appears; re-run the live check after Codex updates |
| Codex residual capabilities that cannot be removed by flag: `apply_patch` (read-only sandbox; any file change kills the run), the JavaScript `exec` runner (its own abilities beyond calling nested tools are **unverified**), multi-agent helpers, MCP resource helpers, goal tools | Seen in the rendered tool list and the model's own report | Accepted and disclosed in the consent screen; revisit if Codex documents a way to remove them |
| Codex ChatGPT-plan login for third-party apps; whether a personal app launching your own `codex` is permitted | Official pages say API keys are recommended for automation and do not address this | You decide; the consent screen says so |
| Codex session persistence location and content | `exec resume` needs persisted sessions; the location was not checked | Check `~/.codex` after a real use |
| How a session token reaches `bridge mcp` through each harness's MCP launch config | Harness-specific | Milestone 7 |
| SDKs perform no SSO login themselves (stated in the JS guide; Swift/Rust not checked) | Only JS docs read | Check Swift SDK docs in Milestone 2; CLI `aws sso login` is the fallback either way |
| MCP authorization/security-best-practices specs | Not fetched | Read before any non-stdio transport |
| Two specifics from the CLI docs fetch rest on summaries, not verbatim text | `cli_pager`/`output`/`region` config-setting text; `ToolAnnotations` field names | Re-read before relying on exact wording |
| SQS `ReceiveMessage` hides messages from consumers; CloudTrail event history covers 90 days of regional management events; ECS stopped-task error docs | Claims from an outside review agent with AWS doc links; we have not opened them | Read the cited AWS pages before relying on the details |
| CLI per-call latency (real calls) | Only the offline startup floor is measured (about 200 ms, `aws --version`) | Milestone 3 |
| Official-installer model path (`/usr/local/aws-cli/v2/...`) | Not installed here; only Homebrew tested | Test if you ever switch installs |
| Swift Charts, SwiftUI `Table` and TextKit meet our needs (10k rows, 1,000-point shared-axis charts, 1 MB JSON) | Not tested | Milestone 2 |
| Anchor-name matching is sufficient to group related resources | Depends on your naming/tagging | Test on a real anchor like `example-workload` in Milestone 4 |
