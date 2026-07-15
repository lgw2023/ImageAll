import Foundation

enum SecurityScopedBookmarkOptions {
    static let creationOptions: URL.BookmarkCreationOptions = [
        .withSecurityScope,
        .securityScopeAllowOnlyReadAccess,
    ]

    static let resolutionOptions: URL.BookmarkResolutionOptions = [
        .withSecurityScope,
        .withoutUI,
        .withoutMounting,
        .withoutImplicitStartAccessing,
    ]
}

enum FolderAccessFailureObservation: Equatable, Sendable {
    case offline
    case authorizationRequired
}

enum FolderAccessFailureClassifier {
    static func classifyBookmarkResolveFailure(_ error: Error) -> FolderAccessFailureObservation {
        if isLikelyOffline(error) {
            return .offline
        }
        return .authorizationRequired
    }

    static func classifyScopeStartFailure() -> FolderAccessFailureObservation {
        .authorizationRequired
    }

    static func classifyInvalidRoot() -> FolderAccessFailureObservation {
        .authorizationRequired
    }

    private static func isLikelyOffline(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError:
                return true
            default:
                break
            }
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == ENOENT {
            return true
        }
        return false
    }
}

struct BookmarkResolveResult: Equatable, Sendable {
    let url: URL
    let isStale: Bool
}

protocol SecurityScopedBookmarkPort: Sendable {
    func createReadOnlyBookmark(for url: URL) throws -> Data
    func resolveBookmark(_ bookmark: Data) throws -> BookmarkResolveResult
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

enum FolderRootValidationFailure: Equatable, Sendable {
    case notDirectory
    case file
    case symbolicLink
    case alias
    case package
    case photosLibrary
    case unreadable
    case missingDisplayName
}

enum FolderRootValidationOutcome: Equatable, Sendable {
    case valid(displayName: String)
    case invalid(FolderRootValidationFailure)
}

protocol FolderRootResourceValueReading: Sendable {
    func resourceValues(for url: URL) throws -> FolderRootResourceSnapshot
}

struct FolderRootResourceSnapshot: Equatable, Sendable {
    let isDirectory: Bool?
    let isSymbolicLink: Bool?
    let isAliasFile: Bool?
    let isPackage: Bool?
    let isReadable: Bool?
    let localizedName: String?
    let pathExtension: String
}

struct FoundationFolderRootResourceReader: FolderRootResourceValueReading {
    func resourceValues(for url: URL) throws -> FolderRootResourceSnapshot {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isAliasFileKey,
            .isPackageKey,
            .isReadableKey,
            .localizedNameKey,
        ])
        return FolderRootResourceSnapshot(
            isDirectory: values.isDirectory,
            isSymbolicLink: values.isSymbolicLink,
            isAliasFile: values.isAliasFile,
            isPackage: values.isPackage,
            isReadable: values.isReadable,
            localizedName: values.localizedName,
            pathExtension: url.pathExtension
        )
    }
}

struct FolderRootValidator: Sendable {
    let resourceReader: any FolderRootResourceValueReading

    init(resourceReader: any FolderRootResourceValueReading = FoundationFolderRootResourceReader()) {
        self.resourceReader = resourceReader
    }

    func validateRoot(at url: URL) -> FolderRootValidationOutcome {
        let snapshot: FolderRootResourceSnapshot
        do {
            snapshot = try resourceReader.resourceValues(for: url)
        } catch {
            return .invalid(.unreadable)
        }

        if snapshot.isSymbolicLink == true {
            return .invalid(.symbolicLink)
        }
        if snapshot.isAliasFile == true {
            return .invalid(.alias)
        }
        if snapshot.pathExtension.compare("photoslibrary", options: .caseInsensitive) == .orderedSame {
            return .invalid(.photosLibrary)
        }
        if snapshot.isPackage == true {
            return .invalid(.package)
        }
        if snapshot.isDirectory != true {
            if snapshot.isDirectory == false {
                return .invalid(.file)
            }
            return .invalid(.notDirectory)
        }
        if snapshot.isReadable != true {
            return .invalid(.unreadable)
        }

        let displayName = snapshot.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let displayName, !displayName.isEmpty else {
            return .invalid(.missingDisplayName)
        }
        return .valid(displayName: displayName)
    }
}

enum FolderRootRelationship: Equatable, Sendable {
    case same
    case existingAncestor
    case newAncestor
    case disjoint
    case indeterminate
}

protocol FolderRootRelationshipChecking: Sendable {
    func relationship(between newRoot: URL, and existingRoot: URL) -> FolderRootRelationship
}

struct FoundationFolderRootRelationshipChecker: FolderRootRelationshipChecking {
    func relationship(between newRoot: URL, and existingRoot: URL) -> FolderRootRelationship {
        let newURL = newRoot.standardizedFileURL
        let existingURL = existingRoot.standardizedFileURL

        switch resourceIdentityRelationship(newURL, existingURL) {
        case .same:
            return .same
        case .indeterminate:
            return .indeterminate
        case .different:
            break
        }

        switch directoryContainment(directory: existingURL, item: newURL) {
        case .contains:
            return .existingAncestor
        case .indeterminate:
            return .indeterminate
        case .notContained:
            break
        }

        switch directoryContainment(directory: newURL, item: existingURL) {
        case .contains:
            return .newAncestor
        case .indeterminate:
            return .indeterminate
        case .notContained:
            break
        }

        switch resourceIdentityRelationship(newURL, existingURL) {
        case .same:
            return .same
        case .different:
            return .disjoint
        case .indeterminate:
            return .indeterminate
        }
    }

    private enum ResourceIdentityRelationship {
        case same
        case different
        case indeterminate
    }

    private enum DirectoryContainmentResult {
        case contains
        case notContained
        case indeterminate
    }

    private func resourceIdentityRelationship(_ lhs: URL, _ rhs: URL) -> ResourceIdentityRelationship {
        let leftID: (any NSObjectProtocol)?
        let rightID: (any NSObjectProtocol)?
        do {
            leftID = try lhs.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
            rightID = try rhs.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        } catch {
            return .indeterminate
        }
        guard let leftID, let rightID else {
            return .indeterminate
        }
        if leftID.isEqual(rightID) {
            return .same
        }
        return .different
    }

    private func directoryContainment(directory: URL, item: URL) -> DirectoryContainmentResult {
        var relationship: FileManager.URLRelationship = .other
        do {
            try FileManager.default.getRelationship(&relationship, ofDirectoryAt: directory, toItemAt: item)
        } catch {
            return .indeterminate
        }
        switch relationship {
        case .contains:
            return .contains
        case .same:
            return .notContained
        case .other:
            return .notContained
        @unknown default:
            return .indeterminate
        }
    }
}

struct FoundationSecurityScopedBookmarkAdapter: SecurityScopedBookmarkPort {
    func createReadOnlyBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: SecurityScopedBookmarkOptions.creationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    func resolveBookmark(_ bookmark: Data) throws -> BookmarkResolveResult {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: SecurityScopedBookmarkOptions.resolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return BookmarkResolveResult(url: url, isStale: isStale)
    }

    func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

enum SecurityScopedAccessRunner {
    static func withAccess<T>(
        bookmarkPort: any SecurityScopedBookmarkPort,
        url: URL,
        perform: (URL) throws -> T
    ) throws -> T {
        let started = bookmarkPort.startAccessing(url)
        defer {
            if started {
                bookmarkPort.stopAccessing(url)
            }
        }
        guard started else {
            throw FolderAuthorizationError.authorizationUnavailable
        }
        return try perform(url)
    }
}
