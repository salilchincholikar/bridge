import Foundation

// W4: S3 browsing. Downloads are in Transfers/S3Downloader.

public struct S3Bucket: Equatable, Sendable {
    public var name: String
    public var created: Date?
    public init(name: String, created: Date? = nil) { self.name = name; self.created = created }
}

public struct S3Object: Equatable, Sendable {
    public var key: String
    public var size: Int64
    public var lastModified: Date?
    public var storageClass: String?
    public var etag: String?
    public init(key: String, size: Int64, lastModified: Date? = nil, storageClass: String? = nil, etag: String? = nil) {
        self.key = key; self.size = size; self.lastModified = lastModified; self.storageClass = storageClass; self.etag = etag
    }
    /// The last path component, for display.
    public var displayName: String { String(key.split(separator: "/", omittingEmptySubsequences: true).last ?? Substring(key)) }
}

public struct S3Listing: Equatable, Sendable {
    /// "Folders": common prefixes ending in the delimiter.
    public var prefixes: [String]
    public var objects: [S3Object]
    public init(prefixes: [String], objects: [S3Object]) { self.prefixes = prefixes; self.objects = objects }
}

public enum S3Workflow {
    public static func listBuckets(profile: String, region: String) -> ExecRequest {
        ExecRequest(profile: profile, region: region, service: "s3api", operation: "list-buckets", maxItems: 1000)
    }

    /// One level of a bucket: folders and objects under `prefix`.
    public static func listObjects(profile: String, region: String, bucket: String, prefix: String = "",
                                   maxItems: Int = 500, startingToken: String? = nil) -> ExecRequest {
        var p: [String: JSONValue] = ["Bucket": .string(bucket), "Delimiter": .string("/")]
        if !prefix.isEmpty { p["Prefix"] = .string(prefix) }
        return ExecRequest(profile: profile, region: region, service: "s3api", operation: "list-objects-v2",
                           params: .object(p), maxItems: maxItems, startingToken: startingToken)
    }

    public static func headObject(profile: String, region: String, bucket: String, key: String) -> ExecRequest {
        ExecRequest(profile: profile, region: region, service: "s3api", operation: "head-object",
                    params: .object(["Bucket": .string(bucket), "Key": .string(key)]))
    }

    /// The download request (tier 2). Hand it to `Authorizer`, then `S3Downloader`.
    public static func download(profile: String, region: String, bucket: String, key: String, timeout: TimeInterval = 3600) -> ExecRequest {
        ExecRequest(profile: profile, region: region, service: "s3api", operation: "get-object",
                    params: .object(["Bucket": .string(bucket), "Key": .string(key)]), timeout: timeout)
    }

    public static func parseBuckets(_ json: JSONValue?) -> [S3Bucket] {
        (json?.array("Buckets") ?? []).compactMap { b in
            guard let n = b.string("Name") else { return nil }
            return S3Bucket(name: n, created: AwsDate.parse(b["CreationDate"]))
        }
    }

    public static func parseListing(_ json: JSONValue?) -> S3Listing {
        let prefixes = (json?.array("CommonPrefixes") ?? []).compactMap { $0.string("Prefix") }
        let objects = (json?.array("Contents") ?? []).compactMap { o -> S3Object? in
            guard let k = o.string("Key") else { return nil }
            return S3Object(key: k, size: Int64(o.double("Size") ?? 0), lastModified: AwsDate.parse(o["LastModified"]),
                            storageClass: o.string("StorageClass"), etag: o.string("ETag"))
        }
        return S3Listing(prefixes: prefixes, objects: objects)
    }

    /// Breadcrumb parts of a prefix: `a/b/` gives `[("a","a/"), ("b","a/b/")]`.
    public static func breadcrumbs(prefix: String) -> [(name: String, prefix: String)] {
        var acc = ""
        return prefix.split(separator: "/", omittingEmptySubsequences: true).map { part in
            acc += part + "/"
            return (String(part), acc)
        }
    }
}
