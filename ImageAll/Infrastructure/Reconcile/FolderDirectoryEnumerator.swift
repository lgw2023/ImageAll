import Foundation

struct FolderEnumerationConfig: Sendable, Equatable {
    let workUnitLimit: Int
    let assetBatchLimit: Int

    init(workUnitLimit: Int, assetBatchLimit: Int) {
        self.workUnitLimit = workUnitLimit
        self.assetBatchLimit = assetBatchLimit
    }

    static let productionDefault = FolderEnumerationConfig(workUnitLimit: 256, assetBatchLimit: 256)
}

enum FolderEnumerationEntryKind: Equatable, Sendable {
    case ignored
    case candidateFile(relativePath: String, fileName: String)
    case unsafeRelativePath
}

final class FolderDirectoryEnumerationSession: @unchecked Sendable {
    private let rootURL: URL
    private let config: FolderEnumerationConfig
    private let fileManager: FileManager
    private let resourceReader: any FolderEnumerationResourceReading
    private let keys: [URLResourceKey] = [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .isAliasFileKey,
        .isPackageKey,
        .isHiddenKey,
        .nameKey,
    ]

    private var enumerator: FileManager.DirectoryEnumerator?
    private var hadDirectoryError = false
    private var workUnitsSinceBoundary = 0
    private var isExhausted = false
    private var aborted = false

    init(
        rootURL: URL,
        config: FolderEnumerationConfig,
        fileManager: FileManager = .default,
        resourceReader: any FolderEnumerationResourceReading = FoundationEnumerationResourceReader()
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.config = config
        self.fileManager = fileManager
        self.resourceReader = resourceReader
    }

    var directoryHadError: Bool { hadDirectoryError }
    var isFinished: Bool { isExhausted || aborted }

    var needsBoundaryFlush: Bool {
        workUnitsSinceBoundary >= config.workUnitLimit
    }

    func markBoundaryFlushed() {
        workUnitsSinceBoundary = 0
    }

    func nextEntry() throws -> FolderEnumerationEntryKind? {
        startIfNeeded()
        guard !isExhausted, !aborted, let enumerator else {
            return nil
        }

        while let item = enumerator.nextObject() as? URL {
            workUnitsSinceBoundary += 1

            if item.lastPathComponent.lowercased().hasSuffix(".photoslibrary") {
                enumerator.skipDescendants()
                return .ignored
            }

            let relativePath = makeRelativePath(for: item)
            guard let relativePath else {
                if isStrictRootBoundaryViolation(for: item) {
                    aborted = true
                    return .unsafeRelativePath
                }
                return .ignored
            }

            switch RelativePathRules.validate(relativePath) {
            case .failure:
                aborted = true
                return .unsafeRelativePath
            case .success:
                break
            }

            if isPhotosLibraryComponent(relativePath) {
                enumerator.skipDescendants()
                return .ignored
            }

            let values: URLResourceValues
            do {
                values = try resourceReader.resourceValues(for: item, keys: Set(keys))
            } catch {
                hadDirectoryError = true
                continue
            }
            if values.isSymbolicLink == true || values.isAliasFile == true {
                return .ignored
            }

            if values.isPackage == true {
                return .ignored
            }

            if values.isDirectory == true {
                return .ignored
            }

            guard values.isRegularFile == true else {
                return .ignored
            }

            guard let fileName = RelativePathRules.fileName(from: relativePath) else {
                aborted = true
                return .unsafeRelativePath
            }

            return .candidateFile(relativePath: relativePath, fileName: fileName)
        }

        isExhausted = true
        return nil
    }

    private func startIfNeeded() {
        guard enumerator == nil else {
            return
        }
        enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in
                self.hadDirectoryError = true
                return true
            }
        )
        if enumerator == nil {
            hadDirectoryError = true
            isExhausted = true
        }
    }

    private func makeRelativePath(for url: URL) -> String? {
        let rootComponents = rootURL.pathComponents
        let itemComponents = url.standardizedFileURL.pathComponents
        guard itemComponents.count > rootComponents.count else {
            return nil
        }
        guard Array(itemComponents.prefix(rootComponents.count)) == rootComponents else {
            return nil
        }
        let relative = itemComponents.dropFirst(rootComponents.count).joined(separator: "/")
        guard !relative.isEmpty else {
            return nil
        }
        return relative
    }

    private func isStrictRootBoundaryViolation(for url: URL) -> Bool {
        let rootPath = rootURL.path
        let itemPath = url.standardizedFileURL.path
        guard itemPath.hasPrefix(rootPath), itemPath.count > rootPath.count else {
            return false
        }
        let nextIndex = itemPath.index(itemPath.startIndex, offsetBy: rootPath.count)
        let boundary = itemPath[nextIndex]
        return boundary != "/"
    }

    private func isPhotosLibraryComponent(_ relativePath: String) -> Bool {
        relativePath
            .split(separator: "/")
            .contains { $0.lowercased().hasSuffix(".photoslibrary") }
    }
}

struct FolderDirectoryEnumerator {
    private let rootURL: URL
    private let config: FolderEnumerationConfig
    private let fileManager: FileManager
    private let resourceReader: any FolderEnumerationResourceReading

    init(
        rootURL: URL,
        config: FolderEnumerationConfig = .productionDefault,
        fileManager: FileManager = .default,
        resourceReader: any FolderEnumerationResourceReading = FoundationEnumerationResourceReader()
    ) {
        self.rootURL = rootURL
        self.config = config
        self.fileManager = fileManager
        self.resourceReader = resourceReader
    }

    func makeSession() -> FolderDirectoryEnumerationSession {
        FolderDirectoryEnumerationSession(
            rootURL: rootURL,
            config: config,
            fileManager: fileManager,
            resourceReader: resourceReader
        )
    }
}
