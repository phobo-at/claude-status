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
    /// so the budget is shared and the app has to spend it sparingly. Every window this
    /// app shows moves over hours or days; polling faster than this buys nothing and
    /// costs the account its quota.
    static let automaticRefreshInterval: TimeInterval = 15 * 60
    static let minimumAutomaticRefreshAge: TimeInterval = 10 * 60

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
    private var pollingTask: Task<Void, Never>?
    private var wakeObserver: (any NSObjectProtocol)?

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

        installMonitoring()

        if isConnectionAuthorized {
            if snapshot != nil {
                state = .stale("Gespeicherter Stand")
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
        await refreshAutomaticallyIfStale()
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

    private func refreshAutomaticallyIfStale() async {
        if let fetchedAt = snapshot?.fetchedAt,
           now().timeIntervalSince(fetchedAt) < Self.minimumAutomaticRefreshAge
        {
            return
        }
        await refresh(force: false, allowCredentialPrompt: false)
    }

    private func accept(_ newSnapshot: UsageSnapshot) async {
        snapshot = newSnapshot
        state = .current
        consecutiveFailures = 0
        retryAfterUntil = nil
        automaticBackoffUntil = nil
        await cache.save(newSnapshot)
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
        }
        automaticBackoffUntil = currentDate.addingTimeInterval(backoff[index])

        let message = error.localizedDescription
        if snapshot != nil {
            state = .stale(message)
        } else {
            state = .failed(message)
        }
    }

    private func installMonitoring() {
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(Self.automaticRefreshInterval))
                } catch {
                    return
                }
                guard !Task.isCancelled else {
                    return
                }
                await self?.refreshAutomaticallyIfStale()
            }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshAutomaticallyIfStale()
            }
        }
    }
}
