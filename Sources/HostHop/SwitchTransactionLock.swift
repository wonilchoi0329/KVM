import Darwin
import Foundation
import HostHopCore

final class SwitchTransactionLock {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire() throws -> SwitchTransactionLock {
        let directory = ConfigurationStore.defaultURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(directory.path, 0o700) == 0 else {
            throw SwitchLockError.io(String(cString: strerror(errno)))
        }
        let path = directory.appendingPathComponent("switch.lock").path
        let descriptor = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw SwitchLockError.io(String(cString: strerror(errno))) }
        guard fchmod(descriptor, 0o600) == 0 else {
            let message = String(cString: strerror(errno))
            close(descriptor)
            throw SwitchLockError.io(message)
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid() else {
            close(descriptor)
            throw SwitchLockError.unsafeFile
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let currentError = errno
            close(descriptor)
            if currentError == EWOULDBLOCK { throw SwitchLockError.busy }
            throw SwitchLockError.io(String(cString: strerror(currentError)))
        }
        return SwitchTransactionLock(descriptor: descriptor)
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

enum SwitchLockError: LocalizedError {
    case busy
    case unsafeFile
    case io(String)

    var errorDescription: String? {
        switch self {
        case .busy: return "Another HostHop switch is already in progress"
        case .unsafeFile: return "The HostHop switch lock is not a safe user-owned regular file"
        case .io(let message): return "Cannot secure the HostHop switch lock: \(message)"
        }
    }
}
