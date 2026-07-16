import Foundation

protocol SnapshotCaching: Sendable {
    func load() async -> UsageSnapshot?
    func save(_ snapshot: UsageSnapshot) async
}

actor FileSnapshotCache: SnapshotCaching {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.fileURL = applicationSupport
                .appendingPathComponent("ClaudeStatus", isDirectory: true)
                .appendingPathComponent("usage-cache.json")
        }
    }

    func load() async -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        return try? JSONDecoder().decode(UsageSnapshot.self, from: data)
    }

    func save(_ snapshot: UsageSnapshot) async {
        do {
            let directoryURL = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directoryURL.path
            )
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            // The cache is an optional convenience. Network data remains authoritative.
        }
    }
}
