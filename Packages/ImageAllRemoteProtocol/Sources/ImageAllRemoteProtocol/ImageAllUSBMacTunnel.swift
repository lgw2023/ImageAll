#if os(macOS)
import Darwin
import Foundation

public struct ImageAllUSBDevice: Identifiable, Sendable, Equatable {
    public let id: Int
    public let serial: String
    public var displayName: String { "iPhone / iPad · \(serial.suffix(6))" }
}

/// Minimal native usbmuxd client. Device listing deliberately excludes network
/// devices; a USB selection can never silently connect via Wi-Fi.
public enum ImageAllUSBMux {
    public static func devices() throws -> [ImageAllUSBDevice] {
        let socket = try USBTunnelSocket.unix()
        let reply = try request(["MessageType": "ListDevices"], on: socket)
        return (reply["DeviceList"] as? [[String: Any]] ?? []).compactMap { row in
            guard let id = row["DeviceID"] as? Int,
                  let properties = row["Properties"] as? [String: Any],
                  properties["ConnectionType"] as? String == "USB",
                  let serial = properties["SerialNumber"] as? String else { return nil }
            return ImageAllUSBDevice(id: id, serial: serial)
        }
    }
    fileprivate static func connect(device: ImageAllUSBDevice) throws -> USBTunnelSocket {
        // Revalidate physical route before each new connection. Handles may be
        // reused after unplugging, so both handle and serial must still match.
        guard try devices().contains(device) else { throw ImageAllUSBError.disconnected }
        let socket = try USBTunnelSocket.unix()
        let reply = try request(["MessageType": "Connect", "DeviceID": device.id,
            "PortNumber": Int(ImageAllUSBHello.devicePort.bigEndian)], on: socket)
        guard reply["Number"] as? Int == 0 else {
            throw ImageAllUSBError.unavailable("手机 USB 服务尚未开启。请解锁手机，在 ImageAll“待分享”开启 USB 有线连接。")
        }
        socket.timeout(seconds: 120)
        return socket
    }
    private static func request(_ fields: [String: Any], on socket: USBTunnelSocket) throws -> [String: Any] {
        var payload = fields
        payload["ClientVersionString"] = "ImageAll USB 1"
        payload["ProgName"] = "ImageAll"
        payload["kLibUSBMuxVersion"] = 3
        let body = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        var header = Data()
        for word in [UInt32(body.count + 16), 1, 8, 1] {
            var little = word.littleEndian
            header.append(withUnsafeBytes(of: &little) { Data($0) })
        }
        try socket.write(header + body)
        let response = try socket.read(count: 16)
        let words = stride(from: 0, to: 16, by: 4).map { offset in
            response[offset..<offset + 4].enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << ($1.offset * 8)) }
        }
        guard words[0] >= 16, words[0] <= 1_048_576, words[1] == 1, words[2] == 8, words[3] == 1,
              let result = try PropertyListSerialization.propertyList(from: socket.read(count: Int(words[0]) - 16), options: [], format: nil) as? [String: Any] else {
            throw ImageAllUSBError.invalidHeader
        }
        return result
    }
}

