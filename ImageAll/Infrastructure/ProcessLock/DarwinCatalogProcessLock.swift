import Foundation
import Darwin

struct DarwinCatalogProcessLock: CatalogProcessLocking, @unchecked Sendable {
    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func tryAcquire(at lockFileURL: URL) throws -> CatalogProcessLockAcquireResult {
        let runtimeDirectory = lockFileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
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

        close(fd)
        if errno == EWOULDBLOCK {
            return .alreadyRunning
        }
        throw CatalogProcessLockError.ioFailure
    }
}
