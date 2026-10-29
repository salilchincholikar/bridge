import AppKit

/// Shared content grouping. Window chrome stays system-managed; panes group resource lists and inspectors.
public final class WorkspacePane: NSBox {
    public init(_ title: String, body: NSView, actions: [NSView] = []) {
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        boxType = .custom; cornerRadius = 8
        fillColor = .controlBackgroundColor; borderColor = .separatorColor
        contentViewMargins = .zero
        let inner = NSView(); contentView = inner
        let name = NSTextField(labelWithString: title); name.textColor = .labelColor; name.font = .systemFont(ofSize: 13, weight: .semibold)
        let header = NSStackView(views: [name, NSView()] + actions); header.spacing = 8
        let separator = NSBox(); separator.boxType = .separator
        for v in [header, separator, body] { inner.addSubview(v); v.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: inner.topAnchor), header.leadingAnchor.constraint(equalTo: inner.leadingAnchor, constant: 12), header.trailingAnchor.constraint(equalTo: inner.trailingAnchor, constant: -12), header.heightAnchor.constraint(equalToConstant: 36),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor), separator.leadingAnchor.constraint(equalTo: inner.leadingAnchor), separator.trailingAnchor.constraint(equalTo: inner.trailingAnchor), separator.heightAnchor.constraint(equalToConstant: 1),
            body.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 6), body.leadingAnchor.constraint(equalTo: inner.leadingAnchor, constant: 6), body.trailingAnchor.constraint(equalTo: inner.trailingAnchor, constant: -6), body.bottomAnchor.constraint(equalTo: inner.bottomAnchor, constant: -6),
        ])
    }
    public required init?(coder: NSCoder) { fatalError() }
}

@MainActor
public enum WorkspaceLayout {
    public static func toolbar(_ views: [NSView]) -> NSStackView {
        let bar = NSStackView(views: views); bar.orientation = .horizontal; bar.spacing = 10
        bar.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return bar
    }
    public static func split(columns: Bool, _ views: [NSView]) -> NSSplitView {
        let split = WorkspaceSplit(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        split.isVertical = columns; split.dividerStyle = .thin
        for view in views {
            view.frame = NSRect(x: 0, y: 0, width: columns ? 900 / CGFloat(views.count) : 900, height: columns ? 600 : 600 / CGFloat(views.count))
            split.addArrangedSubview(view)
        }
        return split
    }
    public static func fill(_ body: NSView, in container: NSView, toolbar: NSView? = nil) {
        container.addSubview(body); body.translatesAutoresizingMaskIntoConstraints = false
        if let toolbar {
            container.addSubview(toolbar); toolbar.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                toolbar.topAnchor.constraint(equalTo: container.topAnchor, constant: 4), toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24), toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
                body.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12),
            ])
        } else { body.topAnchor.constraint(equalTo: container.topAnchor, constant: 4).isActive = true }
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24), body.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24), body.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])
    }
    public static func listWidth(_ view: NSView, minimum: CGFloat = 220, maximum: CGFloat = 280) {
        view.widthAnchor.constraint(greaterThanOrEqualToConstant: minimum).isActive = true
        view.widthAnchor.constraint(lessThanOrEqualToConstant: maximum).isActive = true
    }
}

/// Scrollable forms start at their first field, including after rebuilding the schema.
public final class TopAlignedStackView: NSStackView {
    public override var isFlipped: Bool { true }
}

private final class WorkspaceSplit: NSSplitView {
    override var dividerThickness: CGFloat { 12 }
    override func drawDivider(in rect: NSRect) {}
}
