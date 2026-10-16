import Foundation
import Darwin

struct IPv4InterfaceAddress: Equatable {
    let address: in_addr_t
    let netmask: in_addr_t

    init(address: in_addr_t, netmask: in_addr_t) {
        self.address = address
        self.netmask = netmask
    }

    init?(address: String, netmask: String) {
        var parsedAddress = in_addr()
        var parsedNetmask = in_addr()
        guard inet_pton(AF_INET, address, &parsedAddress) == 1,
            inet_pton(AF_INET, netmask, &parsedNetmask) == 1 else {
            return nil
        }
        self.init(address: parsedAddress.s_addr, netmask: parsedNetmask.s_addr)
    }

    func contains(_ host: String) -> Bool {
        var parsedHost = in_addr()
        guard inet_pton(AF_INET, host, &parsedHost) == 1 else { return false }
        return (parsedHost.s_addr & netmask) == (address & netmask)
    }
}

/// BSD socket configuration helpers shared across KDEConnection, SharePlugin, and
/// NotificationPlugin.
///
/// **Two keepalive presets, deliberately not unified.** A control connection wants
/// slow probes (keep NAT tables alive without burning battery — 60s idle, 15s probe,
/// 4 retries → ~2 min to detect a dead peer). A transfer connection wants fast probes
/// (notice a dead peer in ~30s mid-transfer). Encoding the two intents as separate
/// named functions makes it impossible to accidentally route a transfer through the
/// patient profile (which would hang multi-GB transfers for 2 min on a flaky link).
enum SocketHelpers {
    static func activeIPv4Interfaces() -> [IPv4InterfaceAddress] {
        var interfaces = [IPv4InterfaceAddress]()
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddress = ifaddr else { return interfaces }
        defer { freeifaddrs(ifaddr) }

        var pointer = firstAddress
        while true {
            let interface = pointer.pointee
            let flags = Int32(interface.ifa_flags)
            if (flags & IFF_UP) != 0,
                (flags & IFF_LOOPBACK) == 0,
                let addressPointer = interface.ifa_addr,
                let netmaskPointer = interface.ifa_netmask,
                addressPointer.pointee.sa_family == UInt8(AF_INET),
                netmaskPointer.pointee.sa_family == UInt8(AF_INET) {
                let address = addressPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_addr.s_addr
                }
                let netmask = netmaskPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_addr.s_addr
                }
                interfaces.append(IPv4InterfaceAddress(address: address, netmask: netmask))
            }
            guard let next = interface.ifa_next else { break }
            pointer = next
        }
        return interfaces
    }

    static func localIPv4Address(fd: Int32) -> in_addr_t? {
        guard fd >= 0 else { return nil }

        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard result == 0, address.sin_family == UInt8(AF_INET) else { return nil }
        return address.sin_addr.s_addr
    }

    static func isIPv4AddressActive(_ address: in_addr_t, on interfaces: [IPv4InterfaceAddress]) -> Bool {
        interfaces.contains { $0.address == address }
    }

    static func isIPv4Address(_ host: String, onAny interfaces: [IPv4InterfaceAddress]) -> Bool {
        interfaces.contains { $0.contains(host) }
    }

    /// Disable Nagle's algorithm so small writes go out immediately. Used on every
    /// active TCP socket — a 200ms-batched write is unacceptable for any of our paths.
    static func enableNoDelay(fd: Int32) {
        var nodelay: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &nodelay, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Keepalive profile for the long-lived KDEConnection control channel.
    /// Probes after 60s of idle, every 15s, 4 retries → ~2 min to detect a dead peer.
    /// The 60s idle is intentionally generous so we don't burn battery probing every
    /// few seconds while the user's phone is asleep.
    static func enableControlKeepAlive(fd: Int32) {
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var keepAlive: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &keepAlive, socklen_t(MemoryLayout<Int32>.size))
        var keepIdle: Int32 = 60
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &keepIdle, socklen_t(MemoryLayout<Int32>.size))
        var keepIntvl: Int32 = 15
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &keepIntvl, socklen_t(MemoryLayout<Int32>.size))
        var keepCnt: Int32 = 4
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &keepCnt, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Configure a data-transfer socket: TCP_NODELAY for streaming, SO_KEEPALIVE
    /// with aggressive 30s probing, and short per-syscall timeouts so the I/O
    /// callback returns often enough for higher-level deadlines (handshake timeout,
    /// stall timeout, total transfer timeout) to kick in.
    ///
    /// Note: only sets the keepalive idle threshold (TCP_KEEPALIVE), not the probe
    /// interval / count. macOS's defaults for TCP_KEEPINTVL and TCP_KEEPCNT (75s,
    /// 8) combined with the 30s idle gives roughly 30s + 75s = ~2 min worst-case
    /// detection — which is fine for transfers because the per-I/O timeouts
    /// (`ioTimeoutSeconds`) bound the actual stall window much tighter.
    static func configureTransferSocket(fd: Int32, ioTimeoutSeconds: Int) {
        enableNoDelay(fd: fd)
        // TLS close-notify can race the peer closing; return EPIPE instead of terminating the app.
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var keepAlive: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &keepAlive, socklen_t(MemoryLayout<Int32>.size))
        var keepIdle: Int32 = 30
        setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &keepIdle, socklen_t(MemoryLayout<Int32>.size))

        var io = timeval(tv_sec: __darwin_time_t(ioTimeoutSeconds), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &io, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &io, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Block close() up to `seconds` waiting for the kernel send buffer to drain.
    /// Without this, the last TLS records of a large file can be discarded when we
    /// close the socket.
    static func enableLinger(fd: Int32, seconds: Int = 5) {
        var lng = linger(l_onoff: 1, l_linger: Int32(seconds))
        setsockopt(fd, SOL_SOCKET, SO_LINGER, &lng, socklen_t(MemoryLayout<linger>.size))
    }
}
