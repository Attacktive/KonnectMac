import UserNotifications
import XCTest
@testable import KonnectMac

@MainActor
final class PairingPersistenceTests: XCTestCase {
	// MARK: - Saved Reconnect Endpoints

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

	// MARK: - Device Identity Migration

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
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

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
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

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

	// MARK: - Notification App Preferences

	func testNotificationAppFiltersAreDeviceScopedAndPersist() throws {
		let suiteName = "KonnectMacTests.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		defer { defaults.removePersistentDomain(forName: suiteName) }

		let first = Config(defaults: defaults)
		first.recordNotificationApp(packageName: "com.example.chat", appName: "Chat", for: "phone-a")
		first.recordNotificationApp(packageName: "com.example.chat", appName: "Chat", for: "phone-b")
		first.setNotificationAppEnabled(false, packageName: "com.example.chat", for: "phone-a")

		XCTAssertFalse(first.isNotificationAppEnabled(packageName: "com.example.chat", for: "phone-a"))
		XCTAssertTrue(first.isNotificationAppEnabled(packageName: "com.example.chat", for: "phone-b"))
		XCTAssertTrue(first.isNotificationAppEnabled(packageName: "", for: "phone-a"))

		let relaunched = Config(defaults: defaults)
		XCTAssertEqual(relaunched.notificationApps(for: "phone-a"), [NotificationAppInfo(id: "com.example.chat", name: "Chat")])
		XCTAssertFalse(relaunched.isNotificationAppEnabled(packageName: "com.example.chat", for: "phone-a"))
		XCTAssertTrue(relaunched.isNotificationAppEnabled(packageName: "com.example.chat", for: "phone-b"))

		relaunched.setNotificationAppEnabled(true, packageName: "com.example.chat", for: "phone-a")
		XCTAssertTrue(Config(defaults: defaults).isNotificationAppEnabled(packageName: "com.example.chat", for: "phone-a"))
	}

	func testNotificationAppNamesAreUpdatedWithoutReplacingKnownNamesWithUnknown() throws {
		let suiteName = "KonnectMacTests.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		defer { defaults.removePersistentDomain(forName: suiteName) }

		let config = Config(defaults: defaults)
		config.recordNotificationApp(packageName: "com.example.chat", appName: "Unknown", for: "android")
		XCTAssertEqual(config.notificationApps(for: "android").first?.name, "com.example.chat")

		config.recordNotificationApp(packageName: "com.example.chat", appName: "Chat", for: "android")
		config.recordNotificationApp(packageName: "com.example.chat", appName: "", for: "android")
		XCTAssertEqual(config.notificationApps(for: "android").first?.name, "Chat")
	}

	func testUnpairClearsNotificationAppPreferencesForOnlyThatDevice() throws {
		let suiteName = "KonnectMacTests.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		defer { defaults.removePersistentDomain(forName: suiteName) }

		let config = Config(defaults: defaults)
		for deviceId in ["phone-a", "phone-b"] {
			config.recordNotificationApp(packageName: "com.example.chat", appName: "Chat", for: deviceId)
			config.setNotificationAppEnabled(false, packageName: "com.example.chat", for: deviceId)
		}

		config.removePairedDevice(id: "phone-a")

		let relaunched = Config(defaults: defaults)
		XCTAssertTrue(relaunched.notificationApps(for: "phone-a").isEmpty)
		XCTAssertTrue(relaunched.isNotificationAppEnabled(packageName: "com.example.chat", for: "phone-a"))
		XCTAssertEqual(relaunched.notificationApps(for: "phone-b").count, 1)
		XCTAssertFalse(relaunched.isNotificationAppEnabled(packageName: "com.example.chat", for: "phone-b"))
	}

	func testNotificationPackageIdentityUsesPackageNameNotOpaqueNotificationIds() {
		XCTAssertEqual(NotificationPlugin.packageName(from: "0|com.example.chat|123|null|1000"), "com.example.chat")
		XCTAssertNil(NotificationPlugin.packageName(from: "opaque-id"))
		XCTAssertNil(NotificationPlugin.packageName(from: "0||123"))
		XCTAssertNil(NotificationPlugin.packageName(from: "opaque|com.example.chat|123|null|1000"))
		XCTAssertNil(NotificationPlugin.packageName(from: "0|com.example.chat|oops|null|1000"))
		XCTAssertNil(NotificationPlugin.packageName(from: "0|com.example.chat|123|null|oops"))
		XCTAssertEqual(NotificationPlugin.packageName(from: "0|com.example.chat|123|null|1000|group"), "com.example.chat")
		XCTAssertNil(NotificationPlugin.packageName(from: "0|com.example.chat|123|null|1000|group|extra"))
	}

