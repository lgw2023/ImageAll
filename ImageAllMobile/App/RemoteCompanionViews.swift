import ImageAllRemoteProtocol
import SwiftUI
import UIKit

struct RemoteCompanionRootView: View {
    @ObservedObject var model: RemoteCompanionModel

    var body: some View {
        NavigationStack {
            Group {
                if model.isConnected {
                    libraryView
                } else {
                    connectionView
                }
            }
            .navigationTitle("ImageAll Mobile")
            .toolbar {
                if model.isConnected {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("断开") { model.disconnect() }
                    }
                }
            }
        }
    }

    private var connectionView: some View {
        Form {
            Section("Mac Host") {
                TextField("主机", text: $model.host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("端口", text: $model.port)
                    .keyboardType(.numberPad)
                SecureField("Access Token", text: $model.accessToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section {
                Button {
                    Task { await model.connect() }
                } label: {
                    if model.isBusy {
                        ProgressView()
                    } else {
                        Text("连接")
                    }
                }
                .disabled(model.isBusy)
            }
            if let statusMessage = model.statusMessage {
                Section("状态") {
                    Text(statusMessage)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Text("在 Mac Debug 构建启用 Host：defaults write com.gwlee.ImageAll imageall.remoteHost.enabled -bool YES")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var libraryView: some View {
        VStack(spacing: 0) {
            Form {
                if !model.sources.isEmpty {
                    Picker("来源", selection: $model.selectedSourceID) {
                        ForEach(model.sources) { source in
                            Text(source.displayName).tag(Optional(source.id))
                        }
                    }
                    .onChange(of: model.selectedSourceID) { _, _ in
                        Task { await model.reloadAssets(reset: true) }
                    }
                }
                if !model.tags.isEmpty {
                    Picker("标签", selection: $model.selectedTagID) {
                        ForEach(model.tags) { tag in
                            Text(tag.displayName).tag(Optional(tag.id))
                        }
                    }
                }
            }
            .frame(height: model.tags.isEmpty ? 90 : 140)

            assetGrid

            if let statusMessage = model.statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
            }

            HStack {
                decisionButton("接受", action: .accept)
                decisionButton("拒绝", action: .reject)
                decisionButton("清除", action: .clear)
            }
            .padding()
        }
    }

    private var assetGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8),
                ],
                spacing: 8
            ) {
                ForEach(model.assets) { asset in
                    assetCell(asset)
                        .onAppear {
                            Task { await model.loadMoreIfNeeded(current: asset) }
                        }
                }
            }
            .padding(8)
        }
    }

    private func assetCell(_ asset: RemoteAssetSummary) -> some View {
        let selected = model.selectedAssetIDs.contains(asset.id)
        return Button {
            model.toggleSelection(asset.id)
        } label: {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let data = model.thumbnailDataByAssetID[asset.id],
                       let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.secondary.opacity(0.15)
                            .overlay {
                                Text(asset.fileName ?? asset.id.uuidString.prefix(8).description)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(4)
                            }
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipped()
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 3)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))

                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(6)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func decisionButton(_ title: String, action: RemoteTagDecisionAction) -> some View {
        Button(title) {
            Task { await model.applyTagDecision(action) }
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isBusy || model.selectedAssetIDs.isEmpty || model.selectedTagID == nil)
    }
}
