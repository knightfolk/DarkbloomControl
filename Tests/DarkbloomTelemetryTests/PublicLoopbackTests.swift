import Foundation
import Network
import Testing
@testable import DarkbloomTelemetry

struct PublicLoopbackTests {
    @Test("public resource deadline ends an incomplete body independently of request timeout")
    func resourceDeadline() async throws {
        let server = try PublicLoopbackServer()
        defer { server.stop() }
        let base = try await server.start()
        let start = ContinuousClock.now
        var consumed = 0
        do {
            let request = URLRequest(url: base.appendingPathComponent("stall"), timeoutInterval: 30)
            let (bytes, _) = try await PublicHTTPSession.shared.bytes(for: request)
            defer { bytes.task.cancel() }
            for try await _ in bytes { consumed += 1 }
            Issue.record("Incomplete response ended successfully")
        } catch {
            #expect((error as? URLError)?.code == .timedOut)
        }
        #expect(consumed == 16384)
        let elapsed = start.duration(to: .now)
        #expect(elapsed >= .seconds(12))
        #expect(elapsed < .seconds(25))
    }

    @Test("cancelling a public byte stream terminates after the response has begun")
    func midstreamCancellation() async throws {
        let server = try PublicLoopbackServer()
        defer { server.stop() }
        let base = try await server.start()
        let signal = StreamStarted()
        let task = Task {
            do {
                let request = URLRequest(url: base.appendingPathComponent("stall"), timeoutInterval: 3)
                let (bytes, _) = try await PublicHTTPSession.shared.bytes(for: request)
                defer { bytes.task.cancel() }
                for try await _ in bytes { await signal.mark() }
                return false
            } catch {
                return error is CancellationError || (error as? URLError)?.code == .cancelled
            }
        }
        defer { task.cancel() }
        for _ in 0..<100 {
            if await signal.started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await signal.started)
        let start = ContinuousClock.now
        task.cancel()
        #expect(await task.value)
        #expect(start.duration(to: .now) < .seconds(1))
    }

    @Test("public session refuses a real redirect and does not replay a server cookie")
    func wirePolicy() async throws {
        let server = try PublicLoopbackServer()
        defer { server.stop() }
        let base = try await server.start()
        func request(_ path: String) -> URLRequest {
            URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 3)
        }
        let (_, response) = try await PublicHTTPSession.shared.data(for: request("redirect"))
        #expect((response as? HTTPURLResponse)?.statusCode == 302)
        _ = try await PublicHTTPSession.shared.data(for: request("cookie"))
        _ = try await PublicHTTPSession.shared.data(for: request("probe"))
        let requests = server.requests
        #expect(requests.count == 3)
        #expect(!requests.contains { $0.hasPrefix("GET /target ") })
        #expect(!requests.contains { $0.lowercased().contains("\r\ncookie:") })
        #expect(!requests.contains { $0.lowercased().contains("\r\nauthorization:") })
    }
}

/// Synthetic loopback-only HTTP fixture; no filesystem, credentials or public network.
private final class PublicLoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "PublicLoopbackServer")
    private var received: [String] = []
    private var connections: [NWConnection] = []
    var requests: [String] { queue.sync { received } }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.read(connection, data: Data())
        }
        listener.start(queue: queue)
        for _ in 0..<100 {
            if let port = listener.port, port.rawValue > 0 {
                return URL(string: "http://127.0.0.1:\(port.rawValue)")!
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw URLError(.cannotConnectToHost)
    }

    func stop() {
        listener.cancel()
        queue.sync { connections.forEach { $0.cancel() }; connections.removeAll() }
    }

    private func read(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] chunk, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = data
            if let chunk { buffer.append(chunk) }
            guard buffer.count <= 8192, error == nil else { connection.cancel(); return }
            let request = String(decoding: buffer, as: UTF8.self)
            guard request.contains("\r\n\r\n") else {
                if complete { connection.cancel() } else { self.read(connection, data: buffer) }
                return
            }
            self.received.append(request)
            if request.hasPrefix("GET /stall ") {
                let response = "HTTP/1.1 200 OK\r\nContent-Length: 65536\r\n\r\n" + String(repeating: "x", count: 16384)
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
                return
            }
            let redirect = request.hasPrefix("GET /redirect ")
            let headers = redirect ? "Location: /target\r\n" : "Set-Cookie: fixture=value; Path=/\r\n"
            let status = redirect ? "302 Found" : "200 OK"
            let response = "HTTP/1.1 \(status)\r\n\(headers)Content-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

private actor StreamStarted {
    private(set) var started = false
    func mark() { started = true }
}
