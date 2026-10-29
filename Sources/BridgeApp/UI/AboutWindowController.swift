import AppKit

/// A compact About window: every credit is visible without a nested scroll view.
@MainActor
final class AboutWindowController: NSWindowController {
    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let name = info["CFBundleDisplayName"] as? String ?? "Bridge"
        let demo = info["BridgeDemo"] as? Bool == true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: demo ? 548 : 522),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "About " + name
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        super.init(window: window)
        guard let content = window.contentView else { return }
        func text(_ value: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: value)
            field.font = .systemFont(ofSize: size, weight: weight)
            field.textColor = secondary ? .secondaryLabelColor : .labelColor
            field.alignment = .center
            field.setContentCompressionResistancePriority(.required, for: .vertical)
            return field
        }
        let icon = NSImageView()
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") { icon.image = NSImage(contentsOf: url) }
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        let creator = info["BridgeCreator"] as? String ?? "Salil Chincholikar"
        let github = NSButton(title: "@salilchincholikar", target: self, action: #selector(openCreator))
        github.isBordered = false
        github.contentTintColor = .linkColor
        github.font = .systemFont(ofSize: 13)
        let views: [NSView] = [icon, text(name, size: 24, weight: .semibold), text("Version \(version) · Build \(build)", secondary: true)]
            + (demo ? [text("Demo · Sample data", weight: .medium, secondary: true)] : [])
            + [text("A native macOS workspace for AWS."), text("Made by " + creator + "."), github,
               text("Built with Swift, AppKit and SwiftUI.\nUses your installed AWS CLI.", size: 12, secondary: true),
               text("Independent software. Not affiliated with\nAmazon Web Services.", size: 11, secondary: true),
               text(info["NSHumanReadableCopyright"] as? String ?? "", size: 11, secondary: true)]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 10
        stack.setCustomSpacing(16, after: icon)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
        ])
        for view in views { view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true }
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 420, height: stack.fittingSize.height + 48))
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func openCreator(_ sender: Any?) {
        if let value = Bundle.main.object(forInfoDictionaryKey: "BridgeCreatorURL") as? String, let url = URL(string: value) { NSWorkspace.shared.open(url) }
    }
}
