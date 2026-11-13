// SPDX-FileCopyrightText: 2026 GodSeon
// SPDX-License-Identifier: MIT

import Foundation

/// Client for the guest's busybox httpd control API (vm/initramfs/api.cgi).
struct GuestAPI {
    let host: String
    let token: String

    struct Status: Decodable, Equatable {
        var ok: Bool
        var device: Bool
        var usb_id: String
        var wpa_running: Bool
        var wpa_state: String
        var ssid_hex: String
        var bssid: String
        var freq: Int?
        var rssi: Int?
        var key_mgmt: String
        var ipv4: String
        var prefix: Int?
        var gateway: String
        var dns: String
        var uplink: String
        var route_ready: Bool
        var configured_ssid_hex: String
        /// "wrong-key", "auth-failed" or "not-found" for the configured network.
        var auth_error: String?
        /// "dhcp" or "static" while wlan0 has an address.
        var ip_source: String?
        /// "conflict" when another host answered ARP for the static address.
        var ip_error: String?
        var ip_conflict_mac: String?
        /// "vvvv:pppp" of a USB device in the VM that no driver claimed.
        var usb_unsupported: String?
        /// Changes on every VM boot.
        var boot_id: String?
        /// TRBs waiting on the dongle's stuck bulk OUT endpoint; 0 while transfers complete,
        /// nil when the VM does not watch (older image, no dongle).
        var usb_tx_lag: Int?
        /// The endpoint stopped completing transfers altogether.
        var usb_tx_stall: Bool?
        /// "l1" / "l2" while the VM resets the dongle, "failed" when only a VM restart is left.
        var usb_recover: String?

        var ssid: String { Hex.decodeSSID(ssid_hex) }
        var configuredSSID: String { Hex.decodeSSID(configured_ssid_hex) }
        var isAssociated: Bool { wpa_state == "COMPLETED" }
        var isStatic: Bool { ip_source == "static" }
        var hasIPConflict: Bool { ip_error == "conflict" }
        var isResettingDongle: Bool { usb_recover == "l1" || usb_recover == "l2" }
        var needsVMRestart: Bool { usb_recover == "failed" }
        var hasUSBTXProblem: Bool { (usb_tx_lag ?? 0) > 0 || usb_tx_stall == true }

        /// Network address of the wlan0 lease, e.g. "10.0.0.0/24".
        var subnetCIDR: String? {
            guard let prefix, (1...32).contains(prefix), let address = IPv4.parse(ipv4) else { return nil }
            return "\(IPv4.format(address & IPv4.mask(prefix)))/\(prefix)"
        }
    }

    struct ScanResult: Decodable, Hashable, Identifiable {
        var bssid: String
        var freq: Int
        var signal: Int
        var flags: String
        var ssid_hex: String

        var id: String { bssid }
        var ssid: String { Hex.decodeSSID(ssid_hex) }
        var isSecured: Bool { flags.contains("WPA") || flags.contains("SAE") || flags.contains("WEP") }
    }

    private struct ScanReply: Decodable {
        var ok: Bool
        var error: String?
        var results: [ScanResult]?
    }

    private struct SimpleReply: Decodable {
        var ok: Bool
        var error: String?
    }

    enum APIError: LocalizedError {
        case server(String)
        var errorDescription: String? {
            switch self {
            case .server("no-wifi-device"): return "VM 에 무선랜 동글이 아직 연결되지 않았습니다."
            case .server("unauthorized"): return "VM 토큰이 맞지 않습니다. ThruRNDIS 에 이미지를 다시 적용하세요."
            case .server(let code): return "VM 오류: \(code)"
            }
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private func url(_ action: String) -> URL {
        URL(string: "http://\(host):8080/cgi-bin/api?action=\(action)&token=\(token)")!
    }

    func status() async throws -> Status {
        let (data, _) = try await Self.session.data(from: url("status"))
        let status = try JSONDecoder().decode(Status.self, from: data)
        guard status.ok else { throw APIError.server("status") }
        return status
    }

    func scan(trigger: Bool) async throws -> [ScanResult] {
        let (data, _) = try await Self.session.data(from: url(trigger ? "scan" : "results"))
        let reply = try JSONDecoder().decode(ScanReply.self, from: data)
        guard reply.ok else { throw APIError.server(reply.error ?? "scan") }
        return reply.results ?? []
    }

    func connect(_ credential: WiFiCredential) async throws {
        var request = URLRequest(url: url("connect"))
        request.httpMethod = "POST"
        request.httpBody = credential.formBody.data(using: .utf8)
        let (data, _) = try await Self.session.data(for: request)
        let reply = try JSONDecoder().decode(SimpleReply.self, from: data)
        guard reply.ok else { throw APIError.server(reply.error ?? "connect") }
    }

    func disconnect() async throws {
        let (data, _) = try await Self.session.data(from: url("disconnect"))
        let reply = try JSONDecoder().decode(SimpleReply.self, from: data)
        guard reply.ok else { throw APIError.server(reply.error ?? "disconnect") }
    }

    /// Powers the VM off; ThruRNDIS boots a fresh one when the dongle is free again.
    func restart() async throws {
        var request = URLRequest(url: url("restart"))
        request.httpMethod = "POST"
        let (data, _) = try await Self.session.data(for: request)
        let reply = try JSONDecoder().decode(SimpleReply.self, from: data)
        guard reply.ok else { throw APIError.server(reply.error ?? "restart") }
    }
}
