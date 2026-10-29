import Foundation

// W2: ECS. `list-*` calls return ARNs only, so every list is followed by a describe call (in chunks: the API
// takes at most 10 services and 100 tasks per describe).

public struct EcsCluster: Equatable, Sendable {
    public var name: String
    public var arn: String
    public var status: String?
    public var runningTasks: Int?
    public var pendingTasks: Int?
    public var activeServices: Int?
}

public struct EcsDeployment: Equatable, Sendable {
    public var id: String
    public var status: String?          // PRIMARY, ACTIVE, INACTIVE
    public var rolloutState: String?    // COMPLETED, IN_PROGRESS, FAILED
    public var desired: Int?
    public var running: Int?
    public var pending: Int?
    public var failed: Int?
    public var taskDefinition: String?
    public var created: Date?
}

public struct EcsEvent: Equatable, Sendable {
    public var id: String?
    public var created: Date?
    public var message: String
}

public struct EcsService: Equatable, Sendable {
    public var name: String
    public var arn: String?
    public var status: String?
    public var desired: Int
    public var running: Int
    public var pending: Int
    public var taskDefinition: String?
    public var launchType: String?
    public var deployments: [EcsDeployment]
    public var events: [EcsEvent]
    /// Healthy means the running count has reached the desired count and nothing is rolling out or failing.
    public var isHealthy: Bool {
        running == desired && pending == 0 && !deployments.contains { $0.rolloutState == "FAILED" || $0.rolloutState == "IN_PROGRESS" }
    }
}

public struct EcsTask: Equatable, Sendable {
    public struct Container: Equatable, Sendable { public var name: String; public var exitCode: Int?; public var reason: String?; public var lastStatus: String? }
    public var arn: String
    public var id: String { String(arn.split(separator: "/").last ?? "") }
    public var lastStatus: String?
    public var desiredStatus: String?
    public var stopCode: String?
    public var stoppedReason: String?
    public var stoppedAt: Date?
    public var startedAt: Date?
    public var taskDefinitionArn: String?
    public var group: String?
    public var containers: [Container]
}

public struct EcsTaskDefinition: Equatable, Sendable {
    public struct ContainerDef: Equatable, Sendable {
        public var name: String
        public var image: String?
        public var logGroup: String?
        public var logRegion: String?
        public var logStreamPrefix: String?
    }
    public var family: String
    public var revision: Int?
    public var taskRoleArn: String?
    public var executionRoleArn: String?
    public var cpu: String?
    public var memory: String?
    public var containers: [ContainerDef]
}

public enum EcsWorkflow {
    public static func listClusters(profile: String, region: String) -> ExecRequest {
        ExecRequest(profile: profile, region: region, service: "ecs", operation: "list-clusters", maxItems: 100)
    }
    public static func describeClusters(profile: String, region: String, arns: [String]) -> [ExecRequest] {
        arns.chunked(into: 100).map {
            ExecRequest(profile: profile, region: region, service: "ecs", operation: "describe-clusters",
                        params: .object(["clusters": .array($0.map(JSONValue.string))]))
        }
    }
    public static func listServices(profile: String, region: String, cluster: String) -> ExecRequest {
        ExecRequest(profile: profile, region: region, service: "ecs", operation: "list-services",
                    params: .object(["cluster": .string(cluster)]), maxItems: 200)
    }
    public static func describeServices(profile: String, region: String, cluster: String, services: [String]) -> [ExecRequest] {
        services.chunked(into: 10).map {
            ExecRequest(profile: profile, region: region, service: "ecs", operation: "describe-services",
                        params: .object(["cluster": .string(cluster), "services": .array($0.map(JSONValue.string))]))
        }
    }
    /// `desiredStatus`: "RUNNING" or "STOPPED" (stopped tasks stay visible for about an hour after they stop).
    public static func listTasks(profile: String, region: String, cluster: String, service: String?, desiredStatus: String) -> ExecRequest {
        var p: [String: JSONValue] = ["cluster": .string(cluster), "desiredStatus": .string(desiredStatus)]
        if let service { p["serviceName"] = .string(service) }
        return ExecRequest(profile: profile, region: region, service: "ecs", operation: "list-tasks", params: .object(p), maxItems: 100)
    }
    public static func describeTasks(profile: String, region: String, cluster: String, tasks: [String]) -> [ExecRequest] {
        tasks.chunked(into: 100).map {
            ExecRequest(profile: profile, region: region, service: "ecs", operation: "describe-tasks",
                        params: .object(["cluster": .string(cluster), "tasks": .array($0.map(JSONValue.string))]))
        }
    }
    public static func describeTaskDefinition(profile: String, region: String, taskDefinition: String) -> ExecRequest {
        ExecRequest(profile: profile, region: region, service: "ecs", operation: "describe-task-definition",
                    params: .object(["taskDefinition": .string(taskDefinition)]))
    }

