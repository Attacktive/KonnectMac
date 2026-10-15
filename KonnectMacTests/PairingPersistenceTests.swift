import XCTest
@testable import KonnectMac

@MainActor
final class PairingPersistenceTests: XCTestCase {
    func testReconnectEndpointSurvivesFreshConfigurationInstance() throws {
        let suiteName = "KonnectMacTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }

        let first = Config(defaults: defaults, pairingDirectory: directory)
        first.saveDeviceIP("172.16.1.42", for: "android")
        first.saveDevicePort(1716, for: "android")

        let second = Config(defaults: defaults, pairingDirectory: directory)

        XCTAssertEqual(second.savedDeviceIP(for: "android"), "172.16.1.42")
        XCTAssertEqual(second.savedDevicePort(for: "android"), 1716)
    }

	func testObsoleteLocalListeningPortIsRejectedOnLaunch() throws {
		let suiteName = "KonnectMacTests.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		defer { defaults.removePersistentDomain(forName: suiteName) }

		defaults.set(1714, forKey: "tcpPort")
		let config = Config(defaults: defaults)
		XCTAssertEqual(config.tcpPort, 1716)
	}

	func testObsoleteSavedPeerPortIsRejectedOnRelaunch() throws {
		let suiteName = "KonnectMacTests.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		defer { defaults.removePersistentDomain(forName: suiteName) }

		defaults.set(["desktop": 1714], forKey: "pairedDevicePorts")
		let config = Config(defaults: defaults)
		XCTAssertNil(config.savedDevicePort(for: "desktop"))
	}

    func testUnpairClearsSavedReconnectEndpoint() throws {
        let suiteName = "KonnectMacTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }

        let config = Config(defaults: defaults, pairingDirectory: directory)
        config.saveDeviceName("Android", for: "android")
        config.saveDeviceIP("172.16.1.42", for: "android")
        config.saveDevicePort(1716, for: "android")
        config.removePairedDevice(id: "android")

        XCTAssertNil(config.savedDeviceName(for: "android"))
        XCTAssertNil(config.savedDeviceIP(for: "android"))
        XCTAssertNil(config.savedDevicePort(for: "android"))
    }
}
