# Bridge — native macOS interface

Bridge is a sidebar/detail workbench. The app uses a system-managed split-view sidebar and unified compact toolbar. It follows system light/dark appearance and keeps each window tab's AWS context independent.

## Design rules

- Keep navigation in the sidebar, a right-aligned account button, region selector and time control in the toolbar, and resource actions beside the relevant content.
- Use system controls, semantic colors and familiar keyboard/menu commands. Icon color conveys status rather than decoration.
- Align content to a 24-point margin. Resource screens share labelled panes, compact action rows and resizable list/detail splits.
- Keep account identity and access details in a native toolbar popover, including the profile chooser, account ID with Copy, full principal, access limit, protection state, re-verification and profile settings. Protected/production profiles keep a visible shield cue in the toolbar. Context changes close the popover and clear the previous identity.
- Keep primary information visible first. AWS Command is one shared utility drawer per tab, hosted below the page in a native resizable split view. Its 36-point collapsed bar shows status and ⌘J. Open/closed state is explicit; a supported-size window opens the drawer to at least 180 points with usable preview space. Window and page resizing preserve that state and never save an intermediate shallow height as the preferred size. Dragging near closed snaps to the header. Pane sizing synchronizes AppKit’s native divider position so it cannot draw through the response preview. The toolbar, View menu and shortcut use the same toggle.
- Fit table columns to their current viewport. Long values have tooltips; narrow metadata inspectors stack labels above values. Empty-state text wraps within its pane.
- Prefer scrolling to increasing a window's minimum size. Forms start at their first field, and controls must not stretch vertically to absorb unused space.
- Settings opens in a dedicated profile settings window via Command-comma. A settings window retains the profile it was opened for.

The design review used OpenAI's [macOS Liquid Glass skill](https://github.com/openai/plugins/blob/main/plugins/build-macos-apps/skills/liquid-glass/SKILL.md), its desktop layout guidance, and Apple's [macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/) and [layout](https://developer.apple.com/design/human-interface-guidelines/layout) guidance. System window materials are retained; custom grouping is confined to content panes. The deployment target remains macOS 14.

## Screens

| Screen | Composition |
|---|---|
| Overview | Equal-height native groups for Compute, Observability, Storage & messaging, and Account; direct service links and New investigation |
| Lambda | Filter, function list, and full-height Configuration inspector; logs/role links and explicit environment reveal |
| CloudWatch Logs | Log groups, event list and full-message preview; filter/search/follow controls and a constrained result summary |
| ECS | Cluster/filter row; services above labelled Service details and Recently stopped tasks panes; compact Logs/Role actions |
| SQS | Queue list, attributes and metric panes; consumer and dead-letter queue links |
| IAM | Role list; readable role metadata above a full-width document with a native policy picker |
| S3 | Bucket list; object browser and object inspector; native Save dialog with editable filename, metadata-based extension suggestion, download controls and transfer status |
| Alarms | Alarm list and full-height details, including the trigger reason |
| Investigation | Workload search and saved views; related resources with native include checkboxes, then selected-resource metrics |
| Billing | Month header, three comparable native summary groups with 27-point values; chart and service table sit directly on the content surface. The table fills the remaining viewport and smaller windows scroll. Once data loads, Refresh lives only in the main toolbar |
| Operation runner | Read-operation list, scrollable Parameters form and Result pane; native enum/boolean pickers; JSON/table switch and pagination |
| Profile Settings | Dedicated native window with aligned profile fields, protection, permission limit and atomic save |
| Assistant consent | Shared provider chooser available before consent, wrapped disclosure heading, scrollable disclosure and explicit enable/dismiss actions |
| Assistant chat | Shared provider/close controls, conversation, read-activity table with visible results, and composer; no collapsed transcript |

## Shared command drawer and keyboard behavior

The drawer captures actual service requests through the tab’s existing authorized data path, including pagination. It shows command and response previews, live running count, exit status, duration, and a Cached label when no new CLI call was needed. History holds at most 20 entries in memory; command/output previews are capped at 32,768 characters with an explicit truncation marker. Sensitive responses are omitted, authorized mask paths and Lambda environment masking are applied, and text redaction is best effort. Nothing is written to a transcript file.

Copy uses the displayed preview. Clear is available when reads are idle. Stop cancels active work in the tab; a late success cannot overwrite Cancelled. Profile, region and time-window changes clear the history immediately. Navigation within a tab retains it. Each tab has its own history and drawer state.

The Operation runner button opens the existing generated, policy-checked read-operation forms. The drawer does not evaluate shell text or add new AWS operations. Downloads and assistant read activity retain their existing dedicated controls.

⌘J toggles the drawer; ⌘F focuses the current page’s native search field, or reveals sidebar search when the page has none. Logs focuses its event pattern. ⌘1 Overview, ⌘2 Investigation and ⌘3 Billing now follow sidebar order; ⌘4–⌘9 select Lambda, Logs, ECS, SQS, IAM and S3. ⌘R refreshes, ⌘K jumps to a service, ⌘, opens profile settings, and ⌘⇧A toggles the assistant.

## Data and context behavior

Profiles are merged from the local AWS CLI `configure list-profiles` output, so shared-credentials-only profiles appear alongside config profiles. Existing config regions and role/SSO metadata are retained. Discovery is asynchronous, bounded and does not make AWS API calls. Bridge does not parse credential values.

Profile or region changes immediately clear previous selections and sensitive detail views. Late investigation and transfer updates carry generation guards. Existing execution authorization, redaction and per-provider consent remain enforced.

Billing uses UTC calendar dates and the verified account across all regions. Queries are explicit Load/Refresh actions. A short cost/delay notice and About billing data sheet explain permissions and API charges. Missing prior-period or forecast data displays Unavailable; empty current-period data clears previous amounts. Daily bars and labels use the same UTC dates. The linear chart supports hover values, click-to-pin, arrow-key inspection and Escape to clear. Month-to-date and Latest 7 days are local chart views; the latest-week view ends on the latest reported day, its UTC range is visible, and monthly summaries and queries are unchanged. The previous-period card names the exact date window and identifies the current month’s percentage change. Remaining forecast explicitly covers today through month end. Currency and percentage columns use aligned monospaced digits and typed numeric sorting, including credits and thousands separators. Right-click a service to copy its name, cost or complete row.

Logs Follow polls every five seconds with a one-minute overlap and a bounded, deduplicated buffer. It stops on navigation or context change. This is polling rather than the StartLiveTail event stream.

S3 downloads preserve existing filename extensions. For extensionless keys, known Content-Type metadata supplies a suggested extension (for example, `content` with `image/png` becomes `content.png`). Unknown/generic types keep the key’s basename. The Save dialog makes the local name editable; the remote object key remains unchanged. The downloader sanitizes the chosen name, rejects path components, preserves atomic completion and cancellation cleanup, and uses the normal replacement confirmation.

## Verification

`make ui-test-app` stages a Finder-launchable offline UI suite in `build/Bridge UI Checks.app`. It uses bundled fake AWS and agent executables. Results are written to `/private/tmp/bridge-native-ui-checks.log`; selected-resource captures are in `/private/tmp/bridge-native-snapshots/`.

The latest run passed **179 checks with zero failures**. The suite exercises every screen, selected-resource details, native settings, assistant consent/chat, policy refusals, context changes and transfers. It checks usable pane geometry and tests Billing at 960×640, 1180×780 and 1440×900, including light/dark appearance. Native app screenshots are also reviewed directly because offscreen bitmap captures can omit compositor effects.

Real AWS acceptance remains pending. Demo data is invented. CloudTrail and multi-profile fan-out remain later-phase work.
