import Foundation
import Network
import AppKit

@MainActor
class DeviceManager: ObservableObject {
    static let shared = DeviceManager()

    @Published var devices: [String: Device] = [:]
    var connections: [String: KDEConnection] = [:]
    private var connectingDeviceIds = Set<String>()
    private var tlsEstablishedDeviceIds = Set<String>()
    @Published var pendingPairRequests = Set<String>() // devices WE sent pair request to
    private var pendingIncomingPairDevices = Set<String>() // devices showing incoming pair dialog (prevents duplicate notifications)
    private var lastPairRequestTime: [String: Date] = [:] // deviceId -> when we last sent pair request

    struct ConnectionIdentity: Equatable {
        let deviceId: String
        let deviceName: String
        let deviceType: String
        let tcpPort: UInt16
    }

    private var pendingConnectionIdentities: [ObjectIdentifier: ConnectionIdentity] = [:]
    private var acceptedConnections = Set<ObjectIdentifier>()

    private let udpDiscovery = UDPDiscovery()
    private let tcpServer = LanServer()
    private var broadcastTimer: Timer?
    private var networkMonitor: NWPathMonitor?
    private var sleepWakeObserver: NSObjectProtocol?
    private var networkDebounceTask: Task<Void, Never>?

    private init() {}

    func start() {
        KLog.log("[DeviceManager] Starting...")
        // Load paired devices
        loadPairedDevices()

        // Start TCP server first (claims the port)
        tcpServer.onIncomingConnection = { [weak self] fd, host in
            self?.handleIncomingSocket(fd: fd, host: host)
        }
        tcpServer.start(preferredPort: Config.shared.tcpPort)
        Config.shared.tcpPort = tcpServer.actualPort

        // Start UDP discovery
        udpDiscovery.onIdentityReceived = { [weak self] packet, host in
            self?.handleDiscoveredIdentity(packet: packet, host: host)
        }
        udpDiscovery.startListening(port: Config.shared.tcpPort)

        // Broadcast identity periodically
        broadcastIdentity()
        reconnectPairedDevices()
        broadcastTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.broadcastIdentity()
            }
        }

        // Monitor network changes (WiFi switch, VPN connect, etc.)
        networkMonitor = NWPathMonitor()
        networkMonitor?.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self = self else { return }
                let hasWiFi = path.availableInterfaces.contains { $0.type == .wifi }
                KLog.log("[Network] Path changed — status=\(path.status), wifi=\(hasWiFi)")

                // Debounce: cancel any pending network reaction, wait 2s for stability.
                // macOS fires rapid bursts of path changes during WiFi switches —
                // without debouncing, each triggers reconnection attempts that cascade-fail.
                self.networkDebounceTask?.cancel()
                self.networkDebounceTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                    guard !Task.isCancelled else { return }

                    self.disconnectStalePathConnections()

                    if path.status == .satisfied {
                        self.broadcastIdentity()
                        self.reconnectPairedDevices()
                    }
                }
            }
        }
        networkMonitor?.start(queue: DispatchQueue(label: "network-monitor"))

        // Observe sleep/wake to force immediate reconnection on wake
        sleepWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                KLog.log("[DeviceManager] System woke from sleep — pruning stale connections and reconnecting")
                self.disconnectStalePathConnections()
                self.broadcastIdentity()
                self.reconnectPairedDevices()
            }
        }

        KLog.log("[DeviceManager] Started on port \(Config.shared.tcpPort)")
    }

    func broadcastIdentity() {
        let identity = NetworkPacket.identityPacket()
        udpDiscovery.broadcast(packet: identity)

        for device in devices.values where Config.shared.isPaired(deviceId: device.id) {
            guard let host = Config.shared.savedDeviceIP(for: device.id), !host.isEmpty else { continue }
            let port = Config.shared.savedDevicePort(for: device.id) ?? Config.defaultPort
            udpDiscovery.sendTo(packet: identity, host: host, port: port)
        }

        // Direct connect to Tailscale/VPN IP — full KDEConnection, not fire-and-close
        let tailscaleIP = Config.shared.tailscaleIP
        if !tailscaleIP.isEmpty {
            connectDirectToHost(host: tailscaleIP, port: Config.defaultPort)
        }
    }

    /// Actively reconnect to paired devices using their last known IP.
    /// Called on wake and after network changes — don't wait for the phone to hear our broadcast.
    private func reconnectPairedDevices() {
        for device in devices.values where Config.shared.isPaired(deviceId: device.id) {
            // Skip if already connected
            if let conn = connections[device.id], conn.running {
                continue
            }
            guard let ip = Config.shared.savedDeviceIP(for: device.id), !ip.isEmpty else { continue }
            let port = Config.shared.savedDevicePort(for: device.id) ?? Config.defaultPort
            KLog.log("[DeviceManager] Reconnecting to \(device.name) at \(ip):\(port)")
            connectDirectToHost(host: ip, port: port, expectedDeviceId: device.id)
        }
    }

    static func advertisedTCPPort(from packet: NetworkPacket) -> UInt16? {
        guard let value = packet.body["tcpPort"] else { return Config.minPort }
        guard let port = value.asPort(), port >= Config.minPort, port <= Config.maxPort else { return nil }
        return port
    }

    static func incomingConnectionMatchesExisting(existingHost: String, incomingHost: String) -> Bool {
        existingHost == incomingHost
    }

    static func connectionIdentity(from packet: NetworkPacket) -> ConnectionIdentity? {
        guard packet.type == "kdeconnect.identity" else { return nil }
        guard let deviceId = packet.body["deviceId"]?.value as? String else { return nil }
        let deviceName = packet.body["deviceName"]?.value as? String ?? "Unknown"
        let deviceType = packet.body["deviceType"]?.value as? String ?? "phone"
        guard let tcpPort = advertisedTCPPort(from: packet) else { return nil }
        return ConnectionIdentity(deviceId: deviceId, deviceName: deviceName, deviceType: deviceType, tcpPort: tcpPort)
    }

    static func incomingIdentityTimedOut(_ identity: ConnectionIdentity?) -> Bool {
        identity == nil
    }

    static func directConnectionDeviceId(expectedDeviceId: String?, receivedDeviceId: String?) -> String? {
        if let expectedDeviceId {
            guard receivedDeviceId == nil || receivedDeviceId == expectedDeviceId else { return nil }
            return expectedDeviceId
        }
        return receivedDeviceId
    }

    // MARK: - UDP Discovery Handler

    private func handleDiscoveredIdentity(packet: NetworkPacket, host: String) {
        guard packet.type == "kdeconnect.identity" else { return }
        guard let deviceId = packet.body["deviceId"]?.value as? String else { return }
        guard deviceId != Config.shared.deviceId else { return }

        let deviceName = packet.body["deviceName"]?.value as? String ?? "Unknown"
        let deviceType = packet.body["deviceType"]?.value as? String ?? "phone"
        guard let tcpPort = Self.advertisedTCPPort(from: packet) else {
            KLog.log("[Discovery] Invalid tcpPort from \(deviceName), ignoring")
            return
        }

        // Check if already connected or being connected.
        // Don't require conn.running — an incoming connection may not be running yet
        // (async queue not started) but still blocks a redundant outgoing attempt.
        if tlsEstablishedDeviceIds.contains(deviceId) { return }
        if connectingDeviceIds.contains(deviceId) { return }
        for (_, conn) in connections {
            if conn.remoteDeviceId == deviceId || conn.host == host {
                return
            }
        }

        let device: Device
        if let existing = devices[deviceId] {
            device = existing
        } else {
            device = getOrCreateDevice(id: deviceId, name: deviceName, type: deviceType)
        }

        if !Config.shared.isPaired(deviceId: deviceId) {
            device.name = deviceName
            device.type = deviceType
            device.tcpPort = tcpPort
            if device.connectionState == .disconnected {
                updateDeviceState(device, to: .discovered)
            }
            Config.shared.saveDeviceName(deviceName, for: deviceId)
            Config.shared.saveDeviceType(deviceType, for: deviceId)
        }
        KLog.log("[Discovery] Found: \(deviceName) at \(host):\(tcpPort)")
        connectOutgoing(device: device, host: host, port: tcpPort)
    }

    // MARK: - Incoming TCP Connection

    private let maxConnections = 50

    private func handleIncomingSocket(fd: Int32, host: String) {
        // Reject if too many concurrent connections (prevents resource exhaustion)
        if connections.count >= maxConnections {
            KLog.log("[TCP] Connection limit reached (\(maxConnections)), rejecting from \(host)")
            Darwin.close(fd)
            return
        }

        for (key, existing) in connections {
            guard Self.incomingConnectionMatchesExisting(existingHost: existing.host, incomingHost: host) else { continue }
            let deviceId = existing.remoteDeviceId
            let hasPendingPair = deviceId.map { pendingPairRequests.contains($0) } ?? false
            let isPaired = deviceId.flatMap { devices[$0] }?.connectionState == .paired

            if hasPendingPair {
                KLog.log("[TCP] Accepting during pending pair from \(host)")
                existing.disconnect()
                connections.removeValue(forKey: key)
                if let deviceId = deviceId {
                    tlsEstablishedDeviceIds.remove(deviceId)
                }
                break
            }

            if existing.running {
                if isPaired {
                    Darwin.close(fd)
                    return
                }
                // Unpaired + running → accept (phone reconnects during discovery)
                KLog.log("[TCP] Replacing unpaired connection from \(host)")
                existing.disconnect()
                connections.removeValue(forKey: key)
                if let deviceId = deviceId {
                    tlsEstablishedDeviceIds.remove(deviceId)
                }
                break
            }

            // Connection not running → dead, replace it
            KLog.log("[TCP] Replacing dead connection from \(host)")
            connections.removeValue(forKey: key)
            if let deviceId = deviceId {
                tlsEstablishedDeviceIds.remove(deviceId)
            }
            break
        }

        let conn = KDEConnection(fd: fd, host: host, port: 0, isIncoming: true)
        conn.cachedIdentityData = NetworkPacket.identityPacket().serialize()
        let tempKey = "incoming_\(fd)"
        connections[tempKey] = conn

        conn.onIdentityReceived = { [weak self, weak conn] packet in
            guard let self, let conn else { return }
            guard let identity = Self.connectionIdentity(from: packet) else {
                KLog.log("[TCP] Invalid identity from \(host), closing incoming connection")
                conn.disconnect()
                return
            }

            conn.remoteDeviceId = identity.deviceId
            self.pendingConnectionIdentities[ObjectIdentifier(conn)] = identity
        }

        conn.onTLSReady = { [weak self, weak conn] in
            guard let self, let conn else { return }
            guard let deviceId = conn.remoteDeviceId else {
                KLog.log("[Link] TLS ready but no remote ID yet")
                return
            }
            self.connections.removeValue(forKey: tempKey)
            self.finalizeConnection(deviceId: deviceId, conn: conn)
        }

        conn.onPacketReceived = { [weak self, weak conn] packet in
            guard let conn = conn else { return }
            self?.handlePacket(packet, fromConnection: conn)
        }

        conn.onDisconnected = { [weak self, weak conn] in
            guard let self, let conn else { return }
            self.handleDisconnection(conn: conn)
        }

        conn.startIncoming()

        // Timeout: if identity hasn't arrived in 10 seconds, clean up orphan connection
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak conn] in
            guard let self, let conn else { return }
            let identity = self.pendingConnectionIdentities[ObjectIdentifier(conn)]
            if self.connections[tempKey] === conn && Self.incomingIdentityTimedOut(identity) {
                KLog.log("[TCP] Incoming connection from \(host) timed out waiting for identity, cleaning up")
                conn.disconnect()
                self.connections.removeValue(forKey: tempKey)
            }
        }
    }

    // MARK: - Outgoing Connection

    private func connectOutgoing(device: Device, host: String, port: UInt16) {
        guard !connectingDeviceIds.contains(device.id) else { return }
        guard device.connectionState != .paired || connections[device.id] == nil else { return }
        connectingDeviceIds.insert(device.id)

        let conn = KDEConnection(host: host, port: port, isIncoming: false)
        conn.remoteDeviceId = device.id
        conn.cachedIdentityData = NetworkPacket.identityPacket().serialize()
        connections[device.id] = conn

        conn.onTLSReady = { [weak self, weak conn] in
            guard let self, let conn else { return }
            self.connectingDeviceIds.remove(device.id)
            self.finalizeConnection(deviceId: device.id, conn: conn)
        }

        conn.onIdentityReceived = { [weak self, weak conn] packet in
            guard let self, let conn, self.devices[device.id] != nil else { return }
            guard let identity = Self.connectionIdentity(from: packet) else {
                conn.disconnect()
                return
            }
            guard identity.deviceId == device.id else {
                KLog.log("[Security] Identity changed from \(device.id) to \(identity.deviceId), rejecting")
                conn.disconnect()
                return
            }

            conn.remoteDeviceId = identity.deviceId
            self.pendingConnectionIdentities[ObjectIdentifier(conn)] = identity
            if self.acceptedConnections.contains(ObjectIdentifier(conn)) {
                self.applyPendingIdentity(for: device, connection: conn)
                if Config.shared.isPaired(deviceId: device.id) {
                    self.persistReconnectEndpoint(for: device, connection: conn)
                }
            }
        }

        conn.onPacketReceived = { [weak self, weak conn] packet in
            guard let self, let conn, self.devices[device.id] != nil else { return }
            self.handlePacket(packet, fromConnection: conn)
        }

        conn.onDisconnected = { [weak self, weak conn] in
            guard let self, let conn else { return }
            self.connectingDeviceIds.remove(device.id)
            self.handleDisconnection(conn: conn)
        }

        conn.connectAndRun()
    }

    // MARK: - Direct Host Connection (Tailscale/VPN)

    private func sendDirectedIdentity(to host: String) {
        let identity = NetworkPacket.identityPacket()
        KLog.log("[DirectConnect] Sending directed discovery to \(host) on ports \(Config.minPort)-\(Config.maxPort)")
        for port in Config.minPort...Config.maxPort {
            udpDiscovery.sendTo(packet: identity, host: host, port: port)
        }
    }

    /// Connect directly to a host by IP — creates a full KDEConnection with TLS handshake.
    /// Used for Tailscale/VPN where UDP broadcast doesn't work.
    /// Unlike the old fire-and-close approach, this keeps the socket open for the full protocol.
    private func connectDirectToHost(host: String, port: UInt16, expectedDeviceId: String? = nil) {
        for (_, conn) in connections {
            if conn.host == host && conn.running { return }
        }

        let tempKey = "direct_\(host)"
        // Already connecting? Skip.
        if connectingDeviceIds.contains(tempKey) { return }
        connectingDeviceIds.insert(tempKey)
        if expectedDeviceId == nil {
            sendDirectedIdentity(to: host)
        }
        KLog.log("[DirectConnect] Initiating full connection to \(host):\(port)")

        let conn = KDEConnection(host: host, port: port, isIncoming: false)
        conn.remoteDeviceId = expectedDeviceId
        conn.cachedIdentityData = NetworkPacket.identityPacket().serialize()
        connections[tempKey] = conn

        conn.onIdentityReceived = { [weak self, weak conn] packet in
            guard let self, let conn else { return }
            guard let identity = Self.connectionIdentity(from: packet) else {
                KLog.log("[DirectConnect] Invalid identity from \(host)")
                conn.disconnect()
                return
            }

            guard let deviceId = Self.directConnectionDeviceId(
                expectedDeviceId: expectedDeviceId,
                receivedDeviceId: identity.deviceId
            ) else {
                KLog.log("[Security] Direct identity changed from \(expectedDeviceId ?? "unknown") to \(identity.deviceId), rejecting")
                conn.disconnect()
                return
            }

            conn.remoteDeviceId = deviceId
            self.pendingConnectionIdentities[ObjectIdentifier(conn)] = identity

            if conn.tlsEstablished {
                self.connectingDeviceIds.remove(tempKey)
                self.connections.removeValue(forKey: tempKey)
                self.finalizeConnection(deviceId: deviceId, conn: conn)
            }
        }

        conn.onTLSReady = { [weak self, weak conn] in
            guard let self, let conn else { return }
            self.connectingDeviceIds.remove(tempKey)
            guard let deviceId = conn.remoteDeviceId else { return }
            self.connections.removeValue(forKey: tempKey)
            self.finalizeConnection(deviceId: deviceId, conn: conn)
        }

        conn.onPacketReceived = { [weak self, weak conn] packet in
            guard let conn = conn else { return }
            self?.handlePacket(packet, fromConnection: conn)
        }

        conn.onDisconnected = { [weak self, weak conn] in
            guard let self, let conn else { return }
            self.connectingDeviceIds.remove(tempKey)
            self.handleDisconnection(conn: conn)
        }

        conn.connectAndRun()

        // Unknown direct connections still need an identity before they can be finalized.
        guard expectedDeviceId == nil else { return }

        // Timeout: if identity hasn't arrived in 15 seconds, clean up orphan connection
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self, weak conn] in
            guard let self = self else { return }
            if let conn {
                let identity = self.pendingConnectionIdentities[ObjectIdentifier(conn)]
                if self.connections[tempKey] === conn && Self.incomingIdentityTimedOut(identity) {
                    KLog.log("[DirectConnect] Connection to \(host) timed out waiting for identity, cleaning up")
                    conn.disconnect()
                    self.connections.removeValue(forKey: tempKey)
                    self.connectingDeviceIds.remove(tempKey)
                }
            }
        }
    }

    // MARK: - Connection Finalization

    private func finalizeConnection(deviceId: String, conn: KDEConnection) {
        // If we already have a different, fully finalized connection to this device, keep the existing one.
        // This prevents WiFi↔Tailscale flip-flopping — first to finalize wins.
        if let existing = connections[deviceId], existing !== conn, existing.running, tlsEstablishedDeviceIds.contains(deviceId) {
            KLog.log("[Link] Already have active connection to \(deviceId), discarding duplicate")
            conn.disconnect()
            return
        }
        // Clean up any stale/dead connection for this device
        if let existing = connections[deviceId], existing !== conn {
            KLog.log("[Link] Replacing dead connection to \(deviceId)")
            existing.disconnect()
        }

        tlsEstablishedDeviceIds.insert(deviceId)
        connectingDeviceIds.remove(deviceId)
        connections[deviceId] = conn

        let device = getOrCreateDevice(id: deviceId, name: Config.shared.savedDeviceName(for: deviceId) ?? deviceId)
        device.kdeConn = conn

        if Config.shared.isPaired(deviceId: deviceId) {
            if let storedCertData = Config.shared.loadPairedDeviceCert(id: deviceId), storedCertData.count > 1 {
                if let peerCert = conn.getPeerCertificate() {
                    let peerData = SecCertificateCopyData(peerCert) as Data
                    if peerData != storedCertData {
                        KLog.log("[Security] Certificate mismatch for \(device.name) — rejecting impersonator")
                        conn.disconnect()
                        return
                    }
                } else {
                    KLog.log("[Security] No peer certificate from \(device.name) — rejecting")
                    conn.disconnect()
                    return
                }
            }
            acceptedConnections.insert(ObjectIdentifier(conn))
            applyPendingIdentity(for: device, connection: conn)
            updateDeviceState(device, to: .paired)
            persistReconnectEndpoint(for: device, connection: conn)
            initializePlugins(for: device)
            let batteryRequest = NetworkPacket(type: "kdeconnect.battery.request", body: ["request": AnyCodable(true)])
            device.send(batteryRequest)
        } else {
            acceptedConnections.insert(ObjectIdentifier(conn))
            applyPendingIdentity(for: device, connection: conn)
            updateDeviceState(device, to: .discovered)
        }

        KLog.log("[Link] Finalized connection to \(device.name) (\(deviceId))")

        if pendingPairRequests.contains(deviceId) {
            let timeSinceLastSend = lastPairRequestTime[deviceId].map { Date().timeIntervalSince($0) } ?? .infinity
            if timeSinceLastSend > 5 {
                let pairPacket = NetworkPacket.pairPacket(pair: true)
                device.send(pairPacket)
                lastPairRequestTime[deviceId] = Date()
                KLog.log("[Pairing] Re-sent pair request to \(device.name) on new connection (fd=\(conn.fd))")
            } else {
                KLog.log("[Pairing] Skipping re-send to \(device.name) — last sent \(String(format: "%.1f", timeSinceLastSend))s ago")
            }
        }
    }

    private func applyPendingIdentity(for device: Device, connection: KDEConnection) {
        let connectionId = ObjectIdentifier(connection)
        guard acceptedConnections.contains(connectionId) else { return }
        guard connections[device.id] === connection else { return }
        guard let identity = pendingConnectionIdentities.removeValue(forKey: connectionId) else { return }
        guard identity.deviceId == device.id else { return }

        device.name = identity.deviceName
        device.type = identity.deviceType
        device.tcpPort = identity.tcpPort
        Config.shared.saveDeviceName(identity.deviceName, for: device.id)
        Config.shared.saveDeviceType(identity.deviceType, for: device.id)
    }

    private func persistReconnectEndpoint(for device: Device, connection: KDEConnection) {
        let port: UInt16
        if device.tcpPort >= Config.minPort && device.tcpPort <= Config.maxPort {
            port = device.tcpPort
        } else if let savedPort = Config.shared.savedDevicePort(for: device.id) {
            port = savedPort
        } else if connection.port >= Config.minPort && connection.port <= Config.maxPort {
            port = connection.port
        } else {
            port = Config.defaultPort
        }
        device.tcpPort = port
        Config.shared.saveDeviceIP(connection.host, for: device.id)
        Config.shared.saveDevicePort(port, for: device.id)
    }

    // MARK: - Network Failover

    /// Disconnect connections when the local IPv4 path they were using has disappeared.
    /// This kills a stale WiFi socket immediately after switching networks while keeping
    /// routed links such as Tailscale alive as long as their local interface still exists.
    private func disconnectStalePathConnections() {
        let interfaces = SocketHelpers.activeIPv4Interfaces()
        guard !interfaces.isEmpty else {
            for (_, conn) in connections where conn.running {
                KLog.log("[Network] No active IPv4 interfaces — disconnecting \(conn.host)")
                conn.disconnect()
            }
            return
        }

        for (_, conn) in connections where conn.running {
            guard let localAddress = SocketHelpers.localIPv4Address(fd: conn.fd) else {
                KLog.log("[Network] Could not inspect local path for \(conn.host); keeping live socket", level: .debug)
                continue
            }
            if SocketHelpers.isIPv4AddressActive(localAddress, on: interfaces) {
                continue
            }
            KLog.log("[Network] Local path for \(conn.host) disappeared — disconnecting stale socket")
            conn.disconnect()
        }
    }

    // MARK: - Disconnection

    private func handleDisconnection(conn: KDEConnection) {
        let connectionId = ObjectIdentifier(conn)
        pendingConnectionIdentities.removeValue(forKey: connectionId)
        acceptedConnections.remove(connectionId)
        let deviceId = conn.remoteDeviceId
        if let id = deviceId {
            connectingDeviceIds.remove(id)
            // Only tear down device state if THIS conn is still the active one.
            // If connections[id] already points to a different (newer) conn, a replacement
            // is in progress — don't set the device to .disconnected or wipe tlsEstablished.
            // Without this guard, every 15s reconnect fires a spurious disconnect→reconnect
            // flash in the device list.
            if connections[id] === conn {
                connections.removeValue(forKey: id)
                // Capture whether TLS was established BEFORE clearing the set.
                // If TLS never happened (e.g. outgoing TCP connect was refused), the
                // device was never truly connected — don't flash it to .disconnected.
                let wasTLSEstablished = tlsEstablishedDeviceIds.remove(id) != nil

                if let device = devices[id], wasTLSEstablished || device.connectionState == .paired {
                    if let clipPlugin = device.plugins["clipboard"] as? ClipboardPlugin {
                        clipPlugin.stop()
                    }
                    if let telPlugin = device.plugins["telephony"] as? TelephonyPlugin {
                        if telPlugin.hasActiveCall { telPlugin.onCallEnded() }
                        telPlugin.resetOnDisconnect()
                    }
                    if let batPlugin = device.plugins["battery"] as? BatteryPlugin {
                        batPlugin.resetOnDisconnect()
                    }
                    device.kdeConn = nil
                    device.batteryLevel = -1
                    device.batteryCharging = false
                    updateDeviceState(device, to: .disconnected)
                    devices[id] = device
                }
            } else {
                KLog.log("[Link] Stale disconnect for \(id) — replacement connection active, skipping state change")
            }
        }
        for (key, connection) in connections where connection === conn {
            connections.removeValue(forKey: key)
        }
        KLog.log("[Link] Disconnected from \(deviceId ?? "unknown")")
    }

    // MARK: - Packet Handling

    private func handlePacket(_ packet: NetworkPacket, fromConnection conn: KDEConnection) {
        let connectionId = ObjectIdentifier(conn)
        guard let deviceId = conn.remoteDeviceId,
            let device = devices[deviceId],
            acceptedConnections.contains(connectionId),
            connections[deviceId] === conn else {
            KLog.log("[DeviceManager] Packet \(packet.type) dropped from unaccepted connection \(conn.host)")
            return
        }

        if packet.type == "kdeconnect.pair" {
            handlePairPacket(packet, fromConnection: conn)
            return
        }

        if packet.type == "kdeconnect.notification" {
            let notifId = packet.body["id"]?.value as? String ?? "?"
            let appName = packet.body["appName"]?.value as? String ?? "?"
            let isCancel = packet.body["isCancel"]?.value as? Bool ?? false
            KLog.log("[Packet] notification from \(appName) id=\(notifId.prefix(60)) isCancel=\(isCancel)")
        }

        device.handlePacket(packet)
    }

    // MARK: - Pairing

    func requestPairing(deviceId: String) {
        guard let device = devices[deviceId] else { return }
        pendingPairRequests.insert(deviceId)
        // Find the active connection — either device.kdeConn or from connections dict
        let conn = device.kdeConn ?? connections[deviceId]

        if let conn, conn.running, conn.fd >= 0 {
            let pairPacket = NetworkPacket.pairPacket(pair: true)
            conn.send(pairPacket)
            lastPairRequestTime[deviceId] = Date()
            KLog.log("[Pairing] Sent pair request to \(device.name) (fd=\(conn.fd))")
        } else {
            // No active connection — broadcast to trigger phone to connect, then retry
            KLog.log("[Pairing] No active connection to \(device.name), broadcasting and waiting")
            broadcastIdentity()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.pendingPairRequests.contains(deviceId) else { return }
                let retryConn = device.kdeConn ?? self.connections[deviceId]
                if let retryConn, retryConn.running, retryConn.fd >= 0 {
                    let pairPacket = NetworkPacket.pairPacket(pair: true)
                    retryConn.send(pairPacket)
                    self.lastPairRequestTime[deviceId] = Date()
                    KLog.log("[Pairing] Sent pair request to \(device.name) on retry (fd=\(retryConn.fd))")
                } else {
                    KLog.log("[Pairing] Still no connection to \(device.name), will send on next connect")
                }
            }
        }

        // Auto-cancel after 30s if no response
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            if self?.pendingPairRequests.contains(deviceId) == true {
                self?.pendingPairRequests.remove(deviceId)
                KLog.log("[Pairing] Pair request to \(device.name) timed out")
            }
        }
    }

    func verificationKey(for deviceId: String) -> String? {
        guard let conn = connections[deviceId] ?? device(for: deviceId)?.kdeConn else { return nil }
        let key = VerificationKeyHelper.computeFromConnection(conn: conn)
        return key.isEmpty ? nil : key
    }

    private func device(for id: String) -> Device? {
        devices[id]
    }

    func cancelPairing(deviceId: String) {
        pendingPairRequests.remove(deviceId)
        KLog.log("[Pairing] Cancelled pairing request for \(deviceId)")
    }

    func unpair(deviceId: String) {
        guard let device = devices[deviceId] else { return }
        let unpairPacket = NetworkPacket.pairPacket(pair: false)
        device.send(unpairPacket)
        Config.shared.removePairedDevice(id: deviceId)
        pendingPairRequests.remove(deviceId)
        recentlyPairedDevices.removeValue(forKey: deviceId)
        updateDeviceState(device, to: .discovered)
        device.plugins.removeAll()
        KLog.log("[Pairing] Unpaired from \(device.name)")
    }

    private func handlePairPacket(_ packet: NetworkPacket, fromConnection conn: KDEConnection) {
        guard let deviceId = conn.remoteDeviceId, let device = devices[deviceId] else {
            KLog.log("[Pairing] Pair packet dropped: no device for connection \(conn.host)")
            return
        }
        let pair = packet.body["pair"]?.value as? Bool ?? false
        KLog.log("[Pairing] Received pair=\(pair) from \(device.name) (isPaired=\(Config.shared.isPaired(deviceId: deviceId)), pending=\(pendingPairRequests.contains(deviceId)))")

        if pair {
            if pendingPairRequests.contains(deviceId) {
                KLog.log("[Pairing] Accepted by \(device.name)")
                pendingPairRequests.remove(deviceId)
                completePairing(device: device, conn: conn)
                return
            }

            if Config.shared.isPaired(deviceId: deviceId) {
                KLog.log("[Pairing] Already paired with \(device.name), confirming re-pair silently")
                conn.send(NetworkPacket.pairPacket(pair: true))
                completePairing(device: device, conn: conn)
                return
            }

            // Phone initiated — show dialog.
            // Guard: don't show duplicate dialogs. The phone re-sends pair=true on every
            // new connection (~15s cycle for unpaired devices). Without this guard, the user
            // gets a new notification every 15 seconds.
            if pendingIncomingPairDevices.contains(deviceId) {
                KLog.log("[Pairing] Already showing pair dialog for \(device.name), ignoring duplicate")
                return
            }
            pendingIncomingPairDevices.insert(deviceId)
            KLog.log("[Pairing] Request from \(device.name)")
            // Pre-capture cert now — conn.getPeerCertificate() may return nil later if
            // the phone's connection cycles during runModal() and SSL is cleaned up.
            let preCapturedCert = conn.getPeerCertificate()
            PairingHandler.showPairingRequest(from: device, connection: conn) { [weak self] accepted in
                guard let self = self else { return }
                // defer ensures cleanup even if something throws or returns early
                defer { self.pendingIncomingPairDevices.remove(deviceId) }
                // Re-fetch device — it may have been recreated during the dialog
                guard let device = self.devices[deviceId] else { return }
                if accepted {
                    // Use the CURRENT active connection — the original one captured
                    // in the closure is likely dead (unpaired connections cycle ~15s).
                    let activeConn = self.connections[deviceId] ?? conn
                    // Update device's connection reference — device.send() uses kdeConn,
                    // which may still point to the dead connection from before the dialog.
                    device.kdeConn = activeConn
                    activeConn.send(NetworkPacket.pairPacket(pair: true))
                    KLog.log("[Pairing] Sent pair=true response to \(device.name) on fd=\(activeConn.fd)")
                    self.completePairing(device: device, conn: activeConn, preCapturedCert: preCapturedCert)
                } else {
                    device.send(NetworkPacket.pairPacket(pair: false))
                }
            }
        } else {
            // Unpair request from remote
            let wasPaired = Config.shared.isPaired(deviceId: deviceId)
            let hadPendingRequest = pendingPairRequests.contains(deviceId)

            if wasPaired {
                if let pairedAt = recentlyPairedDevices[deviceId], Date().timeIntervalSince(pairedAt) < 10 {
                    KLog.log("[Pairing] Ignoring pair=false from \(device.name) — just paired \(Int(Date().timeIntervalSince(pairedAt)))s ago")
                    return
                }
                Config.shared.removePairedDevice(id: deviceId)
                updateDeviceState(device, to: .discovered)
                device.plugins.removeAll()
                recentlyPairedDevices.removeValue(forKey: deviceId)
                conn.disconnect()
                connections.removeValue(forKey: deviceId)
                tlsEstablishedDeviceIds.remove(deviceId)
                KLog.log("[Pairing] \(device.name) unpaired by remote, connection closed")
            }

            if !wasPaired && !hadPendingRequest {
                KLog.log("[Pairing] Ignoring unpair from \(device.name) — not paired")
            } else if hadPendingRequest {
                // Phone sent pair=false while we have a pending request.
                // This is normal — the phone clears old state before responding.
                // Don't retry — just wait for the pair=true on this connection.
                KLog.log("[Pairing] Waiting for pair acceptance from \(device.name)")
            }
        }
    }

    private var recentlyPairedDevices: [String: Date] = [:] // deviceId -> when paired

    /// Prune entries older than 30s — only needed for the 10s grace period check
    private func pruneRecentlyPairedDevices() {
        let cutoff = Date().addingTimeInterval(-30)
        recentlyPairedDevices = recentlyPairedDevices.filter { $0.value > cutoff }
    }

    func completePairing(device: Device, conn: KDEConnection, preCapturedCert: SecCertificate? = nil) {
        // Guard against duplicate completePairing calls (reconnect re-confirmation, race conditions)
        if device.connectionState == .paired && Config.shared.isPaired(deviceId: device.id) {
            recentlyPairedDevices[device.id] = Date()
            persistReconnectEndpoint(for: device, connection: conn)
            KLog.log("[Pairing] Already paired with \(device.name), refreshing state")
            return
        }

        recentlyPairedDevices[device.id] = Date()
        pruneRecentlyPairedDevices()
        // Always clear pending state — whether we initiated or phone did
        pendingPairRequests.remove(device.id)

        // Save peer certificate — REQUIRED for secure pairing.
        // Fall back to preCapturedCert if the connection cycled during a runModal() dialog.
        let peerCert = conn.getPeerCertificate() ?? preCapturedCert
        guard let peerCert = peerCert else {
            KLog.log("[Pairing] CRITICAL: No peer certificate from \(device.name) — refusing to pair. Connection has no trust anchor.")
            return
        }
        let certData = SecCertificateCopyData(peerCert) as Data
        Config.shared.savePairedDevice(id: device.id, certData: certData)
        KLog.log("[Pairing] Saved peer certificate for \(device.name) (\(certData.count) bytes)")

        Config.shared.saveDeviceName(device.name, for: device.id)
        Config.shared.saveDeviceType(device.type, for: device.id)
        persistReconnectEndpoint(for: device, connection: conn)

        updateDeviceState(device, to: .paired)
        initializePlugins(for: device)
        KLog.log("[Pairing] Completed with \(device.name)")

        let batteryRequest = NetworkPacket(type: "kdeconnect.battery.request", body: ["request": AnyCodable(true)])
        device.send(batteryRequest)
    }

    // MARK: - Plugins

    private func initializePlugins(for device: Device) {
        let enabled = Config.shared.enabledPlugins(for: device.id)
        device.plugins.removeAll()

        if enabled.contains("ping") { device.plugins["ping"] = PingPlugin(device: device) }
        if enabled.contains("battery") { device.plugins["battery"] = BatteryPlugin(device: device) }
        if enabled.contains("notification") { device.plugins["notification"] = NotificationPlugin(device: device) }
        if enabled.contains("telephony") { device.plugins["telephony"] = TelephonyPlugin(device: device) }
        if enabled.contains("clipboard") {
            let clipPlugin = ClipboardPlugin(device: device)
            clipPlugin.start()
            device.plugins["clipboard"] = clipPlugin
        }
        if enabled.contains("findmyphone") { device.plugins["findmyphone"] = FindMyPhonePlugin(device: device) }
        if enabled.contains("share") { device.plugins["share"] = SharePlugin(device: device) }

        // Request all notifications
        let notifRequest = NetworkPacket(type: "kdeconnect.notification.request", body: ["request": AnyCodable(true)])
        device.send(notifRequest)
    }

    /// Call this when plugin toggles change so plugins are reloaded at runtime
    func reloadPlugins(for deviceId: String) {
        guard let device = devices[deviceId] else { return }
        initializePlugins(for: device)
        KLog.log("[DeviceManager] Reloaded plugins for \(device.name)")
    }

    // MARK: - Helpers

    func getOrCreateDevice(id: String, name: String, type: String = "phone") -> Device {
        if let existing = devices[id] {
            if existing.name != name && name != id {
                existing.name = name
            }
            return existing
        }
        let savedName = Config.shared.savedDeviceName(for: id) ?? name
        let device = Device(id: id, name: savedName, type: type)
        devices[id] = device
        return device
    }

    /// Update device state and force SwiftUI refresh
    private func updateDeviceState(_ device: Device, to state: ConnectionState) {
        device.connectionState = state
        // Force dictionary mutation so @Published triggers SwiftUI update
        devices[device.id] = device
        objectWillChange.send()
    }

    private func loadPairedDevices() {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dir = appSupport.appendingPathComponent("KonnectMac/PairedDevices")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }

        for file in files where file.hasSuffix(".der") {
            let deviceId = String(file.dropLast(4))
            let name = Config.shared.savedDeviceName(for: deviceId) ?? deviceId
            let device = getOrCreateDevice(id: deviceId, name: name)
            device.tcpPort = Config.shared.savedDevicePort(for: deviceId) ?? Config.defaultPort
            updateDeviceState(device, to: .disconnected)
            KLog.log("[DeviceManager] Loaded paired device: \(name)")
        }
    }

    /// Gracefully stop all services, timers, and connections. Called on app termination.
    func stopServices() {
        KLog.log("[DeviceManager] Stopping all services...")
        // Invalidate broadcast timer
        broadcastTimer?.invalidate()
        broadcastTimer = nil

        // Remove sleep/wake observer
        if let observer = sleepWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            sleepWakeObserver = nil
        }

        // Cancel network monitor
        networkMonitor?.cancel()
        networkMonitor = nil
        // Stop UDP discovery and TCP server
        udpDiscovery.stop()
        tcpServer.stop()

        for (_, conn) in connections {
            conn.disconnect()
        }
        connections.removeAll()
        tlsEstablishedDeviceIds.removeAll()
        connectingDeviceIds.removeAll()

        // Stop plugins for all devices
        for (_, device) in devices {
            if let clipPlugin = device.plugins["clipboard"] as? ClipboardPlugin {
                clipPlugin.stop()
            }
            device.plugins.removeAll()
            device.kdeConn = nil
        }

        KLog.log("[DeviceManager] All services stopped")
    }

    func connectToDirectIP(_ ip: String) {
        guard !ip.isEmpty else { return }
        connectDirectToHost(host: ip, port: Config.defaultPort)
    }
}
