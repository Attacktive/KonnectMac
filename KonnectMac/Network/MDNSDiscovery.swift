import Foundation

class MDNSDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
	private let browser = NetServiceBrowser()
	private var service: NetService?
	private var resolvingServices = Set<NetService>()
	private let lock = NSLock()
	var onDeviceDiscovered: ((_ host: String, _ port: UInt16, _ deviceId: String) -> Void)?

	deinit {
		stop()
	}

	func start(deviceId: String, deviceName: String, deviceType: String, tcpPort: UInt16) {
		stop()

		browser.delegate = self
		browser.searchForServices(ofType: "_kdeconnect._udp.", inDomain: "local.")
		KLog.log("[mDNS] Browsing for _kdeconnect._udp.local.")

		let advertisingService = NetService(domain: "local.", type: "_kdeconnect._udp.", name: deviceId, port: Int32(tcpPort))

		let txtDict = Self.txtRecordDictionary(deviceId: deviceId, deviceName: deviceName, deviceType: deviceType)
		let dataDict = txtDict.compactMapValues { $0.data(using: .utf8) }

		advertisingService.setTXTRecord(NetService.data(fromTXTRecord: dataDict))
		advertisingService.delegate = self
		advertisingService.publish()
		self.service = advertisingService
		KLog.log("[mDNS] Advertising _kdeconnect._udp service as \(deviceId) on port \(tcpPort)")
	}

	func stop() {
		browser.stop()
		browser.delegate = nil

		if let currentService = service {
			currentService.stop()
			currentService.delegate = nil
			self.service = nil
		}

		lock.lock()
		for pending in resolvingServices {
			pending.stop()
			pending.delegate = nil
		}

		resolvingServices.removeAll()
		lock.unlock()
	}

	// MARK: - NetServiceBrowserDelegate

	func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
		KLog.log("[mDNS] Found service: \(service.name)")
		lock.lock()
		resolvingServices.insert(service)
		lock.unlock()

		service.delegate = self
		service.resolve(withTimeout: 5.0)
	}

	func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
		KLog.log("[mDNS] Removed service: \(service.name)")
		lock.lock()
		resolvingServices.remove(service)
		lock.unlock()
	}

	func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
		KLog.log("[mDNS] Browser search failed: \(errorDict)", level: .error)
	}

	// MARK: - NetServiceDelegate

	func netServiceDidResolveAddress(_ sender: NetService) {
		lock.lock()
		resolvingServices.remove(sender)
		lock.unlock()

		sender.delegate = nil

		let txt = Self.parseTXTRecord(sender.txtRecordData())
		let deviceId = txt["id"] ?? sender.name
		let port = sender.port > 0 && sender.port <= 65535 ? UInt16(sender.port) : Config.defaultPort
		guard let addresses = sender.addresses else {
			return
		}

		for addrData in addresses {
			guard let host = Self.ipv4Address(from: addrData) else {
				continue
			}

			if host != "127.0.0.1" && host != "0.0.0.0" {
				KLog.log("[mDNS] Resolved \(deviceId) at \(host):\(port)")
				DispatchQueue.main.async { [weak self] in
					self?.onDeviceDiscovered?(host, port, deviceId)
				}

				break
			}
		}
	}

	func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
		KLog.log("[mDNS] Failed to resolve service \(sender.name): \(errorDict)", level: .warn)
		lock.lock()
		resolvingServices.remove(sender)
		lock.unlock()

		sender.delegate = nil
	}

	// MARK: - Helper Methods

	static func txtRecordDictionary(deviceId: String, deviceName: String, deviceType: String) -> [String: String] {
		[
			"id": deviceId,
			"name": deviceName,
			"type": deviceType,
			"protocol": String(Config.protocolVersion)
		]
	}

	static func parseTXTRecord(_ data: Data?) -> [String: String] {
		guard let data else {
			return [:]
		}

		let dict = NetService.dictionary(fromTXTRecord: data)
		var result = [String: String]()
		for (key, value) in dict {
			if let stringValue = String(data: value, encoding: .utf8) {
				result[key] = stringValue
			}
		}

		return result
	}

	static func ipv4Address(from data: Data) -> String? {
		data.withUnsafeBytes { ptr in
			guard let base = ptr.baseAddress else {
				return nil
			}

			let family = base.assumingMemoryBound(to: sockaddr.self).pointee.sa_family
			guard family == UInt8(AF_INET) else {
				return nil
			}

			let sin = base.assumingMemoryBound(to: sockaddr_in.self).pointee
			var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
			var addr = sin.sin_addr
			guard inet_ntop(AF_INET, &addr, &host, socklen_t(host.count)) != nil else {
				return nil
			}

			return String(cString: host)
		}
	}
}
