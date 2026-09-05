import Foundation
import Darwin
import Testing
@testable import DarkbloomMonitor

@Suite("Single-instance guard", .serialized)
struct SingleInstanceGuardTests {
    @Test("the app delegate supports the Objective-C no-argument initializer")
    @MainActor
    func appDelegateSupportsRuntimeInitialization() {
        let delegateType: NSObject.Type = DarkbloomMonitorAppDelegate.self

        let delegate = delegateType.init()

        #expect(delegate is DarkbloomMonitorAppDelegate)
    }

    @Test("first owner acquires the user-scoped lock and records diagnostics")
    func firstOwnerAcquires() throws {
        let lockURL = try makeLockURL()
        defer { removeLockDirectory(for: lockURL) }

        let owner = SingleInstanceGuard(
            lockURL: lockURL,
            metadata: .test(pid: 101, executablePath: "/tmp/DarkbloomMonitor")
        )

        #expect(try owner.acquire() == .acquired)
        #expect(owner.isOwner)
        let metadata = try metadataDecoder().decode(
            SingleInstanceOwnerMetadata.self,
            from: Data(contentsOf: lockURL)
        )
        #expect(metadata.pid == 101)
        #expect(metadata.executablePath == "/tmp/DarkbloomMonitor")
        #expect(metadata.lockVersion == 1)
    }

    @Test("a duplicate owner is rejected without changing the current owner metadata")
    func duplicateOwnerIsRejected() throws {
        let lockURL = try makeLockURL()
        defer { removeLockDirectory(for: lockURL) }

        let first = SingleInstanceGuard(
            lockURL: lockURL,
            metadata: .test(pid: 201, executablePath: "/first/DarkbloomMonitor")
        )
        let duplicate = SingleInstanceGuard(
            lockURL: lockURL,
            metadata: .test(pid: 202, executablePath: "/second/DarkbloomMonitor")
        )

        #expect(try first.acquire() == .acquired)
        let firstMetadata = try Data(contentsOf: lockURL)

        #expect(try duplicate.acquire() == .alreadyRunning)
        #expect(!duplicate.isOwner)
        #expect(try Data(contentsOf: lockURL) == firstMetadata)
    }

    @Test("concurrent launch attempts produce exactly one owner")
    func concurrentOwnersProduceOneWinner() async throws {
        let lockURL = try makeLockURL()
        defer { removeLockDirectory(for: lockURL) }
        let barrier = AcquisitionBarrier(participants: 2)

        let outcomes = await withTaskGroup(of: SingleInstanceAcquireResult?.self) {
            group -> [SingleInstanceAcquireResult] in
            for index in 0..<2 {
                group.addTask {
                    let owner = SingleInstanceGuard(
                        lockURL: lockURL,
                        metadata: .test(
                            pid: Int32(301 + index),
                            executablePath: "/attempt-\(index)/DarkbloomMonitor"
                        )
                    )
                    let result = try? owner.acquire()
                    await barrier.arriveAndWait()
                    return result
                }
            }

            var collected: [SingleInstanceAcquireResult] = []
            for await outcome in group {
                if let outcome { collected.append(outcome) }
            }
            return collected
        }

        #expect(outcomes.filter { $0 == .acquired }.count == 1)
        #expect(outcomes.filter { $0 == .alreadyRunning }.count == 1)
    }

    @Test("release makes the lock available to a later launch")
    func releaseAndReacquire() throws {
        let lockURL = try makeLockURL()
        defer { removeLockDirectory(for: lockURL) }

        let first = SingleInstanceGuard(lockURL: lockURL, metadata: .test(pid: 401))
        let second = SingleInstanceGuard(lockURL: lockURL, metadata: .test(pid: 402))

        #expect(try first.acquire() == .acquired)
        #expect(try second.acquire() == .alreadyRunning)

        first.release()

        #expect(!first.isOwner)
        #expect(try second.acquire() == .acquired)
        #expect(second.isOwner)
    }

