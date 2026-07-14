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
        try CatalogDatabase.validateClosedDatabase(at: url, requireCurrentSchema: true)
    }
}

struct CatalogSnapshotCreationDependencies {
    var fileManager: FileManager
    var pagesPerStep: CInt
    var backupProgressHook: (@Sendable (DatabaseBackupProgress) throws -> Void)?
    var backupAbortAfterSteps: Int?
    var failManifestWrite: Bool
    var failPublicationRename: Bool
    var abortOnlineBackupImmediately: Bool

    init(
        fileManager: FileManager = .default,
        pagesPerStep: CInt = -1,
        backupProgressHook: (@Sendable (DatabaseBackupProgress) throws -> Void)? = nil,
        backupAbortAfterSteps: Int? = nil,
        failManifestWrite: Bool = false,
        failPublicationRename: Bool = false,
        abortOnlineBackupImmediately: Bool = false
    ) {
        self.fileManager = fileManager
        self.pagesPerStep = pagesPerStep
        self.backupProgressHook = backupProgressHook
        self.backupAbortAfterSteps = backupAbortAfterSteps
        self.failManifestWrite = failManifestWrite
        self.failPublicationRename = failPublicationRename
        self.abortOnlineBackupImmediately = abortOnlineBackupImmediately
    }
}

struct CatalogDatabaseRestoreDependencies {
    var fileManager: FileManager
    var fileReplacer: any CatalogDatabaseFileReplacing
    var postReplaceValidator: any CatalogPostReplaceValidator
    var sameVolumeChecker: @Sendable (URL, URL) throws -> Bool
    var failInitialReplacement: Bool
    var failPostReplaceValidation: Bool
    var failRollbackReplacement: Bool

    init(
        fileManager: FileManager = .default,
        fileReplacer: any CatalogDatabaseFileReplacing = FoundationCatalogDatabaseFileReplacer(),
        postReplaceValidator: any CatalogPostReplaceValidator = DefaultCatalogPostReplaceValidator(),
        sameVolumeChecker: @escaping @Sendable (URL, URL) throws -> Bool = { lhs, rhs in
            try CatalogDatabaseSidecarHelpers.isSameVolume(lhs, rhs)
        },
        failInitialReplacement: Bool = false,
        failPostReplaceValidation: Bool = false,
        failRollbackReplacement: Bool = false
    ) {
        self.fileManager = fileManager
        self.fileReplacer = fileReplacer
        self.postReplaceValidator = postReplaceValidator
        self.sameVolumeChecker = sameVolumeChecker
        self.failInitialReplacement = failInitialReplacement
        self.failPostReplaceValidation = failPostReplaceValidation
        self.failRollbackReplacement = failRollbackReplacement
    }
}

final class FaultInjectingCatalogDatabaseFileReplacer: CatalogDatabaseFileReplacing, @unchecked Sendable {
    let underlying: any CatalogDatabaseFileReplacing
    var failInitialReplacement: Bool
    var failRollbackReplacement: Bool
    private let lock = NSLock()
    private var replacementCallCount = 0

    init(
        underlying: any CatalogDatabaseFileReplacing = FoundationCatalogDatabaseFileReplacer(),
        failInitialReplacement: Bool = false,
        failRollbackReplacement: Bool = false
    ) {
        self.underlying = underlying
        self.failInitialReplacement = failInitialReplacement
        self.failRollbackReplacement = failRollbackReplacement
    }

    func replaceItem(
        at originalItemURL: URL,
        withItemAt newItemURL: URL,
        backupItemName: String,
        options: FileManager.ItemReplacementOptions
    ) throws -> URL {
        lock.lock()
        replacementCallCount += 1
        let callCount = replacementCallCount
        lock.unlock()

        if failInitialReplacement && callCount == 1 {
            throw CatalogSnapshotError.initialReplacementFailed
        }
        if failRollbackReplacement && callCount == 2 {
            throw CatalogSnapshotError.rollbackReplacementFailed
        }

        return try underlying.replaceItem(
            at: originalItemURL,
            withItemAt: newItemURL,
            backupItemName: backupItemName,
            options: options
        )
    }
}

struct FaultInjectingCatalogPostReplaceValidator: CatalogPostReplaceValidator {
    var shouldFail: Bool
    let underlying: any CatalogPostReplaceValidator

    init(
        shouldFail: Bool,
        underlying: any CatalogPostReplaceValidator = DefaultCatalogPostReplaceValidator()
    ) {
        self.shouldFail = shouldFail
        self.underlying = underlying
    }

    func validateDatabase(at url: URL) throws {
        if shouldFail {
            throw CatalogSnapshotError.postReplaceValidationFailed
        }
        try underlying.validateDatabase(at: url)
    }
}