/// Owns a control connection and eight bounded raw TLS pipes. Stop shuts down
/// sockets to interrupt blocked IO; file descriptors close only after the last
/// worker releases ownership, avoiding reuse races.
public final class ImageAllUSBMacTunnel: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var sockets: [ObjectIdentifier: USBTunnelSocket] = [:]
    private let device: ImageAllUSBDevice
    private let offer: RemotePairingOffer
    private let key = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
    public init(device: ImageAllUSBDevice, offer: RemotePairingOffer) throws {
        _ = try ImageAllUSBHello(role: .control, sessionKey: key, offer: offer).validated()
        self.device = device; self.offer = offer
    }
    public func stop() {
        lock.lock(); stopped = true; let all = Array(sockets.values); lock.unlock()
        all.forEach { $0.cancel() }
    }
    private var isStopped: Bool { lock.withLock { stopped } }
    private func add(_ socket: USBTunnelSocket) throws {
        try lock.withLock {
            guard !stopped else { throw ImageAllUSBError.disconnected }
            sockets[ObjectIdentifier(socket)] = socket
        }
    }
    private func remove(_ socket: USBTunnelSocket) {
        _ = lock.withLock { sockets.removeValue(forKey: ObjectIdentifier(socket)) }
        socket.cancel()
    }
    public func run(onReady: @escaping @Sendable () -> Void) throws {
        defer { stop() }
        let control = try ImageAllUSBMux.connect(device: device)
        try add(control)
        try control.write(ImageAllUSBHello(role: .control, sessionKey: key, offer: offer).framed())
        control.timeout(seconds: ImageAllUSBHello.approvalTimeoutSeconds(for: offer))
        guard try control.read(count: 1) == Data([1]) else { throw ImageAllUSBError.invalidHeader }
        guard !isStopped else { throw ImageAllUSBError.disconnected }
        onReady()
        for _ in 0..<8 {
            DispatchQueue.global(qos: .utility).async { [self] in
                while !isStopped {
                    do { try dataPipe() }
                    catch { if isStopped { return }; Thread.sleep(forTimeInterval: 0.2) }
                }
            }
        }
        control.timeout(seconds: 8)
        while !isStopped {
            try control.write(Data([0x50]))
            guard try control.read(count: 1) == Data([0x50]) else { throw ImageAllUSBError.disconnected }
            Thread.sleep(forTimeInterval: 1)
        }
    }
    private func dataPipe() throws {
        let phone = try ImageAllUSBMux.connect(device: device)
        try add(phone); defer { remove(phone) }
        try phone.write(ImageAllUSBHello(role: .data, sessionKey: key).framed())
        // Idle pool pipes wait until used or until control loss stops the whole
        // session. A read timeout here would leave stale candidates on the phone.
        phone.timeout(seconds: 0)
        guard try phone.read(count: 1) == Data([1]), !isStopped else { throw ImageAllUSBError.disconnected }
        let host = try USBTunnelSocket.loopback(port: UInt16(offer.listenPort))
        try add(host); defer { remove(host) }
        try USBTunnelSocket.relay(phone, host)
    }
}

private final class USBTunnelSocket: @unchecked Sendable {
    let fd: Int32
    private let lock = NSLock()
    private var cancelled = false
    init(fd: Int32) {
        self.fd = fd
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        timeout(seconds: 5)
    }
    deinit { Darwin.close(fd) }
    func cancel() { lock.withLock { if !cancelled { cancelled = true; shutdown(fd, SHUT_RDWR) } } }
    func timeout(seconds: Int) {
        var value = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout.size(ofValue: value)))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout.size(ofValue: value)))
    }
    static func unix() throws -> USBTunnelSocket {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ImageAllUSBError.system(errno) }
        let socket = USBTunnelSocket(fd: fd)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array("/var/run/usbmuxd".utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw ImageAllUSBError.system(errno) }
        return socket
    }
    static func loopback(port: UInt16) throws -> USBTunnelSocket {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ImageAllUSBError.system(errno) }
        let socket = USBTunnelSocket(fd: fd)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { throw ImageAllUSBError.system(errno) }
        return socket
    }
    func read(count: Int) throws -> Data {
        var result = Data(count: count)
        var offset = 0
        try result.withUnsafeMutableBytes { bytes in
            while offset < count {
                let read = recv(fd, bytes.baseAddress!.advanced(by: offset), count - offset, 0)
                if read < 0, errno == EINTR { continue }
                guard read > 0 else { throw ImageAllUSBError.disconnected }
                offset += read
            }
        }
        return result
    }
    func write(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                let written = send(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset, 0)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw ImageAllUSBError.disconnected }
                offset += written
            }
        }
    }
    static func relay(_ first: USBTunnelSocket, _ second: USBTunnelSocket) throws {
        first.timeout(seconds: 15); second.timeout(seconds: 15)
        var descriptors = [pollfd(fd: first.fd, events: Int16(POLLIN), revents: 0), pollfd(fd: second.fd, events: Int16(POLLIN), revents: 0)]
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            let ready = poll(&descriptors, 2, -1)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { throw ImageAllUSBError.disconnected }
            for index in 0..<2 where descriptors[index].revents != 0 {
                let count = recv(descriptors[index].fd, &buffer, buffer.count, 0)
                if count == 0 {
                    shutdown(index == 0 ? second.fd : first.fd, SHUT_WR)
                    descriptors[index].fd = -1
                    if descriptors.allSatisfy({ $0.fd == -1 }) { return }
                    continue
                }
                guard count > 0 else { throw ImageAllUSBError.disconnected }
                try (index == 0 ? second : first).write(Data(buffer.prefix(count)))
            }
        }
    }
}
#endif
