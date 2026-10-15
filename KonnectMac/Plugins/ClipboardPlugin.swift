import AppKit
import Darwin
import Foundation
import ImageIO
import Security

@MainActor
class ClipboardPlugin: PluginProtocol {
    struct ImageTransferMetadata: Equatable {
        let port: UInt16
        let size: Int
        let mimeType: String
    }

    let device: Device
    private var lastSentContent = ""
    var lastReceivedContent = "" {
        didSet {
            guard !lastReceivedContent.isEmpty else { return }
            lastSentContent = ""
            lastSentImageFingerprint = nil
            lastReceivedImageFingerprint = nil
        }
    }
    private var lastSentImageFingerprint: Int?
    private var lastReceivedImageFingerprint: Int?
    private var imageSendInProgress = false
    private var pendingImageTransfer: (data: Data, fingerprint: Int)?
    private var clipboardTimer: Timer?
    private var lastChangeCount = 0

    private static let maxTextBytes = 131072
    private static let maxImageBytes = 25 * 1024 * 1024
    private static let chunkSize = 65536
    private static let acceptTimeout: TimeInterval = 20
    private static let connectTimeout: TimeInterval = 15
    private static let handshakeTimeout: TimeInterval = 20
    private static let stallTimeout: TimeInterval = 20
    private static let totalTimeout: TimeInterval = 2 * 60

    init(device: Device) {
        self.device = device
    }

    deinit {
        // Timer invalidation must happen on the thread that created it (main thread).
        // Since deinit can run on any thread, schedule it on main.
        if let timer = clipboardTimer {
            DispatchQueue.main.async { timer.invalidate() }
        }
    }

    func start() {
        guard clipboardTimer == nil else { return }
        observePeerCapabilities()
        startMonitoring()
    }

    func stop() {
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        pendingImageTransfer = nil
        device.peerIncomingCapabilities.removeAll()
        device.capabilityObserverConnectionId = nil
        // Clear echo prevention flags — stale values prevent sync after reconnect
        lastSentContent = ""
        lastReceivedContent = ""
        lastSentImageFingerprint = nil
        lastReceivedImageFingerprint = nil
    }

    func canHandle(type: String) -> Bool {
        type == "kdeconnect.clipboard"
            || type == "kdeconnect.clipboard.connect"
            || type == NetworkPacket.clipboardImagePacketType
    }

    func handle(packet: NetworkPacket) {
        if packet.type == NetworkPacket.clipboardImagePacketType {
            handleImage(packet: packet)
            return
        }

        handleText(packet: packet)
    }

    private func handleText(packet: NetworkPacket) {
        guard let content = packet.body["content"]?.value as? String else { return }
        guard content.utf8.count <= Self.maxTextBytes else {
            KLog.log("[Clipboard] Rejected oversized incoming: \(content.utf8.count) bytes")
            return
        }
        guard content != lastReceivedContent else { return }
        guard content != lastSentContent else { return }

        lastReceivedContent = content
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)
        lastChangeCount = pasteboard.changeCount

