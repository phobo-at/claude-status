import Foundation

protocol UsageFetching: Sendable {
    func fetchUsage(accessToken: String) async throws -> UsageSnapshot
}

enum UsageClientError: LocalizedError, Equatable, Sendable {
    case untrustedEndpoint
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(Int)
    case invalidResponse
    case emptyPayload

    var errorDescription: String? {
        switch self {
        case .untrustedEndpoint:
            "Die sichere Claude-Verbindung konnte nicht bestätigt werden."
        case .unauthorized:
            "Die Claude-Anmeldung ist abgelaufen."
        case .rateLimited:
            "Claude hat zu viele Aktualisierungen erhalten."
        case let .serverError(statusCode):
            "Claude ist vorübergehend nicht erreichbar (HTTP \(statusCode))."
        case .invalidResponse:
            "Claude hat eine unerwartete Antwort gesendet."
        case .emptyPayload:
            "Claude hat keine Nutzungslimits zurückgegeben."
        }
    }
}

enum AnthropicUsageEndpoint {
    static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func isAllowed(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return components.scheme == "https"
            && components.host == "api.anthropic.com"
            && components.port == nil
            && components.path == "/api/oauth/usage"
            && components.user == nil
            && components.password == nil
            && components.query == nil
            && components.fragment == nil
    }
}

final class RedirectRejectingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

struct AnthropicUsageClient: UsageFetching {
    private let session: URLSession
    private let now: @Sendable () -> Date

    init(
        session: URLSession = Self.makeSecureSession(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.now = now
    }

    func fetchUsage(accessToken: String) async throws -> UsageSnapshot {
        let endpoint = AnthropicUsageEndpoint.url
        guard AnthropicUsageEndpoint.isAllowed(endpoint) else {
            throw UsageClientError.untrustedEndpoint
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              let responseURL = response.url,
              responseURL == endpoint,
              AnthropicUsageEndpoint.isAllowed(responseURL)
        else {
            throw UsageClientError.untrustedEndpoint
        }
        guard data.count <= 1024 * 1024 else {
            throw UsageClientError.invalidResponse
        }

        switch response.statusCode {
        case 200:
            let payload: UsagePayload
            do {
                payload = try JSONDecoder().decode(UsagePayload.self, from: data)
            } catch {
                throw UsageClientError.invalidResponse
            }
            let snapshot = payload.snapshot(fetchedAt: now())
            guard snapshot.hasAnyLimit else {
                throw UsageClientError.emptyPayload
            }
            return snapshot
        case 401, 403:
            throw UsageClientError.unauthorized
        case 429:
            throw UsageClientError.rateLimited(
                retryAfter: Self.retryAfter(from: response, now: now())
            )
        case 500 ... 599:
            throw UsageClientError.serverError(response.statusCode)
        default:
            throw UsageClientError.invalidResponse
        }
    }

    static func makeSecureSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        return URLSession(
            configuration: configuration,
            delegate: RedirectRejectingDelegate(),
            delegateQueue: nil
        )
    }

    private static func retryAfter(from response: HTTPURLResponse, now: Date) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else {
            return nil
        }
        if let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces)), seconds >= 0 {
            return seconds
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let retryDate = formatter.date(from: value) else {
            return nil
        }
        return max(0, retryDate.timeIntervalSince(now))
    }
}
