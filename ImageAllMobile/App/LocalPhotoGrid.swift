import SwiftUI
import Photos
import UIKit

struct LocalPhotoGrid<Cell: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let items: [LocalShareItem]
    @ViewBuilder let cell: (LocalShareItem) -> Cell

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2),
                                count: dynamicTypeSize.isAccessibilitySize ? 2 : 3), spacing: 2) {
            ForEach(items) { item in cell(item) }
        }
    }
}

struct LocalPhotoTile: View {
    let item: LocalShareItem
    var selecting = false
    var selected = false

    var body: some View {
        Color.clear.aspectRatio(1, contentMode: .fit)
            .overlay { LocalPhotoThumbnail(item: item).clipped() }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 4) {
                    if item.isFavorite { Image(systemName: "heart.fill") }
                    if item.isVideo { Image(systemName: "video.fill") }
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.7), radius: 2).padding(7)
            }
            .overlay { if selecting && selected { Color.accentColor.opacity(0.15) } }
            .overlay(alignment: .bottomTrailing) {
                if selecting {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title2).symbolRenderingMode(.palette)
                        .foregroundStyle(selected ? Color.accentColor : Color.white, .white)
                        .shadow(color: .black.opacity(0.5), radius: 1)
                        .padding(7)
                }
            }
            .clipped()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.accessibilityDescription)
            .accessibilityValue(selecting ? (selected ? "已选择" : "未选择") : "")
    }
}

/// The real browser and synthetic acceptance use the same content layout.
struct LocalPhotoLibraryContent<Destination: View>: View {
    let items: [LocalShareItem]
    let sharedCount: Int
    let limited: Bool
    let hasMore: Bool
    let loadMore: () -> Void
    @ViewBuilder let destination: (LocalShareItem) -> Destination

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text("照片").font(.title2.bold())
                    Spacer()
                    Text("待分享 \(sharedCount) 项").font(.subheadline).foregroundStyle(.secondary)
                }.padding(.horizontal)
                if limited {
                    Label("仅显示已授权照片，可在系统设置中管理访问范围。", systemImage: "lock.shield")
                        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                }
                if items.isEmpty {
                    ContentUnavailableView("暂无可显示的照片", systemImage: "photo.on.rectangle",
                                           description: Text("刷新图库，或核对系统照片访问权限。"))
                } else {
                    LocalPhotoGrid(items: items) { item in
                        NavigationLink { destination(item) } label: { LocalPhotoTile(item: item) }
                            .buttonStyle(.plain)
                    }
                }
                VStack(spacing: 8) {
                    Text("已载入 \(items.count) 项").font(.subheadline).foregroundStyle(.secondary)
                    if hasMore { Button("载入更多照片", action: loadMore).buttonStyle(.bordered) }
                }.padding(.bottom, 24)
            }.padding(.top, 8)
        }
    }
}

/// No network access; only derived thumbnails. A nil identifier never invokes PhotoKit.
struct LocalPhotoThumbnail: View {
    let item: LocalShareItem
    var preview = false
    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?
    @State private var activeRequest: UUID?
    @State private var loading = false
    @State private var unavailableMessage: String?

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image {
                    if preview { Image(uiImage: image).resizable().scaledToFit() }
                    else { Image(uiImage: image).resizable().scaledToFill() }
                } else {
                    #if DEBUG
                    if let fixtureIndex = item.fixtureIndex { LocalSyntheticPhoto(index: fixtureIndex).aspectRatio(1, contentMode: .fit) }
                    else { placeholder }
                    #else
                    placeholder
                    #endif
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .task(id: item.localIdentifier) {
            let generation = UUID()
            activeRequest = generation
            image = nil
            unavailableMessage = nil
            loading = true
            guard let identifier = item.localIdentifier else {
                loading = false
                unavailableMessage = "当前无法访问这项内容。已选记录仍保留，可回到系统照片核对。"
                return
            }
            let fetchOptions = PHFetchOptions()
            fetchOptions.includeHiddenAssets = false
            fetchOptions.includeAssetSourceTypes = .typeUserLibrary
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: fetchOptions).firstObject else {
                loading = false
                unavailableMessage = "当前无法访问这项内容。已选记录仍保留，可回到系统照片核对。"
                return
            }
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = false
            options.deliveryMode = .opportunistic
            let size: CGFloat = preview ? 1024 : 320
            requestID = PHImageManager.default().requestImage(for: asset,
                targetSize: CGSize(width: size, height: size), contentMode: preview ? .aspectFit : .aspectFill,
                options: options) { @Sendable candidate, info in
                guard (info?[PHImageCancelledKey] as? Bool) != true else { return }
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) == true
                let hasError = info?[PHImageErrorKey] != nil
                Task { @MainActor in
                    guard activeRequest == generation else { return }
                    if let candidate, !hasError {
                        image = candidate
                        loading = false
                        unavailableMessage = nil
                    } else if !degraded, image == nil {
                        loading = false
                        unavailableMessage = inCloud
                            ? "本机没有可用预览，且未下载 iCloud 内容。已选记录仍保留，可回到系统照片核对。"
                            : "本机暂时无法取得预览。已选记录仍保留，可回到系统照片核对。"
                    }
                }
            }
        }
        .onDisappear {
            activeRequest = nil
            if let requestID { PHImageManager.default().cancelImageRequest(requestID) }
            requestID = nil; image = nil; loading = false
        }
    }

    @ViewBuilder private var placeholder: some View {
        if preview {
            VStack(spacing: 12) {
                if loading {
                    ProgressView().tint(.white)
                    Text("正在载入预览").font(.headline)
                } else {
                    Image(systemName: item.isVideo ? "video.slash" : "photo").font(.largeTitle)
                    Text("无法预览").font(.headline)
                    Text(unavailableMessage ?? "本机暂时没有可用预览。已选记录仍保留。")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
            }.foregroundStyle(.white).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Rectangle().fill(Color(uiColor: .secondarySystemFill))
                .overlay { Image(systemName: item.isVideo ? "video" : "photo").foregroundStyle(.secondary) }
        }
    }
}

