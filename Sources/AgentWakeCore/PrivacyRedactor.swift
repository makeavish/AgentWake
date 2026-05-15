import Foundation

public enum PrivacyRedactor {
    private static let blockedKeyFragments = [
        "prompt",
        "hookbody",
        "hookpayload",
        "toolarg",
        "transcript",
        "environment",
        "env",
        "rawcwd",
        "cwd"
    ]

    public static func redact(
        _ value: String,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        guard !homeDirectory.isEmpty else {
            return value
        }

        return value.replacingOccurrences(of: homeDirectory, with: "~")
    }

    public static func sanitizedMetadata(
        _ metadata: [String: String],
        allowedKeys: Set<String>,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [String: String] {
        metadata.reduce(into: [:]) { sanitized, pair in
            guard allowedKeys.contains(pair.key), !shouldDropMetadataKey(pair.key) else {
                return
            }

            sanitized[pair.key] = redact(pair.value, homeDirectory: homeDirectory)
        }
    }

    private static func shouldDropMetadataKey(_ key: String) -> Bool {
        let normalized = key
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }

        return blockedKeyFragments.contains { normalized.contains($0) }
    }
}
