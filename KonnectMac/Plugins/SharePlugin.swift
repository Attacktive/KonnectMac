import AppKit
import Foundation
import UserNotifications

@MainActor
class SharePlugin: PluginProtocol {
	let device: Device

	/// Tail of the per-device receive chain.
	/// Every new incoming-file packet awaits the previous receive's completion before connecting to the phone.
	///
	/// This matches KDE Connect Android's `CompositeUploadFileJob` protocol: when the phone shares multiple files (Share Sheet always uses this path, even for one file, via SEND_MULTIPLE), it binds ONE listener on a single port and sends every share packet up front, then loops calling `accept()` to serve the files one at a time.
	/// If we connected in parallel, we'd race on that single port — only one connection would be accepted, the others would sit in the kernel backlog and fail their TLS handshakes with errSSLInternal (-9810).
	/// Worse, the phone's job state ends up wedged, breaking subsequent in-app shares too until the job times out on the phone side.
	///
	/// The chain self-trims: each task only retains the immediately-previous task until its own `await` returns, so the in-memory chain never grows beyond two.
	private var receiveChain: Task<Void, Never>?

	init(device: Device) {
		self.device = device
		// Clean up stale .partial files older than 1 day
		Self.cleanupStalePartialFiles()
	}

	// MARK: - Tunables (single source of truth — no magic numbers buried in code)

	/// Window during which a transfer must make at least one byte of progress, or we abort.
	/// Covers genuinely slow networks while bailing out of permanent stalls.
	private static let stallTimeout: TimeInterval = 60

	/// Bound on the entire transfer (TLS handshake + bytes).
	/// Prevents zombie sockets from holding file handles and ports forever.
	private static let totalTimeout: TimeInterval = 30 * 60

	/// How long we wait for the phone to open the TCP connection back to us after we've sent the share packet.
	/// Generous because the phone may be queueing multiple incoming files.
	private static let acceptTimeout: TimeInterval = 120

	/// TLS handshake hard cap.
	private static let handshakeTimeout: TimeInterval = 20

	/// Per-syscall socket timeout.
	/// Short enough that the I/O callback returns often so the higher-level stall/total timeouts can be evaluated.
	private static let socketIOTimeout: TimeInterval = 10

	/// I/O chunk size. 64 KB matches typical TLS record sizes for TLS 1.2.
	private static let chunkSize = 65536

	/// Hard cap on a single file transfer (2 GB).
	private static let maxFileSize: Int64 = 2_147_483_648

