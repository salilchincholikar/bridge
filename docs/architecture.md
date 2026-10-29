# Bridge architecture

Bridge is a native macOS workbench with a reusable Swift core. AppKit owns windows, menus, native tables, text and split views; SwiftUI/Charts provide hosted data visualizations. Preserve this native behavior while separating responsibilities.

## Current execution path

```text
GUI / CLI / assistant tools
        ↓
DataService: verify identity → authorize → cache → execute
        ↓
CLIExecutor: credential-helper trust → direct subprocess → structured result
```

S3 transfers use `Authorizer` plus `S3Downloader` for file staging/finalization; they enforce the same credential-helper trust check. Only the human app/CLI can approve helper commands. Assistant callers cannot approve them.

`IdentityStore` de-duplicates probes. `ResultCache` keys include verified identity and request scope and refuses sensitive results. Each native tab owns its context and drops results issued for an obsolete profile/region/time window. `CommandActivity` holds bounded, masked history in memory.

## Reusable module direction

Keep one repository and one Swift package:

- **BridgeCore:** UI-independent configuration, models, policy, identity, execution, workflows and transfers.
- **BridgeUI:** extracted native layout/charts, with tables/inspectors planned; no application singleton or AWS execution.
- **Features:** destination-specific presentation currently lives in `BridgeApp/Features`. A separate `BridgeFeatures` target is a possible later extraction once its injected session interface settles; it does not exist yet.
- **BridgeApp:** composition, windows, navigation, menus and CLI.
- **BridgeAgents:** extracted optional provider integration, depending on the authorized Core client.

This is incremental. See the readiness tracker for which extractions are complete. Do not make all controllers public simply to move files or enable UI tests. Expose small interfaces that hide native delegate/layout behavior and retain tested internal seams.

A shared feature registry supplies navigation metadata and UI capabilities. Policy remains separate: registering a feature cannot authorize an operation.

“SDK style” initially means a documented reusable client and native UI library. An AWS Swift SDK adapter is a separate future choice, with shared policy, cancellation and contract tests; it must not create a second authorization path or claim that a CLI equivalent actually ran.

Historical design rationale is in [technical.md](technical.md). Current preparation work and remaining gates are in [open-source-readiness.md](open-source-readiness.md).