    @Test("owner release unlocks while a duplicate of its open file description remains")
    func releaseWithInheritedDescriptor() throws {
        let lockURL = try makeLockURL()
        defer { removeLockDirectory(for: lockURL) }
        let first = SingleInstanceGuard(lockURL: lockURL, metadata: .test(pid: 411))
        let second = SingleInstanceGuard(lockURL: lockURL, metadata: .test(pid: 412))
        #expect(try first.acquire() == .acquired)
        // dup shares the open file description, as an inherited pre-exec
        // descriptor would, without forking the multithreaded Swift runtime.
        var expected = stat()
        try #require(stat(lockURL.path, &expected) == 0)
        let descriptor = try #require((0..<getdtablesize()).first { fd in
            var actual = stat()
            return fstat(fd, &actual) == 0 && actual.st_dev == expected.st_dev && actual.st_ino == expected.st_ino
        })
        let duplicate = dup(descriptor)
        try #require(duplicate >= 0)
        defer { close(duplicate) }
        #expect(try second.acquire() == .alreadyRunning)
        first.release()
        #expect(try second.acquire() == .acquired)
    }

    @Test("stale or malformed metadata does not block recovery when no descriptor is held")
    func staleMetadataDoesNotBlockRecovery() throws {
        let lockURL = try makeLockURL()
        defer { removeLockDirectory(for: lockURL) }
        try Data(#"{"pid":999999,"executablePath":"/gone/DarkbloomMonitor"}"#.utf8)
            .write(to: lockURL)

        let owner = SingleInstanceGuard(lockURL: lockURL, metadata: .test(pid: 501))

        #expect(try owner.acquire() == .acquired)
        #expect(try metadataDecoder().decode(
            SingleInstanceOwnerMetadata.self,
            from: Data(contentsOf: lockURL)
        ).pid == 501)
    }

    @Test("a held descriptor wins over stale metadata and is never force-killed")
    func heldDescriptorIsAuthoritative() throws {
        let lockURL = try makeLockURL()
        defer { removeLockDirectory(for: lockURL) }

        let owner = SingleInstanceGuard(lockURL: lockURL, metadata: .test(pid: 601))
        let duplicate = SingleInstanceGuard(lockURL: lockURL, metadata: .test(pid: 602))
        #expect(try owner.acquire() == .acquired)

        let staleMetadata = Data(#"{"pid":1,"executablePath":"/unrelated/process"}"#.utf8)
        try staleMetadata.write(to: lockURL)

        #expect(try duplicate.acquire() == .alreadyRunning)
        #expect(!duplicate.isOwner)
        #expect(try Data(contentsOf: lockURL) == staleMetadata)
    }

    @Test("duplicate startup terminates itself before startup can continue")
    @MainActor
    func duplicateStartupFailsClosed() throws {
        let lockURL = try makeLockURL()
        defer { removeLockDirectory(for: lockURL) }

        let first = SingleInstanceGuard(lockURL: lockURL, metadata: .test(pid: 701))
        let duplicate = SingleInstanceGuard(lockURL: lockURL, metadata: .test(pid: 702))
        #expect(try first.acquire() == .acquired)

        var terminationCount = 0
        let shouldContinue = DarkbloomMonitorStartupGate.acquireOrTerminate(
            instanceGuard: duplicate,
            terminate: { terminationCount += 1 }
        )

        #expect(!shouldContinue)
        #expect(terminationCount == 1)
        #expect(!duplicate.isOwner)
    }

    private func makeLockURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("darkbloom-instance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("monitor.lock")
    }

    private func removeLockDirectory(for lockURL: URL) {
        try? FileManager.default.removeItem(at: lockURL.deletingLastPathComponent())
    }

    private func metadataDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private actor AcquisitionBarrier {
    private let participants: Int
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(participants: Int) {
        self.participants = participants
    }

    func arriveAndWait() async {
        arrivals += 1
        guard arrivals < participants else {
            let waiters = self.waiters
            self.waiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