        KLog.log("[Clipboard] Received from \(device.name): \(content.utf8.count) bytes")
    }

    private func handleImage(packet: NetworkPacket) {
        guard let metadata = Self.imageTransferMetadata(from: packet) else {
            KLog.log("[Clipboard] Rejected malformed image clipboard packet")
            return
        }
        guard let host = device.kdeConn?.host, !host.isEmpty else {
            KLog.log("[Clipboard] Rejected image clipboard packet without active peer host")
            return
        }
        guard let storedCert = Config.shared.loadPairedDeviceCert(id: device.id), storedCert.count > 1 else {
            KLog.log("[Clipboard] Refusing image receive without a stored peer certificate", level: .error)
            return
        }

        weak var weakSelf = self
        DispatchQueue.global(qos: .userInitiated).async {
            guard let data = Self.downloadImage(
                host: host,
                port: metadata.port,
                expectedSize: metadata.size,
                storedCertData: storedCert
            ) else {
                KLog.log("[Clipboard] Image receive failed from \(host):\(metadata.port)")
                return
            }

            Task { @MainActor in
                weakSelf?.applyReceivedImage(data)
            }
        }
    }

    static func imageTransferMetadata(from packet: NetworkPacket) -> ImageTransferMetadata? {
        guard packet.type == NetworkPacket.clipboardImagePacketType else { return nil }
        guard let mimeType = packet.body["mimeType"]?.value as? String, mimeType == "image/png" else { return nil }
        guard let payloadSize = packet.payloadSize,
            payloadSize > 0,
            payloadSize <= Int64(Self.maxImageBytes),
            let size = Int(exactly: payloadSize) else {
            return nil
        }
        guard let port = packet.payloadTransferInfo?["port"]?.asPort(), port > 0 else { return nil }
        return ImageTransferMetadata(port: port, size: size, mimeType: mimeType)
    }

    static func incomingCapabilities(from packet: NetworkPacket) -> Set<String> {
        guard packet.type == "kdeconnect.identity" else { return [] }
        if let capabilities = packet.body["incomingCapabilities"]?.value as? [String] {
            return Set(capabilities)
        }
        let values = packet.body["incomingCapabilities"]?.value as? [Any] ?? []
        return Set(values.compactMap { $0 as? String })
    }

    private func observePeerCapabilities() {
        guard let connection = device.kdeConn else { return }
        let connectionId = ObjectIdentifier(connection)
        guard device.capabilityObserverConnectionId != connectionId else { return }

        device.peerIncomingCapabilities.removeAll()
        device.capabilityObserverConnectionId = connectionId

        let previousHandler = connection.onIdentityReceived
        let observedDevice = device
        connection.onIdentityReceived = { [weak observedDevice] packet in
            previousHandler?(packet)
            Task { @MainActor in
                guard let observedDevice else { return }
                guard packet.body["deviceId"]?.value as? String == observedDevice.id else { return }
                observedDevice.peerIncomingCapabilities = Self.incomingCapabilities(from: packet)
            }
        }
    }

    private func startMonitoring() {
        lastChangeCount = NSPasteboard.general.changeCount
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkClipboard()
            }
        }
    }

    private func checkClipboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        let changeCount = pasteboard.changeCount
        lastChangeCount = changeCount

        if device.peerIncomingCapabilities.contains(NetworkPacket.clipboardImagePacketType) {
            if let png = pasteboard.data(forType: .png) {
                queueOutgoingImage(png)
                return
            }

            if let imageData = Self.imageSourceData(from: pasteboard) {
                convertImageToPNG(imageData, pasteboardChangeCount: changeCount)
                return
            }
        }

        lastSentImageFingerprint = nil
        lastReceivedImageFingerprint = nil
        guard let content = pasteboard.string(forType: .string) else { return }
        guard content != lastReceivedContent else { return }
        guard content != lastSentContent else { return }
        guard content.utf8.count <= Self.maxTextBytes else {
            KLog.log("[Clipboard] Skipping oversized clipboard: \(content.utf8.count) bytes")
            return
        }

        lastSentContent = content
        lastReceivedContent = ""
        let packet = NetworkPacket(type: "kdeconnect.clipboard", body: ["content": AnyCodable(content)])
        device.send(packet)
        KLog.log("[Clipboard] Sent to \(device.name) (\(content.utf8.count) bytes)")
    }

    private func convertImageToPNG(_ imageData: Data, pasteboardChangeCount: Int) {
        weak var weakSelf = self
        DispatchQueue.global(qos: .userInitiated).async {
            guard let png = Self.encodePNG(from: imageData) else {
                KLog.log("[Clipboard] Failed to encode clipboard image as PNG")
                return
            }

            Task { @MainActor in
                guard let self = weakSelf else { return }
                guard NSPasteboard.general.changeCount == pasteboardChangeCount else { return }
                self.queueOutgoingImage(png)
            }
        }
    }

    private func queueOutgoingImage(_ data: Data) {
        lastSentContent = ""
        lastReceivedContent = ""

        guard data.count <= Self.maxImageBytes else {
            KLog.log("[Clipboard] Skipping oversized image clipboard: \(data.count) bytes")
            return
        }

        let fingerprint = data.hashValue
        guard fingerprint != lastReceivedImageFingerprint else { return }
        guard fingerprint != lastSentImageFingerprint else { return }
        guard device.kdeConn != nil else { return }
        guard device.peerIncomingCapabilities.contains(NetworkPacket.clipboardImagePacketType) else {
            KLog.log("[Clipboard] Peer \(device.name) does not advertise image clipboard support", level: .debug)
            return
        }

        lastReceivedImageFingerprint = nil
        lastSentImageFingerprint = fingerprint
        pendingImageTransfer = (data, fingerprint)
        startNextImageSendIfNeeded()
    }

    private func startNextImageSendIfNeeded() {
        guard !imageSendInProgress, let transfer = pendingImageTransfer else { return }
        pendingImageTransfer = nil

        guard let storedCert = Config.shared.loadPairedDeviceCert(id: device.id), storedCert.count > 1 else {
            KLog.log("[Clipboard] Refusing image send without a stored peer certificate", level: .error)
            if lastSentImageFingerprint == transfer.fingerprint {
                lastSentImageFingerprint = nil
            }
            startNextImageSendIfNeeded()
            return
        }

        imageSendInProgress = true
        let deviceName = device.name
        weak var weakSelf = self
        DispatchQueue.global(qos: .userInitiated).async {
            let sent = Self.sendImagePayload(
                transfer.data,
                deviceName: deviceName,
                storedCertData: storedCert,
                sendPacket: { packet in
                    DispatchQueue.main.async {
                        weakSelf?.device.send(packet)
                    }
                }
            )

            Task { @MainActor in
                guard let self = weakSelf else { return }
                self.imageSendInProgress = false
                if !sent {
                    KLog.log("[Clipboard] Image send failed to \(deviceName)")
                    if self.lastSentImageFingerprint == transfer.fingerprint {
                        self.lastSentImageFingerprint = nil
                    }
                }
                self.startNextImageSendIfNeeded()
            }
        }
    }

    private func applyReceivedImage(_ data: Data) {
        lastSentContent = ""
        lastReceivedContent = ""

        let fingerprint = data.hashValue
        guard fingerprint != lastReceivedImageFingerprint else { return }
        guard fingerprint != lastSentImageFingerprint else { return }
        guard let image = NSImage(data: data) else {
            KLog.log("[Clipboard] Received payload was not a decodable image")
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let wrotePNG = pasteboard.setData(data, forType: .png)
        let wroteTIFF = image.tiffRepresentation.map { pasteboard.setData($0, forType: .tiff) } ?? false
        guard wrotePNG || wroteTIFF else {
            KLog.log("[Clipboard] Failed to write received image to pasteboard")
            return
        }

        lastSentImageFingerprint = nil
        lastReceivedImageFingerprint = fingerprint
        lastChangeCount = pasteboard.changeCount
        KLog.log("[Clipboard] Received image from \(device.name): \(data.count) bytes")
    }

    private static func imageSourceData(from pasteboard: NSPasteboard) -> Data? {
        if let tiff = pasteboard.data(forType: .tiff) {
            return tiff
        }
        return (pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage)?.tiffRepresentation
    }

    private nonisolated static func encodePNG(from imageData: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private nonisolated static func sendImagePayload(
        _ data: Data,
        deviceName: String,
        storedCertData: Data,
        sendPacket: (NetworkPacket) -> Void
    ) -> Bool {
        let serverFd = socket(AF_INET, SOCK_STREAM, 0)
        guard serverFd >= 0 else { return false }

        var reuse: Int32 = 1
        setsockopt(serverFd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(serverFd)
            return false
        }

        var boundAddr = sockaddr_in()
        var addrLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(serverFd, $0, &addrLength)
            }
        }
        let port = UInt16(bigEndian: boundAddr.sin_port)

        guard listen(serverFd, 1) == 0 else {
            Darwin.close(serverFd)
            return false
        }

        var packet = NetworkPacket(type: NetworkPacket.clipboardImagePacketType, body: [
            "mimeType": AnyCodable("image/png"),
            "timestamp": AnyCodable(Int64(Date().timeIntervalSince1970 * 1000))
        ])
        packet.payloadSize = Int64(data.count)
        packet.payloadTransferInfo = ["port": AnyCodable(Int(port))]
        sendPacket(packet)
        KLog.log("[Clipboard] Sending image to \(deviceName): \(data.count) bytes on port \(port)")

        var acceptTimeout = timeval(tv_sec: __darwin_time_t(Self.acceptTimeout), tv_usec: 0)
        setsockopt(serverFd, SOL_SOCKET, SO_RCVTIMEO, &acceptTimeout, socklen_t(MemoryLayout<timeval>.size))

        var clientAddr = sockaddr_storage()
        var clientLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let clientFd = withUnsafeMutablePointer(to: &clientAddr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(serverFd, $0, &clientLength)
            }
        }
        Darwin.close(serverFd)

        guard clientFd >= 0 else { return false }
        SocketHelpers.configureTransferSocket(fd: clientFd, ioTimeoutSeconds: Int(Self.connectTimeout))

        guard let transferId = CertificateManager.shared.freshTransferIdentity() else {
            Darwin.close(clientFd)
            return false
        }

        return withExtendedLifetime(transferId) {
            sendImageTLS(
                data,
                clientFd: clientFd,
                identity: transferId.identity,
                storedCertData: storedCertData
            )
        }
    }

    private nonisolated static func sendImageTLS(
        _ data: Data,
        clientFd: Int32,
        identity: SecIdentity,
        storedCertData: Data
    ) -> Bool {
        guard let context = SSLCreateContext(nil, .serverSide, .streamType) else {
            Darwin.close(clientFd)
            return false
        }

        let fdPointer = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        defer { fdPointer.deallocate() }
        fdPointer.pointee = clientFd
        TLSHelpers.configure(context, TLSContextConfig(isServer: true, identity: identity, fdPtr: fdPointer))

        guard TLSHelpers.runHandshake(context, role: "Clipboard image send", deadline: Self.handshakeTimeout) else {
            SSLClose(context)
            Darwin.close(clientFd)
            return false
        }

        guard peerCertificateMatches(context, expectedCertData: storedCertData) else {
            KLog.log("[Clipboard] Image transfer peer cert mismatch")
            SSLClose(context)
            Darwin.close(clientFd)
            return false
        }

        let started = Date()
        var totalWritten = 0
        var lastProgress = Date()
        var failed = false

        while totalWritten < data.count {
            if Date().timeIntervalSince(started) > Self.totalTimeout {
                failed = true
                break
            }

            var written = 0
            let toWrite = min(Self.chunkSize, data.count - totalWritten)
            let status = data.withUnsafeBytes { buffer -> OSStatus in
                guard let baseAddress = buffer.baseAddress else { return errSecParam }
                return SSLWrite(context, baseAddress + totalWritten, toWrite, &written)
            }

            if written > 0 {
                totalWritten += written
                lastProgress = Date()
            }

            if status == errSecSuccess {
                continue
            }
            if status == errSSLWouldBlock {
                if Date().timeIntervalSince(lastProgress) > Self.stallTimeout {
                    failed = true
                    break
                }
                if written == 0 { usleep(2000) }
                continue
            }

            failed = true
            break
        }

        SocketHelpers.enableLinger(fd: clientFd)
        SSLClose(context)
        Darwin.close(clientFd)
        return !failed && totalWritten == data.count
    }

    private nonisolated static func downloadImage(
        host: String,
        port: UInt16,
        expectedSize: Int,
        storedCertData: Data
    ) -> Data? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            Darwin.close(fd)
            return nil
        }

        var timeout = timeval(tv_sec: __darwin_time_t(Self.connectTimeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let connectResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            Darwin.close(fd)
            return nil
        }

        SocketHelpers.configureTransferSocket(fd: fd, ioTimeoutSeconds: Int(Self.connectTimeout))
        guard let transferId = CertificateManager.shared.freshTransferIdentity() else {
            Darwin.close(fd)
            return nil
        }

        return withExtendedLifetime(transferId) {
            downloadImageTLS(
                fd: fd,
                identity: transferId.identity,
                expectedSize: expectedSize,
                storedCertData: storedCertData
            )
        }
    }

    private nonisolated static func downloadImageTLS(
        fd: Int32,
        identity: SecIdentity,
        expectedSize: Int,
        storedCertData: Data
    ) -> Data? {
        guard let context = SSLCreateContext(nil, .clientSide, .streamType) else {
            Darwin.close(fd)
            return nil
        }

        let fdPointer = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        defer { fdPointer.deallocate() }
        fdPointer.pointee = fd
        TLSHelpers.configure(context, TLSContextConfig(isServer: false, identity: identity, fdPtr: fdPointer))

        guard TLSHelpers.runHandshake(context, role: "Clipboard image receive", deadline: Self.handshakeTimeout) else {
            SSLClose(context)
            Darwin.close(fd)
            return nil
        }

        guard peerCertificateMatches(context, expectedCertData: storedCertData) else {
            KLog.log("[Clipboard] Image receive peer cert mismatch")
            SSLClose(context)
            Darwin.close(fd)
            return nil
        }

        let started = Date()
        var data = Data()
        data.reserveCapacity(expectedSize)
        var buffer = [UInt8](repeating: 0, count: Self.chunkSize)
        var lastProgress = Date()

        readLoop: while data.count < expectedSize {
            if Date().timeIntervalSince(started) > Self.totalTimeout {
                break
            }

            var bytesRead = 0
            let toRead = min(buffer.count, expectedSize - data.count)
            let status = SSLRead(context, &buffer, toRead, &bytesRead)

            if bytesRead > 0 {
                data.append(contentsOf: buffer[0..<bytesRead])
                lastProgress = Date()
            }

            switch status {
            case errSecSuccess:
                if bytesRead == 0 { break readLoop }
            case errSSLWouldBlock:
                if Date().timeIntervalSince(lastProgress) > Self.stallTimeout {
                    break readLoop
                }
                if bytesRead == 0 { usleep(5000) }
            case errSSLClosedGraceful, errSSLClosedAbort:
                break readLoop
            default:
                break readLoop
            }
        }

        SSLClose(context)
        Darwin.close(fd)
        guard data.count == expectedSize else { return nil }
        return data
    }

    private nonisolated static func peerCertificateMatches(_ context: SSLContext, expectedCertData: Data) -> Bool {
        guard let peerCertificate = TLSHelpers.copyPeerLeafCertificate(context) else { return false }
        return SecCertificateCopyData(peerCertificate) as Data == expectedCertData
    }
}
