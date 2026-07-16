import Foundation
import XCTest
@testable import ClaudeStatus

final class UsageClientTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    func testSuccessfulRequestIncludesBearerTokenAndDecodesSnapshot() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.url, AnthropicUsageEndpoint.url)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = Data(
                #"{"five_hour":{"utilization":14,"resets_at":null},"seven_day":{"utilization":2,"resets_at":null}}"#.utf8
            )
            return (response, data)
        }

        let now = Date(timeIntervalSince1970: 42)
        let client = makeClient(now: now)
        let snapshot = try await client.fetchUsage(accessToken: "secret-token")

        XCTAssertEqual(snapshot.currentSession?.utilization, 14)
        XCTAssertEqual(snapshot.weeklyAllModels?.utilization, 2)
        XCTAssertEqual(snapshot.fetchedAt, now)
    }

    func testUnauthorizedResponse() async {
        URLProtocolStub.handler = Self.response(statusCode: 401)
        let client = makeClient()

        do {
            _ = try await client.fetchUsage(accessToken: "token")
            XCTFail("Expected unauthorized error")
        } catch let error as UsageClientError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRateLimitReadsRetryAfter() async {
        URLProtocolStub.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": "120"]
            )!
            return (response, Data())
        }
        let client = makeClient()

        do {
            _ = try await client.fetchUsage(accessToken: "token")
            XCTFail("Expected rate limit error")
        } catch let error as UsageClientError {
            XCTAssertEqual(error, .rateLimited(retryAfter: 120))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTimeoutIsPropagated() async {
        URLProtocolStub.handler = { _ in
            throw URLError(.timedOut)
        }
        let client = makeClient()

        do {
            _ = try await client.fetchUsage(accessToken: "token")
            XCTFail("Expected timeout")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEmptyPayloadIsRejected() async {
        URLProtocolStub.handler = Self.response(statusCode: 200, body: "{}")
        let client = makeClient()

        do {
            _ = try await client.fetchUsage(accessToken: "token")
            XCTFail("Expected empty payload error")
        } catch let error as UsageClientError {
            XCTAssertEqual(error, .emptyPayload)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEndpointPolicyAllowsOnlyExactAnthropicUsageURL() {
        XCTAssertTrue(AnthropicUsageEndpoint.isAllowed(AnthropicUsageEndpoint.url))
        XCTAssertFalse(AnthropicUsageEndpoint.isAllowed(URL(string: "http://api.anthropic.com/api/oauth/usage")!))
        XCTAssertFalse(AnthropicUsageEndpoint.isAllowed(URL(string: "https://evil.example/api/oauth/usage")!))
        XCTAssertFalse(AnthropicUsageEndpoint.isAllowed(URL(string: "https://api.anthropic.com.evil.example/api/oauth/usage")!))
        XCTAssertFalse(AnthropicUsageEndpoint.isAllowed(URL(string: "https://api.anthropic.com:444/api/oauth/usage")!))
        XCTAssertFalse(AnthropicUsageEndpoint.isAllowed(URL(string: "https://api.anthropic.com/api/oauth/usage?next=evil")!))
        XCTAssertFalse(AnthropicUsageEndpoint.isAllowed(URL(string: "https://user:pass@api.anthropic.com/api/oauth/usage")!))
    }

    func testSecureSessionDoesNotPersistCookiesOrCache() {
        let session = AnthropicUsageClient.makeSecureSession()

        XCTAssertEqual(session.configuration.httpShouldSetCookies, false)
        XCTAssertEqual(session.configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(session.configuration.httpCookieStorage)
        XCTAssertNil(session.configuration.urlCache)
        XCTAssertEqual(
            session.configuration.requestCachePolicy,
            .reloadIgnoringLocalAndRemoteCacheData
        )
        session.invalidateAndCancel()
    }

    func testRedirectDelegateRejectsRedirects() throws {
        let delegate = RedirectRejectingDelegate()
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: AnthropicUsageEndpoint.url)
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: AnthropicUsageEndpoint.url,
                statusCode: 302,
                httpVersion: nil,
                headerFields: ["Location": "https://evil.example/"]
            )
        )
        let redirectedRequest = URLRequest(url: URL(string: "https://evil.example/")!)
        let expectation = expectation(description: "redirect rejected")

        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: redirectedRequest
        ) { request in
            XCTAssertNil(request)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1)
        session.invalidateAndCancel()
    }

    private func makeClient(now: Date = Date(timeIntervalSince1970: 1)) -> AnthropicUsageClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return AnthropicUsageClient(
            session: URLSession(configuration: configuration),
            now: { now }
        )
    }

    private static func response(
        statusCode: Int,
        body: String = "",
        headers: [String: String] = [:]
    ) -> @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: headers
            )!
            return (response, Data(body.utf8))
        }
    }
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