	func testMirroredNotificationIdentifiersAreScopedToPairedDevices() {
		let phoneA = NotificationPlugin.notificationIdentifier(deviceId: "phone-a", notificationId: "0|com.example.chat|123")
		let phoneB = NotificationPlugin.notificationIdentifier(deviceId: "phone-b", notificationId: "0|com.example.chat|123")

		XCTAssertNotEqual(phoneA, phoneB)
		XCTAssertEqual(phoneA, "notif-phone-a|0|com.example.chat|123")
	}

	func testForgettingAnApplicationResetsItsFilterAndPreservesOtherDevices() throws {
		let suiteName = "KonnectMacTests.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		defer { defaults.removePersistentDomain(forName: suiteName) }

		let config = Config(defaults: defaults)
		for deviceId in ["phone-a", "phone-b"] {
			config.recordNotificationApp(packageName: "com.example.chat", appName: "Chat", for: deviceId)
			config.setNotificationAppEnabled(false, packageName: "com.example.chat", for: deviceId)
		}

		config.recordNotificationApp(packageName: "com.example.mail", appName: "Mail", for: "phone-a")
		config.forgetNotificationApp(packageName: "com.example.chat", for: "phone-a")

		let relaunched = Config(defaults: defaults)
		XCTAssertEqual(relaunched.notificationApps(for: "phone-a"), [NotificationAppInfo(id: "com.example.mail", name: "Mail")])
		XCTAssertTrue(relaunched.isNotificationAppEnabled(packageName: "com.example.chat", for: "phone-a"))
		XCTAssertFalse(relaunched.isNotificationAppEnabled(packageName: "com.example.chat", for: "phone-b"))

		relaunched.recordNotificationApp(packageName: "com.example.chat", appName: "Chat", for: "phone-a")
		XCTAssertEqual(relaunched.notificationApps(for: "phone-a").count, 2)
		XCTAssertTrue(relaunched.isNotificationAppEnabled(packageName: "com.example.chat", for: "phone-a"))
	}

	func testMutedAppsDoNotExhaustTheRateLimitOrAffectOtherPhones() {
		var limiter = NotificationRateLimiter()
		let now = Date(timeIntervalSince1970: 1000)

		for _ in 0..<20 {
			XCTAssertFalse(limiter.allows(deviceId: "phone-a", eligible: false, now: now))
		}

		for _ in 0..<10 {
			XCTAssertTrue(limiter.allows(deviceId: "phone-a", eligible: true, now: now))
		}

		XCTAssertFalse(limiter.allows(deviceId: "phone-a", eligible: true, now: now))
		XCTAssertTrue(limiter.allows(deviceId: "phone-b", eligible: true, now: now))
		XCTAssertTrue(limiter.allows(deviceId: "phone-a", eligible: true, now: now.addingTimeInterval(1.1)))
	}

	func testNotificationRevisionsRejectCanceledAndSupersededIconUpdates() {
		var state = NotificationDeliveryState()
		let identifier = "notif-phone-a|0|com.example.chat|123|null|1000"
		let original = state.activate(id: identifier)
		XCTAssertTrue(state.isActive(id: identifier, revision: original))

		state.invalidate(id: identifier)
		XCTAssertFalse(state.isActive(id: identifier, revision: original))

		// Re-enabling the app must not revive the old icon download.
		let replacement = state.activate(id: identifier)
		XCTAssertFalse(state.isActive(id: identifier, revision: original))
		XCTAssertTrue(state.isActive(id: identifier, revision: replacement))

		// A cancel packet also invalidates delayed callbacks.
		state.invalidate(id: identifier)
		XCTAssertFalse(state.hasActive(id: identifier))
		XCTAssertFalse(state.isActive(id: identifier, revision: replacement))
	}

	func testDeviceEligibilityRechecksPairingAndFiltersAfterUnpair() throws {
		let suiteName = "KonnectMacTests.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		defer {
			defaults.removePersistentDomain(forName: suiteName)
			try? FileManager.default.removeItem(at: directory)
		}

		let config = Config(defaults: defaults, pairingDirectory: directory)
		let deviceId = "test-phone"
		let packageName = "com.example.chat"

		XCTAssertFalse(NotificationPlugin.isDeviceEligible(deviceId: deviceId, packageName: packageName, config: config))

