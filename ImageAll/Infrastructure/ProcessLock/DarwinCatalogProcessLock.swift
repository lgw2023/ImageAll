import Foundation
import Darwin

struct DarwinCatalogProcessLock: CatalogProcessLocking {
    func tryAcquire(at lockFileURL: URL) throws -> CatalogProcessLockAcquireResult {
        let runtimeDirectory = lockFileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
        } catch {
            throw CatalogProcessLockError.ioFailure
        }

        let fd = lockFileURL.path.withCString { path in
            open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard fd >= 0 else {
            throw CatalogProcessLockError.ioFailure
        }

        let lockResult = flock(fd, LOCK_EX | LOCK_NB)
        if lockResult == 0 {
            let token = CatalogProcessLockToken {
                flock(fd, LOCK_UN)
                close(fd)
            }
            return .acquired(token)
        }

        let savedErrno = errno
        close(fd)
        if savedErrno == EWOULDBLOCK {
            return .alreadyRunning
        }
        throw CatalogProcessLockError.ioFailure
    }
}
