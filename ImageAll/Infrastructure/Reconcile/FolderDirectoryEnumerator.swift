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

struct FolderDirectoryEnumerator {
    private let rootURL: URL
    private let config: FolderEnumerationConfig

    init(rootURL: URL, config: FolderEnumerationConfig = .productionDefault, fileManager: FileManager = .default) {
        self.rootURL = rootURL.standardizedFileURL
        self.config = config
        self.fileManager = fileManager
    }

    private let fileManager: FileManager

    func enumerate(
        onEntry: (FolderEnumerationEntryKind) throws -> Void
    ) throws -> (hadDirectoryError: Bool, finished: Bool) {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isAliasFileKey,
            .isPackageKey,
            .isHiddenKey,
            .nameKey,
        ]

        var hadDirectoryError = false
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in
                hadDirectoryError = true
                return true
            }
        ) else {
            return (true, false)
        }

        var workUnits = 0

        while let item = enumerator.nextObject() as? URL {
            workUnits += 1
            if workUnits > config.workUnitLimit {
                return (hadDirectoryError, false)
            }

            if item.lastPathComponent.lowercased().hasSuffix(".photoslibrary") {
                enumerator.skipDescendants()
                try onEntry(.ignored)
                continue
            }

            let relativePath = makeRelativePath(for: item)
            guard let relativePath else {
                try onEntry(.ignored)
                continue
            }

            switch RelativePathRules.validate(relativePath) {
            case .failure:
                try onEntry(.unsafeRelativePath)
                return (hadDirectoryError, false)
            case .success:
                break
            }

            if isPhotosLibraryComponent(relativePath) {
                enumerator.skipDescendants()
                try onEntry(.ignored)
                continue
            }

            let values = try? item.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true || values?.isAliasFile == true {
                try onEntry(.ignored)
                continue
            }

            if values?.isPackage == true {
                try onEntry(.ignored)
                continue
            }

            if values?.isDirectory == true {
                try onEntry(.ignored)
                continue
            }

            guard values?.isRegularFile == true else {
                try onEntry(.ignored)
                continue
            }

            guard RelativePathRules.fileName(from: relativePath) != nil else {
                try onEntry(.unsafeRelativePath)
                return (hadDirectoryError, false)
            }

            try onEntry(.candidateFile(relativePath: relativePath, fileName: RelativePathRules.fileName(from: relativePath)!))
        }

        return (hadDirectoryError, true)
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