    public static func arns(_ json: JSONValue?, key: String) -> [String] { json?.strings(key) ?? [] }

    public static func parseClusters(_ json: JSONValue?) -> [EcsCluster] {
        (json?.array("clusters") ?? []).compactMap { c in
            guard let name = c.string("clusterName"), let arn = c.string("clusterArn") else { return nil }
            return EcsCluster(name: name, arn: arn, status: c.string("status"), runningTasks: c.int("runningTasksCount"),
                              pendingTasks: c.int("pendingTasksCount"), activeServices: c.int("activeServicesCount"))
        }
    }

    public static func parseServices(_ json: JSONValue?) -> [EcsService] {
        (json?.array("services") ?? []).compactMap { s in
            guard let name = s.string("serviceName") else { return nil }
            let deployments = s.array("deployments").map { d in
                EcsDeployment(id: d.string("id") ?? "", status: d.string("status"), rolloutState: d.string("rolloutState"),
                              desired: d.int("desiredCount"), running: d.int("runningCount"), pending: d.int("pendingCount"),
                              failed: d.int("failedTasks"), taskDefinition: d.string("taskDefinition"), created: AwsDate.parse(d["createdAt"]))
            }
            let events = s.array("events").compactMap { e -> EcsEvent? in
                guard let m = e.string("message") else { return nil }
                return EcsEvent(id: e.string("id"), created: AwsDate.parse(e["createdAt"]), message: m)
            }
            return EcsService(name: name, arn: s.string("serviceArn"), status: s.string("status"), desired: s.int("desiredCount") ?? 0,
                              running: s.int("runningCount") ?? 0, pending: s.int("pendingCount") ?? 0,
                              taskDefinition: s.string("taskDefinition"), launchType: s.string("launchType"),
                              deployments: deployments, events: events)
        }
    }

    public static func parseTasks(_ json: JSONValue?) -> [EcsTask] {
        (json?.array("tasks") ?? []).compactMap { t in
            guard let arn = t.string("taskArn") else { return nil }
            let containers = t.array("containers").map {
                EcsTask.Container(name: $0.string("name") ?? "", exitCode: $0.int("exitCode"), reason: $0.string("reason"), lastStatus: $0.string("lastStatus"))
            }
            return EcsTask(arn: arn, lastStatus: t.string("lastStatus"), desiredStatus: t.string("desiredStatus"), stopCode: t.string("stopCode"),
                           stoppedReason: t.string("stoppedReason"), stoppedAt: AwsDate.parse(t["stoppedAt"]), startedAt: AwsDate.parse(t["startedAt"]),
                           taskDefinitionArn: t.string("taskDefinitionArn"), group: t.string("group"), containers: containers)
        }
    }

    public static func parseTaskDefinition(_ json: JSONValue?) -> EcsTaskDefinition? {
        guard let td = json?["taskDefinition"], let family = td.string("family") else { return nil }
        let containers = td.array("containerDefinitions").map { c in
            EcsTaskDefinition.ContainerDef(name: c.string("name") ?? "", image: c.string("image"),
                                           logGroup: c.string("logConfiguration.options.awslogs-group"),
                                           logRegion: c.string("logConfiguration.options.awslogs-region"),
                                           logStreamPrefix: c.string("logConfiguration.options.awslogs-stream-prefix"))
        }
        return EcsTaskDefinition(family: family, revision: td.int("revision"), taskRoleArn: td.string("taskRoleArn"),
                                 executionRoleArn: td.string("executionRoleArn"), cpu: td.string("cpu"), memory: td.string("memory"),
                                 containers: containers)
    }
}
