import BridgeUI
import AppKit
import BridgeCore

/// W3: IAM role inspection: trust policy, attached and inline policies, and their documents. Read-only.
@MainActor
final class IamViewController: SectionViewController, NSSearchFieldDelegate {
    private let filterField = NSSearchField()
    let roles = DataTable(columns: [ColumnSpec("name", "Role", width: 300), ColumnSpec("path", "Path", width: 120)])
    struct PolicyChoice {
        let id: String
        let title: String
        var attached: IamAttachedPolicy? = nil
        var inlineName: String? = nil
    }
    private(set) var policyChoices: [PolicyChoice] = []
    private var selectedPolicyID: String?
    private let policyPicker = NSPopUpButton()
    private let summary = TextPane(monospaced: false)
    let document = TextPane()

    private var roleNames: [String] = []
    private(set) var selectedRole: String?
    private var trust: JSONValue?
    private var roleLoadID = UUID()
    private var policyLoadID = UUID()
    private var roleLoading = false
    private var loadedRole: String?

    override func contextWillChange() {
        super.contextWillChange()
        roleLoadID = UUID(); policyLoadID = UUID(); roleLoading = false; loadedRole = nil
        roleNames = []; selectedRole = nil; trust = nil
        roles.setRows([]); policyChoices = []; selectedPolicyID = nil; policyPicker.removeAllItems(); policyPicker.isEnabled = false; summary.setText("Select a role to inspect it."); document.setText("Select a policy to read it.")
    }

    override func build() {
        filterField.placeholderString = "Filter roles"; filterField.delegate = self
        filterField.widthAnchor.constraint(equalToConstant: 240).isActive = true
        roles.setColumns([ColumnSpec("name", "Role", width: 260)])
        policyPicker.controlSize = .small; policyPicker.target = self; policyPicker.action = #selector(policyChanged)
        policyPicker.addItem(withTitle: "Select a role"); policyPicker.isEnabled = false
        policyPicker.setAccessibilityLabel("Policy")
        let roleList = WorkspacePane("Roles", body: roles.view)
        WorkspaceLayout.listWidth(roleList, minimum: 200, maximum: 300)
        let policyDocument = WorkspacePane("Policy document", body: document.scroll, actions: [policyPicker])
        policyDocument.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        let metadata = WorkspacePane("Role details", body: summary.scroll)
        metadata.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        let detail = WorkspaceLayout.split(columns: false, [metadata, policyDocument])
        WorkspaceLayout.fill(WorkspaceLayout.split(columns: true, [roleList, detail]), in: content,
            toolbar: WorkspaceLayout.toolbar([filterField, NSView()]))
        summary.setText("Select a role to inspect its trust relationship and permissions.")
        document.setText("Select a policy to read its document.")
        roles.onSelect = { [weak self] row in if let name = row?.id { self?.loadRole(name, refresh: false) } }
    }

    func controlTextDidChange(_ obj: Notification) { roles.filter = filterField.stringValue }

    override var selectionDescription: String? { selectedRole.map { "IAM role \($0)" } }

    override func reload(refresh: Bool) {
        clearError()
        roles.emptyMessage = "Loading…"
        roles.setRows([])
        run { [weak self] in
            guard let self else { return }
            let req = ExecRequest(profile: self.tab.profile, region: self.tab.region, service: "iam", operation: "list-roles", maxItems: 500)
            guard let pages = try await self.tab.fetchPages(req, refresh: refresh, maxPages: 4) else { return }
            let list = pages.flatMap { $0.result.json?.array("Roles") ?? [] }.compactMap { r -> (String, String)? in
                guard let n = r.string("RoleName") else { return nil }
                return (n, r.string("Path") ?? "/")
            }.sorted { $0.0.lowercased() < $1.0.lowercased() }
            self.roleNames = list.map(\.0)
            self.roles.emptyMessage = "No roles"
            self.roles.setRows(list.map { TableRow(id: $0.0, cells: [Cell($0.0, bold: true), Cell($0.1, color: .secondaryLabelColor)]) })

            if case .iamRole(let n)? = self.tab.pendingNavigation { self.tab.pendingNavigation = nil; self.handle(.iamRole(n)) }
            else if let r = self.selectedRole { self.loadRole(r, refresh: refresh) }
        }
    }

    override func handle(_ navigation: Navigation) {
        guard case .iamRole(let name) = navigation else { return }
        if let idx = roles.rows.firstIndex(where: { $0.id == name }) {
            roles.table.selectRowIndexes([idx], byExtendingSelection: false)
            roles.table.scrollRowToVisible(idx)
        } else { loadRole(name, refresh: false) } // not in the loaded list: load it directly
    }

