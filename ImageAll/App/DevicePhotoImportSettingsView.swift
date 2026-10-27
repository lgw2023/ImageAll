import Foundation
@preconcurrency import ImageCaptureCore
import SwiftUI
import ImageAllRemoteProtocol

@MainActor
final class USBPhotoImportLink: ObservableObject {
    static let shared = USBPhotoImportLink()
    @Published private(set) var devices: [ImageAllUSBDevice] = []
    @Published var selectedDeviceID: Int?
    @Published private(set) var status = "插线并打开手机 ImageAll，将自动连接"
    @Published private(set) var isConnecting = false
    @Published private(set) var isReady = false
    private var tunnel: ImageAllUSBMacTunnel?
    private var activeDevice: ImageAllUSBDevice?
    private var monitor: Task<Void, Never>?
    private var attemptID = UUID()
    private var pausedSerial: String?
    private var nextAttemptAt: TimeInterval = 0
    private var retryDelay: TimeInterval = 2

    /// App-owned, not Settings-owned: closing Settings must not stop discovery.
    func startAutomaticConnection() {
        guard monitor == nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let enabled = RemoteHostProcessHolder.isEnabled()
                let running = await RemoteHostProcessHolder.isRunning()
                if !enabled || !running {
                    if self.tunnel != nil || self.isConnecting { self.stopTransport() }
                    self.status = enabled ? "正在等待 Mac 连接服务…" : "连接已关闭"
                } else if self.devices.count == 1, self.tunnel == nil, !self.isConnecting,
                          self.pausedSerial == nil, ProcessInfo.processInfo.systemUptime >= self.nextAttemptAt {
                    self.selectedDeviceID = self.devices.first?.id
                    await self.connect(automatic: true)
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    func refresh() async {
        do {
            let found = try await Task.detached { try ImageAllUSBMux.devices() }.value
            if devices != found { devices = found }
            if let pausedSerial, !found.contains(where: { $0.serial == pausedSerial }) {
                self.pausedSerial = nil; nextAttemptAt = 0; retryDelay = 2
            }
            if let activeDevice, !found.contains(activeDevice) {
                stopTransport(); nextAttemptAt = 0; retryDelay = 2
                status = "USB 已断开；重新插线后自动连接"
            }
            if !found.contains(where: { $0.id == selectedDeviceID }) {
                selectedDeviceID = found.count == 1 ? found.first?.id : nil
            }
            if found.count > 1 && tunnel == nil {
                status = "检测到多台设备，请选择要连接的 iPhone"
            }
        } catch { status = error.localizedDescription }
    }

    func connect(automatic: Bool = false) async {
        guard tunnel == nil, !isConnecting,
              let device = devices.first(where: { $0.id == selectedDeviceID }) else { return }
        if !automatic { pausedSerial = nil; retryDelay = 2 }
        isConnecting = true
        let generation = UUID(); attemptID = generation
        guard RemoteHostProcessHolder.isEnabled(), await RemoteHostProcessHolder.isRunning() else {
            guard attemptID == generation else { return }
            isConnecting = false; status = "请打开本页“允许连接”，再连接手机。"; return
        }
        // Reuse a still-valid offer so discovery does not invalidate a QR code
        // or an identity confirmation already displayed on the phone.
        var offer = await RemoteHostProcessHolder.currentOffer()
        if offer == nil || offer!.expiresAtMs <= Int64(Date().timeIntervalSince1970 * 1000) + 10_000 {
            offer = await RemoteHostProcessHolder.startPairingSession()
        }
        guard attemptID == generation else { return }
        guard let offer, offer.usesTLS else {
            isConnecting = false; status = "Mac 安全连接服务尚未就绪"; scheduleRetry(); return
        }
        do {
            let session = try ImageAllUSBMacTunnel(device: device, offer: offer)
            tunnel = session; activeDevice = device
            status = "正在连接 iPhone；首次连接请在手机确认 Mac 身份"
            Task { [weak self] in
                do {
                    try await Task.detached {
                        try session.run { [weak self] in
                            Task { @MainActor in
                                guard let self, self.tunnel === session else { return }
                                self.isReady = true; self.isConnecting = false; self.retryDelay = 2
                                self.status = "USB 通道已连接 · 请在手机开始导入"
                            }
                        }
                    }.value
                } catch {
                    guard let self, self.tunnel === session else { return }
                    self.status = "等待手机 ImageAll；打开后将自动重连"
                }
                guard let self, self.tunnel === session else { return }
                self.tunnel = nil; self.activeDevice = nil; self.isReady = false; self.isConnecting = false
                self.scheduleRetry()
            }
        } catch { isConnecting = false; status = error.localizedDescription; scheduleRetry() }
    }
    private func scheduleRetry() {
        nextAttemptAt = ProcessInfo.processInfo.systemUptime + retryDelay
        retryDelay = min(15, retryDelay * 2)
    }
    private func stopTransport() {
        attemptID = UUID()
        let previous = tunnel; tunnel = nil; activeDevice = nil
        isReady = false; isConnecting = false; previous?.stop()
    }
    func disconnect() {
        pausedSerial = activeDevice?.serial ?? devices.first(where: { $0.id == selectedDeviceID })?.serial
        stopTransport()
        status = "自动连接已暂停；点“连接 iPhone”或重新插线可恢复"
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
    @ObservedObject private var usb = USBPhotoImportLink.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if !usb.devices.isEmpty {
                    Picker("手机", selection: $usb.selectedDeviceID) {
                        Text("请选择设备").tag(Optional<Int>.none)
                        ForEach(usb.devices) { device in
                            Text(device.displayName).tag(Optional(device.id))
                        }
                    }.disabled(usb.isReady || usb.isConnecting)
                } else {
                    Label("连接并解锁 iPhone", systemImage: "cable.connector")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("刷新") { Task { await usb.refresh() } }
                if usb.isReady || usb.isConnecting {
                    Button("断开") { usb.disconnect() }
                } else {
                    Button("连接 iPhone") { Task { await usb.connect() } }
                        .disabled(usb.selectedDeviceID == nil)
                }
            }
            Text(usb.isReady ? "USB 已连接 · 请在手机开始导入" : usb.status)
                .font(.footnote).foregroundStyle(.secondary)
            if !usb.isReady && !usb.isConnecting {
                Text("打开手机 ImageAll 即可自动连接；首次使用在手机确认 Mac 身份。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { usb.startAutomaticConnection(); await usb.refresh() }
        .accessibilityIdentifier("connectedPhotoDevicesCard")
    }
}
