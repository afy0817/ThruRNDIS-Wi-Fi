// SPDX-FileCopyrightText: 2026 GodSeon
// SPDX-License-Identifier: MIT

import Foundation

/// Dotted-quad IPv4 helpers shared by the routing and static address code.
enum IPv4 {
    static func parse(_ text: some StringProtocol) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard (1...3).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let octet = UInt32(part), octet <= 255 else { return nil }
            value = (value << 8) | octet
        }
        return value
    }

    static func format(_ value: UInt32) -> String {
        "\(value >> 24).\((value >> 16) & 255).\((value >> 8) & 255).\(value & 255)"
    }

    static func mask(_ prefix: Int) -> UInt32 {
        prefix == 0 ? 0 : ~(UInt32.max >> UInt32(prefix))
    }

    /// "255.255.255.0", "/24" or "24" -> 24; nil unless 1...32 and contiguous.
    static func prefix(fromSubnet text: String) -> Int? {
        let text = text.hasPrefix("/") ? String(text.dropFirst()) : text
        if text.allSatisfy({ $0.isASCII && $0.isNumber }), let prefix = Int(text) {
            return (1...32).contains(prefix) ? prefix : nil
        }
        guard let mask = parse(text), mask != 0 else { return nil }
        let prefix = mask.nonzeroBitCount
        return mask == self.mask(prefix) ? prefix : nil
    }

    /// Not 0/8, loopback or multicast/reserved.
    static func isUnicast(_ value: UInt32) -> Bool {
        let first = value >> 24
        return first != 0 && first != 127 && first < 224
    }

    /// The guest API only accepts [0-9A-Za-z_], so addresses travel as hex.
    static func hex(_ value: UInt32) -> String {
        String(format: "%08x", value)
    }
}

/// A manual IPv4 setup for one saved network, used instead of DHCP on
/// networks without a DHCP server.
struct StaticIPv4: Codable, Equatable {
    var address: String
    var prefix: Int
    var gateway: String?
    var dns: [String]
    /// Networks reached through another router on this network, e.g.
    /// 10.10.0.0/24 through 192.168.50.254.
    var routes: [Route]

    struct Route: Codable, Equatable {
        var destination: String
        var gateway: String
    }

    var cidr: String { "\(address)/\(prefix)" }
    var subnetMask: String { IPv4.format(IPv4.mask(prefix)) }

    private enum CodingKeys: String, CodingKey { case address, prefix, gateway, dns, routes }

    // Entries saved before extra routes existed have no "routes" key.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        address = try container.decode(String.self, forKey: .address)
        prefix = try container.decode(Int.self, forKey: .prefix)
        gateway = try container.decodeIfPresent(String.self, forKey: .gateway)
        dns = try container.decode([String].self, forKey: .dns)
        routes = try container.decodeIfPresent([Route].self, forKey: .routes) ?? []
    }

    enum ValidationError: LocalizedError {
        case address, subnet, gateway, dns, routes
        var errorDescription: String? {
            switch self {
            case .address: return "IP 주소는 192.168.50.20 같은 형식이어야 하고, 대역의 첫/끝 주소는 쓸 수 없습니다."
            case .subnet: return "서브넷 마스크는 255.255.255.0 또는 /24 형식이어야 합니다."
            case .gateway: return "게이트웨이는 같은 대역의 다른 주소여야 합니다."
            case .dns: return "DNS 는 IPv4 주소 3개까지, 쉼표로 구분합니다."
            case .routes:
                return "추가 경로는 8개까지, 왼쪽은 10.10.0.0/24 같은 대역, 오른쪽은 같은 대역의 다른 주소(게이트웨이)여야 합니다."
            }
        }
    }

    /// Parses the editor fields. The address may carry its own "/prefix";
    /// otherwise the subnet field (mask or prefix) applies, default /24.
    /// Each extra route is a (대역, 게이트웨이) pair; fully empty rows are skipped.
    init(addressText: String, subnetText: String, gatewayText: String, dnsText: String,
         routeRows: [(destination: String, gateway: String)] = []) throws {
        let parts = addressText.trimmingCharacters(in: .whitespaces).split(separator: "/")
        guard (1...2).contains(parts.count), let address = IPv4.parse(parts[0]), IPv4.isUnicast(address)
        else { throw ValidationError.address }
        let subnetText = subnetText.trimmingCharacters(in: .whitespaces)
        let prefix: Int?
        if parts.count == 2 {
            prefix = IPv4.prefix(fromSubnet: String(parts[1]))
        } else {
            prefix = subnetText.isEmpty ? 24 : IPv4.prefix(fromSubnet: subnetText)
        }
        guard let prefix else { throw ValidationError.subnet }
        let mask = IPv4.mask(prefix)
        if prefix <= 30, address & ~mask == 0 || address & ~mask == ~mask {
            throw ValidationError.address
        }

        var gateway: String?
        let gatewayText = gatewayText.trimmingCharacters(in: .whitespaces)
        if !gatewayText.isEmpty {
            guard let value = IPv4.parse(gatewayText), IPv4.isUnicast(value), value != address,
                  value & mask == address & mask else { throw ValidationError.gateway }
            gateway = IPv4.format(value)
        }

        var dns: [String] = []
        for token in dnsText.split(whereSeparator: { $0 == "," || $0 == " " }) {
            guard let value = IPv4.parse(token), IPv4.isUnicast(value) else { throw ValidationError.dns }
            if !dns.contains(IPv4.format(value)) { dns.append(IPv4.format(value)) }
        }
        guard dns.count <= 3 else { throw ValidationError.dns }

        var routes: [Route] = []
        for row in routeRows {
            let destinationText = row.destination.trimmingCharacters(in: .whitespaces)
            let viaText = row.gateway.trimmingCharacters(in: .whitespaces)
            if destinationText.isEmpty && viaText.isEmpty { continue }
            guard let destination = RouteHelper.canonicalCIDR(destinationText),
                  let via = IPv4.parse(viaText), IPv4.isUnicast(via), via != address,
                  via & mask == address & mask else { throw ValidationError.routes }
            let route = Route(destination: destination, gateway: IPv4.format(via))
            if !routes.contains(route) { routes.append(route) }
        }
        guard routes.count <= 8 else { throw ValidationError.routes }

        self.address = IPv4.format(address)
        self.prefix = prefix
        self.gateway = gateway
        self.dns = dns
        self.routes = routes
    }

    var formFields: String {
        func hex(_ text: String?) -> String { text.flatMap(IPv4.parse).map(IPv4.hex) ?? "" }
        let routeHex = routes.map { route -> String in
            let parts = route.destination.split(separator: "/")
            return hex(String(parts[0])) + String(format: "%02x", Int(parts[1]) ?? 32) + hex(route.gateway)
        }.joined()
        return "ip=\(hex(address))&prefix=\(prefix)&gw=\(hex(gateway))&dns=\(dns.map(hex).joined())&rt=\(routeHex)"
    }
}
