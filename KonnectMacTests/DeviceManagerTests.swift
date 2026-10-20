import Darwin
import XCTest
@testable import KonnectMac

@MainActor
final class DeviceManagerTests: XCTestCase {
	func testDistinctPeersAreAdmittedIndependentlyAtAcceptTime() {
		XCTAssertFalse(DeviceManager.incomingConnectionMatchesExisting(existingHost: "172.16.0.10", incomingHost: "172.16.1.20"))
	}

	func testSameHostIsRecognizedAsDuplicatePath() {
		XCTAssertTrue(DeviceManager.incomingConnectionMatchesExisting(existingHost: "172.16.0.10", incomingHost: "172.16.0.10"))
	}

	func testConnectionIdentityStagesAdvertisedEndpoint() throws {
		let data = Data(#"{"id":1,"type":"kdeconnect.identity","body":{"deviceId":"phone","deviceName":"Phone","deviceType":"phone","tcpPort":1764}}"#.utf8)
		let packet = try XCTUnwrap(NetworkPacket.deserialize(from: data))
		let identity = try XCTUnwrap(DeviceManager.connectionIdentity(from: packet))

		XCTAssertEqual(identity.deviceId, "phone")
		XCTAssertEqual(identity.deviceName, "Phone")
		XCTAssertEqual(identity.deviceType, "phone")
		XCTAssertEqual(identity.tcpPort, 1764)
	}

	func testIdentityReceiptStopsIncomingIdentityTimeout() throws {
		let data = Data(#"{"id":1,"type":"kdeconnect.identity","body":{"deviceId":"phone","tcpPort":1716}}"#.utf8)
		let packet = try XCTUnwrap(NetworkPacket.deserialize(from: data))
		let identity = try XCTUnwrap(DeviceManager.connectionIdentity(from: packet))

		XCTAssertFalse(DeviceManager.incomingIdentityTimedOut(identity))
		XCTAssertTrue(DeviceManager.incomingIdentityTimedOut(nil))
	}

	func testKnownDirectReconnectResolvesWithoutTLSIdentity() {
		XCTAssertEqual(DeviceManager.directConnectionDeviceId(expectedDeviceId: "phone", receivedDeviceId: nil), "phone")

		XCTAssertNil(DeviceManager.directConnectionDeviceId(expectedDeviceId: nil, receivedDeviceId: nil))
		XCTAssertNil(DeviceManager.directConnectionDeviceId(expectedDeviceId: "phone", receivedDeviceId: "other"))
	}

	func testIncomingTLSFailureNotifiesDisconnectAfterIdentity() async throws {
		var sockets = [Int32](repeating: -1, count: 2)
		XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)

		let connection = KDEConnection(fd: sockets[0], host: "local-test", port: 0, isIncoming: true)
		connection.tlsSetupRunner = { _ in false }

		let identityReceived = expectation(description: "identity received")
		let disconnected = expectation(description: "disconnected")

		connection.onIdentityReceived = { _ in
			identityReceived.fulfill()
		}

		connection.onDisconnected = {
			disconnected.fulfill()
		}

		connection.startIncoming()

		var identity = Data(#"{"id":1,"type":"kdeconnect.identity","body":{"deviceId":"phone","deviceName":"Phone","deviceType":"phone","tcpPort":1716}}"#.utf8)
		identity.append(0x0A)
		let written = identity.withUnsafeBytes { buffer in
			Darwin.write(sockets[1], buffer.baseAddress, buffer.count)
		}

		XCTAssertEqual(written, identity.count)
		defer { Darwin.close(sockets[1]) }

		await fulfillment(of: [identityReceived, disconnected], timeout: 2)
		XCTAssertFalse(connection.running)
		XCTAssertEqual(connection.fd, -1)
	}

	func testMDNSDiscoveryTargetsDefaultUDPPortRegardlessOfPeerAdvertisedTCPPort() {
		let peerTCPPort: UInt16 = 1717
		let targetUDPPort = DeviceManager.targetUDPPort(forDiscoveredPeerTCPPort: peerTCPPort)

		XCTAssertEqual(targetUDPPort, Config.defaultPort)
		XCTAssertEqual(targetUDPPort, 1716)
		XCTAssertNotEqual(targetUDPPort, peerTCPPort)
	}
}
