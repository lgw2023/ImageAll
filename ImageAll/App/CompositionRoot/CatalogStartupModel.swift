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
    private let migrationCancelFlag = MigrationCancelFlag()

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
        bootstrapDependencies = dependencies
        migrationCancelFlag.reset()
        presentation = StartupPresentation(
            productName: presentation.productName,
            foundationReady: true,
            catalogState: .starting(.paths),
            storageMigrationProgress: nil
        )

        var stageDependencies = dependencies
        stageDependencies.onStage = { [weak self] stage in
            Task { @MainActor in
                self?.updateStage(stage)
            }
        }
        if dependencies.pathsResolver is FoundationAppPathsResolver {
            let cancelFlag = migrationCancelFlag
            stageDependencies.pathsResolver = FoundationAppPathsResolver(
                onMigrationProgress: { [weak self] progress in
                    Task { @MainActor in
                        self?.updateMigrationProgress(progress)
                    }
                },
                isMigrationCancelled: {
                    cancelFlag.isCancelled
                }
            )
        }

        Task.detached(priority: .userInitiated) {
            let coordinator = CatalogBootstrapCoordinator(dependencies: stageDependencies)
            let result = coordinator.bootstrap()
            await MainActor.run {
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
                storageMigrationProgress: presentation.storageMigrationProgress
            )
            logger.info("catalogState=catalogUnavailable reason=\(Self.reasonToken(reason), privacy: .public)")
        }
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
        case .insufficientSpace:
            return "insufficientSpace"
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

    func reset() {
        lock.withLock { cancelled = false }
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
        case .insufficientSpace: return "insufficientSpace"
        case .snapshotFailed: return "snapshotFailed"
        case .migrationFailed: return "migrationFailed"
        case .publicationFailed: return "publicationFailed"
        case .finalOpenFailed: return "finalOpenFailed"
        case .recoveryFailed: return "recoveryFailed"
        }
    }
}
