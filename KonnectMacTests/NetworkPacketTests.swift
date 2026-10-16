import AppKit
import XCTest
@testable import KonnectMac

@MainActor
final class NetworkPacketTests: XCTestCase {
    func testDecodedIdentityPreservesAdvertisedPort() throws {
        let data = Data(#"{"id":1,"type":"kdeconnect.identity","body":{"deviceId":"phone","tcpPort":1716}}"#.utf8)
        let packet = try XCTUnwrap(NetworkPacket.deserialize(from: data))

        XCTAssertEqual(DeviceManager.advertisedTCPPort(from: packet), 1716)
    }

    func testMissingIdentityPortUsesProtocolFallback() throws {
        let data = Data(#"{"id":1,"type":"kdeconnect.identity","body":{"deviceId":"phone"}}"#.utf8)
        let packet = try XCTUnwrap(NetworkPacket.deserialize(from: data))

        XCTAssertEqual(DeviceManager.advertisedTCPPort(from: packet), 1716)
    }

    func testAdvertisedPortBelowProtocolRangeIsRejected() throws {
        let data = Data(#"{"id":1,"type":"kdeconnect.identity","body":{"deviceId":"phone","tcpPort":1714}}"#.utf8)
        let packet = try XCTUnwrap(NetworkPacket.deserialize(from: data))
        XCTAssertNil(DeviceManager.advertisedTCPPort(from: packet))
    }

    func testInvalidAdvertisedPortsAreRejected() throws {
        let outOfRangeData = Data(#"{"id":1,"type":"kdeconnect.identity","body":{"deviceId":"phone","tcpPort":70000}}"#.utf8)
        let malformedData = Data(#"{"id":1,"type":"kdeconnect.identity","body":{"deviceId":"phone","tcpPort":"nope"}}"#.utf8)
        let outOfRange = try XCTUnwrap(NetworkPacket.deserialize(from: outOfRangeData))
        let malformed = try XCTUnwrap(NetworkPacket.deserialize(from: malformedData))

        XCTAssertNil(DeviceManager.advertisedTCPPort(from: outOfRange))
        XCTAssertNil(DeviceManager.advertisedTCPPort(from: malformed))
    }

    func testClipboardFileCapabilityParsingIsPacketLocal() throws {
        let capableData = Data(#"{"id":1,"type":"kdeconnect.identity","body":{"deviceId":"kde-desktop","incomingCapabilities":["kdeconnect.clipboard.file"]}}"#.utf8)
        let legacyData = Data(#"{"id":2,"type":"kdeconnect.identity","body":{"deviceId":"legacy-phone","incomingCapabilities":["kdeconnect.clipboard"]}}"#.utf8)
        let capable = try XCTUnwrap(NetworkPacket.deserialize(from: capableData))
        let legacy = try XCTUnwrap(NetworkPacket.deserialize(from: legacyData))

        XCTAssertTrue(ClipboardPlugin.incomingCapabilities(from: capable).contains(NetworkPacket.clipboardFilePacketType))
        XCTAssertFalse(ClipboardPlugin.incomingCapabilities(from: legacy).contains(NetworkPacket.clipboardFilePacketType))
    }

    func testDeviceRetainsCapabilitiesWhenClipboardStartsAfterIdentity() async throws {
        let device = Device(id: "kde-desktop", name: "Desktop")
        let connection = KDEConnection(host: "127.0.0.1", port: 1716, isIncoming: false)
        device.kdeConn = connection
        let data = Data(#"{"id":1,"type":"kdeconnect.identity","body":{"deviceId":"kde-desktop","incomingCapabilities":["kdeconnect.clipboard.file"]}}"#.utf8)
        let packet = try XCTUnwrap(NetworkPacket.deserialize(from: data))

        connection.onIdentityReceived?(packet)
        await Task.yield()

        XCTAssertTrue(device.peerIncomingCapabilities.contains(NetworkPacket.clipboardFilePacketType))
        XCTAssertEqual(device.capabilityObserverConnectionId, ObjectIdentifier(connection))

        let replacement = KDEConnection(host: "127.0.0.2", port: 1716, isIncoming: false)
        device.kdeConn = replacement
        XCTAssertTrue(device.peerIncomingCapabilities.isEmpty)

        connection.onIdentityReceived?(packet)
        await Task.yield()

        XCTAssertTrue(device.peerIncomingCapabilities.isEmpty)
    }

	func testUpstreamClipboardImagePacketMetadata() throws {
		// kdeconnect-kde names clipboard images "<epoch ms>.PNG".
		var packet = NetworkPacket(
			type: NetworkPacket.clipboardFilePacketType,
			body: [
				"filename": AnyCodable("1792131265479.PNG")
			]
		)

		packet.payloadSize = 4096
		packet.payloadTransferInfo = ["port": AnyCodable(1739)]

		let metadata = try XCTUnwrap(ClipboardPlugin.fileTransferMetadata(from: packet))

		XCTAssertEqual(metadata.port, 1739)
		XCTAssertEqual(metadata.size, 4096)
		XCTAssertEqual(metadata.filename, "1792131265479.PNG")
	}

	func testClipboardFilePacketAcceptsArbitraryFile() throws {
		var packet = NetworkPacket(
			type: NetworkPacket.clipboardFilePacketType,
			body: [
				"filename": AnyCodable("report.pdf")
			]
		)

		packet.payloadSize = 4096
		packet.payloadTransferInfo = ["port": AnyCodable(1739)]

		let metadata = try XCTUnwrap(ClipboardPlugin.fileTransferMetadata(from: packet))

		XCTAssertEqual(metadata.port, 1739)
		XCTAssertEqual(metadata.size, 4096)
		XCTAssertEqual(metadata.filename, "report.pdf")
	}

	func testClipboardFilePacketSanitizesFilename() throws {
		var packet = NetworkPacket(
			type: NetworkPacket.clipboardFilePacketType,
			body: [
				"filename": AnyCodable("../../report.pdf")
			]
		)

		packet.payloadSize = 4096
		packet.payloadTransferInfo = ["port": AnyCodable(1739)]

		let metadata = try XCTUnwrap(ClipboardPlugin.fileTransferMetadata(from: packet))

		XCTAssertEqual(metadata.port, 1739)
		XCTAssertEqual(metadata.size, 4096)
		XCTAssertEqual(metadata.filename, "____report.pdf")
	}

	func testClipboardFilePacketRejectsOversizedPayload() {
		var packet = NetworkPacket(
			type: NetworkPacket.clipboardFilePacketType,
			body: [
				"filename": AnyCodable("huge.iso")
			]
		)

		packet.payloadSize = 51 * 1024 * 1024
		packet.payloadTransferInfo = ["port": AnyCodable(1739)]

		XCTAssertNil(ClipboardPlugin.fileTransferMetadata(from: packet))
	}

	func testClipboardFilePacketRejectsMissingPort() {
		var packet = NetworkPacket(
			type: NetworkPacket.clipboardFilePacketType,
			body: [
				"filename": AnyCodable("report.pdf")
			]
		)

		packet.payloadSize = 4096

		XCTAssertNil(ClipboardPlugin.fileTransferMetadata(from: packet))
	}

	func testClipboardFilePacketHandlesOverlongExtensionWithoutLooping() throws {
		let overlongFilename = "file." + String(repeating: "a", count: 300)
		var packet = NetworkPacket(
			type: NetworkPacket.clipboardFilePacketType,
			body: [
				"filename": AnyCodable(overlongFilename)
			]
		)

		packet.payloadSize = 4096
		packet.payloadTransferInfo = ["port": AnyCodable(1739)]

		let metadata = try XCTUnwrap(ClipboardPlugin.fileTransferMetadata(from: packet))

		XCTAssertEqual(metadata.port, 1739)
		XCTAssertEqual(metadata.size, 4096)
		XCTAssertLessThanOrEqual(metadata.filename.utf8.count, 250)
		XCTAssertTrue(metadata.filename.hasPrefix("file."))
	}

	func testExtractImagePayloadRejectsNonImageFiles() throws {
		let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("report.pdf")
		try "dummy-pdf-content".write(to: tempURL, atomically: true, encoding: .utf8)
		defer { try? FileManager.default.removeItem(at: tempURL) }

		XCTAssertNil(ClipboardPlugin.extractImagePayload(from: tempURL))
	}

	func testCleanupStaleTransferDirectoriesRemovesOlderDirectories() throws {
		let baseDir = FileManager.default.temporaryDirectory.appendingPathComponent("KonnectMacClipboard", isDirectory: true)
		let oldDir = baseDir.appendingPathComponent("test-old-\(UUID().uuidString)", isDirectory: true)
		let freshDir = baseDir.appendingPathComponent("test-fresh-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: freshDir, withIntermediateDirectories: true)
		defer {
			try? FileManager.default.removeItem(at: oldDir)
			try? FileManager.default.removeItem(at: freshDir)
		}

		let twoDaysAgo = Date().addingTimeInterval(-2 * 24 * 60 * 60)
		try FileManager.default.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: oldDir.path)

		ClipboardPlugin.cleanupStaleTransferDirectories()

		XCTAssertFalse(FileManager.default.fileExists(atPath: oldDir.path))
		XCTAssertTrue(FileManager.default.fileExists(atPath: freshDir.path))
	}

	func testNewerClipboardFileWinsWhenOlderPeerFinishesLast() throws {
		let pasteboard = NSPasteboard.withUniqueName()
		let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		defer {
			pasteboard.releaseGlobally()
			try? FileManager.default.removeItem(at: root)
		}

		let olderURL = try stagedClipboardFile(in: root, name: "older")
		let newerURL = try stagedClipboardFile(in: root, name: "newer")
		let olderPeer = ClipboardPlugin(device: Device(id: "older-peer", name: "Older"), pasteboard: pasteboard)
		let newerPeer = ClipboardPlugin(device: Device(id: "newer-peer", name: "Newer"), pasteboard: pasteboard)
		let olderReceive = olderPeer.beginFileReceive()
		let newerReceive = newerPeer.beginFileReceive()
		newerPeer.applyReceivedFile(at: newerURL, transferDir: newerURL.deletingLastPathComponent(), imagePayload: nil, receive: newerReceive)
		olderPeer.applyReceivedFile(at: olderURL, transferDir: olderURL.deletingLastPathComponent(), imagePayload: nil, receive: olderReceive)

		XCTAssertEqual(pasteboard.string(forType: .fileURL), newerURL.absoluteString)
		XCTAssertTrue(FileManager.default.fileExists(atPath: newerURL.path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: olderURL.deletingLastPathComponent().path))
	}

	func testNewerClipboardTextInvalidatesPendingFileReceive() throws {
		let pasteboard = NSPasteboard.withUniqueName()
		let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		defer {
			pasteboard.releaseGlobally()
			try? FileManager.default.removeItem(at: root)
		}

		let fileURL = try stagedClipboardFile(in: root, name: "older")
		let plugin = ClipboardPlugin(device: Device(id: "peer", name: "Peer"), pasteboard: pasteboard)
		let receive = plugin.beginFileReceive()
		plugin.handle(packet: NetworkPacket(type: "kdeconnect.clipboard", body: ["content": AnyCodable("new text")]))
		plugin.applyReceivedFile(at: fileURL, transferDir: fileURL.deletingLastPathComponent(), imagePayload: nil, receive: receive)

		XCTAssertEqual(pasteboard.string(forType: .string), "new text")
		XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.deletingLastPathComponent().path))
	}

	func testStoppedClipboardPluginDiscardsPendingFileReceive() throws {
		let pasteboard = NSPasteboard.withUniqueName()
		let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		defer {
			pasteboard.releaseGlobally()
			try? FileManager.default.removeItem(at: root)
		}

		pasteboard.setString("local clipboard", forType: .string)
		let fileURL = try stagedClipboardFile(in: root, name: "older")
		let plugin = ClipboardPlugin(device: Device(id: "peer", name: "Peer"), pasteboard: pasteboard)
		let receive = plugin.beginFileReceive()
		plugin.stop()
		plugin.applyReceivedFile(at: fileURL, transferDir: fileURL.deletingLastPathComponent(), imagePayload: nil, receive: receive)

		XCTAssertEqual(pasteboard.string(forType: .string), "local clipboard")
		XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.deletingLastPathComponent().path))
	}

	private func stagedClipboardFile(in root: URL, name: String) throws -> URL {
		let directory = root.appendingPathComponent(name, isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let fileURL = directory.appendingPathComponent("\(name).txt")
		try Data(name.utf8).write(to: fileURL)
		return fileURL
	}

	func testSharedShareFilenameSanitizerBoundsOverlongUnicodeExtension() {
		let filename = "report." + String(repeating: "é", count: 300)
		let sanitized = FileTransferFilename.sanitize(filename, fallback: "download")

		XCTAssertEqual(sanitized, "report." + String(repeating: "é", count: 100))
		XCTAssertLessThanOrEqual(sanitized.utf8.count, 250)
		XCTAssertEqual(FileTransferFilename.sanitize("../../report.pdf", fallback: "download"), "____report.pdf")
		XCTAssertEqual(FileTransferFilename.sanitize("\0", fallback: "download"), "download")
	}
}
