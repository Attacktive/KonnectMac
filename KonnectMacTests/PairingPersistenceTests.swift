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

	func testDeviceIdPersistsAcrossConfigurationInstances() throws {
		let suiteName = "KonnectMacTests.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		defer { defaults.removePersistentDomain(forName: suiteName) }

		let first = Config(defaults: defaults)
		XCTAssertFalse(first.deviceId.isEmpty)
		XCTAssertFalse(first.deviceId.contains("-"))
		XCTAssertEqual(first.deviceId, first.deviceId.lowercased())
		XCTAssertEqual(defaults.string(forKey: "deviceId"), first.deviceId)

		let second = Config(defaults: defaults)
		XCTAssertEqual(second.deviceId, first.deviceId)
	}

	func testLegacyHyphenatedDeviceIdIsMigratedToCompliantId() throws {
		let suiteName = "KonnectMacTests.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
			UUID().uuidString,
			isDirectory: true
		)
		defer {
			defaults.removePersistentDomain(forName: suiteName)
			try? FileManager.default.removeItem(at: directory)
		}

		let legacyId = "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"
		defaults.set(legacyId, forKey: "deviceId")

		let config = Config(defaults: defaults, pairingDirectory: directory)
		config.saveDeviceName("Android", for: "android")
		config.saveDeviceIP("172.16.1.42", for: "android")
		config.saveDevicePort(1716, for: "android")

		// Constructing a Config must not destroy anything; only the explicit launch-time migration may.
		XCTAssertEqual(defaults.string(forKey: "deviceId"), legacyId)
		XCTAssertEqual(config.savedDeviceName(for: "android"), "Android")

		var identityResets = 0
		try config.migrateLegacyDeviceIdIfNeeded { identityResets += 1 }
		try config.migrateLegacyDeviceIdIfNeeded { identityResets += 1 }

		XCTAssertEqual(identityResets, 1)
		XCTAssertNotEqual(config.deviceId, legacyId)
		XCTAssertFalse(config.deviceId.contains("-"))
		XCTAssertEqual(config.deviceId, config.deviceId.lowercased())
		XCTAssertEqual(defaults.string(forKey: "deviceId"), config.deviceId)
		XCTAssertNil(config.savedDeviceName(for: "android"))
		XCTAssertNil(config.savedDeviceIP(for: "android"))
		XCTAssertNil(config.savedDevicePort(for: "android"))

		let relaunched = Config(defaults: defaults, pairingDirectory: directory)
		try relaunched.migrateLegacyDeviceIdIfNeeded { identityResets += 1 }
		XCTAssertEqual(relaunched.deviceId, config.deviceId)
		XCTAssertEqual(identityResets, 1)
	}

	func testCompliantPersistedDeviceIdIsPreservedWithoutMigration() throws {
		let suiteName = "KonnectMacTests.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
			UUID().uuidString,
			isDirectory: true
		)
		defer {
			defaults.removePersistentDomain(forName: suiteName)
			try? FileManager.default.removeItem(at: directory)
		}

		let compliantId = "740bd4b9b4184ee497d6caf1da8151be"
		defaults.set(compliantId, forKey: "deviceId")

		let config = Config(defaults: defaults, pairingDirectory: directory)
		config.saveDeviceName("Android", for: "android")
		XCTAssertEqual(config.deviceId, compliantId)
		XCTAssertEqual(defaults.string(forKey: "deviceId"), compliantId)
		XCTAssertEqual(config.savedDeviceName(for: "android"), "Android")
	}

	func testFailedPairingCleanupLeavesLegacyIdentityRetryable() throws {
		let suiteName = "KonnectMacTests.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		let blocker = root.appendingPathComponent("blocked-parent")
		let pairingDirectory = blocker.appendingPathComponent("PairedDevices", isDirectory: true)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		try Data("not a directory".utf8).write(to: blocker)
		defer {
			defaults.removePersistentDomain(forName: suiteName)
			try? FileManager.default.removeItem(at: root)
		}

		let legacyId = "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"
		defaults.set(legacyId, forKey: "deviceId")
		let config = Config(defaults: defaults, pairingDirectory: pairingDirectory)
		config.saveDeviceName("Android", for: "android")

		XCTAssertThrowsError(try config.migrateLegacyDeviceIdIfNeeded(resetIdentity: {}))
		XCTAssertEqual(defaults.string(forKey: "deviceId"), legacyId)
		XCTAssertEqual(config.savedDeviceName(for: "android"), "Android")

		try FileManager.default.removeItem(at: blocker)
		try FileManager.default.createDirectory(at: pairingDirectory, withIntermediateDirectories: true)
		try Data("paired certificate".utf8).write(to: pairingDirectory.appendingPathComponent("android.der"))
		try config.migrateLegacyDeviceIdIfNeeded(resetIdentity: {})

		XCTAssertEqual(defaults.string(forKey: "deviceId"), config.deviceId)
		XCTAssertFalse(FileManager.default.fileExists(atPath: pairingDirectory.path))
		XCTAssertNil(config.savedDeviceName(for: "android"))
	}

	func testFailedIdentityResetPreservesPairingsUntilRetrySucceeds() throws {
		let suiteName = "KonnectMacTests.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let certificateURL = directory.appendingPathComponent("android.der")
		let certificate = Data("paired certificate".utf8)
		try certificate.write(to: certificateURL)
		defer {
			defaults.removePersistentDomain(forName: suiteName)
			try? FileManager.default.removeItem(at: directory)
		}

		let legacyId = "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"
		defaults.set(legacyId, forKey: "deviceId")
		let config = Config(defaults: defaults, pairingDirectory: directory)
		config.saveDeviceName("Android", for: "android")

		let failedReset: () throws -> Void = {
			throw CocoaError(.fileWriteNoPermission)
		}

		XCTAssertThrowsError(try config.migrateLegacyDeviceIdIfNeeded(resetIdentity: failedReset))

		XCTAssertEqual(defaults.string(forKey: "deviceId"), legacyId)
		XCTAssertEqual(try Data(contentsOf: certificateURL), certificate)
		XCTAssertEqual(config.savedDeviceName(for: "android"), "Android")

		let relaunched = Config(defaults: defaults, pairingDirectory: directory)
		try relaunched.migrateLegacyDeviceIdIfNeeded(resetIdentity: {})

		XCTAssertEqual(defaults.string(forKey: "deviceId"), relaunched.deviceId)
		XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
		XCTAssertNil(relaunched.savedDeviceName(for: "android"))
	}
}
