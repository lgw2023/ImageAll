import Foundation

struct FoundationAppPathsResolver: AppPathsResolving {
    func resolve() throws -> AppPaths {
        let applicationSupportDirectory = try resolveDirectory(
            for: .applicationSupportDirectory,
            appendingPath: "ImageAll",
            create: false
        )
        let cachesDirectory = try resolveDirectory(
            for: .cachesDirectory,
            appendingPath: "ImageAll",
            create: false
        )

        let catalogDirectory = applicationSupportDirectory
            .appendingPathComponent("Catalog", isDirectory: true)
        let backupsDirectory = applicationSupportDirectory
            .appendingPathComponent("Backups", isDirectory: true)
        let runtimeDirectory = applicationSupportDirectory
            .appendingPathComponent("Runtime", isDirectory: true)

        return AppPaths(
            applicationSupportDirectory: applicationSupportDirectory,
            catalogDirectory: catalogDirectory,
            catalogDatabaseURL: catalogDirectory.appendingPathComponent(
                CatalogSnapshotConstants.databaseFilename
            ),
            backupsDirectory: backupsDirectory,
            runtimeDirectory: runtimeDirectory,
            catalogLockFileURL: runtimeDirectory.appendingPathComponent("catalog.lock"),
            cachesDirectory: cachesDirectory
        )
    }

    func ensureRequiredDirectories(for paths: AppPaths) throws {
        try ensureDirectory(at: paths.catalogDirectory)
        try ensureDirectory(at: paths.backupsDirectory)
        try ensureDirectory(at: paths.runtimeDirectory)
        try assertSameVolume(
            paths.catalogDirectory,
            paths.backupsDirectory,
            paths.runtimeDirectory
        )
    }

    private func resolveDirectory(
        for searchPath: FileManager.SearchPathDirectory,
        appendingPath: String,
        create: Bool
    ) throws -> URL {
        do {
            let base = try FileManager.default.url(
                for: searchPath,
                in: .userDomainMask,
                appropriateFor: nil,
                create: create
            )
            return base.appendingPathComponent(appendingPath, isDirectory: true)
        } catch {
            throw AppPathsError.resolutionFailed
        }
    }

    private func ensureDirectory(at url: URL) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw AppPathsError.pathNotDirectory
            }
            return
        }

        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw AppPathsError.directoryCreationFailed
        }
    }

    private func assertSameVolume(_ urls: URL...) throws {
        guard let first = urls.first else { return }
        for url in urls.dropFirst() {
            guard try CatalogDatabaseSidecarHelpers.isSameVolume(first, url) else {
                throw AppPathsError.crossVolumeLayoutRejected
            }
        }
    }
}

struct TemporaryAppPathsResolver: AppPathsResolving {
    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    func resolve() throws -> AppPaths {
        let applicationSupportDirectory = rootURL
            .appendingPathComponent("Application Support/ImageAll", isDirectory: true)
        let cachesDirectory = rootURL
            .appendingPathComponent("Caches/ImageAll", isDirectory: true)
        let catalogDirectory = applicationSupportDirectory
            .appendingPathComponent("Catalog", isDirectory: true)
        let backupsDirectory = applicationSupportDirectory
            .appendingPathComponent("Backups", isDirectory: true)
        let runtimeDirectory = applicationSupportDirectory
            .appendingPathComponent("Runtime", isDirectory: true)

        return AppPaths(
            applicationSupportDirectory: applicationSupportDirectory,
            catalogDirectory: catalogDirectory,
            catalogDatabaseURL: catalogDirectory.appendingPathComponent(
                CatalogSnapshotConstants.databaseFilename
            ),
            backupsDirectory: backupsDirectory,
            runtimeDirectory: runtimeDirectory,
            catalogLockFileURL: runtimeDirectory.appendingPathComponent("catalog.lock"),
            cachesDirectory: cachesDirectory
        )
    }

    func ensureRequiredDirectories(for paths: AppPaths) throws {
        try FoundationAppPathsResolver().ensureRequiredDirectories(for: paths)
    }
}
