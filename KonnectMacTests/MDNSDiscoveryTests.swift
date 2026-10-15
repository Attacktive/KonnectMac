import Darwin
import XCTest
@testable import KonnectMac

final class MDNSDiscoveryTests: XCTestCase {
	func testParseTXTRecordExtractsRequiredMetadata() {
		let txtDict: [String: Data] = [
			"id": Data("device-123".utf8),
			"name": Data("Phone".utf8),
			"type": Data("phone".utf8),
			"protocol": Data("8".utf8)
		]
		let data = NetService.data(fromTXTRecord: txtDict)
		let parsed = MDNSDiscovery.parseTXTRecord(data)

		XCTAssertEqual(parsed["id"], "device-123")
		XCTAssertEqual(parsed["name"], "Phone")
		XCTAssertEqual(parsed["type"], "phone")
		XCTAssertEqual(parsed["protocol"], "8")
	}

	func testParseTXTRecordHandlesNilData() {
		let parsed = MDNSDiscovery.parseTXTRecord(nil)
		XCTAssertTrue(parsed.isEmpty)
	}

	func testIPv4AddressExtractionFromSockaddr() {
		var addr = sockaddr_in()
		addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
		addr.sin_family = sa_family_t(AF_INET)
		addr.sin_port = UInt16(1716).bigEndian
		inet_pton(AF_INET, "172.16.1.92", &addr.sin_addr)

		let data = withUnsafeBytes(of: &addr) { Data($0) }
		let extractedIP = MDNSDiscovery.ipv4Address(from: data)
		XCTAssertEqual(extractedIP, "172.16.1.92")
	}

	func testIPv4AddressExtractionRejectsIPv6() {
		var addr6 = sockaddr_in6()
		addr6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
		addr6.sin6_family = sa_family_t(AF_INET6)
		addr6.sin6_port = UInt16(1716).bigEndian

		let data = withUnsafeBytes(of: &addr6) { Data($0) }
		XCTAssertNil(MDNSDiscovery.ipv4Address(from: data))
	}
}