	private static var lastCleanupTime = Date.distantPast
	private static let cleanupLock = NSLock()
	private static func cleanupStalePartialFiles() {
		cleanupLock.lock()
		guard Date().timeIntervalSince(lastCleanupTime) > 3600 else {
			cleanupLock.unlock()

			return
		}

		lastCleanupTime = Date()
		cleanupLock.unlock()
		let downloadPath = Config.shared.downloadDirectory
		let downloadsDir = URL(fileURLWithPath: downloadPath, isDirectory: true)
		guard let files = try? FileManager.default.contentsOfDirectory(atPath: downloadsDir.path) else {
			return
		}

		let oneDayAgo = Date().addingTimeInterval(-24 * 60 * 60)
		for file in files where file.hasSuffix(".partial") {
			let fullPath = downloadsDir.appendingPathComponent(file).path
			if let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath), let modDate = attrs[.modificationDate] as? Date, modDate < oneDayAgo {
				try? FileManager.default.removeItem(atPath: fullPath)
				KLog.log("[Share] Cleaned up stale partial file: \(file)")
			}
		}
	}

	// MARK: - Incoming Shares

	func canHandle(type: String) -> Bool { type == "kdeconnect.share.request" }

	func handle(packet: NetworkPacket) {
		if let url = packet.body["url"]?.value as? String {
			KLog.log("[Share] Received URL: \(url)")
			if let nsurl = URL(string: url), let scheme = nsurl.scheme?.lowercased(), scheme == "http" || scheme == "https" {
				NSWorkspace.shared.open(nsurl)
			} else {
				KLog.log("[Share] Rejected non-HTTP URL scheme: \(url)")
			}

			return
		}

		if let text = packet.body["text"]?.value as? String {
			KLog.log("[Share] Received text (\(text.utf8.count) bytes)")
			// Prevent ClipboardPlugin from echoing this text back to the phone
			if let clipboardPlugin = device.plugins["clipboard"] as? ClipboardPlugin {
				clipboardPlugin.lastReceivedContent = text
			}

			NSPasteboard.general.clearContents()
			NSPasteboard.general.setString(text, forType: .string)

			return
		}

		if let filename = packet.body["filename"]?.value as? String {
			let sanitized = FileTransferFilename.sanitize(filename, fallback: "download")
			let payloadSize = packet.payloadSize ?? 0

			let port = packet.payloadTransferInfo?["port"]?.asPort()

			// Capture host eagerly — kdeConn can drop between this MainActor-hop and the Task
			let host = device.kdeConn?.host ?? ""

			guard let port = port else {
				KLog.log("[Share] Rejected file \(sanitized): missing/invalid port in payloadTransferInfo")

				return
			}

			guard payloadSize > 0 else {
				KLog.log("[Share] Rejected file \(sanitized): payloadSize=\(payloadSize)")

				return
			}

			guard !host.isEmpty else {
				KLog.log("[Share] Rejected file \(sanitized): no active connection host")
				showFileFailedNotification(filename: sanitized)

				return
			}

			// Chain after any in-flight receive so we connect to the phone's listener sequentially.
			// Phone's CompositeUploadFileJob expects exactly one TCP connection at a time on the shared port — see `receiveChain` doc above.
			let previousTail = self.receiveChain
			let waitingForPrevious = previousTail != nil
			if waitingForPrevious {
				KLog.log("[Share] Queued \(sanitized) (\(payloadSize) bytes) from \(host):\(port) — waiting for previous receive")
			} else {
				KLog.log("[Share] Receiving \(sanitized) (\(payloadSize) bytes) from \(host):\(port)")
			}

			self.receiveChain = Task { [weak self] in
				_ = await previousTail?.value
				guard let self = self else {
					return
				}

				if waitingForPrevious {
					KLog.log("[Share] Starting queued receive: \(sanitized)")
				}

				await self.receiveFile(host: host, port: port, filename: sanitized, expectedSize: payloadSize)
			}
		}
	}

	/// Tunables for send retry.
	/// Same rationale as receive retry — phone-side TLS endpoint can hiccup on a fresh handshake; retrying with a new socket + port + share packet usually works on the next attempt.
	private static let sendRetryAttempts = 5
	private static let sendRetryInitialBackoffMs: UInt32 = 200

	/// Outcome of one send attempt.
	/// Drives the retry loop in `sendFile`.
	private enum SendAttemptResult {
		case success
		case retryable(String)  // transient failure — try again with a fresh port + share packet
		case fatal(String)      // not worth retrying (e.g., file unreadable, identity missing)
	}

	// MARK: - Outgoing Transfers

	func sendFile(url: URL) {
		// === Pre-validation (run once on MainActor — no retry helps these) ===

		guard device.kdeConn != nil else {
			KLog.log("[Share] No connection to send file")
			showFileSendFailedNotification(filename: url.lastPathComponent, reason: "no active connection")

			return
		}

		let filename = url.lastPathComponent

		guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let fileSize = attrs[.size] as? Int64 else {
			KLog.log("[Share] Failed to read file attributes: \(filename)")
			showFileSendFailedNotification(filename: filename, reason: "could not read file")

			return
		}

		guard fileSize > 0 else {
			KLog.log("[Share] Refusing to send empty file: \(filename)")
			showFileSendFailedNotification(filename: filename, reason: "file is empty")

			return
		}

		guard fileSize <= Self.maxFileSize else {
			KLog.log("[Share] File too large: \(fileSize) bytes (max \(Self.maxFileSize))")
			showFileSendFailedNotification(filename: filename, reason: "file exceeds 2 GB limit")

			return
		}

		// Confirm we can open the file at least once before announcing the transfer
		guard let probeHandle = try? FileHandle(forReadingFrom: url) else {
			KLog.log("[Share] Failed to open file: \(filename)")
			showFileSendFailedNotification(filename: filename, reason: "could not open file")

			return
		}

		try? probeHandle.close()

		// Pre-flight check that we can build a TLS identity at all (not used for the actual handshake — each retry creates its own fresh transfer identity).
		guard CertificateManager.shared.getOrCreateIdentity() != nil else {
			KLog.log("[Share] No identity available for file send")
			showFileSendFailedNotification(filename: filename, reason: "missing local identity")

			return
		}

		let storedCert = Config.shared.loadPairedDeviceCert(id: device.id)
		let deviceName = device.name
		weak var weakSelf = self

		// === Run retry loop on background queue ===
		DispatchQueue.global(qos: .userInitiated).async {
			var lastError = "unknown"
			for attempt in 1...Self.sendRetryAttempts {
				if attempt > 1 {
					let backoffMs = Self.sendRetryInitialBackoffMs * UInt32(1 << (attempt - 1))
					KLog.log("[Share] Send retry \(attempt)/\(Self.sendRetryAttempts) for \(filename) after \(backoffMs)ms (\(lastError))")
					usleep(backoffMs * 1000)
				}

				let result = Self.runSendAttempt(
					url: url,
					filename: filename,
					fileSize: fileSize,
					deviceName: deviceName,
					storedCert: storedCert,
					attempt: attempt,
					sendPacket: { packet in
						// device.send is @MainActor — bounce back to the main queue.
						DispatchQueue.main.async {
							weakSelf?.device.send(packet)
						}
					}
				)

				switch result {
				case .success:
					Task { @MainActor in weakSelf?.showFileSentNotification(filename: filename) }

					return
				case .fatal(let reason):
					Task { @MainActor in
						weakSelf?.showFileSendFailedNotification(filename: filename, reason: reason)
					}

					return
				case .retryable(let reason):
					lastError = reason
					continue
				}
			}

			KLog.log("[Share] Send failed after \(Self.sendRetryAttempts) attempts for \(filename): \(lastError)")
			Task { @MainActor in
				weakSelf?.showFileSendFailedNotification(filename: filename, reason: "\(lastError) (after \(Self.sendRetryAttempts) attempts)")
			}
		}
	}

	/// Runs one full send attempt: bind a fresh server socket, announce the new port to the phone via the supplied `sendPacket` closure, accept the phone's connection, TLS handshake, stream the file.
	/// Returns a result that the retry loop interprets.
	///
	/// This is `nonisolated` so the retry loop on the background queue can call it without bouncing back through MainActor for every step.
	private nonisolated static func runSendAttempt(url: URL, filename: String, fileSize: Int64, deviceName: String, storedCert: Data?, attempt: Int, sendPacket: (NetworkPacket) -> Void) -> SendAttemptResult {
		// Open a fresh file handle for this attempt (each attempt streams from the start).
		guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
			return .fatal("could not open file")
		}

		defer { try? fileHandle.close() }

		// ---- Bind + listen on a fresh ephemeral port ----
		let serverFd = socket(AF_INET, SOCK_STREAM, 0)
		guard serverFd >= 0 else {
			return .retryable("socket() failed errno=\(errno)")
		}

		var reuse: Int32 = 1
		setsockopt(serverFd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

		var addr = sockaddr_in()
		addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
		addr.sin_family = sa_family_t(AF_INET)
		addr.sin_port = 0 // OS picks port
		addr.sin_addr.s_addr = INADDR_ANY.bigEndian

		let bindResult = withUnsafePointer(to: &addr) { ptr in
			ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				bind(serverFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
			}
		}

		guard bindResult == 0 else {
			Darwin.close(serverFd)

			return .retryable("bind() failed errno=\(errno)")
		}

		var boundAddr = sockaddr_in()
		var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
		_ = withUnsafeMutablePointer(to: &boundAddr) { ptr in
			ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				getsockname(serverFd, $0, &addrLen)
			}
		}

		let port = UInt16(bigEndian: boundAddr.sin_port)

		guard listen(serverFd, 1) == 0 else {
			Darwin.close(serverFd)

			return .retryable("listen() failed errno=\(errno)")
		}

		// Now (after listen) tell the phone what port to connect to.
		// It can never beat us.
		var sharePacket = NetworkPacket(type: "kdeconnect.share.request", body: [
			"filename": AnyCodable(filename)
		])

		sharePacket.payloadSize = fileSize
		sharePacket.payloadTransferInfo = ["port": AnyCodable(Int(port))]
		sendPacket(sharePacket)
		KLog.log("[Share] Sending \(filename) (\(fileSize) bytes) on port \(port) (attempt \(attempt))")

		// ---- Accept ----
		var acceptTimeout = timeval(tv_sec: __darwin_time_t(Self.acceptTimeout), tv_usec: 0)
		setsockopt(serverFd, SOL_SOCKET, SO_RCVTIMEO, &acceptTimeout, socklen_t(MemoryLayout<timeval>.size))

		var clientAddr = sockaddr_storage()
		var clientLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
		let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
			ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				accept(serverFd, $0, &clientLen)
			}
		}

		Darwin.close(serverFd)

		guard clientFd >= 0 else {
			return .retryable("phone did not connect to port \(port) (errno=\(errno))")
		}

		SocketHelpers.configureTransferSocket(fd: clientFd, ioTimeoutSeconds: Int(Self.socketIOTimeout))

		// Get a fresh, single-use SecIdentity for THIS handshake — see TransferIdentity doc in CertificateManager.
		// Without this, SecureTransport's per-SecIdentity session-cache state corrupts after 5–7 short-lived TLS handshakes and every subsequent handshake fails with errSSLInternal (-9810) until app restart.
		guard let transferId = CertificateManager.shared.freshTransferIdentity() else {
			Darwin.close(clientFd)

			return .retryable("could not create fresh TLS identity")
		}

		return withExtendedLifetime(transferId) { () -> SendAttemptResult in
			Self.runSendTLSAndStream(clientFd: clientFd, identity: transferId.identity, fileHandle: fileHandle, fileSize: fileSize, filename: filename, deviceName: deviceName, storedCert: storedCert)
		}
	}

	/// TLS handshake + stream-the-file portion of a send attempt.
	/// Split out so the caller can wrap it in `withExtendedLifetime(transferId)` to keep the keychain alive for the entire SSLContext lifetime.
	private nonisolated static func runSendTLSAndStream(clientFd: Int32, identity: SecIdentity, fileHandle: FileHandle, fileSize: Int64, filename: String, deviceName: String, storedCert: Data?) -> SendAttemptResult {
		// ---- TLS handshake ----
		guard let ctx = SSLCreateContext(nil, .serverSide, .streamType) else {
			Darwin.close(clientFd)

			return .retryable("SSLCreateContext failed")
		}

		let fdPtr = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
		defer { fdPtr.deallocate() }

		fdPtr.pointee = clientFd
		TLSHelpers.configure(ctx, TLSContextConfig(isServer: true, identity: identity, fdPtr: fdPtr))

		guard TLSHelpers.runHandshake(ctx, role: "Share send", deadline: Self.handshakeTimeout) else {
			SSLClose(ctx); Darwin.close(clientFd)
			// Hand-shake failure is the classic transient mode that retry was built for.

			return .retryable("TLS handshake failed")
		}

		// ---- Peer cert validation (paired device must present the cert we recorded) ----
		if let storedCert = storedCert, storedCert.count > 1 {
			if !TLSHelpers.validatePeer(ctx, expectedCertData: storedCert) {
				KLog.log("[Share] File transfer peer cert mismatch — rejecting")
				SSLClose(ctx); Darwin.close(clientFd)

				return .fatal("peer certificate mismatch")
			}
		}

		// ---- Stream file data ----
		let started = Date()
		var totalWritten: Int64 = 0
		var lastProgress = Date()
		var sendError: String? = nil

		outerLoop: while totalWritten < fileSize {
			if Date().timeIntervalSince(started) > Self.totalTimeout {
				sendError = "exceeded total transfer timeout"
				break
			}

			let chunk: Data
			do {
				guard let read = try fileHandle.read(upToCount: Self.chunkSize), !read.isEmpty else {
					sendError = "file ended before expected size (\(totalWritten)/\(fileSize) bytes)"
					break
				}

				chunk = read
			} catch {
				sendError = "file read failed: \(error)"
				break
			}

			var chunkWritten = 0
			while chunkWritten < chunk.count {
				var written = 0
				let remaining = chunk.count - chunkWritten
				let writeStatus = chunk.withUnsafeBytes { buf -> OSStatus in
					guard let baseAddr = buf.baseAddress else {
						return errSecParam
					}

					return SSLWrite(ctx, baseAddr + chunkWritten, remaining, &written)
				}

				if written > 0 {
					chunkWritten += written
					lastProgress = Date()
				}

				if writeStatus == errSecSuccess {
					continue
				}

				if writeStatus == errSSLWouldBlock {
					if Date().timeIntervalSince(lastProgress) > Self.stallTimeout {
						sendError = "no progress for \(Int(Self.stallTimeout))s during send"
						break outerLoop
					}

					if written == 0 {
						usleep(2000)
					}

					continue
				}

				sendError = "SSLWrite returned \(writeStatus)"
				break outerLoop
			}

			totalWritten += Int64(chunkWritten)

			if fileSize > 5_000_000 {
				let pct = totalWritten * 100 / fileSize
				let prevPct = (totalWritten - Int64(chunkWritten)) * 100 / fileSize
				if pct / 5 != prevPct / 5 {
					KLog.log("[Share] \(filename): \(pct)% (\(totalWritten)/\(fileSize) bytes)")
				}
			}
		}

		// Graceful close — SO_LINGER drains the kernel send buffer before FIN.
		SocketHelpers.enableLinger(fd: clientFd)
		SSLClose(ctx)
		Darwin.close(clientFd)

		let elapsed = Date().timeIntervalSince(started)
		if let err = sendError {
			KLog.log("[Share] Send incomplete: \(filename) (\(totalWritten)/\(fileSize) bytes, \(String(format: "%.1f", elapsed))s) — \(err)")
			// Mid-stream failure: if we got nothing, retry; if we got partial bytes, the phone has a partial file — don't double-send, just report the failure.

			return totalWritten == 0 ? .retryable(err) : .fatal(err)
		}

		let mbps = elapsed > 0 ? Double(totalWritten) / elapsed / 1_000_000 : 0
		KLog.log("[Share] Sent \(filename) → \(deviceName) (\(totalWritten) bytes, \(String(format: "%.1f", elapsed))s, \(String(format: "%.1f", mbps)) MB/s)")

		return .success
	}

	// MARK: - Incoming File Transfers

	private func receiveFile(host: String, port: UInt16, filename: String, expectedSize: Int64) async {
		if expectedSize > Self.maxFileSize {
			KLog.log("[Share] File too large: \(expectedSize) bytes, max \(Self.maxFileSize)")
			showFileFailedNotification(filename: filename)

			return
		}

		let downloadPath = Config.shared.downloadDirectory
		let downloadsDir = URL(fileURLWithPath: downloadPath, isDirectory: true)
		try? FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)

		// Validate downloads directory is writable
		guard FileManager.default.isWritableFile(atPath: downloadsDir.path) else {
			KLog.log("[Share] Downloads directory not writable: \(downloadsDir.path)")
			showFileFailedNotification(filename: filename)

			return
		}

		var destURL = downloadsDir.appendingPathComponent(filename)

		// Handle duplicate filenames
		var counter = 1
		while FileManager.default.fileExists(atPath: destURL.path) {
			let name = (filename as NSString).deletingPathExtension
			let ext = (filename as NSString).pathExtension
			if ext.isEmpty {
				destURL = downloadsDir.appendingPathComponent("\(name) (\(counter))")
			} else {
				destURL = downloadsDir.appendingPathComponent("\(name) (\(counter)).\(ext)")
			}

			counter += 1
		}

		// Use .partial extension during download
		let partialURL = destURL.appendingPathExtension("partial")

		// Load stored cert on MainActor before dispatching to background
		let storedCert = Config.shared.loadPairedDeviceCert(id: device.id)

		let bytesWritten = await withCheckedContinuation { continuation in
			DispatchQueue.global(qos: .userInitiated).async {
				let result = self.downloadFileStreaming(host: host, port: port, expectedSize: Int(expectedSize), destURL: partialURL, storedCertData: storedCert)
				continuation.resume(returning: result)
			}
		}

		guard bytesWritten > 0 else {
			KLog.log("[Share] File download failed for \(filename) (no bytes received)")
			try? FileManager.default.removeItem(at: partialURL)
			showFileFailedNotification(filename: filename)

			return
		}

		let complete = bytesWritten == Int(expectedSize)
		do {
			if complete {
				try FileManager.default.moveItem(at: partialURL, to: destURL)
				KLog.log("[Share] Saved \(destURL.lastPathComponent) (\(bytesWritten) bytes)")
				showFileReceivedNotification(filename: filename, path: destURL.path)
			} else {
				KLog.log("[Share] Partial: \(partialURL.lastPathComponent) (\(bytesWritten)/\(expectedSize) bytes)")
				showFileReceivedNotification(filename: filename, path: partialURL.path, partial: true, received: bytesWritten, expected: Int(expectedSize))
			}
		} catch {
			KLog.log("[Share] Failed to finalize file: \(error)")
			try? FileManager.default.removeItem(at: partialURL)
			showFileFailedNotification(filename: filename)
		}
	}

	/// Tunables for transfer retry.
	/// The phone-side TLS upload endpoint goes stale after idle periods (every short-lived TLS handshake fails with errSSLInternal -9810 until something kicks it back).
	/// Retrying with a fresh TCP+TLS context typically succeeds within 1-2 attempts because the failed connection wakes the phone-side listener back up.
	private static let receiveRetryAttempts = 5
	private static let receiveRetryInitialBackoffMs: UInt32 = 200

	/// Stream file download directly to disk, with retry on TLS handshake / connect failure.
	/// Each attempt uses a brand-new TCP socket and SSLContext — no shared state survives a failed attempt.
	/// Returns the total bytes received from the LAST attempt that got any data (we don't retry once we've started receiving — partial files are kept).
	private nonisolated func downloadFileStreaming(host: String, port: UInt16, expectedSize: Int, destURL: URL, storedCertData: Data?) -> Int {
		for attempt in 1...Self.receiveRetryAttempts {
			if attempt > 1 {
				// Exponential backoff: 400ms, 800ms, 1.6s, 3.2s.
				// Gives the phone time to refresh its TLS endpoint between attempts.
				let backoffMs = Self.receiveRetryInitialBackoffMs * UInt32(1 << (attempt - 1))
				KLog.log("[Share] Retry \(attempt)/\(Self.receiveRetryAttempts) for \(destURL.lastPathComponent) after \(backoffMs)ms backoff")
				usleep(backoffMs * 1000)
			}

			let bytes = downloadFileStreamingOnce(host: host, port: port, expectedSize: expectedSize, destURL: destURL, storedCertData: storedCertData, attempt: attempt)
			if bytes > 0 {
				// Got data — even if partial, keep what we have rather than restart from zero.
				// Partial files are saved with .partial extension by the caller.
				return bytes
			}
		}

		return 0
	}

	/// One attempt at the download.
	/// Returns total bytes written.
	/// Returns 0 if connect or TLS handshake failed; the retry wrapper will try again.
	private nonisolated func downloadFileStreamingOnce(host: String, port: UInt16, expectedSize: Int, destURL: URL, storedCertData: Data?, attempt: Int) -> Int {
		let totalReceived = TLSHelpers.downloadPayloadFile(
			host: host,
			port: port,
			expectedSize: Int64(expectedSize),
			destURL: destURL,
			storedCertData: storedCertData,
			role: "Share recv",
			connectTimeout: 15,
			handshakeTimeout: Self.handshakeTimeout,
			stallTimeout: Self.stallTimeout,
			totalTimeout: Self.totalTimeout,
			chunkSize: Self.chunkSize,
			onProgress: { totalRead in
				if expectedSize > 5_000_000 {
					let pct = totalRead * 100 / Int64(expectedSize)
					let prevPct = max(0, totalRead - Int64(Self.chunkSize)) * 100 / Int64(expectedSize)
					if pct / 5 != prevPct / 5 {
						KLog.log("[Share] Recv \(pct)% (\(totalRead)/\(expectedSize) bytes)")
					}
				}
			}
		)

		return Int(totalReceived ?? 0)
	}

	// MARK: - Notifications

	private func showFileReceivedNotification(filename: String, path: String, partial: Bool = false, received: Int = 0, expected: Int = 0) {
		let content = UNMutableNotificationContent()
		if partial {
			content.title = "File Partially Received"
			content.body = "\(filename) — \(received / 1024)KB of \(expected / 1024)KB"
		} else {
			content.title = "File Received"
			content.body = filename
		}

		content.sound = .default
		content.categoryIdentifier = "FILE_RECEIVED"
		content.userInfo = ["filePath": path]

		let request = UNNotificationRequest(identifier: "file-\(UUID().uuidString)", content: content, trigger: nil)
		UNUserNotificationCenter.current().add(request)
	}

	private func showFileFailedNotification(filename: String) {
		let content = UNMutableNotificationContent()
		content.title = "File Transfer Failed"
		content.body = filename
		content.sound = .default

		let request = UNNotificationRequest(identifier: "file-\(UUID().uuidString)", content: content, trigger: nil)
		UNUserNotificationCenter.current().add(request)
	}

	private func showFileSentNotification(filename: String) {
		let content = UNMutableNotificationContent()
		content.title = "File Sent"
		content.body = filename
		content.sound = .default

		let request = UNNotificationRequest(identifier: "file-\(UUID().uuidString)", content: content, trigger: nil)
		UNUserNotificationCenter.current().add(request)
	}

	private func showFileSendFailedNotification(filename: String, reason: String = "transfer failed") {
		let content = UNMutableNotificationContent()
		content.title = "File Send Failed"
		content.body = "\(filename) — \(reason)"
		content.sound = .default

		let request = UNNotificationRequest(identifier: "file-\(UUID().uuidString)", content: content, trigger: nil)
		UNUserNotificationCenter.current().add(request)
	}

}

