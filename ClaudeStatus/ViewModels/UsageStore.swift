import AppKit
import Combine
import Foundation

enum UsageDisplayState: Equatable, Sendable {
    case disconnected
    case loading
    case current
    case stale(String)
    case authenticationRequired(String)
    case failed(String)
}

@MainActor
final class UsageStore: ObservableObject {
    /// Anthropic rate-limits `/api/oauth/usage` per account and answers a 429 with a
    /// half-hour `Retry-After`. Claude Code polls the same endpoint on the same account,
    /// so the budget is shared and the app has to spend it sparingly. The saving grace:
    /// a stale percentage is only *visibly* stale while usage is climbing, and usage only
    /// climbs while Claude is actively in use. So the poll cadence adapts — fast while
    /// consecutive fetches show utilization increasing, slow once it goes flat — which
    /// keeps the display effectively current when it matters without raising the
    /// steady-state spend. A 429 clamps straight back to the idle cadence.
    nonisolated static let automaticRefreshInterval: TimeInterval = 15 * 60
    nonisolated static let minimumAutomaticRefreshAge: TimeInterval = 10 * 60
    nonisolated static let activeRefreshInterval: TimeInterval = 5 * 60
    nonisolated static let minimumActiveRefreshAge: TimeInterval = 4 * 60
    /// A delta against a much older snapshot says nothing about the *current* rate of
    /// use, so it must not switch the cadence to active.
    static let activityComparisonWindow: TimeInterval = 30 * 60
    /// Flat fetches in a row before the cadence drops back to idle.
    static let idleConfirmationCount = 2

    enum PollingCadence: Equatable, Sendable {
        case idle
        case active

        var interval: TimeInterval {
            self == .active
                ? UsageStore.activeRefreshInterval
                : UsageStore.automaticRefreshInterval
        }

        var minimumRefreshAge: TimeInterval {
            self == .active
                ? UsageStore.minimumActiveRefreshAge
                : UsageStore.minimumAutomaticRefreshAge
        }
    }
    /// Opening the popover is the user asking "how much is left, right now", so it gets a
    /// shorter gate than the background tick. It is still a gate: repeatedly opening the
    /// menu costs at most one request per interval, and only while someone is looking.
    static let minimumInteractiveRefreshAge: TimeInterval = 3 * 60
    /// Grace period added after a window's `resets_at` before the confirming fetch, so
    /// clock skew between the Mac and Anthropic cannot land the request just before the
    /// rollover and read the old value back.
    static let resetRefreshGrace: TimeInterval = 20
    /// Resets further out than this are left to the polling loop. Every accepted snapshot
    /// reschedules, so a weekly window is picked up once it comes within the horizon
    /// instead of parking a task for days.
    static let resetRefreshHorizon: TimeInterval = 6 * 60 * 60

    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var planName: String?
    @Published private(set) var state: UsageDisplayState = .disconnected
    @Published private(set) var isRefreshing = false
    @Published private(set) var isConnectionAuthorized: Bool
    /// Cool-down demanded by Anthropic via `Retry-After`. Binding for every caller:
    /// an explicit user action must not hammer a rate-limited endpoint either.
    @Published private(set) var retryAfterUntil: Date?
    /// Backoff we impose on ourselves after transient failures. It throttles only the
    /// automatic refresh; an explicit user action bypasses it, so a user who just fixed
    /// their network is never locked out of the refresh button.
    @Published private(set) var automaticBackoffUntil: Date?

    private let credentialProvider: any CredentialProviding
    private let usageClient: any UsageFetching
    private let cache: any SnapshotCaching
    private let userDefaults: UserDefaults
    private let now: @Sendable () -> Date
    private let connectionDefaultsKey: String

    private var hasStarted = false
    private var activeCredential: ClaudeCredential?
    private var lastAttemptAt: Date?
    private var consecutiveFailures = 0
    private(set) var pollingCadence: PollingCadence = .idle
    private var unchangedFetchCount = 0
    private var pollingTask: Task<Void, Never>?
    private var resetRefreshTask: Task<Void, Never>?
    private var wakeObserver: (any NSObjectProtocol)?
    private var screenWakeObserver: (any NSObjectProtocol)?

