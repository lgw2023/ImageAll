import Foundation

struct FolderAuthorizationDependencies: Sendable {
    let repository: GRDBFolderSourceAuthorizationRepository
    let picker: any FolderDirectoryPickerPort
    let bookmarkPort: any SecurityScopedBookmarkPort
    let rootValidator: FolderRootValidator
    let relationshipChecker: any FolderRootRelationshipChecking
    let clock: any JobClock
    let idGenerator: @Sendable () -> UUID
}

struct FolderAuthorizationCoordinator: FolderAuthorizationCommandPort {
    let dependencies: FolderAuthorizationDependencies

    func connectFolder() async throws -> ConnectFolderOutcome {
        guard let selectedURL = await pickDirectoryOnMainActor() else {
            return .cancelled
        }
        defer {
            dependencies.bookmarkPort.stopAccessing(selectedURL)
        }

        let displayName: String
        switch dependencies.rootValidator.validateRoot(at: selectedURL) {
        case let .valid(name):
            displayName = name
        case .invalid:
            throw FolderAuthorizationError.invalidRoot
        }

        let bookmark: Data
        do {
            bookmark = try dependencies.bookmarkPort.createReadOnlyBookmark(for: selectedURL)
        } catch {
            throw FolderAuthorizationError.bookmarkCreationFailed
        }

        try checkOverlap(with: selectedURL)

        let sourceID = dependencies.idGenerator()
        let jobID = dependencies.idGenerator()
        let nowMs = dependencies.clock.nowMs

        do {
            try dependencies.repository.connectFolder(
                sourceID: sourceID,
                displayName: displayName,
                bookmark: bookmark,
                jobID: jobID,
                nowMs: nowMs
            )
        } catch let error as FolderAuthorizationError {
            throw error
        } catch {
            throw FolderAuthorizationError.persistenceFailure
        }

        return .connected(sourceID: sourceID)
    }

    func reauthorizeFolder(sourceID: UUID) async throws -> ReauthorizeFolderOutcome {
        let existing = try requireFolderSource(id: sourceID)

        switch existing.state {
        case .unavailable, .authorizationRequired:
            break
        case .active, .disabled:
            throw FolderAuthorizationError.invalidSourceState
        }

        guard let selectedURL = await pickDirectoryOnMainActor() else {
            return .cancelled
        }
        defer {
            dependencies.bookmarkPort.stopAccessing(selectedURL)
        }

        let displayName: String
        switch dependencies.rootValidator.validateRoot(at: selectedURL) {
        case let .valid(name):
            displayName = name
        case .invalid:
            throw FolderAuthorizationError.invalidRoot
        }

        let newBookmark: Data
        do {
            newBookmark = try dependencies.bookmarkPort.createReadOnlyBookmark(for: selectedURL)
        } catch {
            throw FolderAuthorizationError.bookmarkCreationFailed
        }

        let identity = try verifySameIdentity(
            existingBookmark: existing.bookmark,
            newRoot: selectedURL
        )
        switch identity {
        case .same:
            break
        case .different:
            throw FolderAuthorizationError.identityMismatch
        case .indeterminate:
            throw FolderAuthorizationError.identityIndeterminate
        }

        let jobID = dependencies.idGenerator()
        let nowMs = dependencies.clock.nowMs

        do {
            try dependencies.repository.reauthorizeFolder(
                sourceID: sourceID,
                displayName: displayName,
                bookmark: newBookmark,
                jobID: jobID,
                nowMs: nowMs
            )
        } catch let error as FolderAuthorizationError {
            throw error
        } catch {
            throw FolderAuthorizationError.persistenceFailure
        }

        return .reauthorized(sourceID: sourceID)
    }

    func disableFolderSource(sourceID: UUID) async throws -> DisableFolderOutcome {
        _ = try requireFolderSource(id: sourceID)

        do {
            try dependencies.repository.disableFolderSource(
                sourceID: sourceID,
                nowMs: dependencies.clock.nowMs
            )
        } catch let error as FolderAuthorizationError {
            throw error
        } catch {
            throw FolderAuthorizationError.persistenceFailure
        }

        return .disabled(sourceID: sourceID)
    }

    func accessFolderSource<T>(
        sourceID: UUID,
        perform: (URL) throws -> T
    ) throws -> T {
        let source = try requireFolderSource(id: sourceID)

        switch source.state {
        case .disabled:
            throw FolderAuthorizationError.invalidSourceState
        case .unavailable, .authorizationRequired:
            throw FolderAuthorizationError.authorizationUnavailable
        case .active:
            break
        }

        return try resolveAccess(source: source, perform: perform)
    }

    func auditOverlapRoot(for source: StoredFolderSourceRecord) throws -> URL {
        try resolveURLForOverlapAudit(source: source)
    }

    private enum IdentityVerificationResult {
        case same
        case different
        case indeterminate
    }

    @MainActor
    private func pickDirectoryOnMainActor() async -> URL? {
        dependencies.picker.pickDirectory()
    }

