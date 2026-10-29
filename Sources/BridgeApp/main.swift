import AppKit
import BridgeCore

// A separate demo bundle carries invented profiles and fake executables. Production bundles never set this key.
if Bundle.main.object(forInfoDictionaryKey: "BridgeDemo") as? Bool == true, let resources = Bundle.main.resourcePath {
    setenv("BRIDGE_AWS_PATH", resources + "/Fixtures/fake-aws/aws", 1)
    setenv("AWS_CONFIG_FILE", resources + "/Fixtures/aws/typical.config", 1)
    setenv("AWS_SHARED_CREDENTIALS_FILE", resources + "/Fixtures/aws/demo.credentials", 1)
    setenv("BRIDGE_MODEL_PATH", resources + "/Fixtures/catalog", 1)
    let demoRoot = NSTemporaryDirectory() + "bridge-demo-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: demoRoot, withIntermediateDirectories: true)
    let settings = demoRoot + "/settings.json"
    try? FileManager.default.copyItem(atPath: resources + "/Fixtures/settings/demo.json", toPath: settings)
    setenv("BRIDGE_SETTINGS", settings, 1)
    setenv("BRIDGE_AGENT_CONSENT", demoRoot + "/agent-consent.json", 1)
    setenv("BRIDGE_CLAUDE_PATH", resources + "/Fixtures/fake-claude/claude", 1)
    setenv("BRIDGE_CODEX_PATH", resources + "/Fixtures/fake-codex/codex", 1)
}

// `bridge <command> ...` runs the command line front end (see CLI.swift). With no arguments the app opens.

if CommandLine.arguments.count > 1, !CommandLine.arguments[1].hasPrefix("-psn") {
    CLI.run(Array(CommandLine.arguments.dropFirst()))
}

#if BRIDGE_UI_TESTS
if ProcessInfo.processInfo.environment["BRIDGE_UI_SELFTEST"] != nil {
    if let path = ProcessInfo.processInfo.environment["BRIDGE_UI_SELFTEST_LOG"] {
        freopen(path, "w", stdout)
        freopen(path + ".stderr", "w", stderr)
    }
    let code = MainActor.assumeIsolated { UISelfTest.run() }
    fflush(stdout)
    exit(code)
}

#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var aboutWindow: AboutWindowController?

    @objc func showBridgeAbout(_ sender: Any?) {
        if aboutWindow == nil { aboutWindow = AboutWindowController() }
        aboutWindow?.showWindow(sender)
        aboutWindow?.window?.makeKeyAndOrderFront(sender)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        NSApp.mainMenu = MainMenu.build()
        let runtime = BridgeRuntime.load()
        Task { @MainActor in
            let runtime = await runtime.discoveringProfiles()
            let data = await runtime.makeDataService()
            AppModel.shared = AppModel(runtime: runtime, data: data)
            let first = AppModel.shared.newTab()
            if data == nil {
                first.tab.pendingNavigation = nil
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc func showBridgeHelp(_ sender: Any?) {
        if let url = Bundle.main.url(forResource: "Bridge Help", withExtension: "html") { NSWorkspace.shared.open(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
