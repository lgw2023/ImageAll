import Foundation
@preconcurrency import ImageCaptureCore
import SwiftUI
import ImageAllRemoteProtocol

@MainActor
final class USBPhotoImportLink: ObservableObject {
    static let shared = USBPhotoImportLink()
    @Published private(set) var devices: [ImageAllUSBDevice] = []
    @Published var selectedDeviceID: Int?
    @Published private(set) var status = "USB 照片传输尚未连接"
    @Published private(set) var isConnecting = false
    @Published private(set) var isReady = false
    private var tunnel: ImageAllUSBMacTunnel?

    func refresh() async {
        do {
            devices = try await Task.detached { try ImageAllUSBMux.devices() }.value
            if !devices.contains(where: { $0.id == selectedDeviceID }) {
                selectedDeviceID = devices.count == 1 ? devices.first?.id : nil
            }
        } catch { status = error.localizedDescription }
    }
    func connect() async {
        guard tunnel == nil, let device = devices.first(where: { $0.id == selectedDeviceID }) else { return }
        guard await RemoteHostProcessHolder.isRunning(),
              let offer = await RemoteHostProcessHolder.startPairingSession(), offer.usesTLS else {
            status = "请先启用下方手机连接服务，并确认 Host 使用安全 TLS 身份。"; return
        }
        do {
            let session = try ImageAllUSBMacTunnel(device: device, offer: offer)
            tunnel = session; isConnecting = true; status = "请在手机“待分享”开启 USB，并确认此 Mac 的连接请求"
            let owner = self
            Task {
                do {
                    try await Task.detached {
                        try session.run {
                            Task { @MainActor in
                                guard owner.tunnel === session else { return }
                                owner.isReady = true; owner.isConnecting = false
                                owner.status = "USB 有线通道已连接 · 请在手机选择照片并导入"
                            }
                        }
                    }.value
                } catch {
                    guard owner.tunnel === session else { return }
                    owner.status = error.localizedDescription
                }
                guard owner.tunnel === session else { return }
                owner.tunnel = nil; owner.isReady = false; owner.isConnecting = false
            }
        } catch { status = error.localizedDescription }
    }
    func disconnect() {
        tunnel?.stop(); tunnel = nil; isReady = false; isConnecting = false
        status = "USB 已断开，传输暂停；不会自动改用无线网络"
    }
}

/// USB discovery is a connection hint only. Media and organization facts are
/// obtained together through the existing authorized iPhone App workflow.
@MainActor
final class ConnectedPhotoDeviceDiscovery: NSObject, ObservableObject, @preconcurrency ICDeviceBrowserDelegate {
    struct Device: Identifiable, Equatable {
        let id: UUID
        let name: String
    }
    @Published private(set) var devices: [Device] = []
    private let browser = ICDeviceBrowser()
    private var identities: [ObjectIdentifier: UUID] = [:]
    func start() {
        guard !browser.isBrowsing else { return }
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: 0x101)!
        browser.start()
    }
    func stop() { browser.stop(); identities = [:]; devices = [] }
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard device is ICCameraDevice, device.transportType == ICDeviceTransport.transportTypeUSB.rawValue else { return }
        let key = ObjectIdentifier(device)
        guard identities[key] == nil else { return }
        let id = UUID(); identities[key] = id
        devices.append(.init(id: id, name: device.name ?? "USB 照片设备"))
    }
    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        guard let id = identities.removeValue(forKey: ObjectIdentifier(device)) else { return }
        devices.removeAll { $0.id == id }
    }
}

struct DevicePhotoImportSettingsView: View {
    var body: some View { RemoteHostSettingsView() }
}

struct DevicePhotoConnectionCard: View {
    @StateObject private var discovery = ConnectedPhotoDeviceDiscovery()
    @ObservedObject private var usb = USBPhotoImportLink.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("连接的设备", systemImage: "cable.connector").font(.headline)
            if discovery.devices.isEmpty {
                Text("尚未发现有线照片设备。可以连接并解锁 iPhone，也可以直接使用已配对手机的网络连接。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(discovery.devices) { device in
                    HStack {
                        Label(device.name, systemImage: "iphone.gen3")
                        Spacer()
                        Label("USB 已连接", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
            }
            Text("照片、相簿、红心与标记统一通过 iPhone 上的 ImageAll 读取和导入。开启 USB 有线通道后，数据沿线缆传输；手机仍需确认照片访问权限和此 Mac 身份。")
                .font(.footnote).foregroundStyle(.secondary)
            if !usb.devices.isEmpty {
                Picker("有线传输设备", selection: $usb.selectedDeviceID) {
                    Text("请选择设备").tag(Optional<Int>.none)
                    ForEach(usb.devices) { device in Text(device.displayName).tag(Optional(device.id)) }
                }.disabled(usb.isReady || usb.isConnecting)
            }
            HStack {
                Button("刷新 USB") { Task { await usb.refresh() } }
                if usb.isReady || usb.isConnecting {
                    Button("断开 USB") { usb.disconnect() }
                } else {
                    Button("通过 USB 连接手机 App") { Task { await usb.connect() } }
                        .disabled(usb.selectedDeviceID == nil)
                }
            }
            Label(usb.status, systemImage: usb.isReady ? "cable.connector" : "info.circle")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .task { discovery.start(); await usb.refresh() }
        .onDisappear { discovery.stop() }
        .accessibilityIdentifier("connectedPhotoDevicesCard")
    }
}