    private func requireFolderSource(id: UUID) throws -> StoredFolderSourceRecord {
        switch try dependencies.repository.lookupSource(id: id) {
        case .notFound:
            throw FolderAuthorizationError.sourceNotFound
        case .wrongKind:
            throw FolderAuthorizationError.sourceKindMismatch
        case let .folder(record):
            return record
        }
    }

    private func verifySameIdentity(
        existingBookmark: Data,
        newRoot: URL
    ) throws -> IdentityVerificationResult {
        let resolved: BookmarkResolveResult
        do {
            resolved = try dependencies.bookmarkPort.resolveBookmark(existingBookmark)
        } catch {
            return .indeterminate
        }

        let started = dependencies.bookmarkPort.startAccessing(resolved.url)
        guard started else {
            return .indeterminate
        }
        defer {
            dependencies.bookmarkPort.stopAccessing(resolved.url)
        }

        switch dependencies.relationshipChecker.relationship(between: newRoot, and: resolved.url) {
        case .same:
            return .same
        case .disjoint:
            return .different
        case .existingAncestor, .newAncestor, .indeterminate:
            return .indeterminate
        }
    }

    private func checkOverlap(with newRoot: URL) throws {
        let existingSources = try dependencies.repository.fetchAllFolderSources()
        for existing in existingSources {
            let existingURL: URL
            do {
                existingURL = try resolveURLForOverlapAudit(source: existing)
            } catch {
                throw FolderAuthorizationError.overlapIndeterminate
            }
            defer {
                dependencies.bookmarkPort.stopAccessing(existingURL)
            }

            switch dependencies.relationshipChecker.relationship(between: newRoot, and: existingURL) {
            case .same, .existingAncestor, .newAncestor:
                throw FolderAuthorizationError.sourceOverlap
            case .disjoint:
                continue
            case .indeterminate:
                throw FolderAuthorizationError.overlapIndeterminate
            }
        }
    }

    private func resolveURLForOverlapAudit(source: StoredFolderSourceRecord) throws -> URL {
        let resolved = try dependencies.bookmarkPort.resolveBookmark(source.bookmark)
        let started = dependencies.bookmarkPort.startAccessing(resolved.url)
        guard started else {
            throw FolderAuthorizationError.overlapIndeterminate
        }
        return resolved.url
    }

    private func resolveAccess<T>(
        source: StoredFolderSourceRecord,
        perform: (URL) throws -> T
    ) throws -> T {
        let resolved: BookmarkResolveResult
        do {
            resolved = try dependencies.bookmarkPort.resolveBookmark(source.bookmark)
        } catch {
            try persistAccessObservation(
                sourceID: source.id,
                observation: FolderAccessFailureClassifier.classifyBookmarkResolveFailure(error)
            )
            throw FolderAuthorizationError.authorizationUnavailable
        }

        let started = dependencies.bookmarkPort.startAccessing(resolved.url)
        guard started else {
            try persistAccessObservation(
                sourceID: source.id,
                observation: FolderAccessFailureClassifier.classifyScopeStartFailure(for: resolved.url)
            )
            throw FolderAuthorizationError.authorizationUnavailable
        }
        defer {
            dependencies.bookmarkPort.stopAccessing(resolved.url)
        }

        switch dependencies.rootValidator.validateRoot(at: resolved.url) {
        case .valid:
            break
        case .invalid:
            try persistAccessObservation(
                sourceID: source.id,
                observation: FolderAccessFailureClassifier.classifyInvalidRoot(at: resolved.url)
            )
            throw FolderAuthorizationError.authorizationUnavailable
        }

        if resolved.isStale {
            do {
                try refreshStaleBookmarkInCurrentScope(sourceID: source.id, resolvedURL: resolved.url)
            } catch let error as FolderAuthorizationError {
                throw error
            } catch {
                throw FolderAuthorizationError.persistenceFailure
            }
        }

        do {
            return try perform(resolved.url)
        } catch {
            throw error
        }
    }

    private func refreshStaleBookmarkInCurrentScope(sourceID: UUID, resolvedURL: URL) throws {
        let newBookmark: Data
        do {
            newBookmark = try dependencies.bookmarkPort.createReadOnlyBookmark(for: resolvedURL)
        } catch {
            try persistAccessObservation(sourceID: sourceID, observation: .authorizationRequired)
            throw FolderAuthorizationError.authorizationUnavailable
        }

        do {
            try dependencies.repository.replaceStaleBookmark(
                sourceID: sourceID,
                bookmark: newBookmark,
                nowMs: dependencies.clock.nowMs
            )
        } catch let error as FolderAuthorizationError {
            throw error
        } catch {
            throw FolderAuthorizationError.persistenceFailure
        }
    }

    private func persistAccessObservation(
        sourceID: UUID,
        observation: FolderAccessFailureObservation
    ) throws {
        let state: SourceState
        switch observation {
        case .offline:
            state = .unavailable
        case .authorizationRequired:
            state = .authorizationRequired
        }
        do {
            try dependencies.repository.updateSourceState(
                sourceID: sourceID,
                state: state,
                nowMs: dependencies.clock.nowMs
            )
        } catch let error as FolderAuthorizationError {
            throw error
        } catch {
            throw FolderAuthorizationError.persistenceFailure
        }
    }
}
