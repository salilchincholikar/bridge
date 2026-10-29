import Foundation
import UniformTypeIdentifiers
import BridgeCore

/// S3 keys need not have extensions. Offer a useful local name without changing the remote key.
enum S3DownloadName {
    static func suggested(key: String, contentType: String?) -> String {
        guard let base = try? PathSanitizer.fileName(forKey: key) else { return "download" }
        guard (base as NSString).pathExtension.isEmpty, !base.hasPrefix("."),
              let mime = contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let type = UTType(mimeType: mime), let ext = type.preferredFilenameExtension, !ext.isEmpty else { return base }
        return (try? PathSanitizer.fileName(forKey: base + "." + ext)) ?? base
    }
}
