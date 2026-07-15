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
        guard let selectedURL = dependencies.picker.pickDirectory() else {
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
        } catch {
            throw FolderAuthorizationError.persistenceFailure
        }

        return .connected(sourceID: sourceID)
    }

    func reauthorizeFolder(sourceID: UUID) async throws -> ReauthorizeFolderOutcome {
        guard let existing = try dependencies.repository.fetchFolderSource(id: sourceID) else {
            throw FolderAuthorizationError.sourceNotFound
        }

        switch existing.state {
        case .unavailable, .authorizationRequired:
            break
        case .active, .disabled:
            throw FolderAuthorizationError.invalidSourceState
        }

        guard let selectedURL = dependencies.picker.pickDirectory() else {
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
        } catch {
            throw FolderAuthorizationError.persistenceFailure
        }

        return .reauthorized(sourceID: sourceID)
    }

    func disableFolderSource(sourceID: UUID) async throws -> DisableFolderOutcome {
        guard let existing = try dependencies.repository.fetchFolderSource(id: sourceID) else {
            throw FolderAuthorizationError.sourceNotFound
        }

        if existing.state == .disabled {
            return .disabled(sourceID: sourceID)
        }

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
        guard let source = try dependencies.repository.fetchFolderSource(id: sourceID) else {
            throw FolderAuthorizationError.sourceNotFound
        }

        switch source.state {
        case .disabled:
            throw FolderAuthorizationError.invalidSourceState
        case .unavailable:
            throw FolderAuthorizationError.authorizationUnavailable
        case .authorizationRequired:
            throw FolderAuthorizationError.authorizationUnavailable
        case .active:
            break
        }

        return try resolveAccess(source: source, allowStaleRefresh: true, perform: perform)
    }

    func auditOverlapRoot(for source: StoredFolderSourceRecord) throws -> URL {
        try resolveURLForOverlapAudit(source: source)
    }

    private enum IdentityVerificationResult {
        case same
        case different
        case indeterminate
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

        return try SecurityScopedAccessRunner.withAccess(
            bookmarkPort: dependencies.bookmarkPort,
            url: resolved.url
        ) { existingURL in
            switch dependencies.relationshipChecker.relationship(between: newRoot, and: existingURL) {
            case .same:
                return .same
            case .disjoint:
                return .different
            case .existingAncestor, .newAncestor, .indeterminate:
                return .indeterminate
            }
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
        allowStaleRefresh: Bool,
        perform: (URL) throws -> T
    ) throws -> T {
        let resolved: BookmarkResolveResult
        do {
            resolved = try dependencies.bookmarkPort.resolveBookmark(source.bookmark)
        } catch {
            throw FolderAuthorizationError.authorizationUnavailable
        }

        return try SecurityScopedAccessRunner.withAccess(
            bookmarkPort: dependencies.bookmarkPort,
            url: resolved.url
        ) { url in
            switch dependencies.rootValidator.validateRoot(at: url) {
            case .valid:
                break
            case .invalid:
                throw FolderAuthorizationError.authorizationUnavailable
            }

            if allowStaleRefresh, resolved.isStale {
                let refreshed = try refreshStaleBookmark(sourceID: source.id, resolvedURL: url)
                return try SecurityScopedAccessRunner.withAccess(
                    bookmarkPort: dependencies.bookmarkPort,
                    url: refreshed
                ) { refreshedURL in
                    try perform(refreshedURL)
                }
            }

            return try perform(url)
        }
    }

    private func refreshStaleBookmark(sourceID: UUID, resolvedURL: URL) throws -> URL {
        let newBookmark: Data
        do {
            newBookmark = try dependencies.bookmarkPort.createReadOnlyBookmark(for: resolvedURL)
        } catch {
            try dependencies.repository.updateSourceState(
                sourceID: sourceID,
                state: .authorizationRequired,
                nowMs: dependencies.clock.nowMs
            )
            throw FolderAuthorizationError.authorizationUnavailable
        }

        do {
            try dependencies.repository.replaceStaleBookmark(
                sourceID: sourceID,
                bookmark: newBookmark,
                nowMs: dependencies.clock.nowMs
            )
        } catch {
            throw FolderAuthorizationError.persistenceFailure
        }

        let refreshed = try dependencies.bookmarkPort.resolveBookmark(newBookmark)
        return refreshed.url
    }
}
