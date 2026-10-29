# bridge — product direction

Docs only; nothing here is implemented yet. Tags used across all three docs:
`[done]` exists in the repo · `[experiment]` done in a scratch project, reported not reproduced in repo · `[unverified]` assumption, no source checked · `[future]` planned work.

**Naming:** the project is **bridge**. "myaws" was the working title; the local folder is still `~/Personal/code/myaws` and may be renamed later (renaming moves the session's working directory, so do it between sessions).

## One-liner
A local, native desktop workbench for investigating and operating AWS from the profiles already in `~/.aws/config`. It starts with six services (Lambda, ECS, IAM, S3, CloudWatch, SQS) organized around **investigations**: pick a thing you're debugging and a time range, and see its related logs, tasks, functions, queues and alarms together. An AI assistant that uses your installed coding-agent CLI comes later.

## Who it's for
One developer/operator with several AWS profiles who currently runs `aws ...` in a terminal. Built for the author first. Open-sourcing is undecided.

## Problems we're trying to solve
1. The AWS console is one account per tab, with many clicks between "what is this function" and "why is it failing".
2. CLI output is large JSON; following a Lambda to its role and logs, or an ECS service to its stopped tasks, means copy-pasting identifiers between commands.
3. Several profiles are in daily use, and it is easy to run a command against the wrong account.

## Positioning (corrected)

Earlier drafts said existing tools are "narrow" and that nothing offers broad multi-profile browsing. That was wrong. Below is what four tools **document about themselves**, from their own repositories and docs, fetched 2026-10-28. Release dates are shown on the pages without a year.

| | Form | License | Profiles | Coverage of our original five services (documented; SQS not checked) | Actions / safety | AI |
|---|---|---|---|---|---|---|
| [claws](https://github.com/clawscli/claws) | Go TUI | Apache-2.0 | **Several profiles and regions queried in parallel** (`-p dev,prod -r ...`) | "70 services, 175 resources". [services.md](https://github.com/clawscli/claws/blob/main/docs/services.md) lists Lambda functions; ECS clusters/services/tasks/task defs; IAM users/roles/policies/groups/instance profiles; S3 buckets; CloudWatch alarms/log groups/log streams | Start/stop, delete, tail logs; `--read-only`; cross-resource jumps (e.g. Lambda to CloudWatch). Confirmations, S3 object download, Lambda invoke: not documented on pages read | Built-in chat via [Amazon Bedrock](https://github.com/clawscli/claws/blob/main/docs/ai-chat.md) |
| [taws](https://github.com/huseyinbabal/taws) | Rust TUI (Ratatui) | MIT | **Switch** between profiles/regions; simultaneous display not documented | README gives two figures ("94+ resource types / 60+ services" and "30 services with 51 resource types"). Lists Lambda functions; ECS clusters/services/tasks; IAM users/groups/roles/policies/access keys; S3 buckets; CloudWatch log groups | EC2 start/stop/terminate; `--readonly`; confirmations not documented. Latest release page is a release candidate (v1.3.0-rc.8) | None documented |
| [Mercek](https://www.mercek.dev/) ([repo](https://github.com/utibeabasi6/mercek)) | Tauri desktop (Rust + React) | MIT | **Several accounts/regions at once** from `~/.aws` profiles | **ECS only** (plus its logs, ECR scans, ALB target health, autoscaling). Lambda/S3: not documented | "Read-only by default - writes always go through a diff you confirm." macOS and Linux; Windows planned | **Bring-your-own coding agent over the Agent Client Protocol**; chat history stays local |
| AWS Toolkit for VS Code ([docs](https://docs.aws.amazon.com/toolkit-for-vscode/latest/userguide/setup-credentials.html)) | IDE extension | not checked | Multiple credential profiles can be configured; **explorer coverage and simultaneous-profile display are not verified** (the explorer docs page did not render when fetched) | Not verified | Not verified | Not verified |

Notes on the table:
- **Mercek is the closest in shape** (local desktop app, existing profiles, coding-agent integration). It is ECS-only.
- **claws overlaps most on breadth** and already covers the five services at the resource-list level. Whether it supports our workflows (log filtering by pattern, S3 download, policy documents) is not established from docs; that is what the trial in `plan.md` Milestone 0 checks.
- Mercek says it "connects to AWS and nothing else" yet also documents in-app auto-update. Not our problem to resolve, but a reminder that "no network except AWS" claims need care. See our own wording under Principles.
- Earlier notes on credential tools (Leapp, Granted, aws-vault) and inventory tools (Steampipe, CloudQuery, Komiser) came from search snippets and were not re-verified. They are adjacent categories, and we make no "gap" claim about them.

### Differentiation hypotheses (not facts)
Each is something we believe might matter and can test cheaply.
- **D1. Native GUI over TUI.** A real table, log viewer and JSON/policy viewer are better for investigation than a TUI. *Test:* use claws for the workflows first (Milestone 0); note where a TUI hurts.
- **D2. Investigation-first, not resource-first.** Navigation follows what you're debugging, not an alphabetical resource list. The concrete form is the **investigation view** (below): one anchor plus one shared time range driving logs, ECS, Lambda, SQS and alarms together. claws documents some cross-resource jumps, so the difference is depth (shared time range, correlated panels), not novelty. This is our strongest hypothesis.
- **D3. One policy for human and agent.** The same tiers, identity check and approval path whether you click or an agent calls. Neither claws (Bedrock chat) nor Mercek (ACP agent) documents an equivalent shared policy layer. Not verified further.
- **D4. Coding-agent subscription for AI (built, off by default, and legally unresolved).** Anthropic's documentation tells product builders to use API-key authentication and does not say whether a personal app that starts your own logged-in `claude` is allowed (see the ledger in `plan.md`). So the assistant requires an informed opt-in, separately for each provider (Claude Code and Codex are both supported), and is not claimed to be permitted. You have decided to use the CLIs under your own logins; the disclosure remains as an honest record.
- **D4 (original wording).** Mercek documents bring-your-own-agent over ACP, so this is **not unique**. It stays only as a design choice, and AI is Phase 3.

Honest read: overlap is substantial. The case for building is personal fit (your five services, your workflows, your safety model), not a market gap. Milestone 0 is designed to falsify that quickly.

## Principles
- **Local execution.** No bridge server, no telemetry, no account. Credentials stay in your AWS config and the AWS CLI's own handling; bridge never stores or copies them. *Caveat:* once AI is added, data you show the agent goes to that agent's provider (see `technical.md`, Phase 3).
- **Config is the source of truth.** Reads `~/.aws/config` as-is; never rewrites it.
- **Always know which account.** Every view shows profile, region and the verified account/role from `sts get-caller-identity`.
- **Safe by default, actions opt-in.** Four action tiers (1 read, 2 transfer to local disk, 3 reversible change, 4 destructive), set per profile with one setting (`max_tier`). Anything not explicitly classified is refused. Credential- and secret-returning operations are a separate, gated class.
- **CLI-transparent.** Each result shows an equivalent, copy-pasteable `aws` command.
- **A few services done well before "any service".** A generic runner for arbitrary operations is a hypothesis (H1 in `technical.md`), not a promise.
- **AI is a guest.** Later, it drives your installed agent CLI. No API keys in bridge. Provider-specific details are unverified (see `plan.md` ledger).

## Initial scope: six services, one investigation view, six workflows

Services: **Lambda, ECS, IAM, S3, CloudWatch (Logs, Metrics, Alarms), SQS**. EC2, RDS, ALB and the rest are explicitly later (see Phase 2). Revisit if usage says otherwise.

### The investigation view
An **investigation** is `{ profile, region, anchor, time range }`.
- **Anchor:** a name or substring (e.g. `example-workload`). In the MVP it is matched against each service's list (ECS services, Lambda functions, SQS queues, log groups, alarms) and the user confirms the matches. Tag-based discovery is `[future]`.
- **Links we can follow deterministically:** ECS task definition to its container log group; Lambda to its log group (`/aws/lambda/<name>`); Lambda to its SQS source queue through its event source mappings; any of these to the IAM role they use.
- **Shared time range:** one control (e.g. "last 15 min", or an absolute window) that updates every panel at once. Relative ranges are resolved to absolute times when a request is sent (see `technical.md`).
- **Saved:** an investigation (anchor, profile, region, range preset) can be saved and reopened. Saved files hold no AWS data and no credentials.
- Per-service views (W1–W6) remain available on their own; the investigation view composes them.

Targets below are **acceptance targets to validate, not measured results**. "Warm" means the SSO session is valid.

**W1 — Lambda: why is this function failing?**
Find a function by name substring in a profile/region; see runtime, handler, memory, timeout, role ARN, and environment variable **names** (values hidden until revealed). Open its log group, filter the last 15 minutes by pattern (e.g. `ERROR`), expand an event, jump to the execution role (W3).
Target: warm, at most 6 interactions and about 10 s from profile selection to filtered error lines.

**W2 — ECS: what's wrong with this service?**
Cluster, then service (desired/running/pending, deployment states, recent events), then stopped tasks with `stoppedReason`, then that task's container log group. Note that ECS list calls return ARNs only; the UI must follow with the matching describe call (see `technical.md`).
Target: warm, service health and the last stopped-task reason within 4 interactions.

**W3 — IAM: what can this role do?**
Role: trust policy, attached managed policies, inline policy names. Open a policy document (default version). Show "who am I" for the active profile.
Target: policy document readable (formatted, collapsible) within 4 interactions from a role ARN.

**W4 — S3: find and download an object.**
Buckets, prefix navigation (with pagination), object metadata, download to a chosen folder with progress and cancel. Cancel or failure leaves no partial file; overwrite needs confirmation. Download is tier 2.
Target: a multi-hundred-MB object downloads with accurate progress; cancelling mid-way leaves the destination folder unchanged.

**W5 — CloudWatch: search and tail logs.**
Log group list with filter; search by pattern and time range; live tail with stop; optionally a Logs Insights query with a visible "queries may incur cost" notice; optionally alarms currently in ALARM.
Target: tail starts within a few seconds and stops cleanly, leaving no orphaned `aws` processes.

**W6 — SQS: slow consumer or stopped consumer?**
Queue list with filter; for a queue, show visible / in-flight / delayed message counts, oldest-message age and its trend, visibility timeout, DLQ configuration and DLQ depth, and the Lambda functions consuming it (via event source mappings). **Metrics and queue attributes only; no message receive/peek in v1**, because receiving messages changes their visibility and would interfere with real consumers.
Target: warm, distinguish "backlog growing while consumers run" from "no consumers" within 3 interactions.

Cross-links that matter: Lambda to its log group, role and source queues; ECS service to task definition, task role and log group; SQS queue to consuming Lambda and its DLQ.

## Features by phase
**Phase 1 — Six workflows and the investigation view**
- Profile sidebar from `~/.aws/config`; region picker; SSO login and expiry handled; verified-identity header on every view.
- Curated views for W1–W6; the investigation view with a shared time range; time-series charts for metrics (Lambda duration/errors, queue depth and age); common JSON viewer; command display and copy.
- Action tiers and per-profile `max_tier`; **v1 ships tiers 1 and 2 only** (reads and S3 downloads). The tier 3/4 machinery exists in policy but no change actions are exposed.
- S3 download with safe destination handling.
- Independent tabs, each with its own profile and region (see `technical.md`).

**Phase 1b — Generic runner (only if hypothesis H1 passes its spike)**
- Pick service, operation and parameters from the AWS CLI's models; results in a generic table or JSON tree.
- If H1 fails, replaced by a small curated catalog (see fallback in `technical.md`).

**Phase 2 — Productive**
- **CloudTrail "what changed before this broke?"** inside the investigation view (deploys, configuration and permission changes). The 90-day event-history limit cited in review feedback has not been checked by us.
- **UAT-vs-production comparison:** run one saved investigation against two profiles (e.g. `example-dev` and `example-prod`) and diff configuration (Lambda memory/timeout/env var **names**, ECS task definition image/cpu/memory, SQS attributes). Secret-class values are excluded from diffs.
- Cmd-K palette; saved views and history; multi-profile and multi-region fan-out; result cache polish.
- RDS/Aurora health, ALB/ELBv2 target health, EventBridge/SNS, ECR image lookup, VPC/Route 53/Cloud Map as use demands. EC2 only if it earns a place.

**Phase 3 — AI**
- Agent panel using an installed harness (Claude Code, Codex, etc.), guarded local tools, approval cards, trace. Details and open verification tasks in `technical.md`.

**Later / maybe**
- Opt-in tier 3/4 actions beyond the first few, cost views, diffing resources, Linux/Windows.

## Non-goals
- Not a credential manager (no Leapp/Granted replacement).
- Not an IaC tool; not a full console clone; not hosted or multi-user.
- No bridge-hosted AI and no AWS-hosted AI feature.

## Success looks like
- For W1–W6 you stop opening the AWS console for everyday investigation and downloads.
- You never act on the wrong account without a visible warning.
- The same tier guarantees hold whether you or an agent is driving.

## Feedback considered
An outside review agent proposed a service list and a connected-investigation idea. Adopted vs not:
- **Adopted:** the investigation view with a shared time range; SQS as a sixth workflow (metrics/attributes only); CloudTrail, saved investigations and UAT-vs-prod comparison as Phase 2; v1 limited to tiers 1 and 2.
- **Adopted as a design lesson:** SQS `ReceiveMessage` is not a pure read (it changes message visibility). That is why operation classification is an explicit table and not a name-prefix rule (`technical.md` 4.5).
- **Not adopted:** dropping IAM and S3 from v1. S3 download is a stated requirement, and IAM is needed when a Lambda or ECS failure is a permissions problem.
- **Deferred pending measurement:** "use the SDK for authentication." We keep the AWS CLI as the engine until a latency measurement says otherwise (`plan.md` Milestones 1 and 3).
- The AWS-docs claims in that feedback (SQS visibility behavior, CloudTrail 90-day history, ECS stopped-task docs) have not been checked by us; see the ledger in `plan.md`.

## Open product questions
- After the Milestone 0 trial: is there still a gap worth building for, and which one?
- Which tier-3 actions matter first (Lambda invoke, ECS force-new-deployment/stop task, S3 upload)? None are committed yet; v1 is tiers 1–2.
- ~~Name-substring matching on an anchor (e.g. `example-workload`) versus tags~~ Decided: name matching is enough for the MVP; tags are later.
- Open-source it? (affects licensing and a terms-of-service review of the harness integration)

## W7 — Billing (added 2026-10-29)

For the selected verified account, inspect month-to-date spend across all regions, daily costs, costs by service, a same-days previous-month comparison and the forecast for the remaining month. Use Cost Explorer's unblended metric, UTC calendar periods, and an explicit Load billing data action because AWS may charge for queries. Always display the account scope, units and estimated status. Missing permissions, activation, or forecast data must be visible; switching profile must clear the previous account's costs. Real-profile acceptance remains pending.