		config.savePairedDevice(id: deviceId, certData: Data([0x30, 0x00]))
		XCTAssertTrue(NotificationPlugin.isDeviceEligible(deviceId: deviceId, packageName: packageName, config: config))

		config.setNotificationAppEnabled(false, packageName: packageName, for: deviceId)
		XCTAssertFalse(NotificationPlugin.isDeviceEligible(deviceId: deviceId, packageName: packageName, config: config))

		config.setNotificationAppEnabled(true, packageName: packageName, for: deviceId)
		XCTAssertTrue(NotificationPlugin.isDeviceEligible(deviceId: deviceId, packageName: packageName, config: config))

		config.removePairedDevice(id: deviceId)
		XCTAssertFalse(NotificationPlugin.isDeviceEligible(deviceId: deviceId, packageName: packageName, config: config))
	}

	// MARK: - Muted Call Notifications

	func testMutedVoIPCallsAreDiscoveredButDoNotStartCallAlerts() throws {
		let suiteName = "KonnectMacTests.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		defer { defaults.removePersistentDomain(forName: suiteName) }

		let config = Config(defaults: defaults)
		let device = Device(id: "voip-\(UUID().uuidString)", name: "Android")
		let telephony = RecordingTelephonyPlugin(device: device)
		device.plugins["telephony"] = telephony
		let notification = NotificationPlugin(device: device, config: config)
		let packet = NetworkPacket(type: "kdeconnect.notification", body: [
			"id": AnyCodable("0|com.whatsapp|42|null|1000"),
			"appName": AnyCodable("WhatsApp"),
			"title": AnyCodable("Alice"),
			"text": AnyCodable("Incoming voice call")
		])

		config.setNotificationAppEnabled(false, packageName: "com.whatsapp", for: device.id)
		notification.handle(packet: packet)

		XCTAssertTrue(telephony.startedCalls.isEmpty)
		XCTAssertEqual(config.notificationApps(for: device.id), [NotificationAppInfo(id: "com.whatsapp", name: "WhatsApp")])

		config.setNotificationAppEnabled(true, packageName: "com.whatsapp", for: device.id)
		notification.handle(packet: packet)
		XCTAssertEqual(telephony.startedCalls, ["Alice"])
	}

	func testMutedDialerStillHandlesCallCancellation() throws {
		let suiteName = "KonnectMacTests.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		defer { defaults.removePersistentDomain(forName: suiteName) }

		let config = Config(defaults: defaults)
		let device = Device(id: "dialer-\(UUID().uuidString)", name: "Android")
		let telephony = RecordingTelephonyPlugin(device: device)
		device.plugins["telephony"] = telephony
		let notification = NotificationPlugin(device: device, config: config)
		let statusId = "0|com.samsung.android.dialer|43|null|1000"

		config.setNotificationAppEnabled(false, packageName: "com.samsung.android.dialer", for: device.id)
		notification.handle(packet: NetworkPacket(type: "kdeconnect.notification", body: [
			"id": AnyCodable(statusId),
			"appName": AnyCodable("Phone"),
			"title": AnyCodable("Bob"),
			"text": AnyCodable("Incoming call")
		]))

		XCTAssertTrue(telephony.startedCalls.isEmpty)
		XCTAssertEqual(config.notificationApps(for: device.id).first?.id, "com.samsung.android.dialer")

		notification.handle(packet: NetworkPacket(type: "kdeconnect.notification", body: [
			"id": AnyCodable(statusId),
			"isCancel": AnyCodable(true)
		]))

		XCTAssertEqual(telephony.endedCalls, 1)
	}

	func testMutedSixFieldAndroidGroupNotificationsAreDiscoveredAndFiltered() throws {
		let suiteName = "KonnectMacTests.\(UUID().uuidString)"
		let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		defer { defaults.removePersistentDomain(forName: suiteName) }

		let config = Config(defaults: defaults)
		let device = Device(id: "group-\(UUID().uuidString)", name: "Android")
		let telephony = RecordingTelephonyPlugin(device: device)
		device.plugins["telephony"] = telephony
		let notification = NotificationPlugin(device: device, config: config)

		config.setNotificationAppEnabled(false, packageName: "com.whatsapp", for: device.id)
		notification.handle(packet: NetworkPacket(type: "kdeconnect.notification", body: [
			"id": AnyCodable("0|com.whatsapp|42|null|1000|group"),
			"appName": AnyCodable("WhatsApp"),
			"title": AnyCodable("Alice"),
			"text": AnyCodable("Incoming voice call")
		]))

		XCTAssertEqual(config.notificationApps(for: device.id), [NotificationAppInfo(id: "com.whatsapp", name: "WhatsApp")])
		XCTAssertTrue(telephony.startedCalls.isEmpty)
		XCTAssertFalse(config.isNotificationAppEnabled(packageName: "com.whatsapp", for: device.id))
	}

	// MARK: - Notification Delivery Ordering

	func testDeliveryQueueCoalescesUpdatesWhileAnotherAddIsInFlight() {
		let identifier = "notif-phone-a|0|com.example.chat|42|null|1000"
		var latest = 1
		var submitted: [String] = []
		var completions: [NotificationDeliveryQueue.Completion] = []
		var removed: [String] = []
		let queue = NotificationDeliveryQueue(
			submit: { request, completion in
				submitted.append(request.content.body)
				completions.append(completion)
			},
			remove: { removed.append($0) }
		)

		func makeRequest(_ body: String) -> UNNotificationRequest {
			let content = UNMutableNotificationContent()
			content.body = body

			return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
		}

		queue.enqueue(request: makeRequest("old"), isCurrent: { latest == 1 }, shouldRemove: { latest == 0 }, onResult: { _ in })
		latest = 2
		queue.enqueue(request: makeRequest("intermediate"), isCurrent: { latest == 2 }, shouldRemove: { latest == 0 }, onResult: { _ in })
		latest = 3
		queue.enqueue(request: makeRequest("newest"), isCurrent: { latest == 3 }, shouldRemove: { latest == 0 }, onResult: { _ in })

		// The next add cannot start until the previous add with the same identifier finishes.
		XCTAssertEqual(submitted, ["old"])
		completions[0](nil)
		XCTAssertEqual(submitted, ["old", "newest"])
		completions[1](nil)
		XCTAssertTrue(removed.isEmpty)
	}

	func testDeliveryQueueHandlesOutOfOrderCompletionsAcrossIdentifiers() {
		var submitted: [String] = []
		var completions: [NotificationDeliveryQueue.Completion] = []
		var lastVersion = 1
		let queue = NotificationDeliveryQueue(
			submit: { request, completion in
				submitted.append(request.content.body)
				completions.append(completion)
			},
			remove: { _ in XCTFail("A live notification should not be removed") }
		)

		func makeRequest(id: String, body: String) -> UNNotificationRequest {
			let content = UNMutableNotificationContent()
			content.body = body

			return UNNotificationRequest(identifier: id, content: content, trigger: nil)
		}

		queue.enqueue(request: makeRequest(id: "first", body: "old"), isCurrent: { lastVersion == 1 }, shouldRemove: { false }, onResult: { _ in })
		queue.enqueue(request: makeRequest(id: "other", body: "unrelated"), isCurrent: { true }, shouldRemove: { false }, onResult: { _ in })
		lastVersion = 2
		queue.enqueue(request: makeRequest(id: "first", body: "new"), isCurrent: { lastVersion == 2 }, shouldRemove: { false }, onResult: { _ in })

		// An unrelated identifier can complete earlier without reversing the first identifier's updates.
		completions[1](nil)
		XCTAssertEqual(submitted, ["old", "unrelated"])
		completions[0](nil)
		XCTAssertEqual(submitted, ["old", "unrelated", "new"])
		completions[2](nil)
	}

	func testDeliveryQueueRemovesCanceledNotificationAfterLateCompletion() {
		let identifier = "notif-phone-a|0|com.example.chat|42|null|1000"
		let content = UNMutableNotificationContent()
		var valid = true
		var completions: [NotificationDeliveryQueue.Completion] = []
		var removed: [String] = []
		let queue = NotificationDeliveryQueue(
			submit: { _, completion in completions.append(completion) },
			remove: { removed.append($0) }
		)

		queue.enqueue(
			request: UNNotificationRequest(identifier: identifier, content: content, trigger: nil),
			isCurrent: { valid },
			shouldRemove: { !valid },
			onResult: { _ in }
		)

		valid = false
		completions[0](nil)
		XCTAssertEqual(removed, [identifier])
	}

}

@MainActor
private final class RecordingTelephonyPlugin: TelephonyPlugin {
	private(set) var startedCalls: [String] = []
	private(set) var endedCalls = 0

	override func onCallStarted(caller: String) {
		startedCalls.append(caller)
	}

	override func onCallEnded() {
		endedCalls += 1
	}
}
