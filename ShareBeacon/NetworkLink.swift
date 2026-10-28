import CoreWLAN
import Darwin
import Foundation
import Synchronization
import SystemConfiguration

/// The kind of interface the route to a share's host leaves the Mac through.
enum NetworkLinkKind: String, Sendable {
    case wired
    case wifi
    case tunnel
    case other
}

/// The local interface macOS routes a share's traffic through.
struct NetworkLink: Equatable, Sendable {
    let interfaceName: String
    let kind: NetworkLinkKind
    /// Link speed reported by the interface, or 0 when it reports none.
    let bitsPerSecond: UInt64

    var label: String {
        switch kind {
        case .wired:
            guard let speed = Self.speedLabel(bitsPerSecond) else { return "Ethernet" }
            return "Ethernet \(speed)"
        case .wifi:
            guard let speed = Self.speedLabel(bitsPerSecond) else { return "Wi-Fi" }
            return "Wi-Fi \(speed)"
        case .tunnel:
            return "VPN"
        case .other:
            return interfaceName
        }
    }

    var symbolName: String {
        switch kind {
        case .wired: return "cable.connector"
        case .wifi: return "wifi"
        case .tunnel: return "lock.shield"
        case .other: return "network"
        }
    }

    /// The link speed in a few characters, such as 2.5G or 10G, for the badge.
    var shortSpeed: String? {
        guard bitsPerSecond > 0 else { return nil }
        let gigabits = Double(bitsPerSecond) / 1_000_000_000
        if gigabits >= 1 {
            return "\(Self.trimmed(gigabits))G"
        }
        return "\(bitsPerSecond / 1_000_000)M"
    }

    private static func trimmed(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }

    static func speedLabel(_ bitsPerSecond: UInt64) -> String? {
        guard bitsPerSecond > 0 else { return nil }
        let gigabits = Double(bitsPerSecond) / 1_000_000_000
        if gigabits >= 1 {
            return "\(trimmed(gigabits)) Gb/s"
        }
        return "\(bitsPerSecond / 1_000_000) Mb/s"
    }

    /// Classifies an interface from its BSD name and its System Configuration type.
    static func kind(interfaceName: String, systemType: String?) -> NetworkLinkKind {
        let tunnelPrefixes = ["utun", "ipsec", "ppp", "tun", "tap", "wg"]
        if tunnelPrefixes.contains(where: interfaceName.hasPrefix) {
            return .tunnel
        }
        switch systemType {
        case "IEEE80211": return .wifi
        case "Ethernet": return .wired
        default: return .other
        }
    }
}

/// Which link a share is expected to use. A share that expects a wired link is
/// flagged when macOS routes it through anything else.
enum LinkExpectation: String, Codable, CaseIterable, Sendable {
    case any
    case wired

    /// An unknown link is never flagged, because nothing can be said about it.
    func isSatisfied(by link: NetworkLink?) -> Bool {
        guard self == .wired, let link else { return true }
        return link.kind == .wired
    }
}

protocol NetworkLinkResolving: Sendable {
    func link(toHost host: String) -> NetworkLink?
    func link(forInterface name: String) -> NetworkLink?
    /// A resolver that reads the interfaces once and answers every later
    /// question from that reading, for a status refresh that asks per share.
    func snapshot() -> NetworkLinkResolving
}

extension NetworkLinkResolving {
    func snapshot() -> NetworkLinkResolving { self }
}

/// Asks the routing table which interface reaches a host.
///
/// Connecting a UDP socket sends nothing; it only makes the kernel pick a route
/// and a source address, which then names the interface SMB uses as well.
struct SystemNetworkLinkResolver: NetworkLinkResolving {
    func link(toHost host: String) -> NetworkLink? {
        NetworkSnapshot.capture().link(toHost: host)
    }

    func link(forInterface name: String) -> NetworkLink? {
        NetworkSnapshot.capture().link(forInterface: name)
    }

