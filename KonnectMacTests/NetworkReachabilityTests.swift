import XCTest
@testable import KonnectMac

final class NetworkReachabilityTests: XCTestCase {
    func testAdjacentThirdOctetIsInsideSlash23() throws {
        let interface = try XCTUnwrap(
            IPv4InterfaceAddress(
                address: "172.16.0.25",
                netmask: "255.255.254.0"
            )
        )

        XCTAssertTrue(interface.contains("172.16.1.80"))
        XCTAssertFalse(interface.contains("172.16.2.1"))
    }

    func testLocalPathRequiresExactActiveAddress() throws {
        let oldWiFi = try XCTUnwrap(
            IPv4InterfaceAddress(
                address: "192.168.1.20",
                netmask: "255.255.255.0"
            )
        )
        let newWiFi = try XCTUnwrap(
            IPv4InterfaceAddress(
                address: "192.168.2.20",
                netmask: "255.255.255.0"
            )
        )

        XCTAssertFalse(SocketHelpers.isIPv4AddressActive(oldWiFi.address, on: [newWiFi]))
        XCTAssertTrue(SocketHelpers.isIPv4AddressActive(newWiFi.address, on: [newWiFi]))
    }

    func testRoutedConnectionStaysValidWhileItsLocalAddressIsActive() throws {
        let tailscale = try XCTUnwrap(
            IPv4InterfaceAddress(
                address: "100.64.0.10",
                netmask: "255.255.255.255"
            )
        )
        let wifi = try XCTUnwrap(
            IPv4InterfaceAddress(
                address: "192.168.2.20",
                netmask: "255.255.255.0"
            )
        )

        XCTAssertTrue(SocketHelpers.isIPv4AddressActive(tailscale.address, on: [wifi, tailscale]))
    }
}
