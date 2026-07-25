import Foundation
import os

@MainActor
final class CatalogStartupModel: ObservableObject {
    @Published private(set) var presentation: StartupPresentation
    @Published private(set) var workspaceModel: LibraryWorkspaceModel?

    private var runtimeToken: CatalogRuntimeToken?
    private var bootstrapDependencies: CatalogBootstrapDependencies
    private let workspaceFactory: @MainActor (CatalogRuntimeToken) -> LibraryWorkspaceModel?
    private let logger = Logger(subsystem: "com.imageall.app", category: "CatalogStartup")
    private var migrationCancelFlag = MigrationCancelFlag()
    private var bootstrapGeneration = 0

    init(
        dependencies: CatalogBootstrapDependencies,
        workspaceFactory: @escaping @MainActor (CatalogRuntimeToken) -> LibraryWorkspaceModel? = { _ in nil }
    ) {
        self.workspaceFactory = workspaceFactory
        bootstrapDependencies = dependencies
        presentation = StartupPresentation(
            productName: "ImageAll",
            foundationReady: true,
            catalogState: .starting(.paths)
        )
        startBootstrap(dependencies: dependencies)
    }

    func startBootstrap(dependencies: CatalogBootstrapDependencies) {
        // Invalidate any in-flight bootstrap/migration before starting a new generation.
        migrationCancelFlag.cancel()
        let cancelFlag = MigrationCancelFlag()
        migrationCancelFlag = cancelFlag
        bootstrapGeneration += 1
        let generation = bootstrapGeneration

        bootstrapDependencies = dependencies
        presentation = StartupPresentation(
            productName: presentation.productName,
            foundationReady: true,
            catalogState: .starting(.paths),
            storageMigrationProgress: nil
        )

        var stageDependencies = dependencies
        stageDependencies.onStage = { [weak self] stage in
            Task { @MainActor in
                guard let self, generation == self.bootstrapGeneration else { return }
                self.updateStage(stage)
            }
        }
        stageDependencies.pathsResolver = dependencies.pathsResolver.resolvingWithMigrationHooks(
            onProgress: { [weak self] progress in
                Task { @MainActor in
                    guard let self, generation == self.bootstrapGeneration else { return }
                    self.updateMigrationProgress(progress)
                }
            },
            isCancelled: {
                cancelFlag.isCancelled
            }
        )

        Task.detached(priority: .userInitiated) {
            let coordinator = CatalogBootstrapCoordinator(dependencies: stageDependencies)
            let result = coordinator.bootstrap()
            await MainActor.run {
                guard generation == self.bootstrapGeneration else {
                    if case let .ready(token) = result {
                        try? token.close()
                    }
                    return
                }
                self.applyBootstrapResult(result)
            }
        }
    }

    func retryBootstrap() {
        guard workspaceModel == nil else { return }
        startBootstrap(dependencies: bootstrapDependencies)
    }

    func cancelStorageMigration() {
        migrationCancelFlag.cancel()
    }

    func closeForTesting() throws {
        try runtimeToken?.close()
        runtimeToken = nil
    }

    private func updateStage(_ stage: CatalogStartupStage) {
        presentation = StartupPresentation(
            productName: presentation.productName,
            foundationReady: true,
            catalogState: .starting(stage),
            storageMigrationProgress: presentation.storageMigrationProgress
        )
        logger.info("catalogState=starting stage=\(stage.rawValue, privacy: .public)")
    }

    private func updateMigrationProgress(_ progress: ExternalAppStorageMigrationProgress) {
        presentation = StartupPresentation(
            productName: presentation.productName,
            foundationReady: true,
            catalogState: presentation.catalogState,
            storageMigrationProgress: progress
        )
    }

    private func applyBootstrapResult(_ result: CatalogBootstrapResult) {
        switch result {
        case let .ready(token):
            runtimeToken = token
            workspaceModel = workspaceFactory(token)
            presentation = StartupPresentation(
                productName: presentation.productName,
                foundationReady: true,
                catalogState: .catalogReady,
                storageMigrationProgress: presentation.storageMigrationProgress.map {
                    var completed = $0
                    if completed.phase != .completed {
                        completed.phase = .completed
                    }
                    return completed
                }
            )
            logger.info("catalogState=catalogReady")
        case .anotherInstanceRunning:
            presentation = StartupPresentation(
                productName: presentation.productName,
                foundationReady: true,
                catalogState: .anotherInstanceRunning,
                storageMigrationProgress: presentation.storageMigrationProgress
            )
            logger.info("catalogState=anotherInstanceRunning")
        case let .unavailable(reason):
            presentation = StartupPresentation(
                productName: presentation.productName,
                foundationReady: true,
                catalogState: .catalogUnavailable(reason),
                storageMigrationProgress: Self.normalizedUnavailableMigrationProgress(
                    reason: reason,
                    current: presentation.storageMigrationProgress
                )
            )
            logger.info("catalogState=catalogUnavailable reason=\(Self.reasonToken(reason), privacy: .public)")
        }
    }

    private static func normalizedUnavailableMigrationProgress(
        reason: CatalogUnavailableReason,
        current: ExternalAppStorageMigrationProgress?
    ) -> ExternalAppStorageMigrationProgress? {
        guard var progress = current else { return nil }
        switch reason {
        case .storageMigrationCancelled:
            progress.phase = .cancelled
        default:
            if progress.phase != .cancelled,
               progress.phase != .failed,
               progress.phase != .completed
            {
                progress.phase = .failed
            }
        }
        return progress
    }

    private static func reasonToken(_ reason: CatalogUnavailableReason) -> String {
        switch reason {
        case .pathsFailed:
            return "pathsFailed"
        case .lockIOFailed:
            return "lockIOFailed"
        case .schemaUnsupported:
            return "schemaUnsupported"
        case .integrityFailed:
            return "integrityFailed"
        case let .insufficientSpace(requiredBytes):
            return "insufficientSpace:\(requiredBytes)"
        case .snapshotFailed:
            return "snapshotFailed"
        case .migrationFailed:
            return "migrationFailed"
        case .publicationFailed:
            return "publicationFailed"
        case .finalOpenFailed:
            return "finalOpenFailed"
        case .recoveryFailed:
            return "recoveryFailed"
        case .storageMigrationCancelled:
            return "storageMigrationCancelled"
        }
    }
}

private final class MigrationCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

extension CatalogStartupOutcome {
    var displayToken: String {
        switch self {
        case let .starting(stage):
            return "starting(\(stage.rawValue))"
        case .catalogReady:
            return "catalogReady"
        case .anotherInstanceRunning:
            return "anotherInstanceRunning"
        case let .catalogUnavailable(reason):
            return "catalogUnavailable(\(reasonToken(reason)))"
        }
    }

    private func reasonToken(_ reason: CatalogUnavailableReason) -> String {
        switch reason {
        case .pathsFailed: return "pathsFailed"
        case .lockIOFailed: return "lockIOFailed"
        case .schemaUnsupported: return "schemaUnsupported"
        case .integrityFailed: return "integrityFailed"
        case let .insufficientSpace(requiredBytes):
            return "insufficientSpace:\(requiredBytes)"
        case .snapshotFailed: return "snapshotFailed"
        case .migrationFailed: return "migrationFailed"
        case .publicationFailed: return "publicationFailed"
        case .finalOpenFailed: return "finalOpenFailed"
        case .recoveryFailed: return "recoveryFailed"
        case .storageMigrationCancelled: return "storageMigrationCancelled"
        }
    }
}
