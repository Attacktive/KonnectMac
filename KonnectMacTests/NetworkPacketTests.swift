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

    func testIdentityAdvertisesImageClipboardCapability() {
        let packet = NetworkPacket.identityPacket()
        let incoming = packet.body["incomingCapabilities"]?.value as? [String]
        let outgoing = packet.body["outgoingCapabilities"]?.value as? [String]

        XCTAssertTrue(incoming?.contains(NetworkPacket.clipboardImagePacketType) == true)
        XCTAssertTrue(outgoing?.contains(NetworkPacket.clipboardImagePacketType) == true)
    }

    func testImageClipboardCapabilityParsingIsPacketLocal() throws {
        let capableData = Data(#"{"id":1,"type":"kdeconnect.identity","body":{"deviceId":"image-capable-phone","incomingCapabilities":["kdeconnect.clipboard.image"]}}"#.utf8)
        let legacyData = Data(#"{"id":2,"type":"kdeconnect.identity","body":{"deviceId":"legacy-phone","incomingCapabilities":["kdeconnect.clipboard"]}}"#.utf8)
        let capable = try XCTUnwrap(NetworkPacket.deserialize(from: capableData))
        let legacy = try XCTUnwrap(NetworkPacket.deserialize(from: legacyData))

        XCTAssertTrue(ClipboardPlugin.incomingCapabilities(from: capable).contains(NetworkPacket.clipboardImagePacketType))
        XCTAssertFalse(ClipboardPlugin.incomingCapabilities(from: legacy).contains(NetworkPacket.clipboardImagePacketType))
    }

    func testDeviceRetainsCapabilitiesWhenClipboardStartsAfterIdentity() async throws {
        let device = Device(id: "image-capable-phone", name: "Phone")
        let connection = KDEConnection(host: "127.0.0.1", port: 1716, isIncoming: false)
        device.kdeConn = connection
        let data = Data(#"{"id":1,"type":"kdeconnect.identity","body":{"deviceId":"image-capable-phone","incomingCapabilities":["kdeconnect.clipboard.image"]}}"#.utf8)
        let packet = try XCTUnwrap(NetworkPacket.deserialize(from: data))

        connection.onIdentityReceived?(packet)
        await Task.yield()

        XCTAssertTrue(device.peerIncomingCapabilities.contains(NetworkPacket.clipboardImagePacketType))
        XCTAssertEqual(device.capabilityObserverConnectionId, ObjectIdentifier(connection))

        let replacement = KDEConnection(host: "127.0.0.2", port: 1716, isIncoming: false)
        device.kdeConn = replacement
        XCTAssertTrue(device.peerIncomingCapabilities.isEmpty)

        connection.onIdentityReceived?(packet)
        await Task.yield()

        XCTAssertTrue(device.peerIncomingCapabilities.isEmpty)
    }

    func testImageClipboardPacketMetadataValidation() throws {
        var packet = NetworkPacket(type: NetworkPacket.clipboardImagePacketType, body: [
            "mimeType": AnyCodable("image/png")
        ])
        packet.payloadSize = 4096
        packet.payloadTransferInfo = ["port": AnyCodable(1739)]

        let metadata = try XCTUnwrap(ClipboardPlugin.imageTransferMetadata(from: packet))

        XCTAssertEqual(metadata.port, 1739)
        XCTAssertEqual(metadata.size, 4096)
        XCTAssertEqual(metadata.mimeType, "image/png")
    }

    func testImageClipboardPacketRejectsOversizedPayload() {
        var packet = NetworkPacket(type: NetworkPacket.clipboardImagePacketType, body: [
            "mimeType": AnyCodable("image/png")
        ])
        packet.payloadSize = 100 * 1024 * 1024
        packet.payloadTransferInfo = ["port": AnyCodable(1739)]

        XCTAssertNil(ClipboardPlugin.imageTransferMetadata(from: packet))
    }
}