    private func loadRole(_ name: String, refresh: Bool) {
        if !refresh, selectedRole == name, roleLoading || loadedRole == name { return }
        let token = UUID(); roleLoadID = token; policyLoadID = UUID(); roleLoading = true; loadedRole = nil
        selectedRole = name
        summary.setText("Loading \(name)…")
        policyChoices = []; selectedPolicyID = nil
        policyPicker.removeAllItems(); policyPicker.addItem(withTitle: "Loading policies…"); policyPicker.isEnabled = false
        document.setText("")
        run { [weak self] in
            guard let self else { return }
            defer { if self.roleLoadID == token { self.roleLoading = false } }
            let p = self.tab.profile, r = self.tab.region
            guard let roleF = try await self.tab.fetch(IamWorkflow.getRole(profile: p, region: r, role: name), refresh: refresh), self.selectedRole == name, self.roleLoadID == token else { return }
            guard let role = IamWorkflow.parseRole(roleF.result.json) else { self.summary.setText("Role \(name) not found."); return }
            self.trust = role.trustPolicy

            self.summary.setPairs([("Role", role.name), ("ARN", role.arn), ("Path", role.path ?? "/"), ("Created", Format.date(role.created)), ("Description", role.description ?? "-"),
                                   ("Trusted by", Self.principals(role.trustPolicy))])
            guard let att = try await self.tab.fetch(IamWorkflow.listAttached(profile: p, region: r, role: name), refresh: refresh), self.selectedRole == name, self.roleLoadID == token,
                  let inl = try await self.tab.fetch(IamWorkflow.listInlineNames(profile: p, region: r, role: name), refresh: refresh), self.selectedRole == name, self.roleLoadID == token else { return }
            var choices = [PolicyChoice(id: "trust", title: "Trust relationship")]
            for policy in IamWorkflow.parseAttached(att.result.json) { choices.append(PolicyChoice(id: "att:" + policy.arn, title: policy.name, attached: policy)) }
            for name in IamWorkflow.parseInlineNames(inl.result.json) { choices.append(PolicyChoice(id: "inl:" + name, title: name, inlineName: name)) }
            self.loadedRole = name
            self.policyChoices = choices
            self.policyPicker.removeAllItems(); self.policyPicker.addItems(withTitles: choices.map(\.title)); self.policyPicker.isEnabled = true
            self.selectPolicy(at: 0)
        }
    }

    @objc private func policyChanged() { selectPolicy(at: policyPicker.indexOfSelectedItem) }

    func selectPolicy(at index: Int) {
        guard policyChoices.indices.contains(index), let role = selectedRole else { return }
        let row = policyChoices[index]
        selectedPolicyID = row.id; policyPicker.selectItem(at: index)
        let token = UUID(); policyLoadID = token
        if row.id == "trust" { document.setJSON(trust); return }
        document.setText("Loading…")
        run { [weak self] in
            guard let self else { return }
            let p = self.tab.profile, r = self.tab.region
            if let a = row.attached {
                guard let pol = try await self.tab.fetch(IamWorkflow.getPolicy(profile: p, region: r, arn: a.arn)), let v = IamWorkflow.defaultVersionId(pol.result.json),
                      let doc = try await self.tab.fetch(IamWorkflow.getPolicyVersion(profile: p, region: r, arn: a.arn, version: v)), self.selectedPolicyID == row.id, self.policyLoadID == token, self.selectedRole == role else { return }
                self.document.setJSON(IamWorkflow.parseVersionDocument(doc.result.json))

            } else if let name = row.inlineName {
                guard let doc = try await self.tab.fetch(IamWorkflow.getInlinePolicy(profile: p, region: r, role: role, policy: name)), self.selectedPolicyID == row.id, self.policyLoadID == token, self.selectedRole == role else { return }
                self.document.setJSON(IamWorkflow.parseInlineDocument(doc.result.json))

            }
        }
    }

    /// A readable summary of who may assume the role.
    static func principals(_ trust: JSONValue?) -> String {
        var out: [String] = []
        for s in trust?.array("Statement") ?? [] {
            guard s.string("Effect") == "Allow" else { continue }
            if let p = s.value(at: "Principal") {
                for key in ["Service", "AWS", "Federated"] {
                    if let v = p[key]?.stringValue { out.append("\(key): \(v)") }
                    else if let arr = p[key]?.arrayValue { out += arr.compactMap { $0.stringValue }.map { "\(key): \($0)" } }
                }
                if let star = p.stringValue { out.append(star) }
            }
        }
        return out.isEmpty ? "-" : out.joined(separator: "\n")
    }
}
