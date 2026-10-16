import AppKit
import Darwin
import Foundation
import ImageIO
import Security
import UniformTypeIdentifiers

@MainActor
class ClipboardPlugin: PluginProtocol {
	struct FileTransferMetadata: Equatable {
		let port: UInt16
		let size: Int64
		let filename: String
	}

    let device: Device
	private let pasteboard: NSPasteboard
	private var activeReceiveToken: UUID?
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
	private static let maxFileBytes: Int64 = 50 * 1024 * 1024
	private static let chunkSize = 65536
	private static var lastReceivedTransferDirectory: URL?
	// The pasteboard is shared by all peers, so a newer receive supersedes transfers from every plugin instance.
	private static var latestReceiveToken: UUID?
	private static let acceptTimeout: TimeInterval = 20
    private static let connectTimeout: TimeInterval = 15
    private static let handshakeTimeout: TimeInterval = 20
    private static let stallTimeout: TimeInterval = 20
    private static let totalTimeout: TimeInterval = 2 * 60
    private nonisolated static let minPayloadPort: UInt16 = 1739


	/// Removes clipboard transfer staging directories older than 24 hours left by previous sessions.
	static func cleanupStaleTransferDirectories() {
		let baseDir = FileManager.default.temporaryDirectory.appendingPathComponent("KonnectMacClipboard", isDirectory: true)
		guard let entries = try? FileManager.default.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
		let oneDayAgo = Date().addingTimeInterval(-24 * 60 * 60)
		for dir in entries {
			if let values = try? dir.resourceValues(forKeys: [.contentModificationDateKey]),
			   let modDate = values.contentModificationDate,
			   modDate < oneDayAgo {
				try? FileManager.default.removeItem(at: dir)
			}
		}
	}
	init(device: Device, pasteboard: NSPasteboard = .general) {
		self.device = device
		self.pasteboard = pasteboard
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
		activeReceiveToken = nil
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
            || type == NetworkPacket.clipboardFilePacketType
    }

	func handle(packet: NetworkPacket) {
		if packet.type == NetworkPacket.clipboardFilePacketType {
			handleFile(packet: packet)
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

		Self.latestReceiveToken = nil
        guard content != lastReceivedContent else { return }
        guard content != lastSentContent else { return }

        lastReceivedContent = content
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)
        lastChangeCount = pasteboard.changeCount

        KLog.log("[Clipboard] Received from \(device.name): \(content.utf8.count) bytes")
    }

	private func handleFile(packet: NetworkPacket) {
		guard let metadata = Self.fileTransferMetadata(from: packet) else {
			KLog.log("[Clipboard] Rejected malformed clipboard file packet")
			return
		}

		guard let host = device.kdeConn?.host, !host.isEmpty else {
			KLog.log("[Clipboard] Rejected clipboard file packet without active peer host")
			return
		}

		guard let storedCert = Config.shared.loadPairedDeviceCert(id: device.id), storedCert.count > 1 else {
			KLog.log("[Clipboard] Refusing clipboard file receive without a stored peer certificate", level: .error)
			return
		}

		let transferDir = FileManager.default.temporaryDirectory.appendingPathComponent(
			"KonnectMacClipboard/\(UUID().uuidString)",
			isDirectory: true
		)

		do {
			try FileManager.default.createDirectory(
				at: transferDir,
				withIntermediateDirectories: true
			)
		} catch {
			KLog.log("[Clipboard] Failed to create clipboard temp directory: \(error)", level: .error)
			return
		}

		let destURL = transferDir.appendingPathComponent(metadata.filename)
		let receive = beginFileReceive()
		weak var weakSelf = self
		DispatchQueue.global(qos: .userInitiated).async {
			let success = Self.downloadFile(
				host: host,
				port: metadata.port,
				expectedSize: metadata.size,
				destURL: destURL,
				storedCertData: storedCert
			)
			guard success else {
				KLog.log("[Clipboard] File receive failed from \(host):\(metadata.port)")
				try? FileManager.default.removeItem(at: transferDir)
				return
			}

			let imagePayload = Self.extractImagePayload(from: destURL)

			Task { @MainActor in
				guard let self = weakSelf else {
					try? FileManager.default.removeItem(at: transferDir)
					return
				}

				self.applyReceivedFile(at: destURL, transferDir: transferDir, imagePayload: imagePayload, receive: receive)
			}
		}
	}