    init(
        credentialProvider: any CredentialProviding = KeychainCredentialProvider(),
        usageClient: any UsageFetching = AnthropicUsageClient(),
        cache: any SnapshotCaching = FileSnapshotCache(),
        userDefaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() },
        connectionDefaultsKey: String = "hasAuthorizedClaudeCodeConnection"
    ) {
        self.credentialProvider = credentialProvider
        self.usageClient = usageClient
        self.cache = cache
        self.userDefaults = userDefaults
        self.now = now
        self.connectionDefaultsKey = connectionDefaultsKey
        self.isConnectionAuthorized = userDefaults.bool(forKey: connectionDefaultsKey)
    }

    var currentUtilization: Double? {
        snapshot?.currentSession?.utilization
    }

    var canRefresh: Bool {
        guard !isRefreshing, isConnectionAuthorized else {
            return false
        }
        return activeRetryAfter == nil
    }

    /// When Anthropic's cool-down is still running, the time it lifts — otherwise nil.
    /// Every refresh is blocked until then, including the button, so the UI has to say so
    /// rather than leave the user looking at a dead control.
    var activeRetryAfter: Date? {
        guard let retryAfterUntil, retryAfterUntil > now() else {
            return nil
        }
        return retryAfterUntil
    }

    var isStale: Bool {
        if case .stale = state {
            return true
        }
        return false
    }

    func start() async {
        guard !hasStarted else {
            return
        }
        hasStarted = true

        snapshot = await cache.load()
        scheduleResetRefresh()

        installMonitoring()

        if isConnectionAuthorized {
            if snapshot != nil {
                state = .stale(String(localized: "Cached data"))
            } else {
                state = .loading
            }
            await refresh(force: true, allowCredentialPrompt: true)
        } else {
            state = .disconnected
        }
    }

    func connect() async {
        guard !isRefreshing else {
            return
        }

        isRefreshing = true
        state = .loading
        do {
            let credential = try await credentialProvider.credential()
            activeCredential = credential
            isConnectionAuthorized = true
            userDefaults.set(true, forKey: connectionDefaultsKey)
            planName = credential.planName
            let fetchedSnapshot = try await usageClient.fetchUsage(accessToken: credential.accessToken)
            await accept(fetchedSnapshot)
        } catch {
            handleConnectionError(error)
        }
        isRefreshing = false
    }

    func popoverOpened() async {
        guard isConnectionAuthorized else {
            return
        }
        await refreshAutomaticallyIfStale(minimumAge: Self.minimumInteractiveRefreshAge)
    }

    func manualRefresh() async {
        await refresh(force: true, allowCredentialPrompt: true)
    }

    func retryAuthentication() async {
        if isConnectionAuthorized {
            await refresh(force: true, allowCredentialPrompt: true)
        } else {
            await connect()
        }
    }

    func refresh(force: Bool, allowCredentialPrompt: Bool = false) async {
        guard isConnectionAuthorized, !isRefreshing else {
            return
        }

        guard activeCredential != nil || allowCredentialPrompt else {
            return
        }

        let currentDate = now()
        if let retryAfterUntil, retryAfterUntil > currentDate {
            return
        }
        if !force {
            if let automaticBackoffUntil, automaticBackoffUntil > currentDate {
                return
            }
            if let lastAttemptAt, currentDate.timeIntervalSince(lastAttemptAt) < 10 {
                return
            }
        }

        isRefreshing = true
        lastAttemptAt = currentDate
        if snapshot == nil {
            state = .loading
        }

        do {
            await accept(try await fetchUsage())
        } catch {
            handleRefreshError(error)
        }
        isRefreshing = false
    }

    /// Fetches with the in-memory token and, if Claude Code rotated it out from under us,
    /// re-reads the keychain exactly once and retries with the new one.
    ///
    /// The re-read costs the user nothing: the keychain grant is bound to the app's code
    /// identity, and rewriting the item's data — which is all a rotation does — leaves the
    /// grant intact, so this never raises a dialog. A 401 on a *freshly* read token is a
    /// real login problem, so it is surfaced rather than retried; that bounds this at two
    /// requests and one keychain read per refresh.
    private func fetchUsage() async throws -> UsageSnapshot {
        if let activeCredential {
            do {
                return try await usageClient.fetchUsage(accessToken: activeCredential.accessToken)
            } catch UsageClientError.unauthorized {
                self.activeCredential = nil
            }
        }

        let credential = try await credentialProvider.credential()
        activeCredential = credential
        if let credentialPlanName = credential.planName {
            planName = credentialPlanName
        }
        return try await usageClient.fetchUsage(accessToken: credential.accessToken)
    }

    private func refreshAutomaticallyIfStale(
        minimumAge: TimeInterval = UsageStore.minimumAutomaticRefreshAge
    ) async {
        if let fetchedAt = snapshot?.fetchedAt,
           now().timeIntervalSince(fetchedAt) < minimumAge
        {
            return
        }
        await refresh(force: false, allowCredentialPrompt: false)
    }

    private func accept(_ newSnapshot: UsageSnapshot) async {
        updateCadence(with: newSnapshot)
        snapshot = newSnapshot
        state = .current
        consecutiveFailures = 0
        retryAfterUntil = nil
        automaticBackoffUntil = nil
        scheduleResetRefresh()
        scheduleNextPoll()
        await cache.save(newSnapshot)
    }

    /// Climbing utilization between two recent fetches switches to the fast cadence;
    /// `idleConfirmationCount` flat fetches in a row drop back to the slow one.
    private func updateCadence(with newSnapshot: UsageSnapshot) {
        guard let previous = snapshot,
              newSnapshot.fetchedAt.timeIntervalSince(previous.fetchedAt)
              <= Self.activityComparisonWindow
        else {
            return
        }

        if newSnapshot.showsIncreasedUsage(since: previous) {
            pollingCadence = .active
            unchangedFetchCount = 0
        } else {
            unchangedFetchCount += 1
            if unchangedFetchCount >= Self.idleConfirmationCount {
                pollingCadence = .idle
            }
        }
    }

    /// Delay until the fetch that confirms the next window rollover, or nil if none is due
    /// within the horizon. Pure so the schedule can be asserted without waiting on a clock.
    static func resetRefreshDelay(for snapshot: UsageSnapshot?, now: Date) -> TimeInterval? {
        guard let nextReset = snapshot?.nextReset(after: now) else {
            return nil
        }

        let delay = nextReset.timeIntervalSince(now) + resetRefreshGrace
        guard delay > 0, delay <= resetRefreshHorizon else {
            return nil
        }
        return delay
    }

    /// Puts one fetch right after the next window reset. The menu bar's percentage drops to
    /// zero at that moment, and waiting for the next uniform tick shows the old number for
    /// up to a quarter hour. This costs no extra requests in the steady state: it replaces
    /// a tick rather than adding to one, and it goes through the same `force: false` path,
    /// so `Retry-After` and the backoff still hold it back.
    private func scheduleResetRefresh() {
        resetRefreshTask?.cancel()
        resetRefreshTask = nil

        guard let delay = Self.resetRefreshDelay(for: snapshot, now: now()) else {
            return
        }

        resetRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            await self?.refresh(force: false, allowCredentialPrompt: false)
        }
    }

    private func handleConnectionError(_ error: any Error) {
        switch error {
        case CredentialError.accessDenied:
            activeCredential = nil
            isConnectionAuthorized = false
            userDefaults.set(false, forKey: connectionDefaultsKey)
            state = .failed(error.localizedDescription)
        case CredentialError.notFound,
             CredentialError.invalidPayload,
             CredentialError.keychain,
             UsageClientError.unauthorized:
            activeCredential = nil
            state = .authenticationRequired(error.localizedDescription)
        case let UsageClientError.rateLimited(retryAfter):
            registerTransientFailure(error: error, retryAfter: retryAfter)
        default:
            registerTransientFailure(error: error)
        }
    }

    private func handleRefreshError(_ error: any Error) {
        switch error {
        case CredentialError.notFound, UsageClientError.unauthorized:
            activeCredential = nil
            state = .authenticationRequired(error.localizedDescription)
        case CredentialError.accessDenied, CredentialError.invalidPayload, CredentialError.keychain:
            activeCredential = nil
            registerTransientFailure(error: error)
        case let UsageClientError.rateLimited(retryAfter):
            registerTransientFailure(error: error, retryAfter: retryAfter)
        default:
            registerTransientFailure(error: error)
        }
    }

    private func registerTransientFailure(error: any Error, retryAfter: TimeInterval? = nil) {
        let backoff: [TimeInterval] = [60, 120, 300, 900]
        let index = min(consecutiveFailures, backoff.count - 1)
        consecutiveFailures += 1

        let currentDate = now()
        if let retryAfter {
            retryAfterUntil = currentDate.addingTimeInterval(max(1, retryAfter))
            // A rate limit means the account's shared budget is exhausted: stop the fast
            // cadence until fresh evidence of activity arrives after recovery.
            pollingCadence = .idle
            unchangedFetchCount = 0
        }
        automaticBackoffUntil = currentDate.addingTimeInterval(backoff[index])
        scheduleNextPoll()

        let message = error.localizedDescription
        if snapshot != nil {
            state = .stale(message)
        } else {
            state = .failed(message)
        }
    }

    /// Delay until the next background poll, anchored to the last successful fetch. The
    /// anchoring is what kills the old worst case: with a fixed cadence, an off-cycle
    /// refresh (popover, wake, reset) could leave the next tick facing a too-young
    /// snapshot, so it skipped and the display aged for interval + gate. Anchored, a tick
    /// always arrives a full interval after the data it would replace. Gates that are
    /// still running push the tick past their expiry instead of wasting a wakeup on a
    /// refresh that would return early.
    static func nextPollDelay(
        lastFetchedAt: Date?,
        interval: TimeInterval,
        backoffUntil: Date?,
        retryAfterUntil: Date?,
        now: Date
    ) -> TimeInterval {
        var delay = interval
        if let lastFetchedAt {
            delay = min(max(interval - now.timeIntervalSince(lastFetchedAt), 60), interval)
        }
        for gate in [backoffUntil, retryAfterUntil] {
            if let gate, gate > now {
                delay = max(delay, gate.timeIntervalSince(now) + 1)
            }
        }
        return delay
    }

    private func scheduleNextPoll() {
        pollingTask?.cancel()

        let delay = Self.nextPollDelay(
            lastFetchedAt: snapshot?.fetchedAt,
            interval: pollingCadence.interval,
            backoffUntil: automaticBackoffUntil,
            retryAfterUntil: retryAfterUntil,
            now: now()
        )

        pollingTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            await self?.pollTick()
        }
    }

    private func pollTick() async {
        await refreshAutomaticallyIfStale(minimumAge: pollingCadence.minimumRefreshAge)
        // A gated or failed refresh re-arms here; a successful one already re-anchored
        // in `accept`, and the cancel-first schedule makes the second call harmless.
        scheduleNextPoll()
    }

    private func installMonitoring() {
        scheduleNextPoll()

        let refreshOnWake: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                await self.refreshAutomaticallyIfStale(
                    minimumAge: self.pollingCadence.minimumRefreshAge
                )
            }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main,
            using: refreshOnWake
        )

        // Display wake is not system wake: coming back to a Mac whose screen merely
        // slept should also find a fresh number without anyone clicking.
        screenWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main,
            using: refreshOnWake
        )
    }
}
