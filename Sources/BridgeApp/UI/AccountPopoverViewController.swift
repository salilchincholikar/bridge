import AppKit
import BridgeCore

/// Identity details belong to the account control, rather than a permanent row on every page.
@MainActor
final class AccountPopoverViewController: NSViewController {
    private let profilePicker: NSPopUpButton
    private let state = NSTextField(wrappingLabelWithString: "")
    private let account = NSTextField(labelWithString: "")
    private let principal = NSTextField(wrappingLabelWithString: "")
    private let access = NSTextField(wrappingLabelWithString: "")
    private let protection = NSTextField(wrappingLabelWithString: "")
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private var accountID: String?
    private var stack: NSStackView!
    var onVerify: (() -> Void)?
    var onSettings: (() -> Void)?
    var summaryText: String { [state.stringValue, account.stringValue, principal.stringValue, access.stringValue, protection.stringValue].joined(separator: " | ") }

    init(profilePicker: NSPopUpButton) {
        self.profilePicker = profilePicker
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 400))
        func caption(_ title: String) -> NSTextField {
            let field = NSTextField(labelWithString: title)
            field.font = .systemFont(ofSize: 11, weight: .medium); field.textColor = .secondaryLabelColor
            return field
        }
        func group(_ title: String, _ field: NSView) -> NSStackView {
            let group = NSStackView(views: [caption(title), field]); group.orientation = .vertical; group.alignment = .leading; group.spacing = 5
            field.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
            return group
        }
        let title = NSTextField(labelWithString: "AWS account"); title.font = .systemFont(ofSize: 16, weight: .semibold)
        state.font = .systemFont(ofSize: 12); state.textColor = .secondaryLabelColor
        account.font = .monospacedSystemFont(ofSize: 14, weight: .medium); account.isSelectable = true
        principal.font = .monospacedSystemFont(ofSize: 11, weight: .regular); principal.isSelectable = true
        principal.preferredMaxLayoutWidth = 340
        principal.lineBreakMode = .byCharWrapping; principal.maximumNumberOfLines = 0
        access.font = .systemFont(ofSize: 12); protection.font = .systemFont(ofSize: 12)
        copyButton.bezelStyle = .inline; copyButton.controlSize = .small; copyButton.target = self; copyButton.action = #selector(copyAccount)
        copyButton.setAccessibilityLabel("Copy account ID")
        let accountRow = NSStackView(views: [account, NSView(), copyButton]); accountRow.spacing = 8
        let verify = NSButton(title: "Verify again", target: self, action: #selector(verifyAccount)); verify.bezelStyle = .rounded
        let settings = NSButton(title: "Profile settings…", target: self, action: #selector(openSettings)); settings.bezelStyle = .rounded
        let actions = NSStackView(views: [verify, NSView(), settings]); actions.spacing = 8
        let separator = NSBox(); separator.boxType = .separator
        stack = NSStackView(views: [title, state, group("Profile", profilePicker), group("Account ID", accountRow), group("Principal", principal), group("Access limit", access), protection, separator, actions])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.setCustomSpacing(4, after: title)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20), stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
        for child in stack.arrangedSubviews { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }

    func update(for tab: TabModel) {
        _ = view
        accountID = tab.identity?.account
        account.stringValue = accountID ?? "Not verified"
        principal.stringValue = tab.identity?.arn ?? "Verify this profile to see its AWS identity."
        state.stringValue = tab.identity == nil ? "Identity not verified" : "Verified AWS identity"
        if Bundle.main.object(forInfoDictionaryKey: "BridgeDemo") as? Bool == true { state.stringValue = "Demo · Invented identity" }
        switch tab.policy.maxTier {
        case .read: access.stringValue = "Read only"
        case .transfer: access.stringValue = "Read and download"
        case .reversibleChange: access.stringValue = "Reversible changes allowed"
        case .destructive: access.stringValue = "Destructive actions allowed"
        }
        protection.stringValue = tab.isProtected ? "Protected account" : (tab.suggestsProtection ? "Production profile · protection is off" : "Account protection is off")
        protection.textColor = tab.isProtected || tab.suggestsProtection ? .systemOrange : .secondaryLabelColor
        copyButton.isEnabled = accountID != nil
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: 380, height: stack.fittingSize.height + 40)
    }

    @objc private func copyAccount() {
        guard let accountID else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(accountID, forType: .string)
    }
    @objc private func verifyAccount() { onVerify?() }
    @objc private func openSettings() { onSettings?() }
}