    func snapshot() -> NetworkLinkResolving {
        NetworkSnapshot.capture()
    }

    /// The negotiated speed of an interface.
    ///
    /// `ifi_baudrate` is 0xFFFFFFFF on an interface whose speed macOS does not
    /// expose, which a 10Gbase-T port does. Dividing that value by a billion
    /// made a 10 Gb link read as "4.3G", so the media word is asked instead.
    fileprivate static func mediaSpeed(interfaceName: String) -> UInt64? {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var request = ifmediareq()
        withUnsafeMutablePointer(to: &request.ifm_name) { name in
            name.withMemoryRebound(to: CChar.self, capacity: Int(IFNAMSIZ)) { buffer in
                _ = strlcpy(buffer, interfaceName, Int(IFNAMSIZ))
            }
        }
        // SIOCGIFMEDIA is not imported because its macro spelling embeds a
        // structure; 3224135992 is `_IOWR('i', 56, struct ifmediareq)`.
        guard ioctl(descriptor, 3_224_135_992, &request) == 0,
              request.ifm_status & IFM_AVALID != 0
        else { return nil }

        // IFM_TMASK from net/if_media.h.
        return speed(forMediaSubtype: request.ifm_active & 0x000f_001f)
    }

    /// A baud rate of 0xFFFFFFFF means "not reported", not 4.3 Gb/s.
    static func usableBaudRate(_ value: UInt64) -> UInt64 {
        value == UInt64(UInt32.max) ? 0 : value
    }

    /// Maps a media subtype from net/if_media.h to bits per second.
    static func speed(forMediaSubtype subtype: Int32) -> UInt64? {
        let megabits: UInt64
        switch subtype {
        case 3, 4, 5, 12, 13:
            megabits = 10
        case 6, 7, 8, 9, 10:
            megabits = 100
        case 11, 14, 15, 16, 24, 25:
            megabits = 1_000
        case 22:
            megabits = 2_500
        case 23:
            megabits = 5_000
        case 18, 19, 20, 21, 26, 33, 34, 35:
            megabits = 10_000
        case 37, 38, 43, 44, 45, 72, 73, 74:
            megabits = 40_000
        case 47, 48, 49, 50, 89, 90, 91:
            megabits = 100_000
        default:
            return nil
        }
        return megabits * 1_000_000
    }

    fileprivate static func sourceAddress(toHost host: String) -> Data? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "445", &hints, &result) == 0, let result else { return nil }
        defer { freeaddrinfo(result) }

        var cursor: UnsafeMutablePointer<addrinfo>? = result
        while let current = cursor {
            cursor = current.pointee.ai_next
            let info = current.pointee
            guard let address = info.ai_addr else { continue }
            let descriptor = socket(info.ai_family, SOCK_DGRAM, IPPROTO_UDP)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }
            guard connect(descriptor, address, info.ai_addrlen) == 0 else { continue }

            var local = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let named = withUnsafeMutablePointer(to: &local) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(descriptor, $0, &length)
                }
            }
            guard named == 0 else { continue }
            if let bytes = addressBytes(&local) {
                return bytes
            }
        }
        return nil
    }

    private static func addressBytes(_ storage: UnsafeMutablePointer<sockaddr_storage>) -> Data? {
        switch Int32(storage.pointee.ss_family) {
        case AF_INET:
            return storage.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin_addr) { Data($0) }
            }
        case AF_INET6:
            return storage.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin6_addr) { Data($0) }
            }
        default:
            return nil
        }
    }

    /// Baud rates by interface, and the interface that owns each local address.
    fileprivate static func interfaceAddresses() -> (speeds: [String: UInt64], owners: [Data: String]) {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let list else { return ([:], [:]) }
        defer { freeifaddrs(list) }

        var speeds: [String: UInt64] = [:]
        var owners: [Data: String] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = list
        while let current = cursor {
            cursor = current.pointee.ifa_next
            guard let socketAddress = current.pointee.ifa_addr else { continue }
            let name = String(cString: current.pointee.ifa_name)
            let family = Int32(socketAddress.pointee.sa_family)
            if family == AF_LINK, let data = current.pointee.ifa_data {
                let linkData = data.assumingMemoryBound(to: if_data.self).pointee
                speeds[name] = UInt64(linkData.ifi_baudrate)
            } else if family == AF_INET || family == AF_INET6 {
                var storage = sockaddr_storage()
                memcpy(&storage, socketAddress, Int(socketAddress.pointee.sa_len))
                if let bytes = addressBytes(&storage), owners[bytes] == nil {
                    owners[bytes] = name
                }
            }
        }
        return (speeds, owners)
    }

    fileprivate static func wifiTransmitRate(interfaceName: String) -> UInt64 {
        guard let megabits = CWWiFiClient.shared().interface(withName: interfaceName)?.transmitRate(),
              megabits > 0
        else { return 0 }
        return UInt64(megabits * 1_000_000)
    }

    fileprivate static func systemInterfaceTypes() -> [String: String] {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var types: [String: String] = [:]
        for interface in interfaces {
            guard let name = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let type = SCNetworkInterfaceGetInterfaceType(interface) as String?
            else { continue }
            types[name] = type
        }
        return types
    }
}

