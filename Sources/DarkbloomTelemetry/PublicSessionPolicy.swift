import Foundation

/// Public endpoints must not inherit authenticated cookies, credentials or cache.
enum PublicHTTPSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration, delegate: PublicSessionPolicy(), delegateQueue: nil)
    }()
}

final class PublicSessionPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Even same-origin endpoint changes require a contract review.
        completionHandler(nil)
    }
}
