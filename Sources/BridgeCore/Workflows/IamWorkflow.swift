import Foundation

// W3: IAM roles and policy documents. Read-only: nothing here changes IAM.

public struct IamRole: Equatable, Sendable {
    public var name: String
    public var arn: String
    public var path: String?
    public var created: Date?
    public var description: String?
    public var trustPolicy: JSONValue?
}

public struct IamAttachedPolicy: Equatable, Sendable {
    public var name: String
    public var arn: String
}

public enum IamWorkflow {
    public static func getRole(profile: String, region: String, role: String) -> ExecRequest {
        ExecRequest(profile: profile, region: region, service: "iam", operation: "get-role", params: .object(["RoleName": .string(role)]))
    }
    public static func listAttached(profile: String, region: String, role: String) -> ExecRequest {
        ExecRequest(profile: profile, region: region, service: "iam", operation: "list-attached-role-policies",
                    params: .object(["RoleName": .string(role)]), maxItems: 200)
    }
    public static func listInlineNames(profile: String, region: String, role: String) -> ExecRequest {
        ExecRequest(profile: profile, region: region, service: "iam", operation: "list-role-policies",
                    params: .object(["RoleName": .string(role)]), maxItems: 200)
    }
    public static func getInlinePolicy(profile: String, region: String, role: String, policy: String) -> ExecRequest {
        ExecRequest(profile: profile, region: region, service: "iam", operation: "get-role-policy",
                    params: .object(["RoleName": .string(role), "PolicyName": .string(policy)]))
    }
    public static func getPolicy(profile: String, region: String, arn: String) -> ExecRequest {
        ExecRequest(profile: profile, region: region, service: "iam", operation: "get-policy", params: .object(["PolicyArn": .string(arn)]))
    }
    public static func getPolicyVersion(profile: String, region: String, arn: String, version: String) -> ExecRequest {
        ExecRequest(profile: profile, region: region, service: "iam", operation: "get-policy-version",
                    params: .object(["PolicyArn": .string(arn), "VersionId": .string(version)]))
    }

    /// IAM returns policy documents URL-encoded in the API; the CLI normally shows them decoded as JSON.
    /// Accept both so a CLI version difference cannot break the viewer.
    public static func policyDocument(_ v: JSONValue?) -> JSONValue? {
        switch v {
        case .object?: return v
        case .string(let s)?:
            let decoded = s.removingPercentEncoding ?? s
            return decoded.data(using: .utf8).flatMap { try? JSONValue.parse($0) }
        default: return nil
        }
    }

    public static func parseRole(_ json: JSONValue?) -> IamRole? {
        guard let r = json?["Role"], let name = r.string("RoleName"), let arn = r.string("Arn") else { return nil }
        return IamRole(name: name, arn: arn, path: r.string("Path"), created: AwsDate.parse(r["CreateDate"]),
                       description: r.string("Description"), trustPolicy: policyDocument(r["AssumeRolePolicyDocument"]))
    }

    public static func parseAttached(_ json: JSONValue?) -> [IamAttachedPolicy] {
        (json?.array("AttachedPolicies") ?? []).compactMap {
            guard let n = $0.string("PolicyName"), let a = $0.string("PolicyArn") else { return nil }
            return IamAttachedPolicy(name: n, arn: a)
        }
    }

    public static func parseInlineNames(_ json: JSONValue?) -> [String] { json?.strings("PolicyNames") ?? [] }
    public static func parseInlineDocument(_ json: JSONValue?) -> JSONValue? { policyDocument(json?["PolicyDocument"]) }
    public static func defaultVersionId(_ json: JSONValue?) -> String? { json?.string("Policy.DefaultVersionId") }
    public static func parseVersionDocument(_ json: JSONValue?) -> JSONValue? { policyDocument(json?["PolicyVersion"]?["Document"]) }

    /// The role name from a role ARN (`arn:aws:iam::123456789012:role/path/Name` gives `Name`), for jumping from
    /// a Lambda or task role ARN to the role view.
    public static func roleName(fromArn arn: String) -> String? { AwsConfigParser.parseRoleArn(arn)?.role }
}
