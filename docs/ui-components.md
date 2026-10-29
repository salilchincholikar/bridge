# Native UI reuse

`BridgeUI` is an experimental SwiftPM library product. It imports Core data types and native frameworks; it has no credential discovery, command execution, application singleton or navigation dependency.

Currently extracted:

- `WorkspacePane`: consistent native heading/actions/content grouping.
- `WorkspaceLayout`: toolbar, list/detail split, fitting and list-width behavior.
- `TopAlignedStackView`: form content starts at the first field.
- `ChartHost`: AppKit-embeddable Swift Charts, shared time domain and hover across metric series; `show` and `clear` manage presentation.

Use these from the main actor. Keep window chrome system-managed. Supply semantic colors and explicit units. Mask/reveal decisions belong to the caller's authorized Core state, never to a UI module.

```swift
import AppKit
import BridgeUI

@MainActor
func embedResources(_ resourceView: NSView, in container: NSView) {
    let pane = WorkspacePane("Resources", body: resourceView)
    WorkspaceLayout.fill(pane, in: container)
}
```

The app's existing tables, text viewers and banners still live in `BridgeApp/UI/Components.swift`. Extracting their interfaces and replacing untyped payloads are follow-up work; they are not part of the public library yet. Do not duplicate them in new screens to avoid the eventual migration.

The dedicated `Bridge UI Checks.app` exercises the complete window with synthetic data. It is compiled with `BRIDGE_UI_TESTS`; production and normal demo builds exclude that harness. A standalone visual state catalog, keyboard/accessibility coverage and broader OS/appearance validation remain release tasks.
