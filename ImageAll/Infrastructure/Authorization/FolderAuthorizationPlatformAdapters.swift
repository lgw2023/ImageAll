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

enum BookmarkResolveFailureCategory: Equatable, Sendable {
    case unavailable
    case authorizationRequired
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
        if snapshot.isPackage == true {
            return .invalid(.package)
        }
        if snapshot.pathExtension.compare("photoslibrary", options: .caseInsensitive) == .orderedSame {
            return .invalid(.photosLibrary)
        }
        if snapshot.isDirectory != true {
            if snapshot.isDirectory == false {
                return .invalid(.file)
            }
            return .invalid(.notDirectory)
        }
        if snapshot.isReadable == false {
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
        let newPath = newRoot.standardizedFileURL.path
        let existingPath = existingRoot.standardizedFileURL.path
        if newPath == existingPath {
            return .same
        }

        let newComponents = newRoot.standardizedFileURL.pathComponents
        let existingComponents = existingRoot.standardizedFileURL.pathComponents
        if existingComponents.count < newComponents.count {
            let prefix = Array(newComponents.prefix(existingComponents.count))
            if prefix == existingComponents {
                return .existingAncestor
            }
        }
        if newComponents.count < existingComponents.count {
            let prefix = Array(existingComponents.prefix(newComponents.count))
            if prefix == newComponents {
                return .newAncestor
            }
        }

        if let newID = try? newRoot.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
           let existingID = try? existingRoot.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier {
            if newID.isEqual(existingID) {
                return .same
            }
            return .disjoint
        }
        return .indeterminate
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
