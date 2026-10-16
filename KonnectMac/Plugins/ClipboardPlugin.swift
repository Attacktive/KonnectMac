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
	private static let maxFileBytes: Int64 = 2_147_483_648
	private static let chunkSize = 65536
	private static let acceptTimeout: TimeInterval = 20
    private static let connectTimeout: TimeInterval = 15
    private static let handshakeTimeout: TimeInterval = 20
    private static let stallTimeout: TimeInterval = 20
    private static let totalTimeout: TimeInterval = 2 * 60
    private nonisolated static let minPayloadPort: UInt16 = 1739

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
        guard content != lastReceivedContent else { return }
        guard content != lastSentContent else { return }

        lastReceivedContent = content
        let pasteboard = NSPasteboard.general
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

			Task { @MainActor in
				weakSelf?.applyReceivedFile(at: destURL)
			}
		}
	}

	static func fileTransferMetadata(from packet: NetworkPacket) -> FileTransferMetadata? {
		guard packet.type == NetworkPacket.clipboardFilePacketType else { return nil }
		guard let rawFilename = packet.body["filename"]?.value as? String, !rawFilename.isEmpty else {
			return nil
		}

		let filename = sanitizeFilename(rawFilename)
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

	static func sanitizeFilename(_ name: String) -> String {
		var sanitized = name.precomposedStringWithCanonicalMapping
		sanitized = sanitized.replacingOccurrences(of: "..", with: "_")
		sanitized = sanitized.replacingOccurrences(of: "/", with: "_")
		sanitized = sanitized.replacingOccurrences(of: "\\", with: "_")
		sanitized = sanitized.replacingOccurrences(of: ":", with: "_")
		sanitized = sanitized.replacingOccurrences(of: "\0", with: "")
		while sanitized.hasPrefix(".") {
			sanitized = String(sanitized.dropFirst())
		}

		if sanitized.isEmpty {
			sanitized = "clipboard-file"
		}

		if sanitized.utf8.count > 250 {
			let ext = (sanitized as NSString).pathExtension
			let stem = (sanitized as NSString).deletingPathExtension
			let maxStemBytes = 250 - (ext.isEmpty ? 0 : ext.utf8.count + 1)
			var truncated = stem
			while truncated.utf8.count > maxStemBytes {
				truncated = String(truncated.dropLast())
			}

			sanitized = ext.isEmpty ? truncated : "\(truncated).\(ext)"
		}

		return sanitized
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

	private func applyReceivedFile(at fileURL: URL) {
		lastSentContent = ""
		lastReceivedContent = ""

		let pasteboard = NSPasteboard.general
		pasteboard.clearContents()

		var didWrite = false
		if let image = NSImage(contentsOf: fileURL) {
			if let fileData = try? Data(contentsOf: fileURL),
				let png = Self.pngData(from: fileData) {
				if pasteboard.setData(png, forType: .png) {
					didWrite = true
				}
			}

			if let tiff = image.tiffRepresentation {
				if pasteboard.setData(tiff, forType: .tiff) {
					didWrite = true
				}
			}
		}

		if pasteboard.writeObjects([fileURL as NSURL]) {
			didWrite = true
		}

		guard didWrite else {
			KLog.log("[Clipboard] Failed to write received clipboard file to pasteboard", level: .error)
			return
		}

		lastSentImageFingerprint = nil
		lastReceivedImageFingerprint = (try? Data(contentsOf: fileURL))?.hashValue
		lastChangeCount = pasteboard.changeCount
		KLog.log("[Clipboard] Received clipboard file from \(device.name): \(fileURL.lastPathComponent)")
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
		let fd = socket(AF_INET, SOCK_STREAM, 0)
		guard fd >= 0 else { return false }

		var addr = sockaddr_in()
		addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
		addr.sin_family = sa_family_t(AF_INET)
		addr.sin_port = port.bigEndian
		guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
			Darwin.close(fd)
			return false
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
			return false
		}

		SocketHelpers.configureTransferSocket(fd: fd, ioTimeoutSeconds: Int(Self.connectTimeout))
		guard let transferId = CertificateManager.shared.freshTransferIdentity() else {
			Darwin.close(fd)
			return false
		}

		return withExtendedLifetime(transferId) {
			downloadFileTLS(
				fd: fd,
				identity: transferId.identity,
				expectedSize: expectedSize,
				destURL: destURL,
				storedCertData: storedCertData
			)
		}
	}

	private nonisolated static func downloadFileTLS(
		fd: Int32,
		identity: SecIdentity,
		expectedSize: Int64,
		destURL: URL,
		storedCertData: Data
	) -> Bool {
		guard let context = SSLCreateContext(nil, .clientSide, .streamType) else {
			Darwin.close(fd)
			return false
		}

		let fdPointer = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
		defer { fdPointer.deallocate() }
		fdPointer.pointee = fd
		TLSHelpers.configure(
			context,
			TLSContextConfig(
				isServer: false,
				identity: identity,
				fdPtr: fdPointer
			)
		)

		guard TLSHelpers.runHandshake(context, role: "Clipboard file receive", deadline: Self.handshakeTimeout) else {
			SSLClose(context)
			Darwin.close(fd)
			return false
		}

		guard peerCertificateMatches(context, expectedCertData: storedCertData) else {
			KLog.log("[Clipboard] File receive peer cert mismatch")
			SSLClose(context)
			Darwin.close(fd)
			return false
		}

		guard FileManager.default.createFile(atPath: destURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
			SSLClose(context)
			Darwin.close(fd)
			return false
		}

		guard let fileHandle = try? FileHandle(forWritingTo: destURL) else {
			SSLClose(context)
			Darwin.close(fd)
			return false
		}

		defer { try? fileHandle.close() }

		let started = Date()
		var totalRead: Int64 = 0
		var buffer = [UInt8](repeating: 0, count: Self.chunkSize)
		var lastProgress = Date()

		readLoop: while totalRead < expectedSize {
			if Date().timeIntervalSince(started) > Self.totalTimeout {
				break
			}

			var bytesRead = 0
			let toRead = min(buffer.count, Int(expectedSize - totalRead))
			let status = SSLRead(context, &buffer, toRead, &bytesRead)

			if bytesRead > 0 {
				fileHandle.write(Data(buffer[0..<bytesRead]))
				totalRead += Int64(bytesRead)
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

		guard totalRead == expectedSize else {
			try? FileManager.default.removeItem(at: destURL)
			return false
		}

		return true
	}

    private nonisolated static func peerCertificateMatches(_ context: SSLContext, expectedCertData: Data) -> Bool {
        guard let peerCertificate = TLSHelpers.copyPeerLeafCertificate(context) else { return false }
        return SecCertificateCopyData(peerCertificate) as Data == expectedCertData
    }
}
