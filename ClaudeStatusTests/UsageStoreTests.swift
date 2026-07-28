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
        XCTAssertNotNil(store.automaticBackoffUntil)
        XCTAssertNil(store.retryAfterUntil)
        // A self-imposed backoff must never disable the user's refresh button.
        XCTAssertTrue(store.canRefresh)
    }

    func testExplicitRefreshBypassesSelfImposedBackoffButAutomaticOneDoesNot() async {
        let defaults = makeDefaults(connected: true)
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let snapshot = Self.snapshot(utilization: 10)
        let usageClient = ScriptedUsageClient(results: [
            .failure(.serverError(503)),
            .success(snapshot),
        ])
        let store = UsageStore(
            credentialProvider: SuccessfulCredentialProvider(),
            usageClient: usageClient,
            cache: MemorySnapshotCache(),
            userDefaults: defaults,
            now: { clock.now }
        )

        await store.start()

        var requestCount = await usageClient.requestCount
        XCTAssertEqual(requestCount, 1)
        XCTAssertNotNil(store.automaticBackoffUntil)
        XCTAssertNil(store.retryAfterUntil)
        XCTAssertTrue(store.canRefresh)

        // Automatic triggers stay throttled while the backoff window is open.
        await store.popoverOpened()
        requestCount = await usageClient.requestCount
        XCTAssertEqual(requestCount, 1)

        // An explicit user action retries immediately, without waiting out the backoff.
        await store.manualRefresh()
        requestCount = await usageClient.requestCount
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(store.state, .current)
        XCTAssertNil(store.automaticBackoffUntil)
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

    func testRotatedTokenIsReReadFromKeychainWithoutUserAction() async {
        let defaults = makeDefaults(connected: true)
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let credentials = RotatingCredentialProvider(tokens: ["token-1", "token-2"])
        let usageClient = TokenValidatingUsageClient(
            validToken: "token-1",
            snapshot: Self.snapshot(utilization: 10)
        )
        let store = UsageStore(
            credentialProvider: credentials,
            usageClient: usageClient,
            cache: MemorySnapshotCache(),
            userDefaults: defaults,
            now: { clock.now }
        )

        await store.start()
        XCTAssertEqual(store.state, .current)
        var credentialReads = await credentials.requestCount
        XCTAssertEqual(credentialReads, 1)

        // Claude Code refreshes its OAuth token: the token this app is holding stops
        // working, and the keychain now hands out a new one.
        await usageClient.rotate(to: "token-2")
        clock.advance(by: UsageStore.minimumAutomaticRefreshAge)

        await store.popoverOpened()

        credentialReads = await credentials.requestCount
        XCTAssertEqual(credentialReads, 2)
        XCTAssertEqual(store.state, .current)
    }

    func testUnauthorizedAfterKeychainReReadRequiresExplicitRetry() async {
        let defaults = makeDefaults(connected: true)
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let credentials = RotatingCredentialProvider(tokens: ["token-1", "token-2"])
        let usageClient = TokenValidatingUsageClient(
            validToken: "token-1",
            snapshot: Self.snapshot(utilization: 10)
        )
        let store = UsageStore(
            credentialProvider: credentials,
            usageClient: usageClient,
            cache: MemorySnapshotCache(),
            userDefaults: defaults,
            now: { clock.now }
        )

        await store.start()

        // Nothing the keychain hands out is accepted any more: the re-read must happen
        // exactly once and then stop, rather than loop on the keychain.
        await usageClient.rotate(to: "token-nobody-has")
        clock.advance(by: UsageStore.minimumAutomaticRefreshAge)
        await store.popoverOpened()

        var credentialReads = await credentials.requestCount
        XCTAssertEqual(credentialReads, 2)
        guard case .authenticationRequired = store.state else {
            return XCTFail("Expected authenticationRequired, got \(store.state)")
        }

        clock.advance(by: UsageStore.minimumAutomaticRefreshAge)
        await store.popoverOpened()

        credentialReads = await credentials.requestCount
        XCTAssertEqual(credentialReads, 2)
    }

    func testActiveRetryAfterIsExposedOnlyWhileTheCoolDownRuns() async {
        let defaults = makeDefaults()
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let usageClient = ScriptedUsageClient(results: [
            .success(Self.snapshot(utilization: 10)),
            .failure(.rateLimited(retryAfter: 1_805)),
        ])
        let store = UsageStore(
            credentialProvider: SuccessfulCredentialProvider(),
            usageClient: usageClient,
            cache: MemorySnapshotCache(),
            userDefaults: defaults,
            now: { clock.now }
        )

        await store.connect()
        XCTAssertNil(store.activeRetryAfter)

        await store.manualRefresh()
        XCTAssertEqual(store.activeRetryAfter, Date(timeIntervalSince1970: 2_805))

        clock.advance(by: 1_805)
        XCTAssertNil(store.activeRetryAfter)
    }

    /// Opening the popover is a deliberate "show me now", so it runs on a shorter gate than
    /// the background triggers — but it is still gated, and still bounded by one request.
    func testPopoverRefreshesOnTheShorterInteractiveGate() async {
        XCTAssertLessThan(
            UsageStore.minimumInteractiveRefreshAge,
            UsageStore.minimumAutomaticRefreshAge
        )

        let defaults = makeDefaults()
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let usageClient = CountingUsageClient(snapshot: Self.snapshot(utilization: 10))
        let store = UsageStore(
            credentialProvider: SuccessfulCredentialProvider(),
            usageClient: usageClient,
            cache: MemorySnapshotCache(),
            userDefaults: defaults,
            now: { clock.now }
        )

        await store.connect()
        await store.popoverOpened()
        var requestCount = await usageClient.requestCount
        XCTAssertEqual(requestCount, 1)

        clock.advance(by: UsageStore.minimumInteractiveRefreshAge - 1)
        await store.popoverOpened()
        requestCount = await usageClient.requestCount
        XCTAssertEqual(requestCount, 1)

        // One second past the interactive gate, and still far inside the background one.
        clock.advance(by: 1)
        await store.popoverOpened()
        requestCount = await usageClient.requestCount
        XCTAssertEqual(requestCount, 2)
    }

    func testManualRefreshStillFetchesWhenSnapshotIsFresh() async {
        let defaults = makeDefaults()
        let usageClient = CountingUsageClient(snapshot: Self.snapshot(utilization: 10))
        let store = UsageStore(
            credentialProvider: SuccessfulCredentialProvider(),
            usageClient: usageClient,
            cache: MemorySnapshotCache(),
            userDefaults: defaults,
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        await store.connect()
        await store.manualRefresh()

        let requestCount = await usageClient.requestCount
        XCTAssertEqual(requestCount, 2)
    }

    func testRateLimitBlocksEveryRefreshUntilRetryAfterExpires() async {
        let defaults = makeDefaults()
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let snapshot = Self.snapshot(utilization: 10)
        let usageClient = ScriptedUsageClient(results: [
            .success(snapshot),
            .failure(.rateLimited(retryAfter: 600)),
            .success(snapshot),
        ])
        let store = UsageStore(
            credentialProvider: SuccessfulCredentialProvider(),
            usageClient: usageClient,
            cache: MemorySnapshotCache(),
            userDefaults: defaults,
            now: { clock.now }
        )

        await store.connect()
        await store.manualRefresh()

        XCTAssertEqual(store.retryAfterUntil, Date(timeIntervalSince1970: 1_600))
        XCTAssertFalse(store.canRefresh)

        await store.manualRefresh()
        await store.popoverOpened()
        var requestCount = await usageClient.requestCount
        XCTAssertEqual(requestCount, 2)

        clock.advance(by: 599)
        await store.manualRefresh()
        requestCount = await usageClient.requestCount
        XCTAssertEqual(requestCount, 2)

        clock.advance(by: 1)
        await store.manualRefresh()
        requestCount = await usageClient.requestCount
        XCTAssertEqual(requestCount, 3)
        XCTAssertNil(store.retryAfterUntil)
        XCTAssertEqual(store.state, .current)
    }

    func testNextPollDelayAnchorsToTheLastSuccessfulFetch() {
        let now = Date(timeIntervalSince1970: 10_000)
        let interval = UsageStore.automaticRefreshInterval

        // No snapshot yet: wait a full interval.
        XCTAssertEqual(
            UsageStore.nextPollDelay(
                lastFetchedAt: nil, interval: interval,
                backoffUntil: nil, retryAfterUntil: nil, now: now
            ),
            interval
        )

        // An off-cycle refresh five minutes ago pushes the tick out to interval-minus-age,
        // so it can never arrive too young to pass its own gate.
        XCTAssertEqual(
            UsageStore.nextPollDelay(
                lastFetchedAt: now.addingTimeInterval(-5 * 60), interval: interval,
                backoffUntil: nil, retryAfterUntil: nil, now: now
            ),
            interval - 5 * 60
        )

        // A snapshot already older than the interval polls after the floor, not instantly.
        XCTAssertEqual(
            UsageStore.nextPollDelay(
                lastFetchedAt: now.addingTimeInterval(-2 * interval), interval: interval,
                backoffUntil: nil, retryAfterUntil: nil, now: now
            ),
            60
        )

        // Running gates move the tick past their expiry instead of wasting a wakeup.
        XCTAssertEqual(
            UsageStore.nextPollDelay(
                lastFetchedAt: now.addingTimeInterval(-2 * interval), interval: interval,
                backoffUntil: nil, retryAfterUntil: now.addingTimeInterval(1_800), now: now
            ),
            1_801
        )
    }

    func testClimbingUsageSpeedsUpTheCadenceAndFlatUsageSlowsItDown() async {
        let defaults = makeDefaults(connected: true)
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let usageClient = ScriptedUsageClient(results: [
            .success(Self.snapshot(utilization: 10)),
            .success(Self.snapshot(utilization: 12)),
            .success(Self.snapshot(utilization: 12)),
            .success(Self.snapshot(utilization: 12)),
        ])
        let store = UsageStore(
            credentialProvider: SuccessfulCredentialProvider(),
            usageClient: usageClient,
            cache: MemorySnapshotCache(),
            userDefaults: defaults,
            now: { clock.now }
        )

        // First fetch has nothing to compare against: cadence stays idle.
        await store.start()
        XCTAssertEqual(store.pollingCadence, .idle)

        // Utilization climbed since the previous fetch: someone is using Claude.
        clock.advance(by: 60)
        await store.manualRefresh()
        XCTAssertEqual(store.pollingCadence, .active)

        // One flat fetch is not yet proof of idleness …
        clock.advance(by: 60)
        await store.manualRefresh()
        XCTAssertEqual(store.pollingCadence, .active)

        // … the second one is.
        clock.advance(by: 60)
        await store.manualRefresh()
        XCTAssertEqual(store.pollingCadence, .idle)
    }

    func testRateLimitClampsTheCadenceBackToIdle() async {
        let defaults = makeDefaults(connected: true)
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let usageClient = ScriptedUsageClient(results: [
            .success(Self.snapshot(utilization: 10)),
            .success(Self.snapshot(utilization: 12)),
            .failure(.rateLimited(retryAfter: 1_800)),
        ])
        let store = UsageStore(
            credentialProvider: SuccessfulCredentialProvider(),
            usageClient: usageClient,
            cache: MemorySnapshotCache(),
            userDefaults: defaults,
            now: { clock.now }
        )

        await store.start()
        clock.advance(by: 60)
        await store.manualRefresh()
        XCTAssertEqual(store.pollingCadence, .active)

        clock.advance(by: 60)
        await store.manualRefresh()
        XCTAssertEqual(store.pollingCadence, .idle)
        XCTAssertNotNil(store.retryAfterUntil)
    }

    func testResetRefreshIsScheduledJustAfterTheEarliestRollover() {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = UsageSnapshot(
            currentSession: LimitWindow(utilization: 80, resetsAt: now.addingTimeInterval(600)),
            weeklyAllModels: LimitWindow(utilization: 40, resetsAt: now.addingTimeInterval(86_400)),
            weeklySonnet: nil,
            weeklyOpus: nil,
            fetchedAt: now
        )

        XCTAssertEqual(
            UsageStore.resetRefreshDelay(for: snapshot, now: now),
            600 + UsageStore.resetRefreshGrace
        )
    }

    func testResetRefreshSkipsRolloversAlreadyPastOrBeyondTheHorizon() {
        let now = Date(timeIntervalSince1970: 1_000)

        // A reset Anthropic has not actually rolled over yet must not arm a retry loop;
        // the polling interval picks it up instead.
        let past = UsageSnapshot(
            currentSession: LimitWindow(utilization: 80, resetsAt: now.addingTimeInterval(-60)),
            weeklyAllModels: nil,
            weeklySonnet: nil,
            weeklyOpus: nil,
            fetchedAt: now
        )
        XCTAssertNil(UsageStore.resetRefreshDelay(for: past, now: now))

        // Weekly windows stay with the polling loop until they come within the horizon.
        let farOut = UsageSnapshot(
            currentSession: nil,
            weeklyAllModels: LimitWindow(
                utilization: 40,
                resetsAt: now.addingTimeInterval(UsageStore.resetRefreshHorizon + 60)
            ),
            weeklySonnet: nil,
            weeklyOpus: nil,
            fetchedAt: now
        )
        XCTAssertNil(UsageStore.resetRefreshDelay(for: farOut, now: now))

        XCTAssertNil(UsageStore.resetRefreshDelay(for: nil, now: now))
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

/// Hands out a different token on each read, the way the keychain does once Claude Code
/// has refreshed its OAuth token.
private actor RotatingCredentialProvider: CredentialProviding {
    private(set) var requestCount = 0
    private let tokens: [String]

    init(tokens: [String]) {
        self.tokens = tokens
    }

    func credential() async throws -> ClaudeCredential {
        let token = tokens[min(requestCount, tokens.count - 1)]
        requestCount += 1
        return ClaudeCredential(accessToken: token, planName: "Max")
    }
}

/// Accepts exactly one token, so a token the app is still holding after a rotation gets
/// the same 401 Anthropic would send.
private actor TokenValidatingUsageClient: UsageFetching {
    private(set) var requestCount = 0
    private var validToken: String
    private let snapshot: UsageSnapshot

    init(validToken: String, snapshot: UsageSnapshot) {
        self.validToken = validToken
        self.snapshot = snapshot
    }

    func rotate(to token: String) {
        validToken = token
    }

    func fetchUsage(accessToken: String) async throws -> UsageSnapshot {
        requestCount += 1
        guard accessToken == validToken else {
            throw UsageClientError.unauthorized
        }
        return snapshot
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

private actor CountingUsageClient: UsageFetching {
    private(set) var requestCount = 0
    let snapshot: UsageSnapshot

    init(snapshot: UsageSnapshot) {
        self.snapshot = snapshot
    }

    func fetchUsage(accessToken: String) async throws -> UsageSnapshot {
        requestCount += 1
        return snapshot
    }
}

private actor ScriptedUsageClient: UsageFetching {
    private(set) var requestCount = 0
    private var results: [Result<UsageSnapshot, UsageClientError>]

    init(results: [Result<UsageSnapshot, UsageClientError>]) {
        self.results = results
    }

    func fetchUsage(accessToken: String) async throws -> UsageSnapshot {
        requestCount += 1
        guard !results.isEmpty else {
            throw UsageClientError.invalidResponse
        }
        return try results.removeFirst().get()
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    var now: Date {
        lock.withLock { date }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock {
            date = date.addingTimeInterval(interval)
        }
    }
}

private actor MemorySnapshotCache: SnapshotCaching {
    private var snapshot: UsageSnapshot?

    init(snapshot: UsageSnapshot? = nil) {
        self.snapshot = snapshot
    }

    func load() async -> UsageSnapshot? { snapshot }
    func save(_ snapshot: UsageSnapshot) async { self.snapshot = snapshot }
}
