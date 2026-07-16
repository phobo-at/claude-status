import Foundation
import XCTest
@testable import ClaudeStatus

@MainActor
final class UsageStoreTests: XCTestCase {
    func testStartsDisconnectedWithoutPriorConsent() async {
        let defaults = makeDefaults()
        let store = makeStore(userDefaults: defaults)

        await store.start()

        XCTAssertEqual(store.state, .disconnected)
        XCTAssertFalse(store.isConnectionAuthorized)
    }

    func testConnectFetchesAndCachesUsage() async {
        let defaults = makeDefaults()
        let cache = MemorySnapshotCache()
        let expected = Self.snapshot(utilization: 14)
        let store = makeStore(
            usageClient: SuccessfulUsageClient(snapshot: expected),
            cache: cache,
            userDefaults: defaults
        )

        await store.connect()

        XCTAssertEqual(store.state, .current)
        XCTAssertEqual(store.snapshot, expected)
        XCTAssertTrue(store.isConnectionAuthorized)
        let cachedSnapshot = await cache.load()
        XCTAssertEqual(cachedSnapshot, expected)
    }

    func testCachedSnapshotBecomesStaleWhenOffline() async {
        let defaults = makeDefaults(connected: true)
        let cached = Self.snapshot(utilization: 33)
        let store = makeStore(
            usageClient: FailingUsageClient(error: URLError(.notConnectedToInternet)),
            cache: MemorySnapshotCache(snapshot: cached),
            userDefaults: defaults
        )

        await store.start()

        XCTAssertEqual(store.snapshot, cached)
        guard case .stale = store.state else {
            return XCTFail("Expected stale state, got \(store.state)")
        }
        XCTAssertNotNil(store.nextRefreshAllowedAt)
    }

    func testUnauthorizedUsageRequiresLoginWithoutExecutingAnotherProgram() async {
        let defaults = makeDefaults(connected: true)
        let store = makeStore(
            usageClient: FailingUsageClient(error: UsageClientError.unauthorized),
            userDefaults: defaults
        )

        await store.start()

        guard case .authenticationRequired = store.state else {
            return XCTFail("Expected authenticationRequired, got \(store.state)")
        }
    }

    func testDeniedKeychainAccessExposesRecoverableFailure() async {
        let defaults = makeDefaults()
        let store = UsageStore(
            credentialProvider: DeniedCredentialProvider(),
            usageClient: SuccessfulUsageClient(snapshot: Self.snapshot(utilization: 10)),
            cache: MemorySnapshotCache(),
            userDefaults: defaults,
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        await store.connect()

        XCTAssertFalse(store.isConnectionAuthorized)
        guard case .failed = store.state else {
            return XCTFail("Expected failed state, got \(store.state)")
        }
    }

    func testCredentialIsReadOnlyOnceAcrossAutomaticAndManualRefreshes() async {
        let defaults = makeDefaults(connected: true)
        let credentials = CountingCredentialProvider()
        let store = UsageStore(
            credentialProvider: credentials,
            usageClient: SuccessfulUsageClient(snapshot: Self.snapshot(utilization: 10)),
            cache: MemorySnapshotCache(),
            userDefaults: defaults,
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        await store.start()
        await store.popoverOpened()
        await store.manualRefresh()

        let requestCount = await credentials.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testUnauthorizedStopsAutomaticKeychainReadsUntilExplicitRetry() async {
        let defaults = makeDefaults(connected: true)
        let credentials = CountingCredentialProvider()
        let store = UsageStore(
            credentialProvider: credentials,
            usageClient: FailingUsageClient(error: UsageClientError.unauthorized),
            cache: MemorySnapshotCache(),
            userDefaults: defaults,
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        await store.start()
        await store.popoverOpened()

        var requestCount = await credentials.requestCount
        XCTAssertEqual(requestCount, 1)

        await store.retryAuthentication()

        requestCount = await credentials.requestCount
        XCTAssertEqual(requestCount, 2)
    }

    private func makeStore(
        usageClient: any UsageFetching = SuccessfulUsageClient(snapshot: snapshot(utilization: 10)),
        cache: any SnapshotCaching = MemorySnapshotCache(),
        userDefaults: UserDefaults
    ) -> UsageStore {
        UsageStore(
            credentialProvider: SuccessfulCredentialProvider(),
            usageClient: usageClient,
            cache: cache,
            userDefaults: userDefaults,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
    }

    private func makeDefaults(connected: Bool = false) -> UserDefaults {
        let suite = "ClaudeStatusTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(connected, forKey: "hasAuthorizedClaudeCodeConnection")
        return defaults
    }

    private static func snapshot(utilization: Double) -> UsageSnapshot {
        UsageSnapshot(
            currentSession: LimitWindow(utilization: utilization, resetsAt: nil),
            weeklyAllModels: LimitWindow(utilization: 2, resetsAt: nil),
            weeklySonnet: nil,
            weeklyOpus: nil,
            fetchedAt: Date(timeIntervalSince1970: 1_000)
        )
    }
}

private struct SuccessfulCredentialProvider: CredentialProviding {
    func credential() async throws -> ClaudeCredential {
        ClaudeCredential(accessToken: "token", planName: "Max")
    }
}

private struct DeniedCredentialProvider: CredentialProviding {
    func credential() async throws -> ClaudeCredential { throw CredentialError.accessDenied }
}

private actor CountingCredentialProvider: CredentialProviding {
    private(set) var requestCount = 0

    func credential() async throws -> ClaudeCredential {
        requestCount += 1
        return ClaudeCredential(accessToken: "token", planName: "Max")
    }
}

private struct SuccessfulUsageClient: UsageFetching {
    let snapshot: UsageSnapshot
    func fetchUsage(accessToken: String) async throws -> UsageSnapshot { snapshot }
}

private struct FailingUsageClient: UsageFetching {
    let error: any Error & Sendable
    func fetchUsage(accessToken: String) async throws -> UsageSnapshot { throw error }
}

private actor MemorySnapshotCache: SnapshotCaching {
    private var snapshot: UsageSnapshot?

    init(snapshot: UsageSnapshot? = nil) {
        self.snapshot = snapshot
    }

    func load() async -> UsageSnapshot? { snapshot }
    func save(_ snapshot: UsageSnapshot) async { self.snapshot = snapshot }
}