/// The interfaces as they were at one moment. Listing the System Configuration
/// interfaces walks the I/O Registry, and the Wi-Fi rate and the media word are
/// calls into other processes or the kernel, so a refresh reads each once
/// instead of once per share.
final class NetworkSnapshot: NetworkLinkResolving {
    private typealias System = SystemNetworkLinkResolver

    private let systemTypes: [String: String]
    private let baudRates: [String: UInt64]
    /// The interface that owns each local address.
    private let owners: [Data: String]
    private let speeds = Mutex<[String: UInt64]>([:])
    private let hostLinks = Mutex<[String: NetworkLink?]>([:])

    private init(systemTypes: [String: String], baudRates: [String: UInt64], owners: [Data: String]) {
        self.systemTypes = systemTypes
        self.baudRates = baudRates
        self.owners = owners
    }

    static func capture() -> NetworkSnapshot {
        let (baudRates, owners) = System.interfaceAddresses()
        return NetworkSnapshot(systemTypes: System.systemInterfaceTypes(), baudRates: baudRates, owners: owners)
    }

    func link(toHost host: String) -> NetworkLink? {
        let key = host.lowercased()
        if let known = hostLinks.withLock({ $0[key] }) {
            return known
        }
        let link = System.sourceAddress(toHost: host)
            .flatMap { owners[$0] }
            .map { link(interfaceName: $0) }
        hostLinks.withLock { $0[key] = link }
        return link
    }

    func link(forInterface name: String) -> NetworkLink? {
        guard baudRates[name] != nil else { return nil }
        return link(interfaceName: name)
    }

    func snapshot() -> NetworkLinkResolving { self }

    private func link(interfaceName: String) -> NetworkLink {
        let kind = NetworkLink.kind(interfaceName: interfaceName, systemType: systemTypes[interfaceName])
        return NetworkLink(
            interfaceName: interfaceName,
            kind: kind,
            bitsPerSecond: speed(interfaceName: interfaceName, kind: kind)
        )
    }

    private func speed(interfaceName: String, kind: NetworkLinkKind) -> UInt64 {
        if let known = speeds.withLock({ $0[interfaceName] }) {
            return known
        }
        let speed: UInt64
        if kind == .wifi {
            // Wi-Fi reports no fixed baud rate, so the current transmit rate stands in.
            speed = System.wifiTransmitRate(interfaceName: interfaceName)
        } else {
            speed = System.mediaSpeed(interfaceName: interfaceName)
                ?? System.usableBaudRate(baudRates[interfaceName] ?? 0)
        }
        speeds.withLock { $0[interfaceName] = speed }
        return speed
    }
}
