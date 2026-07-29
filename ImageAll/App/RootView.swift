import SwiftUI

struct RootView: View {
    let presentation: StartupPresentation
    let workspaceModel: LibraryWorkspaceModel?
    var onCancelStorageMigration: (() -> Void)?
    var onRetryBootstrap: (() -> Void)?

    init(
        presentation: StartupPresentation,
        workspaceModel: LibraryWorkspaceModel? = nil,
        onCancelStorageMigration: (() -> Void)? = nil,
        onRetryBootstrap: (() -> Void)? = nil
    ) {
        self.presentation = presentation
        self.workspaceModel = workspaceModel
        self.onCancelStorageMigration = onCancelStorageMigration
        self.onRetryBootstrap = onRetryBootstrap
    }

    var body: some View {
        switch presentation.catalogState {
        case .catalogReady:
            if let workspaceModel {
                LibraryWorkspaceView(model: workspaceModel)
            } else {
                startupStatus
            }
        case .starting, .anotherInstanceRunning, .catalogUnavailable:
            startupStatus
        }
    }

    private var startupStatus: some View {
        VStack(spacing: 12) {
            Text(presentation.productName).font(.title)
            if let migration = presentation.storageMigrationProgress,
               migration.phase != .completed
            {
                storageMigrationPanel(migration)
            } else {
                ProgressView()
                    .opacity(isStarting ? 1 : 0)
            }
            Text(presentation.catalogState.displayToken)
                .font(.body.monospaced())
                .accessibilityIdentifier("catalogStateToken")
            if case .catalogUnavailable = presentation.catalogState {
                Button("重试启动") {
                    onRetryBootstrap?()
                }
                .accessibilityIdentifier("startupRetryButton")
                .persistentHelp("重新初始化目录和数据库，然后再次进入 ImageAll。")
            }
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 240)
    }

    private func storageMigrationPanel(
        _ migration: ExternalAppStorageMigrationProgress
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("应用存储迁移")
                .font(.headline)
            Text(migration.statusText)
                .foregroundStyle(.secondary)
            ProgressView(value: migration.fractionCompleted)
                .accessibilityIdentifier("storageMigrationProgress")
            Text(migrationProgressCaption(migration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if isStarting, migration.phase != .cancelled, migration.phase != .failed {
                Button("取消迁移") {
                    onCancelStorageMigration?()
                }
                .accessibilityIdentifier("storageMigrationCancelButton")
                .persistentHelp("停止当前存储迁移；已经安全完成的步骤会保留，原照片不会被修改。")
            }
        }
        .frame(maxWidth: 360, alignment: .leading)
    }

    private func migrationProgressCaption(
        _ migration: ExternalAppStorageMigrationProgress
    ) -> String {
        if migration.totalBytes > 0 {
            return "\(formattedBytes(migration.bytesCopied)) / \(formattedBytes(migration.totalBytes))"
                + " · \(migration.filesCopied)/\(migration.totalFiles) 个文件"
        }
        if migration.totalFiles > 0 {
            return "\(migration.filesCopied)/\(migration.totalFiles) 个文件"
        }
        return migration.statusText
    }

    private func formattedBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private var isStarting: Bool {
        if case .starting = presentation.catalogState { return true }
        return false
    }
}

#if DEBUG
#Preview {
    RootView(
        presentation: StartupPresentation(
            productName: "ImageAll",
            foundationReady: true,
            catalogState: .catalogReady
        )
    )
}
#endif
