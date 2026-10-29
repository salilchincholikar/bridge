import Foundation

// Investigations (docs/technical.md 4.10): an anchor (a name or substring such as "example-workload"), a profile and
// region, and a time window. Discovery matches the anchor against each service's list and the user confirms.
// Saved files hold NO AWS response data and no credentials.

public enum ResourceKind: String, Codable, Sendable, CaseIterable {
    case lambdaFunction, ecsService, sqsQueue, logGroup, alarm
}

public struct ResourceRef: Hashable, Codable, Sendable {
    public var kind: ResourceKind
    public var name: String
    /// Extra identity: the cluster for an ECS service, the URL for a queue.
    public var detail: String?
    public init(kind: ResourceKind, name: String, detail: String? = nil) { self.kind = kind; self.name = name; self.detail = detail }
}

public struct Investigation: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var profile: String
    public var region: String
    public var anchor: String
    /// The relative window preset, in seconds (for example 900 for "last 15 min").
    public var windowSeconds: TimeInterval
    /// Matches the user unticked.
    public var excluded: [ResourceRef]
    /// Resources the user added by hand.
    public var added: [ResourceRef]

    public init(id: UUID = UUID(), name: String, profile: String, region: String, anchor: String,
                windowSeconds: TimeInterval = 900, excluded: [ResourceRef] = [], added: [ResourceRef] = []) {
        self.id = id; self.name = name; self.profile = profile; self.region = region; self.anchor = anchor
        self.windowSeconds = windowSeconds; self.excluded = excluded; self.added = added
    }

    /// The same investigation pointed at another profile (for UAT-versus-production comparison).
    public func retargeted(profile: String, region: String? = nil) -> Investigation {
        var copy = self
        copy.id = UUID(); copy.profile = profile; copy.region = region ?? self.region
        return copy
    }
}

public struct EcsServiceName: Hashable, Sendable {
    public var cluster: String
    public var name: String
    public init(cluster: String, name: String) { self.cluster = cluster; self.name = name }
}

/// Everything discovery listed, before matching.
public struct DiscoveryCandidates: Sendable {
    public var lambdas: [String]
    public var ecsServices: [EcsServiceName]
    public var queues: [SqsQueue]
    public var logGroups: [String]
    public var alarms: [String]
    public init(lambdas: [String] = [], ecsServices: [EcsServiceName] = [], queues: [SqsQueue] = [], logGroups: [String] = [], alarms: [String] = []) {
        self.lambdas = lambdas; self.ecsServices = ecsServices; self.queues = queues; self.logGroups = logGroups; self.alarms = alarms
    }
}

public enum InvestigationDiscovery {
    /// Case-insensitive substring match on names. An empty anchor matches nothing (it would match everything).
    public static func matches(anchor: String, in c: DiscoveryCandidates) -> [ResourceRef] {
        let a = anchor.trimmingCharacters(in: .whitespaces).lowercased()
        guard !a.isEmpty else { return [] }
        func hit(_ s: String) -> Bool { s.lowercased().contains(a) }
        var out: [ResourceRef] = []
        out += c.lambdas.filter(hit).sorted().map { ResourceRef(kind: .lambdaFunction, name: $0) }
        out += c.ecsServices.filter { hit($0.name) }.sorted { ($0.cluster, $0.name) < ($1.cluster, $1.name) }
            .map { ResourceRef(kind: .ecsService, name: $0.name, detail: $0.cluster) }
        out += c.queues.filter { hit($0.name) }.sorted { $0.name < $1.name }.map { ResourceRef(kind: .sqsQueue, name: $0.name, detail: $0.url) }
        out += c.logGroups.filter(hit).sorted().map { ResourceRef(kind: .logGroup, name: $0) }
        out += c.alarms.filter(hit).sorted().map { ResourceRef(kind: .alarm, name: $0) }
        return out
    }

    /// Matches plus hand-added resources, minus the ones the user excluded. Order and uniqueness preserved.
    public static func resolve(_ inv: Investigation, matches: [ResourceRef]) -> [ResourceRef] {
        var seen = Set<ResourceRef>()
        let excluded = Set(inv.excluded)
        return (matches + inv.added).filter { !excluded.contains($0) && seen.insert($0).inserted }
    }
}

/// Deterministic links between resources: nothing is guessed from names except the Lambda default log group,
/// which is a documented AWS convention.
public enum InvestigationLinks {
    /// The log groups an ECS task definition writes to (`awslogs-group` of each container), unique, in order.
    public static func ecsLogGroups(_ td: EcsTaskDefinition) -> [String] {
        var seen = Set<String>()
        return td.containers.compactMap { $0.logGroup }.filter { seen.insert($0).inserted }
    }

    /// Queues that feed a Lambda function, by matching its SQS event sources against known queues.
    public static func sourceQueues(of sources: [LambdaWorkflow.EventSource], among queues: [SqsQueue]) -> [SqsQueue] {
        let names = Set(sources.compactMap { $0.sqsQueueName })
        return queues.filter { names.contains($0.name) }
    }

    /// The Lambda functions that consume a queue: the reverse of `sourceQueues`.
    public static func consumers(ofQueue queue: SqsQueue, mappingsByFunction: [String: [LambdaWorkflow.EventSource]]) -> [String] {
        mappingsByFunction.filter { $0.value.contains { $0.sqsQueueName == queue.name } }.map(\.key).sorted()
    }

    public static func roleName(fromArn arn: String?) -> String? { arn.flatMap(IamWorkflow.roleName(fromArn:)) }
}

public enum InvestigationStore {
    public static func defaultPath() -> String { NSHomeDirectory() + "/.config/bridge/investigations.json" }

    public static func load(path: String = defaultPath()) -> (items: [Investigation], warning: String?) {
        guard let data = FileManager.default.contents(atPath: path) else { return ([], nil) }
        do { return (try JSONDecoder().decode([Investigation].self, from: data), nil) }
        catch { return ([], "\(path) could not be read; it was left untouched") }
    }

    public static func save(_ items: [Investigation], path: String = defaultPath()) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let tmp = path + ".tmp-\(UUID().uuidString)"
        guard FileManager.default.createFile(atPath: tmp, contents: try enc.encode(items), attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        if rename(tmp, path) != 0 { try? FileManager.default.removeItem(atPath: tmp); throw CocoaError(.fileWriteUnknown) }
    }
}
