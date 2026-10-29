import AppKit

enum AppSection: String, CaseIterable {
    case home, investigation, billing, lambda, logs, ecs, sqs, iam, s3, alarms, runner, settings
    var title: String {
        switch self {
        case .home: return "Overview"
        case .billing: return "Billing"
        case .runner: return "Operation runner"
        case .settings: return "Settings"
        case .investigation: return "Investigation"
        case .lambda: return "Lambda"
        case .logs: return "CloudWatch Logs"
        case .ecs: return "ECS"
        case .sqs: return "SQS"
        case .iam: return "IAM"
        case .s3: return "S3"
        case .alarms: return "Alarms"
        }
    }
    var symbol: String {
        switch self {
        case .home: return "square.grid.2x2"
        case .billing: return "chart.pie"
        case .runner: return "terminal"
        case .settings: return "gearshape"
        case .investigation: return "scope"
        case .lambda: return "function"
        case .logs: return "text.alignleft"
        case .ecs: return "shippingbox"
        case .sqs: return "tray.full"
        case .iam: return "person.badge.key"
        case .s3: return "externaldrive"
        case .alarms: return "bell"
        }
    }
}

extension AppSection {
    var detail: String {
        switch self {
        case .home: return "Services, costs and investigations in one place"
        case .investigation: return "Connect related resources around an application or workload"
        case .lambda: return "Functions, configuration and links to logs and execution roles"
        case .logs: return "Search a log group or follow new events"
        case .ecs: return "Cluster health, deployments and stopped-task diagnostics"
        case .sqs: return "Queue metrics, dead letters and consuming functions"
        case .iam: return "Roles, trust relationships and permission policies"
        case .s3: return "Browse buckets, inspect objects and download files"
        case .alarms: return "CloudWatch alarms that need attention"
        case .billing: return "Account spend across all regions · Cost Explorer"
        case .runner: return "Run supported read operations with generated parameter forms"
        case .settings: return "Labels, default regions and account protection"
        }
    }
}

extension AppSection {
    static var destinations: [AppSection] { allCases.filter { $0 != .settings } }
    static let sidebarGroupNames = ["Workspace", "Services", "Tools"]
    var sidebarGroup: String {
        switch self {
        case .home, .investigation, .billing: return "Workspace"
        case .runner, .settings: return "Tools"
        default: return "Services"
        }
    }
    var accountGlobal: Bool { self == .billing }
    var supportsTimeRange: Bool { [.logs, .lambda, .sqs, .investigation].contains(self) }
    static let overviewGroupNames = ["Compute", "Observability", "Storage & messaging", "Account"]
    var overviewGroup: String? {
        switch self {
        case .lambda, .ecs: return "Compute"
        case .logs, .alarms: return "Observability"
        case .s3, .sqs: return "Storage & messaging"
        case .iam, .billing: return "Account"
        default: return nil
        }
    }
    static var overviewGroups: [(String, [AppSection])] {
        overviewGroupNames.map { name in (name, allCases.filter { $0.overviewGroup == name }) }
    }

    @MainActor
    func makeController(tab: TabModel, onSelect: @escaping (AppSection) -> Void) -> SectionViewController {
        switch self {
        case .home:
            let c = HomeViewController(tab: tab); c.onSelect = onSelect; return c
        case .billing: return BillingViewController(tab: tab)
        case .runner: return RunnerViewController(tab: tab)
        case .settings: return SettingsViewController(tab: tab)
        case .lambda: return LambdaViewController(tab: tab)
        case .logs: return LogsViewController(tab: tab)
        case .ecs: return EcsViewController(tab: tab)
        case .sqs: return SqsViewController(tab: tab)
        case .iam: return IamViewController(tab: tab)
        case .s3: return S3ViewController(tab: tab)
        case .alarms: return AlarmsViewController(tab: tab)
        case .investigation: return InvestigationViewController(tab: tab)
        }
    }
}
