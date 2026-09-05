import Foundation
import Testing
@testable import DarkbloomTelemetry

struct PublicSessionTests {
    @Test("public session has no cookie credential or cache persistence")
    func isolation() {
        let session = PublicHTTPSession.shared
        let configuration = session.configuration
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.timeoutIntervalForResource > 0)
        #expect(configuration.timeoutIntervalForResource <= 15)
        #expect(session.delegate is PublicSessionPolicy)
    }
    @Test("public transport rejects redirect destinations before a follow-up request")
    func redirects() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let origin = try #require(URL(string: "https://api.darkbloom.dev/v1/pricing"))
        let task = session.dataTask(with: origin)
        defer { task.cancel() }
        let response = try #require(HTTPURLResponse(url: origin, statusCode: 302, httpVersion: nil, headerFields: nil))
        for destination in ["https://elsewhere.invalid/path", "http://api.darkbloom.dev/path", "https://api.darkbloom.dev/new"] {
            let result: URLRequest? = await withCheckedContinuation { continuation in
                PublicSessionPolicy().urlSession(session, task: task, willPerformHTTPRedirection: response,
                    newRequest: URLRequest(url: URL(string: destination)!)) { continuation.resume(returning: $0) }
            }
            #expect(result == nil)
        }
    }
}
