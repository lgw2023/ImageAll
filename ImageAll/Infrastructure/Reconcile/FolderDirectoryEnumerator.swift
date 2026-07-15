import Foundation

struct FolderEnumerationConfig: Sendable, Equatable {
    let workUnitLimit: Int
    let assetBatchLimit: Int

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

    init(rootURL: URL, config: FolderEnumerationConfig, fileManager: FileManager = .default) {
        self.rootURL = rootURL.standardizedFileURL
        self.config = config
        self.fileManager = fileManager
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

            let values = try? item.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true || values?.isAliasFile == true {
                return .ignored
            }

            if values?.isPackage == true {
                return .ignored
            }

            if values?.isDirectory == true {
                return .ignored
            }

            guard values?.isRegularFile == true else {
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
        let rootPath = rootURL.path
        let itemPath = url.standardizedFileURL.path
        guard itemPath.hasPrefix(rootPath) else {
            return nil
        }
        var suffix = String(itemPath.dropFirst(rootPath.count))
        if suffix.hasPrefix("/") {
            suffix.removeFirst()
        }
        guard !suffix.isEmpty else {
            return nil
        }
        return suffix
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

    init(rootURL: URL, config: FolderEnumerationConfig = .productionDefault, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.config = config
        self.fileManager = fileManager
    }

    func makeSession() -> FolderDirectoryEnumerationSession {
        FolderDirectoryEnumerationSession(rootURL: rootURL, config: config, fileManager: fileManager)
    }
}
