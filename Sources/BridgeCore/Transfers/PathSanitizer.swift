import Foundation

public enum PathError: Error, Equatable, Sendable {
    case emptyKey
    case directoryKey          // key ends with "/": there is no file to save
    case traversal(String)     // "." or ".." component
    case outsideDestination
}

/// Turns an S3 object key into a safe local path under a destination folder (docs/technical.md 4.6).
/// S3 keys are arbitrary strings; they may contain "..", control characters, leading slashes and so on.
public enum PathSanitizer {
    /// Longest file name we create, in UTF-8 bytes (HFS+/APFS limit is 255).
    static let maxNameBytes = 255
    /// Room for ".bridge-part" and a " (99)" collision suffix.
    static let reservedBytes = 20

    /// Just the file name: the last path component of the key.
    public static func fileName(forKey key: String) throws -> String {
        guard !key.isEmpty, !key.contains("\0") else { throw PathError.emptyKey }
        if key.hasSuffix("/") { throw PathError.directoryKey }
        let last = key.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        guard !last.isEmpty else { throw PathError.emptyKey }
        if last == "." || last == ".." { throw PathError.traversal(last) }
        return clean(last)
    }

    /// The key's folder structure, preserved under the destination (for prefix downloads). Any "." or ".."
    /// component rejects the whole key rather than trying to repair it.
    public static func relativePath(forKey key: String) throws -> String {
        guard !key.isEmpty, !key.contains("\0") else { throw PathError.emptyKey }
        let comps = key.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !comps.isEmpty else { throw PathError.emptyKey }
        for c in comps where c == "." || c == ".." { throw PathError.traversal(c) }
        return comps.map(clean).joined(separator: "/")
    }

    /// Final location: destination + sanitized relative path, verified to stay inside the destination even
    /// after symlinks are resolved (a symlink already inside the folder must not lead the download outside).
    public static func destinationURL(folder: URL, relativePath: String) throws -> URL {
        guard let base = realPath(folder.path),
              let resolved = resolvedAllowingMissingTail(base + "/" + relativePath) else { throw PathError.outsideDestination }
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard resolved.hasPrefix(prefix), resolved != base else { throw PathError.outsideDestination }
        return URL(fileURLWithPath: base).appendingPathComponent(relativePath)
    }

    /// `realpath(3)`: fully resolved, or nil if the path does not exist or cannot be resolved.
    static func realPath(_ path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    /// Resolves symlinks in the longest EXISTING prefix of `path` and appends the missing tail unchanged.
    /// (Foundation's `resolvingSymlinksInPath()` does not resolve symlinks when the final file is missing,
    /// which is exactly the case for a file about to be created.) A dangling symlink, whose target cannot
    /// be resolved, returns nil: unsafe.
    static func resolvedAllowingMissingTail(_ path: String) -> String? {
        var existing = path
        var tail: [String] = []
        var st = stat()
        while lstat(existing, &st) != 0 {
            guard errno == ENOENT else { return nil }
            tail.insert((existing as NSString).lastPathComponent, at: 0)
            let parent = (existing as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == existing { return nil }
            existing = parent
        }
        guard let real = realPath(existing) else { return nil }
        return tail.isEmpty ? real : real + (real.hasSuffix("/") ? "" : "/") + tail.joined(separator: "/")
    }

    /// `name (1).ext`, `name (2).ext`, ... until it does not exist.
    public static func uniqueURL(for url: URL, fileManager: FileManager = .default) -> URL {
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        var n = 1
        while true {
            let name = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    /// Replace control characters, and truncate to a safe length keeping the extension.
    static func clean(_ component: String) -> String {
        var s = String(component.unicodeScalars.map { scalar -> Character in
            (scalar.value < 0x20 || scalar.value == 0x7f) ? "_" : Character(scalar)
        })
        let limit = maxNameBytes - reservedBytes
        if s.utf8.count > limit {
            let ext = (s as NSString).pathExtension
            let keepExt = ext.utf8.count <= 16 ? "." + ext : ""
            var stem = ext.isEmpty ? s : String(s.dropLast(ext.count + 1))
            while (stem + keepExt).utf8.count > limit { stem.removeLast() }
            s = stem + (ext.isEmpty ? "" : keepExt)
        }
        return s
    }
}
