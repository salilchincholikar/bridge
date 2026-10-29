import AppKit
import BridgeCore

@MainActor
final class SettingsViewController: SectionViewController {
    private let name = NSTextField()
    private let region = NSTextField()
    private let account = NSTextField()
    private let color = NSPopUpButton()
    private let tier = NSPopUpButton()
    private let protected = NSButton(checkboxWithTitle: "Protected account", target: nil, action: nil)
    private let save = NSButton(title: "Save profile settings", target: nil, action: nil)
    private let status = label("", size: 12)
    private var baseline: BridgeSettings?
    override func build() {
        name.placeholderString = "Display name"; region.placeholderString = "Default AWS region"; account.placeholderString = "12-digit account ID (optional)"
        color.addItems(withTitles: ["Default", "blue", "green", "orange", "red", "purple", "pink", "gray"])
        tier.addItems(withTitles: ["1 · Read only", "2 · Read and download", "3 · Reversible changes", "4 · Destructive changes"])
        save.bezelStyle = .rounded; save.target = self; save.action = #selector(saveSettings)
        let grid = NSGridView(views: [[label("Profile label"), name], [label("Default region"), region], [label("Expected account"), account], [label("Environment color"), color], [label("Permission limit"), tier]])
        grid.rowSpacing = 12; grid.columnSpacing = 24
        let title = label("Profile settings", size: 22, color: .labelColor)
        let note = NSTextField(wrappingLabelWithString: "Labels, account protection and limits apply to this profile in every tab. Tier 3 and 4 operations still require confirmation. The service views and operation runner expose reads and downloads.")
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        note.font = .systemFont(ofSize: 12); note.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, note, grid, protected, save, status]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        content.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 28), stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor), name.widthAnchor.constraint(equalToConstant: 320)])
    }
    override func reload(refresh: Bool) {
        let loaded = SettingsStore.load(path: tab.app.runtime.settingsPath)
        baseline = loaded.settings
        let p = loaded.settings.profiles[tab.profile] ?? ProfileSettings()
        name.stringValue = p.label ?? ""; region.stringValue = p.defaultRegion ?? tab.region; account.stringValue = p.expectedAccount ?? ""
        color.selectItem(withTitle: p.color ?? "Default"); tier.selectItem(at: loaded.settings.policy(for: tab.profile).maxTier.rawValue - 1)
        protected.state = p.protected == true ? .on : .off
        save.isEnabled = !loaded.fileWasCorrupt
        status.stringValue = loaded.fileWasCorrupt ? "Settings could not be read. Repair the file before saving." : "Editing \(tab.profile)"

    }
    @objc private func saveSettings() {
        let latest = SettingsStore.load(path: tab.app.runtime.settingsPath)
        guard !latest.fileWasCorrupt, latest.settings == baseline else {
            status.stringValue = "Settings changed on disk. Refresh to reload them before saving."; return
        }
        let r = region.stringValue.trimmingCharacters(in: .whitespaces)
        guard ExecRequest.isSafeToken(r) else { status.stringValue = "Enter a valid AWS region."; return }
        var settings = latest.settings
        var profile = settings.profiles[tab.profile] ?? ProfileSettings()
        profile.label = name.stringValue.isEmpty ? nil : name.stringValue
        profile.defaultRegion = r; profile.expectedAccount = account.stringValue.isEmpty ? nil : account.stringValue
        profile.color = color.titleOfSelectedItem == "Default" ? nil : color.titleOfSelectedItem
        profile.protected = protected.state == .on; profile.maxTier = tier.indexOfSelectedItem + 1
        settings.profiles[tab.profile] = profile
        guard settings.validate().isEmpty else { status.stringValue = settings.validate().joined(separator: " · "); return }
        save.isEnabled = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.tab.app.applySettings(settings); self.baseline = settings; self.status.stringValue = "Saved for \(self.tab.profile)" }
            catch { self.status.stringValue = "Could not save: \(error)" }
            self.save.isEnabled = true
        }
    }
}
