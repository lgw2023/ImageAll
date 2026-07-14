import Foundation
import GRDB

protocol CatalogDatabaseFileReplacing: Sendable {
    func replaceItem(
        at originalItemURL: URL,
        withItemAt newItemURL: URL,
        backupItemName: String,
        options: FileManager.ItemReplacementOptions
    ) throws -> URL
}

struct FoundationCatalogDatabaseFileReplacer: CatalogDatabaseFileReplacing {
    func replaceItem(
        at originalItemURL: URL,
        withItemAt newItemURL: URL,
        backupItemName: String,
        options: FileManager.ItemReplacementOptions
    ) throws -> URL {
        var resultingURL: NSURL?
        try FileManager.default.replaceItem(
            at: originalItemURL,
            withItemAt: newItemURL,
            backupItemName: backupItemName,
            options: options,
            resultingItemURL: &resultingURL
        )
        return (resultingURL as URL?) ?? originalItemURL
    }
}

protocol CatalogPostReplaceValidator: Sendable {
    func validateDatabase(at url: URL) throws
}

struct DefaultCatalogPostReplaceValidator: CatalogPostReplaceValidator {
    func validateDatabase(at url: URL) throws {
        try CatalogDatabase.validateAndCloseReplacedDatabase(at: url)
    }
}

struct CatalogSnapshotCreationDependencies {
    var fileManager: FileManager
    var pagesPerStep: CInt
    var backupProgressHook: (@Sendable (DatabaseBackupProgress) throws -> Void)?
    var destinationPreCloseHook: (@Sendable (DatabaseQueue, URL) throws -> Void)?
    var destinationCloseFailureHook: (@Sendable () throws -> Void)?
    var destinationQueueOpenFailureHook: (@Sendable () throws -> Void)?
    var quickCheckFailureHook: (@Sendable (DatabaseQueue) throws -> Void)?
    var hashFailureHook: (@Sendable () throws -> Void)?
    var manifestDataWriter: (@Sendable (Data, URL) throws -> Void)?
    var publicationFailureHook: (@Sendable () throws -> Void)?

    init(
        fileManager: FileManager = .default,
        pagesPerStep: CInt = -1,
        backupProgressHook: (@Sendable (DatabaseBackupProgress) throws -> Void)? = nil,
        destinationPreCloseHook: (@Sendable (DatabaseQueue, URL) throws -> Void)? = nil,
        destinationCloseFailureHook: (@Sendable () throws -> Void)? = nil,
        destinationQueueOpenFailureHook: (@Sendable () throws -> Void)? = nil,
        quickCheckFailureHook: (@Sendable (DatabaseQueue) throws -> Void)? = nil,
        hashFailureHook: (@Sendable () throws -> Void)? = nil,
        manifestDataWriter: (@Sendable (Data, URL) throws -> Void)? = nil,
        publicationFailureHook: (@Sendable () throws -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.pagesPerStep = pagesPerStep
        self.backupProgressHook = backupProgressHook
        self.destinationPreCloseHook = destinationPreCloseHook
        self.destinationCloseFailureHook = destinationCloseFailureHook
        self.destinationQueueOpenFailureHook = destinationQueueOpenFailureHook
        self.quickCheckFailureHook = quickCheckFailureHook
        self.hashFailureHook = hashFailureHook
        self.manifestDataWriter = manifestDataWriter
        self.publicationFailureHook = publicationFailureHook
    }
}

struct CatalogDatabaseRestoreDependencies {
    var fileManager: FileManager
    var fileReplacer: any CatalogDatabaseFileReplacing
    var postReplaceValidator: any CatalogPostReplaceValidator
    var sameVolumeChecker: @Sendable (URL, URL) throws -> Bool

    init(
        fileManager: FileManager = .default,
        fileReplacer: any CatalogDatabaseFileReplacing = FoundationCatalogDatabaseFileReplacer(),
        postReplaceValidator: any CatalogPostReplaceValidator = DefaultCatalogPostReplaceValidator(),
        sameVolumeChecker: @escaping @Sendable (URL, URL) throws -> Bool = { lhs, rhs in
            try CatalogDatabaseSidecarHelpers.isSameVolume(lhs, rhs)
        }
    ) {
        self.fileManager = fileManager
        self.fileReplacer = fileReplacer
        self.postReplaceValidator = postReplaceValidator
        self.sameVolumeChecker = sameVolumeChecker
    }
}