extension LocalShareItem {
    var accessibilityDescription: String {
        var text = isVideo ? "视频" : "照片"
        if let date { text += "，" + date.formatted(date: .abbreviated, time: .omitted) }
        if isFavorite { text += "，已收藏" }
        return text
    }
}

#if DEBUG
/// Vector-only fixture; these images are never added to Photos or persisted as user assets.
private struct LocalSyntheticPhoto: View {
    let index: Int
    private let skies: [Color] = [Color(red: 0.70, green: 0.84, blue: 0.91), Color(red: 0.95, green: 0.73, blue: 0.57),
                                  Color(red: 0.62, green: 0.76, blue: 0.72), Color(red: 0.44, green: 0.59, blue: 0.74)]
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            let variant = index % 8
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(skies[variant % 4]))
            let sun = CGRect(x: w * (variant.isMultiple(of: 2) ? 0.67 : 0.18), y: h * 0.16, width: w * 0.15, height: w * 0.15)
            context.fill(Path(ellipseIn: sun), with: .color(Color(red: 1, green: 0.94, blue: 0.76)))
            if variant < 4 {
                for layer in 0..<3 {
                    var ridge = Path()
                    ridge.move(to: CGPoint(x: 0, y: h))
                    ridge.addLine(to: CGPoint(x: 0, y: h * (0.58 + Double(layer) * 0.1)))
                    ridge.addLine(to: CGPoint(x: w * 0.33, y: h * (0.28 + Double(layer) * 0.19)))
                    ridge.addLine(to: CGPoint(x: w * 0.65, y: h * (0.52 + Double(layer) * 0.08)))
                    ridge.addLine(to: CGPoint(x: w, y: h * (0.31 + Double(layer) * 0.2)))
                    ridge.addLine(to: CGPoint(x: w, y: h)); ridge.closeSubpath()
                    context.fill(ridge, with: .color(Color(red: 0.15 + Double(layer) * 0.08,
                                                         green: 0.35 + Double(layer) * 0.06, blue: 0.40 + Double(layer) * 0.04)))
                }
            } else {
                context.fill(Path(CGRect(x: 0, y: h * 0.48, width: w, height: h * 0.52)),
                             with: .color(Color(red: 0.17, green: 0.46, blue: 0.58)))
                var shore = Path()
                shore.move(to: CGPoint(x: 0, y: h * 0.60))
                shore.addQuadCurve(to: CGPoint(x: w, y: h * 0.86), control: CGPoint(x: w * 0.63, y: h * 0.50))
                shore.addLine(to: CGPoint(x: w, y: h)); shore.addLine(to: CGPoint(x: 0, y: h)); shore.closeSubpath()
                context.fill(shore, with: .color(Color(red: 0.89, green: 0.82, blue: 0.63)))
                for i in 0..<3 {
                    let x = w * (0.2 + Double(i) * 0.22)
                    context.fill(Path(CGRect(x: x, y: h * 0.85, width: w * 0.04, height: h * 0.15)), with: .color(.brown))
                    context.fill(Path(ellipseIn: CGRect(x: x - w * 0.07, y: h * 0.72, width: w * 0.18, height: h * 0.17)),
                                 with: .color(Color(red: 0.14, green: 0.37, blue: 0.25)))
                }
            }
        }
    }
}
#endif
