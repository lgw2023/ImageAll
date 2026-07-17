import CoreServices
import Foundation
import GRDB

/// Read-only file resource facts used by media classification and move probing.
protocol FolderFileResourceReading: Sendable {
    func fileSizeBytes(for url: URL) -> Int64?
    func modifiedAtNs(for url: URL) -> Int64?
    func resourceIdentifier(for url: URL) -> Data?
}

struct FoundationFolderFileResourceReader: FolderFileResourceReading, Sendable {
    func fileSizeBytes(for url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize
        else {
            return nil
        }
        return Int64(size)
    }

    func modifiedAtNs(for url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let date = values.contentModificationDate
        else {
            return nil
        }
        return Int64(date.timeIntervalSince1970 * 1_000_000_000)
    }

    func resourceIdentifier(for url: URL) -> Data? {
        let values = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey])
        guard let object = values?.fileResourceIdentifier else {
            return nil
        }
        if let data = object as? Data {
            return data
        }
        if let number = object as? NSNumber {
            return number.stringValue.data(using: .utf8)
        }
        return nil
    }
}

/// Enumeration-time resource reads for directory entries.
protocol FolderEnumerationResourceReading: Sendable {
    func resourceValues(for url: URL, keys: Set<URLResourceKey>) throws -> URLResourceValues
    func isAliasFile(for url: URL) -> Bool?
}

extension FolderEnumerationResourceReading {
    func isAliasFile(for url: URL) -> Bool? { nil }
}

struct FoundationEnumerationResourceReader: FolderEnumerationResourceReading, Sendable {
    func resourceValues(for url: URL, keys: Set<URLResourceKey>) throws -> URLResourceValues {
        try url.resourceValues(forKeys: keys)
    }
}

struct FolderSourceDirtyTrigger: Sendable {
    let database: CatalogDatabase
    let clock: any JobClock
    let idGenerator: @Sendable () -> UUID

    init(
        database: CatalogDatabase,
        clock: any JobClock = SystemJobClock(),
        idGenerator: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.database = database
        self.clock = clock
        self.idGenerator = idGenerator
    }

    @discardableResult
    func recordEventBatch(sourceID: UUID, eventCount: Int) throws -> Bool {
        let delta = max(1, eventCount)
        return try database.pool.write { db in
            let sourceIDString = sourceID.uuidString.lowercased()
            try db.execute(
                sql: """
                UPDATE source SET dirty_epoch = dirty_epoch + ?, updated_at_ms = ?
                WHERE id = ? AND kind = 'folder' AND state = 'active'
                """,
                arguments: [delta, clock.nowMs, sourceIDString]
            )
            guard db.changesCount == 1 else { return false }
            try enqueueIfNeeded(sourceID: sourceID, db: db)
            return true
        }
    }

    @discardableResult
    func enqueueInitialReconcile(sourceID: UUID) throws -> Bool {
        try database.pool.write { db in
            let isActive = try Bool.fetchOne(
                db,
                sql: """
                SELECT EXISTS(
                    SELECT 1 FROM source
                    WHERE id = ? AND kind = 'folder' AND state = 'active'
                )
                """,
                arguments: [sourceID.uuidString.lowercased()]
            ) ?? false
            guard isActive else { return false }
            try enqueueIfNeeded(sourceID: sourceID, db: db)
            return true
        }
    }

