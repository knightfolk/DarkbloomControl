import Foundation
import Testing
@testable import DarkbloomTelemetry

@Suite("Public HTTP transport")
struct PublicTransportTests {
    @Test("opt-in live public endpoints decode through the production session",
          .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_PUBLIC"] == "1"),
          arguments: Endpoint.allCases)
    func livePublic(endpoint: Endpoint) async throws {
        let date = Date()
        #expect(try await endpoint.fetch(session: PublicHTTPSession.shared, at: date) == date)
    }

    enum Endpoint: String, CaseIterable, Sendable {
        case catalog, pricing, capacity, series

        func fetch(session: URLSession, at date: Date) async throws -> Date {
            switch self {
            case .catalog: return try await PublicCatalogClient(session: session).fetch(at: date).capturedAt
            case .pricing: return try await PublicPricingClient(session: session).fetch(at: date).capturedAt
            case .capacity: return try await PublicNetworkCapacityClient(session: session).fetch(at: date).capturedAt
            case .series: return try await NetworkSeriesClient(session: session).fetch(at: date).capturedAt
            }
        }

        func statusError(_ status: Int) -> any Error {
            switch self {
            case .catalog: PublicCatalogError.httpStatus(status)
            case .pricing: PublicPricingError.httpStatus(status)
            case .capacity: NetworkCapacityError.httpStatus(status)
            case .series: NetworkSeriesError.httpStatus(status)
            }
        }
    }

    @Test("real clients decode successful HTTP bodies through the exact byte limit", arguments: Endpoint.allCases, ["success", "exact-limit"])
    func success(endpoint: Endpoint, mode: String) async throws {
        let session = makeSession(mode: mode)
        defer { session.invalidateAndCancel() }
        let date = Date(timeIntervalSince1970: 2_000_000)
        #expect(try await endpoint.fetch(session: session, at: date) == date)
    }

    @Test("HTTP failures retain source-specific status codes", arguments: Endpoint.allCases, [401, 403, 404, 429, 500])
    func statuses(endpoint: Endpoint, status: Int) async {
        let session = makeSession(mode: String(status))
        defer { session.invalidateAndCancel() }
        do {
            _ = try await endpoint.fetch(session: session, at: Date())
            Issue.record("Accepted an HTTP failure")
        } catch {
            #expect(sameError(error, endpoint.statusError(status)))
        }
    }

    @Test("declared and streamed oversized responses are rejected before JSON decoding", arguments: Endpoint.allCases, ["declared-large", "streamed-large"])
    func sizeLimits(endpoint: Endpoint, mode: String) async {
        let session = makeSession(mode: mode)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await endpoint.fetch(session: session, at: Date())
            Issue.record("Accepted oversized response")
        } catch {
            switch endpoint {
            case .catalog: #expect(error as? PublicCatalogError == .responseTooLarge)
            case .pricing: #expect(error as? PublicPricingError == .responseTooLarge)
            case .capacity: #expect(error as? NetworkCapacityError == .responseTooLarge)
            case .series: #expect(error as? NetworkSeriesError == .responseTooLarge)
            }
        }
    }

    @Test("malformed success bodies never publish a snapshot", arguments: Endpoint.allCases)
    func malformed(endpoint: Endpoint) async {
        let session = makeSession(mode: "malformed")
        defer { session.invalidateAndCancel() }
        await #expect(throws: (any Error).self) {
            _ = try await endpoint.fetch(session: session, at: Date())
        }
    }

    @Test("transport timeout propagates without becoming empty data", arguments: Endpoint.allCases)
    func timeout(endpoint: Endpoint) async {
        let session = makeSession(mode: "timeout")
        defer { session.invalidateAndCancel() }
        do {
            _ = try await endpoint.fetch(session: session, at: Date())
            Issue.record("Accepted transport timeout")
        } catch {
            #expect((error as? URLError)?.code == .timedOut)
        }
    }

    @Test("already cancelled fetches never start a URL request", arguments: Endpoint.allCases)
    func cancelled(endpoint: Endpoint) async {
        let session = makeSession(mode: "must-not-start")
        defer { session.invalidateAndCancel() }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await endpoint.fetch(session: session, at: Date())
                Issue.record("Accepted cancelled request")
            } catch {
                #expect(error is CancellationError)
            }
        }
        await task.value
    }

    private func makeSession(mode: String) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PublicFixtureProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Fixture-Mode": mode]
        return URLSession(configuration: configuration)
    }

    private func sameError(_ actual: any Error, _ expected: any Error) -> Bool {
        if let expected = expected as? PublicCatalogError { return actual as? PublicCatalogError == expected }
        if let expected = expected as? PublicPricingError { return actual as? PublicPricingError == expected }
        if let expected = expected as? NetworkCapacityError { return actual as? NetworkCapacityError == expected }
        if let expected = expected as? NetworkSeriesError { return actual as? NetworkSeriesError == expected }
        return false
    }
}

/// Per-session scenarios avoid shared mutable handlers across concurrent tests.
private final class PublicFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        #expect(request.httpMethod == "GET")
        #expect(request.url?.scheme == "https")
        #expect(request.url?.host == "api.darkbloom.dev")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.timeoutInterval == 15)
        guard let mode = request.value(forHTTPHeaderField: "X-Fixture-Mode"), mode != "must-not-start" else {
            Issue.record("Unexpected HTTP acquisition")
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        if mode == "timeout" {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        var body: Data
        switch mode {
        case "declared-large": body = Data()
        case "streamed-large": body = Data(repeating: 32, count: 256 * 1_024 + 1)
        case "malformed": body = Data("not JSON".utf8)
        default:
            switch request.url?.path {
            case "/v1/models/catalog", "/v1/models/capacity": body = Data(#"{"models":[]}"#.utf8)
            case "/v1/pricing": body = Data(#"{"prices":[]}"#.utf8)
            case "/v1/network/series":
                #expect(request.url?.query == "window=24h")
                body = Data(#"{"window":"24h","bucket_seconds":1800,"start_at":"2026-09-04T00:00:00Z","end_at":"2026-09-05T00:00:00Z","updated_at":"2026-09-05T00:01:00Z","time_series":[]}"#.utf8)
            default:
                Issue.record("Unexpected public endpoint")
                body = Data()
            }
        }
        if mode == "exact-limit" {
            body.append(Data(repeating: 32, count: 256 * 1_024 - body.count))
        }
        var headers = ["Content-Type": "application/json"]
        if mode == "declared-large" { headers["Content-Length"] = "262145" }
        let response = HTTPURLResponse(url: request.url!, statusCode: Int(mode) ?? 200,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
