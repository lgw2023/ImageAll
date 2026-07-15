import Foundation
import os

@MainActor
final class CatalogStartupModel: ObservableObject {
    @Published private(set) var presentation: StartupPresentation
    @Published private(set) var workspaceModel: LibraryWorkspaceModel?

    private var runtimeToken: CatalogRuntimeToken?
    private let workspaceFactory: @MainActor (CatalogRuntimeToken) -> LibraryWorkspaceModel?
    private let logger = Logger(subsystem: "com.imageall.app", category: "CatalogStartup")

    init(
        dependencies: CatalogBootstrapDependencies,
        workspaceFactory: @escaping @MainActor (CatalogRuntimeToken) -> LibraryWorkspaceModel? = { _ in nil }
    ) {
        self.workspaceFactory = workspaceFactory
        presentation = StartupPresentation(
            productName: "ImageAll",
            foundationReady: true,
            catalogState: .starting(.paths)
        )
        startBootstrap(dependencies: dependencies)
    }

    func startBootstrap(dependencies: CatalogBootstrapDependencies) {
        presentation = StartupPresentation(
            productName: presentation.productName,
            foundationReady: true,
            catalogState: .starting(.paths)
        )

        var stageDependencies = dependencies
        stageDependencies.onStage = { [weak self] stage in
            Task { @MainActor in
                self?.updateStage(stage)
            }
        }

        Task.detached(priority: .userInitiated) {
            let coordinator = CatalogBootstrapCoordinator(dependencies: stageDependencies)
            let result = coordinator.bootstrap()
            await MainActor.run {
                self.applyBootstrapResult(result)
            }
        }
    }

    func closeForTesting() throws {
        try runtimeToken?.close()
        runtimeToken = nil
    }

    private func updateStage(_ stage: CatalogStartupStage) {
        presentation = StartupPresentation(
            productName: presentation.productName,
            foundationReady: true,
            catalogState: .starting(stage)
        )
        logger.info("catalogState=starting stage=\(stage.rawValue, privacy: .public)")
    }

    private func applyBootstrapResult(_ result: CatalogBootstrapResult) {
        switch result {
        case let .ready(token):
            runtimeToken = token
            workspaceModel = workspaceFactory(token)
            presentation = StartupPresentation(
                productName: presentation.productName,
                foundationReady: true,
                catalogState: .catalogReady
            )
            logger.info("catalogState=catalogReady")
        case .anotherInstanceRunning:
            presentation = StartupPresentation(
                productName: presentation.productName,
                foundationReady: true,
                catalogState: .anotherInstanceRunning
            )
            logger.info("catalogState=anotherInstanceRunning")
        case let .unavailable(reason):
            presentation = StartupPresentation(
                productName: presentation.productName,
                foundationReady: true,
                catalogState: .catalogUnavailable(reason)
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

extension CatalogStartupOutcome {
    var displayToken: String {
        switch self {
        case let .starting(stage):
            return "catalogStarting(\(stage.rawValue))"
        case .catalogReady:
            return "catalogReady"
        case .anotherInstanceRunning:
            return "anotherInstanceRunning"
        case let .catalogUnavailable(reason):
            return "catalogUnavailable(\(Self.reasonToken(reason)))"
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
        }
    }
}