    private func enqueueIfNeeded(sourceID: UUID, db: Database) throws {
        let coalescingKey = FolderReconcileJobFactory.coalescingKey(sourceID: sourceID)
        let activeJobExists = try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS(
                SELECT 1 FROM job
                WHERE coalescing_key = ?
                    AND state IN ('pending', 'running', 'paused', 'retryableFailed')
            )
            """,
            arguments: [coalescingKey]
        ) ?? false
        guard !activeJobExists else { return }
        let command = try FolderReconcileJobFactory.makeEnqueueCommand(
            jobID: idGenerator(),
            sourceID: sourceID,
            notBeforeMs: clock.nowMs
        )
        try JobInsertInTransaction.insertPendingJob(db, command: command, nowMs: clock.nowMs)
    }
}

struct FolderFileSystemEventFlags: OptionSet, Sendable {
    let rawValue: UInt32

    static let mustScanSubdirectories = Self(rawValue: 1 << 0)
    static let userDropped = Self(rawValue: 1 << 1)
    static let kernelDropped = Self(rawValue: 1 << 2)
    static let eventIDsWrapped = Self(rawValue: 1 << 3)
    static let rootChanged = Self(rawValue: 1 << 4)
    static let unmounted = Self(rawValue: 1 << 5)

    var indicatesRootUnavailable: Bool {
        !intersection([.rootChanged, .unmounted]).isEmpty
    }
}

struct FolderFileSystemEventBatch: Sendable {
    let eventCount: Int
    let flags: FolderFileSystemEventFlags
}

protocol FolderFileSystemEventStream: AnyObject, Sendable {
    func stop()
}

protocol FolderFileSystemEventStreamFactory: Sendable {
    func start(
        rootURL: URL,
        onEventBatch: @escaping @Sendable (FolderFileSystemEventBatch) -> Void
    ) throws -> any FolderFileSystemEventStream
}

enum FoundationFolderFileSystemEventStreamError: Error {
    case creationFailed
    case startFailed
}

struct FoundationFolderFileSystemEventStreamFactory: FolderFileSystemEventStreamFactory, Sendable {
    let latency: TimeInterval

    init(latency: TimeInterval = 0.25) {
        self.latency = latency
    }

    func start(
        rootURL: URL,
        onEventBatch: @escaping @Sendable (FolderFileSystemEventBatch) -> Void
    ) throws -> any FolderFileSystemEventStream {
        try FoundationFolderFileSystemEventStream(
            rootURL: rootURL,
            latency: latency,
            onEventBatch: onEventBatch
        )
    }
}

private final class FolderFileSystemEventCallbackBox: @unchecked Sendable {
    let callback: @Sendable (FolderFileSystemEventBatch) -> Void

    init(callback: @escaping @Sendable (FolderFileSystemEventBatch) -> Void) {
        self.callback = callback
    }
}

private let folderFileSystemEventCallback: FSEventStreamCallback = {
    _, info, eventCount, _, rawFlags, _ in
    guard let info else { return }
    let callback = Unmanaged<FolderFileSystemEventCallbackBox>
        .fromOpaque(info)
        .takeUnretainedValue()
        .callback
    let flags = UnsafeBufferPointer(start: rawFlags, count: eventCount).reduce(
        into: FolderFileSystemEventFlags()
    ) { aggregate, rawFlag in
        if rawFlag & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
            aggregate.insert(.mustScanSubdirectories)
        }
        if rawFlag & FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped) != 0 {
            aggregate.insert(.userDropped)
        }
        if rawFlag & FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped) != 0 {
            aggregate.insert(.kernelDropped)
        }
        if rawFlag & FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped) != 0 {
            aggregate.insert(.eventIDsWrapped)
        }
        if rawFlag & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
            aggregate.insert(.rootChanged)
        }
        if rawFlag & FSEventStreamEventFlags(kFSEventStreamEventFlagUnmount) != 0 {
            aggregate.insert(.unmounted)
        }
    }
    callback(FolderFileSystemEventBatch(eventCount: eventCount, flags: flags))
}

private final class FoundationFolderFileSystemEventStream: FolderFileSystemEventStream, @unchecked Sendable {
    private let lock = NSLock()
    private let deliveryQueue: DispatchQueue
    private var stream: FSEventStreamRef?
    private var callbackBox: Unmanaged<FolderFileSystemEventCallbackBox>?

    init(
        rootURL: URL,
        latency: TimeInterval,
        onEventBatch: @escaping @Sendable (FolderFileSystemEventBatch) -> Void
    ) throws {
        deliveryQueue = DispatchQueue(label: "com.imageall.folder-fsevents")
        let retainedBox = Unmanaged.passRetained(
            FolderFileSystemEventCallbackBox(callback: onEventBatch)
        )
        var context = FSEventStreamContext(
            version: 0,
            info: retainedBox.toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let createFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagFileEvents
        )
        guard let createdStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            folderFileSystemEventCallback,
            &context,
            [rootURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            createFlags
        ) else {
            retainedBox.release()
            throw FoundationFolderFileSystemEventStreamError.creationFailed
        }
        FSEventStreamSetDispatchQueue(createdStream, deliveryQueue)
        guard FSEventStreamStart(createdStream) else {
            FSEventStreamInvalidate(createdStream)
            FSEventStreamRelease(createdStream)
            retainedBox.release()
            throw FoundationFolderFileSystemEventStreamError.startFailed
        }
        stream = createdStream
        callbackBox = retainedBox
    }

    deinit {
        stop()
    }

    func stop() {
        let resources = lock.withLock { () -> (FSEventStreamRef, Unmanaged<FolderFileSystemEventCallbackBox>)? in
            guard let stream, let callbackBox else { return nil }
            self.stream = nil
            self.callbackBox = nil
            return (stream, callbackBox)
        }
        guard let resources else { return }
        FSEventStreamStop(resources.0)
        FSEventStreamInvalidate(resources.0)
        FSEventStreamRelease(resources.0)
        resources.1.release()
    }
}

final class FolderSourceMonitoringCoordinator: @unchecked Sendable {
    private struct StartFailure: Error {
        let sourceState: SourceState
    }

    private final class Session {
        let stream: any FolderFileSystemEventStream
        let rootURL: URL
        let bookmarkPort: any SecurityScopedBookmarkPort

        init(
            stream: any FolderFileSystemEventStream,
            rootURL: URL,
            bookmarkPort: any SecurityScopedBookmarkPort
        ) {
            self.stream = stream
            self.rootURL = rootURL
            self.bookmarkPort = bookmarkPort
        }

        func stop() {
            stream.stop()
            bookmarkPort.stopAccessing(rootURL)
        }
    }

    private let repository: GRDBFolderSourceAuthorizationRepository
    private let bookmarkPort: any SecurityScopedBookmarkPort
    private let rootValidator: FolderRootValidator
    private let dirtyTrigger: FolderSourceDirtyTrigger
    private let streamFactory: any FolderFileSystemEventStreamFactory
    private let clock: any JobClock
    private let lock = NSLock()
    private var sessions: [UUID: Session] = [:]
    private var onChange: (@Sendable () -> Void)?

    init(
        repository: GRDBFolderSourceAuthorizationRepository,
        bookmarkPort: any SecurityScopedBookmarkPort,
        rootValidator: FolderRootValidator,
        dirtyTrigger: FolderSourceDirtyTrigger,
        streamFactory: any FolderFileSystemEventStreamFactory,
        clock: any JobClock = SystemJobClock()
    ) {
        self.repository = repository
        self.bookmarkPort = bookmarkPort
        self.rootValidator = rootValidator
        self.dirtyTrigger = dirtyTrigger
        self.streamFactory = streamFactory
        self.clock = clock
    }

    deinit {
        stop()
    }

    func start(onChange: @escaping @Sendable () -> Void) throws {
        lock.withLock { self.onChange = onChange }
        try synchronize()
    }

    func synchronize() throws {
        let activeSources = try repository.fetchAllFolderSources().filter { $0.state == .active }
        let activeIDs = Set(activeSources.map(\.id))
        let removedSessions = lock.withLock { () -> [Session] in
            let removed = sessions.compactMap { activeIDs.contains($0.key) ? nil : $0.value }
            sessions = sessions.filter { activeIDs.contains($0.key) }
            return removed
        }
        removedSessions.forEach { $0.stop() }

        for source in activeSources {
            let alreadyWatching = lock.withLock { sessions[source.id] != nil }
            guard !alreadyWatching else { continue }
            do {
                let session = try makeSession(for: source)
                lock.withLock { sessions[source.id] = session }
                guard isActiveFolderSource(source.id) else {
                    let removed = lock.withLock { sessions.removeValue(forKey: source.id) }
                    removed?.stop()
                    continue
                }
                if try dirtyTrigger.enqueueInitialReconcile(sourceID: source.id) {
                    notifyChange()
                }
            } catch {
                let sourceState = (error as? StartFailure)?.sourceState ?? .unavailable
                try? repository.updateSourceState(
                    sourceID: source.id,
                    state: sourceState,
                    nowMs: clock.nowMs
                )
                notifyChange()
            }
        }
    }

    func stop() {
        let stoppedSessions = lock.withLock { () -> [Session] in
            let stopped = Array(sessions.values)
            sessions.removeAll()
            onChange = nil
            return stopped
        }
        stoppedSessions.forEach { $0.stop() }
    }

    private func makeSession(for source: StoredFolderSourceRecord) throws -> Session {
        let resolved: BookmarkResolveResult
        do {
            resolved = try bookmarkPort.resolveBookmark(source.bookmark)
        } catch {
            let observation = FolderAccessFailureClassifier.classifyBookmarkResolveFailure(error)
            throw StartFailure(
                sourceState: observation == .offline ? .unavailable : .authorizationRequired
            )
        }
        guard bookmarkPort.startAccessing(resolved.url) else {
            throw StartFailure(sourceState: .authorizationRequired)
        }

        do {
            guard case .valid = rootValidator.validateRoot(at: resolved.url) else {
                throw StartFailure(sourceState: .authorizationRequired)
            }
            if resolved.isStale {
                let refreshed = try bookmarkPort.createReadOnlyBookmark(for: resolved.url)
                try repository.replaceStaleBookmark(
                    sourceID: source.id,
                    bookmark: refreshed,
                    nowMs: clock.nowMs
                )
            }
            let stream = try streamFactory.start(rootURL: resolved.url) { [weak self] batch in
                self?.handle(batch: batch, sourceID: source.id)
            }
            return Session(stream: stream, rootURL: resolved.url, bookmarkPort: bookmarkPort)
        } catch {
            bookmarkPort.stopAccessing(resolved.url)
            throw error
        }
    }

    private func handle(batch: FolderFileSystemEventBatch, sourceID: UUID) {
        if batch.flags.indicatesRootUnavailable {
            try? repository.updateSourceState(
                sourceID: sourceID,
                state: .unavailable,
                nowMs: clock.nowMs
            )
            let session = lock.withLock { sessions.removeValue(forKey: sourceID) }
            session?.stop()
            notifyChange()
            return
        }

        if (try? dirtyTrigger.recordEventBatch(
            sourceID: sourceID,
            eventCount: batch.eventCount
        )) == true {
            notifyChange()
        }
    }

    private func notifyChange() {
        lock.withLock { onChange }?()
    }

    private func isActiveFolderSource(_ sourceID: UUID) -> Bool {
        guard case let .folder(source) = try? repository.lookupSource(id: sourceID) else {
            return false
        }
        return source.state == .active
    }
}
