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

        XCTAssertEqual(DeviceManager.advertisedTCPPort(from: packet), Config.minPort)
    }

    func testInvalidAdvertisedPortsAreRejected() throws {
        let outOfRangeData = Data(#"{"id":1,"type":"kdeconnect.identity","body":{"deviceId":"phone","tcpPort":70000}}"#.utf8)
        let malformedData = Data(#"{"id":1,"type":"kdeconnect.identity","body":{"deviceId":"phone","tcpPort":"nope"}}"#.utf8)
        let outOfRange = try XCTUnwrap(NetworkPacket.deserialize(from: outOfRangeData))
        let malformed = try XCTUnwrap(NetworkPacket.deserialize(from: malformedData))

        XCTAssertNil(DeviceManager.advertisedTCPPort(from: outOfRange))
        XCTAssertNil(DeviceManager.advertisedTCPPort(from: malformed))
    }
}
