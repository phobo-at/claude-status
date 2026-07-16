import Foundation
import XCTest
@testable import ClaudeStatus

final class SnapshotCacheTests: XCTestCase {
    func testCacheUsesPrivatePOSIXPermissionsAndContainsNoCredentialFields() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeStatusCacheTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = root.appendingPathComponent("usage-cache.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = UsageSnapshot(
            currentSession: LimitWindow(utilization: 14, resetsAt: nil),
            weeklyAllModels: nil,
            weeklySonnet: nil,
            weeklyOpus: nil,
            fetchedAt: Date(timeIntervalSince1970: 42)
        )
        let cache = FileSnapshotCache(fileURL: fileURL)

        await cache.save(snapshot)

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: root.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(contents.localizedCaseInsensitiveContains("token"))
        XCTAssertFalse(contents.localizedCaseInsensitiveContains("credential"))
        let loadedSnapshot = await cache.load()
        XCTAssertEqual(loadedSnapshot, snapshot)
    }
}
