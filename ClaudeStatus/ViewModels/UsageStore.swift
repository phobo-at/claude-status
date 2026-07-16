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
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var planName: String?
    @Published private(set) var state: UsageDisplayState = .disconnected
    @Published private(set) var isRefreshing = false
    @Published private(set) var isConnectionAuthorized: Bool
    @Published private(set) var nextRefreshAllowedAt: Date?

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
        guard let nextRefreshAllowedAt else {
            return true
        }
        return nextRefreshAllowedAt <= now()
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
        await refresh(force: false, allowCredentialPrompt: false)
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
        if let nextRefreshAllowedAt, nextRefreshAllowedAt > currentDate {
            return
        }
        if !force, let lastAttemptAt, currentDate.timeIntervalSince(lastAttemptAt) < 10 {
            return
        }

        isRefreshing = true
        lastAttemptAt = currentDate
        if snapshot == nil {
            state = .loading
        }

        do {
            let credential: ClaudeCredential
            if let activeCredential {
                credential = activeCredential
            } else {
                credential = try await credentialProvider.credential()
                activeCredential = credential
            }
            if let credentialPlanName = credential.planName {
                planName = credentialPlanName
            }
            let fetchedSnapshot = try await usageClient.fetchUsage(
                accessToken: credential.accessToken
            )
            await accept(fetchedSnapshot)
        } catch {
            handleRefreshError(error)
        }
        isRefreshing = false
    }

    private func accept(_ newSnapshot: UsageSnapshot) async {
        snapshot = newSnapshot
        state = .current
        consecutiveFailures = 0
        nextRefreshAllowedAt = nil
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
        let delay = max(1, retryAfter ?? backoff[index])
        consecutiveFailures += 1
        nextRefreshAllowedAt = now().addingTimeInterval(delay)

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
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
                guard !Task.isCancelled else {
                    return
                }
                await self?.refresh(force: false, allowCredentialPrompt: false)
            }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh(force: true, allowCredentialPrompt: false)
            }
        }
    }
}
