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

		packet.payloadSize = 3 * 1024 * 1024 * 1024
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
}
