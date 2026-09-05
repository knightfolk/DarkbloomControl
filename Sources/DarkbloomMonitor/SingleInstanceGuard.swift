import Darwin
import Foundation

/// The result of trying to claim the monitor's process-wide user lock.
enum SingleInstanceAcquireResult: Equatable, Sendable {
    case acquired
    case alreadyRunning
}

/// Human-readable, non-secret information left in the lock file for diagnosis.
///
/// The metadata is never used to decide whether another process owns the lock.
/// The kernel-held descriptor is the authority, so a crashed process is
/// recovered automatically when its descriptor is closed by the kernel.
struct SingleInstanceOwnerMetadata: Codable, Equatable, Sendable {
    let lockVersion: Int
    let pid: Int32
    let launchedAt: Date
    let executablePath: String
    let bundleIdentifier: String?
    let bundlePath: String?
    let ownerToken: UUID

    static func current(
        processInfo: ProcessInfo = .processInfo,
        bundle: Bundle = .main,
        now: @Sendable () -> Date = Date.init
    ) -> Self {
        Self(
            lockVersion: 1,
            pid: processInfo.processIdentifier,
            launchedAt: now(),
            executablePath: processInfo.arguments.first
                ?? bundle.executableURL?.path
                ?? "unknown",
            bundleIdentifier: bundle.bundleIdentifier,
            bundlePath: bundle.bundleURL.path,
            ownerToken: UUID()
        )
    }

    static func test(
        pid: Int32,
        executablePath: String = "/test/DarkbloomMonitor"
    ) -> Self {
        Self(
            lockVersion: 1,
            pid: pid,
            launchedAt: Date(timeIntervalSince1970: 1_750_000_000),
            executablePath: executablePath,
            bundleIdentifier: "dev.darkbloom.monitor.tests",
            bundlePath: "/test/DarkbloomMonitor.app",
            ownerToken: UUID()
        )
    }
}

enum SingleInstanceGuardError: Error, Equatable, LocalizedError, Sendable {
    case directoryCreationFailed(path: String, reason: String)
    case openFailed(path: String, errno: Int32)
    case permissionFailed(path: String, errno: Int32)
    case metadataWriteFailed(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .directoryCreationFailed(let path, let reason):
            return "Could not create the single-instance directory at \(path): \(reason)"
        case .openFailed(let path, let errno):
            return "Could not open the single-instance lock at \(path) (errno \(errno))"
        case .permissionFailed(let path, let errno):
            return "Could not secure the single-instance lock at \(path) (errno \(errno))"
        case .metadataWriteFailed(let path, let reason):
            return "Could not write single-instance diagnostics at \(path): \(reason)"
        }
    }
}

/// A process-scoped advisory lock shared by the SwiftPM executable and the
/// bundled app. It never identifies or terminates another process.
final class SingleInstanceGuard {
    static let lockFileName = "darkbloom-monitor.lock"

    static func defaultLockURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/Darkbloom Monitor", isDirectory: true)
            .appendingPathComponent(lockFileName, isDirectory: false)
    }

    private let lockURL: URL
    private let metadata: SingleInstanceOwnerMetadata
    private var descriptor: Int32 = -1

    init(
        lockURL: URL = SingleInstanceGuard.defaultLockURL(),
        metadata: SingleInstanceOwnerMetadata = .current()
    ) {
        self.lockURL = lockURL.standardizedFileURL
        self.metadata = metadata
    }

    var isOwner: Bool { descriptor >= 0 }

    /// Claims the lock without trusting the contents of the lock file.
    ///
    /// `O_EXLOCK` is released automatically by the kernel if this process
    /// crashes. A stale or malformed metadata payload therefore never blocks a
    /// new launch, while a held descriptor always wins over stale metadata.
    @discardableResult
    func acquire() throws -> SingleInstanceAcquireResult {
        if isOwner { return .acquired }

        try createParentDirectoryIfNeeded()
        let path = lockURL.path
        let openedDescriptor = path.withCString { pathPointer in
            Darwin.open(
                pathPointer,
                O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_EXLOCK | O_NONBLOCK,
                mode_t(0o600)
            )
        }
        guard openedDescriptor >= 0 else {
            let lockError = errno
            if lockError == EWOULDBLOCK || lockError == EAGAIN {
                return .alreadyRunning
            }
            throw SingleInstanceGuardError.openFailed(path: path, errno: lockError)
        }

        // The mode passed to open() applies only on creation. Re-apply it
        // after every successful claim so diagnostics remain user-scoped.
        guard Darwin.fchmod(openedDescriptor, mode_t(0o600)) == 0 else {
            let permissionError = errno
            Darwin.close(openedDescriptor)
            throw SingleInstanceGuardError.permissionFailed(path: path, errno: permissionError)
        }

        descriptor = openedDescriptor
        do {
            try writeMetadata()
            return .acquired
        } catch {
            release()
            throw error
        }
    }

    /// Releases only this instance's descriptor. It is safe to call more than
    /// once; no process lookup or termination is performed.
    func release() {
        let ownedDescriptor = descriptor
        guard ownedDescriptor >= 0 else { return }
        descriptor = -1
        // A child can briefly inherit this open file description before
        // O_CLOEXEC takes effect. Explicit release must not wait for that
        // child to exec/exit and close its copy of the descriptor.
        while flock(ownedDescriptor, LOCK_UN) == -1 && errno == EINTR {}
        Darwin.close(ownedDescriptor)
    }

    deinit {
        release()
    }

    private func createParentDirectoryIfNeeded() throws {
        let parent = lockURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw SingleInstanceGuardError.directoryCreationFailed(
                path: parent.path,
                reason: error.localizedDescription
            )
        }
    }

    private func writeMetadata() throws {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(metadata)
        } catch {
            throw SingleInstanceGuardError.metadataWriteFailed(
                path: lockURL.path,
                reason: error.localizedDescription
            )
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        do {
            try handle.truncate(atOffset: 0)
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            throw SingleInstanceGuardError.metadataWriteFailed(
                path: lockURL.path,
                reason: error.localizedDescription
            )
        }
    }
}

/// Startup policy used by the app delegate before it constructs any status
/// item or other UI. A duplicate terminates only the current application via
/// the injected closure; the lock owner is never inspected or signalled.
@MainActor
enum DarkbloomMonitorStartupGate {
    @discardableResult
    static func acquireOrTerminate(
        instanceGuard: SingleInstanceGuard,
        terminate: @escaping () -> Void
    ) -> Bool {
        do {
            switch try instanceGuard.acquire() {
            case .acquired:
                return true
            case .alreadyRunning:
                terminate()
                return false
            }
        } catch {
            // A lock that cannot be verified is unsafe to run beside another
            // possible instance, so fail closed without touching any PID.
            terminate()
            return false
        }
    }
}
