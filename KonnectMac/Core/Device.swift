import Foundation

enum ConnectionState {
	case disconnected, discovered, paired
}

@MainActor
class Device: ObservableObject, Identifiable {
	let id: String
	@Published var name: String
	@Published var type: String
	@Published var connectionState: ConnectionState = .disconnected
	@Published var batteryLevel: Int = -1
	@Published var batteryCharging: Bool = false
	var tcpPort: UInt16 = 0
	var plugins: [String: any PluginProtocol] = [:]
	var kdeConn: KDEConnection? {
		didSet {
			if let oldValue, let kdeConn, oldValue === kdeConn {
				return
			}

			if oldValue == nil && kdeConn == nil {
				return
			}

			peerIncomingCapabilities.removeAll()
			capabilityObserverConnectionId = nil
			guard let connection = kdeConn else {
				return
			}

			capabilityObserverConnectionId = ObjectIdentifier(connection)
			let previousHandler = connection.onIdentityReceived
			connection.onIdentityReceived = { [weak self, weak connection] packet in
				previousHandler?(packet)
				Task { @MainActor in
					guard let self, let connection else {
						return
					}

					guard self.kdeConn === connection else {
						return
					}

					guard packet.body["deviceId"]?.value as? String == self.id else {
						return
					}

					self.peerIncomingCapabilities = Self.incomingCapabilities(from: packet)
				}
			}
		}
	}

	var peerIncomingCapabilities = Set<String>()
	var capabilityObserverConnectionId: ObjectIdentifier?

	init(id: String, name: String, type: String = "phone") {
		self.id = id
		self.name = name
		self.type = type
		if Config.shared.isPaired(deviceId: id) {
			self.connectionState = .paired
		}
	}

	func send(_ packet: NetworkPacket) {
		guard let conn = kdeConn else {
			KLog.log("[Device] Send failed for \(name): no connection (\(packet.type))")

			return
		}

		conn.send(packet)
	}

	func handlePacket(_ packet: NetworkPacket) {
		for (_, plugin) in plugins {
			if plugin.canHandle(type: packet.type) {
				plugin.handle(packet: packet)
			}
		}
	}

	private static func incomingCapabilities(from packet: NetworkPacket) -> Set<String> {
		guard packet.type == "kdeconnect.identity" else {
			return []
		}

		if let capabilities = packet.body["incomingCapabilities"]?.value as? [String] {
			return Set(capabilities)
		}

		let values = packet.body["incomingCapabilities"]?.value as? [Any] ?? []

		return Set(values.compactMap { $0 as? String })
	}
}
