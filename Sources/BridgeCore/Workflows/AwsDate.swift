import Foundation

/// Parses the timestamp shapes AWS CLI output uses: ISO 8601 with or without fractional seconds, with
/// "+00:00" or "+0000" offsets (Lambda's `LastModified` uses the latter), and epoch seconds or milliseconds.
public enum AwsDate {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let plain = ISO8601DateFormatter()
    private static let compactOffset: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return f
    }()

    public static func parse(_ s: String) -> Date? {
        withFraction.date(from: s) ?? plain.date(from: s) ?? compactOffset.date(from: s)
    }

    public static func parse(_ v: JSONValue?) -> Date? {
        switch v {
        case .string(let s)?: return parse(s)
        case .number(let n)?: return fromEpoch(n)
        default: return nil
        }
    }

    /// Values above 1e11 are milliseconds (that is year 5138 in seconds), otherwise seconds.
    public static func fromEpoch(_ n: Double) -> Date {
        Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n)
    }

    /// ISO 8601 in UTC with a trailing Z, the form accepted for timestamp parameters.
    public static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.string(from: d)
    }

    public static func epochMillis(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }
}

extension Array {
    /// Splits into consecutive chunks of at most `size` (AWS describe calls take at most 10 services, 100 tasks).
    public func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
