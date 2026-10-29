# Reusing BridgeCore

`BridgeCore` and `BridgeUI` are SwiftPM library products with experimental interfaces. They are not a stable public SDK yet. The AWS execution backend remains the AWS CLI; no AWS SDK dependency has been introduced.

Core's client is `DataService`. Request builders and parsers live in the workflow modules. The client coordinates identity verification, authorization, cache keys, sensitive-result handling and request context. Callers must discard results when their original tab/profile/region/time context is obsolete.

```swift
let runtime = BridgeRuntime.load()
guard let client = await runtime.makeDataService() else { return }
let request = LambdaWorkflow.listFunctions(profile: "my-profile", region: "eu-west-1")
let fetched = try await client.fetch(request, tab: UUID())
let functions = LambdaWorkflow.parseFunctions(fetched.result.json)
```

This example makes real AWS calls when run. It requires configured credentials and any credential-helper approvals. Prefer the offline executable when learning the interface:

```sh
swift run BridgeClientExample
```

The offline example imports only Core and injects an in-memory adapter. It never launches AWS or reads credentials. Its source is in `examples/BridgeClient/main.swift`.

## Execution adapters

`ExecutionBackend` accepts authorized requests, checks credential-helper trust and reports a backend version. `CLIExecutor` implements it with direct subprocesses. Tests use a second in-memory implementation through the same `DataService` interface. Request parameters cannot select an adapter.

Adapters must honor cancellation and bounded output, return accurate provenance and check credential trust before credential-using execution. Core enforces policy sensitivity even if an adapter incorrectly marks its result ordinary. Injecting a backend is trusted application composition, not a sandbox for arbitrary plugins. Do not expose `run` directly to untrusted callers.

The current result shape and request names remain CLI-oriented. A future AWS Swift SDK adapter requires typed error/page contracts and truthful activity reporting before implementation; do not label SDK requests as executed CLI commands. Downloads retain a separate authorized transfer interface for staging, progress and finalization.