	static func fileTransferMetadata(from packet: NetworkPacket) -> FileTransferMetadata? {
		guard packet.type == NetworkPacket.clipboardFilePacketType else { return nil }
		guard let rawFilename = packet.body["filename"]?.value as? String, !rawFilename.isEmpty else {
			return nil
		}

		let filename = FileTransferFilename.sanitize(rawFilename, fallback: "clipboard-file")
		guard !filename.isEmpty else { return nil }

		guard let payloadSize = packet.payloadSize,
			payloadSize > 0,
			payloadSize <= Self.maxFileBytes else {
			return nil
		}

		guard let port = packet.payloadTransferInfo?["port"]?.asPort(), port > 0 else { return nil }

		return FileTransferMetadata(
			port: port,
			size: payloadSize,
			filename: filename
		)
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
		lastChangeCount = pasteboard.changeCount
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkClipboard()
            }
        }
    }

    private func checkClipboard() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        let changeCount = pasteboard.changeCount
        lastChangeCount = changeCount

        // A copied file carries its URL, and possibly an icon, but it is not a clipboard image.
        let hasFileURLs = pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        if !hasFileURLs, device.peerIncomingCapabilities.contains(NetworkPacket.clipboardFilePacketType) {
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
            guard let png = Self.pngData(from: imageData) else {
                KLog.log("[Clipboard] Failed to encode clipboard image as PNG")
                return
            }

            Task { @MainActor in
                guard let self = weakSelf else { return }
				guard self.pasteboard.changeCount == pasteboardChangeCount else { return }
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
        guard device.peerIncomingCapabilities.contains(NetworkPacket.clipboardFilePacketType) else {
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

	struct FileReceive {
		let token: UUID
		let pasteboardChangeCount: Int
	}

	func beginFileReceive() -> FileReceive {
		let token = UUID()
		activeReceiveToken = token
		Self.latestReceiveToken = token
		return FileReceive(token: token, pasteboardChangeCount: pasteboard.changeCount)
	}

	func applyReceivedFile(at fileURL: URL, transferDir: URL, imagePayload: ReceivedImagePayload?, receive: FileReceive) {
		guard receive.token == activeReceiveToken,
			  receive.token == Self.latestReceiveToken,
			  receive.pasteboardChangeCount == pasteboard.changeCount else {
			try? FileManager.default.removeItem(at: transferDir)
			return
		}

		activeReceiveToken = nil
		lastSentContent = ""
		lastReceivedContent = ""

		pasteboard.clearContents()

		var didWrite = false
		if let imagePayload = imagePayload {
			if pasteboard.setData(imagePayload.pngData, forType: .png) {
				didWrite = true
			}

			if let tiff = imagePayload.tiffData, pasteboard.setData(tiff, forType: .tiff) {
				didWrite = true
			}
		}

		if pasteboard.writeObjects([fileURL as NSURL]) {
			didWrite = true
		}

		guard didWrite else {
			KLog.log("[Clipboard] Failed to write received clipboard file to pasteboard", level: .error)
			try? FileManager.default.removeItem(at: transferDir)
			return
		}

		if let previousDir = Self.lastReceivedTransferDirectory, previousDir != transferDir {
			try? FileManager.default.removeItem(at: previousDir)
		}

		Self.lastReceivedTransferDirectory = transferDir

		lastSentImageFingerprint = nil
		lastReceivedImageFingerprint = imagePayload?.pngData.hashValue
		lastChangeCount = pasteboard.changeCount
		KLog.log("[Clipboard] Received clipboard file from \(device.name): \(fileURL.lastPathComponent)")
	}

	struct ReceivedImagePayload {
		let pngData: Data
		let tiffData: Data?
	}

	nonisolated static func extractImagePayload(from fileURL: URL) -> ReceivedImagePayload? {
		let ext = fileURL.pathExtension
		guard !ext.isEmpty else { return nil }
		guard let utType = UTType(filenameExtension: ext), utType.conforms(to: .image) else {
			return nil
		}

		guard let fileData = try? Data(contentsOf: fileURL),
			  let png = pngData(from: fileData) else {
			return nil
		}

		var tiff: Data?
		if let source = CGImageSourceCreateWithData(png as CFData, nil),
		   let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
			let output = NSMutableData()
			if let destination = CGImageDestinationCreateWithData(output, UTType.tiff.identifier as CFString, 1, nil) {
				CGImageDestinationAddImage(destination, image, nil)
				if CGImageDestinationFinalize(destination) {
					tiff = output as Data
				}
			}
		}

		return ReceivedImagePayload(pngData: png, tiffData: tiff)
	}

    private static func imageSourceData(from pasteboard: NSPasteboard) -> Data? {
        if let tiff = pasteboard.data(forType: .tiff) {
            return tiff
        }
        return (pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage)?.tiffRepresentation
    }

    /// Returns PNG bytes for any decodable image, passing PNG input through without re-encoding.
    private nonisolated static func pngData(from imageData: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        if CGImageSourceGetType(source) as String? == UTType.png.identifier {
            return imageData
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
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

        guard let port = Self.bindTransferListener(fd: serverFd), listen(serverFd, 1) == 0 else {
            Darwin.close(serverFd)
            return false
        }

        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        var packet = NetworkPacket(type: NetworkPacket.clipboardFilePacketType, body: [
            "filename": AnyCodable("\(timestamp).png")
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

        guard clientFd >= 0 else {
            KLog.log("[Clipboard] Peer \(deviceName) did not connect to image port \(port) (errno=\(errno))")
            return false
        }

        SocketHelpers.configureTransferSocket(fd: clientFd, ioTimeoutSeconds: Int(Self.connectTimeout))

        guard let transferId = CertificateManager.shared.freshTransferIdentity() else {
            KLog.log("[Clipboard] Could not create fresh TLS identity for image send")
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

		guard let peerCert = TLSHelpers.copyPeerLeafCertificate(context),
			  (SecCertificateCopyData(peerCert) as Data) == storedCertData else {
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

            let writeErr = errno
            KLog.log("[Clipboard] Image send SSLWrite returned \(status) (errno=\(writeErr): \(String(cString: strerror(writeErr)))) at \(totalWritten)/\(data.count) bytes")
            failed = true
            break
        }

        SocketHelpers.enableLinger(fd: clientFd)
        SSLClose(context)
        Darwin.close(clientFd)
        return !failed && totalWritten == data.count
    }

    private nonisolated static func bindTransferListener(fd: Int32) -> UInt16? {
        for candidate in Array(Self.minPayloadPort...Config.maxPort) + [0] {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = candidate.bigEndian
            addr.sin_addr.s_addr = INADDR_ANY.bigEndian

            let bound = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

            guard bound == 0 else { continue }
            if candidate > 0 {
                return candidate
            }

            var boundAddr = sockaddr_in()
            var addrLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &boundAddr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(fd, $0, &addrLength)
                }
            }

            return UInt16(bigEndian: boundAddr.sin_port)
        }

        return nil
    }

	private nonisolated static func downloadFile(
		host: String,
		port: UInt16,
		expectedSize: Int64,
		destURL: URL,
		storedCertData: Data
	) -> Bool {
		let totalRead = TLSHelpers.downloadPayloadFile(
			host: host,
			port: port,
			expectedSize: expectedSize,
			destURL: destURL,
			storedCertData: storedCertData,
			role: "Clipboard file receive",
			filePermissions: 0o600,
			connectTimeout: connectTimeout,
			handshakeTimeout: handshakeTimeout,
			stallTimeout: stallTimeout,
			totalTimeout: totalTimeout,
			chunkSize: chunkSize
		)

		guard let totalRead = totalRead, totalRead == expectedSize else {
			try? FileManager.default.removeItem(at: destURL)
			return false
		}

		return true
	}
}
