// SPDX-FileCopyrightText: 2026 GodSeon
// SPDX-License-Identifier: MIT

import Darwin
import Foundation

enum RoutingMode: String, CaseIterable, Identifiable {
    case split, full, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .split: return "지정 대역만"
        case .full: return "전체 트래픽"
        case .off: return "끔"
        }
    }
}

/// The root route daemon (helper/thrurndis-wifi-routed) is installed once with an
/// administrator prompt; afterwards the app only rewrites its config file.
enum RouteHelper {
    static let label = "io.github.afy0817.thrurndis-wifi.routed"
    static let plistPath = "/Library/LaunchDaemons/\(label).plist"

    static var configURL: URL {
        ThruRNDISBridge.supportDirectory.appendingPathComponent("routes.conf")
    }

    private static let installedDaemonPath = "/usr/local/libexec/thrurndis-wifi-routed"
    private static let installedFiles = ["thrurndis-wifi-routed", "thrurndis-wifi-rank"]
    private static let statusPath = "/var/run/thrurndis-wifi-routed.status"

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
            && FileManager.default.fileExists(atPath: installedDaemonPath)
    }

    /// The installed helper files differ from the ones bundled in this build.
    static var isOutdated: Bool {
        guard let bundled = Bundle.main.url(forResource: "helper", withExtension: nil) else { return false }
        return installedFiles.contains { name in
            let current = FileManager.default.contents(atPath: "/usr/local/libexec/\(name)")
            return current == nil || (try? Data(contentsOf: bundled.appendingPathComponent(name))) != current
        }
    }

    struct DaemonStatus: Equatable {
        /// Interface of the Mac's default route.
        var primary: String?
        /// Requested routes left alone because another gateway already has them.
        var conflicts: [(cidr: String, gateway: String)] = []

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.primary == rhs.primary
                && lhs.conflicts.map { "\($0.cidr) \($0.gateway)" } == rhs.conflicts.map { "\($0.cidr) \($0.gateway)" }
        }
    }

    static func daemonStatus() -> DaemonStatus {
        var status = DaemonStatus()
        guard let text = try? String(contentsOfFile: statusPath, encoding: .utf8) else { return status }
        for line in text.split(separator: "\n") {
            if line.hasPrefix("primary=") {
                let value = line.dropFirst("primary=".count)
                status.primary = value.isEmpty ? nil : String(value)
            } else if line.hasPrefix("conflict=") {
                let parts = line.dropFirst("conflict=".count).split(separator: " ")
                if let cidr = parts.first {
                    status.conflicts.append((String(cidr), parts.count > 1 ? String(parts[1]) : "?"))
                }
            }
        }
        return status
    }

    /// ThruRNDIS's helper owns 192.168.100.2 on its Bond while routing is up.
    static var hostLinkUp: Bool {
        localIPv4Addresses().contains { $0.address == "192.168.100.2" }
    }

    /// Every IPv4 address configured on this Mac, with its interface name.
    static func localIPv4Addresses() -> [(interface: String, address: String)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [(interface: String, address: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            if let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    result.append((String(cString: entry.pointee.ifa_name), String(cString: host)))
                }
            }
            cursor = entry.pointee.ifa_next
        }
        return result
    }

    static func writeConfig(mode: RoutingMode, routes: [String]) throws {
        try FileManager.default.createDirectory(at: ThruRNDISBridge.supportDirectory, withIntermediateDirectories: true)
        var lines = ["mode=\(mode.rawValue)"]
        lines += routes.map { "route=\($0)" }
        let text = lines.joined(separator: "\n") + "\n"
        if (try? String(contentsOf: configURL, encoding: .utf8)) == text { return }
        try text.write(to: configURL, atomically: true, encoding: .utf8)
    }

    /// "10.0.0.5/24, 192.168.50.0/24" -> canonical network CIDRs; nil if any entry is invalid.
    static func parseCIDRList(_ text: String) -> [String]? {
        var result: [String] = []
        for token in text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }) {
            guard let cidr = canonicalCIDR(String(token)) else { return nil }
            if !result.contains(cidr) { result.append(cidr) }
        }
        return result
    }

    static func canonicalCIDR(_ text: String) -> String? {
        let parts = text.split(separator: "/")
        let prefix: Int
        if parts.count == 1 {
            prefix = 32
        } else if parts.count == 2, let value = Int(parts[1]), (1...32).contains(value) {
            prefix = value
        } else {
            return nil
        }
        guard let address = IPv4.parse(parts[0]) else { return nil }
        return "\(IPv4.format(address & IPv4.mask(prefix)))/\(prefix)"
    }

    static func install() async throws {
        guard let helper = Bundle.main.url(forResource: "helper", withExtension: nil) else {
            throw HelperError.missingBundle
        }
        try writeConfigIfMissing()
        try await runAsAdministrator([
            "/bin/sh", helper.appendingPathComponent("install.sh").path,
            helper.appendingPathComponent("thrurndis-wifi-routed").path, configURL.path,
        ])
    }

    static func uninstall() async throws {
        guard let helper = Bundle.main.url(forResource: "helper", withExtension: nil) else {
            throw HelperError.missingBundle
        }
        try await runAsAdministrator(["/bin/sh", helper.appendingPathComponent("uninstall.sh").path])
    }

    private static func writeConfigIfMissing() throws {
        if !FileManager.default.fileExists(atPath: configURL.path) {
            try writeConfig(mode: .split, routes: [])
        }
    }

    private static func runAsAdministrator(_ arguments: [String]) async throws {
        func appleScriptQuoted(_ value: String) -> String {
            "quoted form of \"" + value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let command = arguments.map(appleScriptQuoted).joined(separator: " & \" \" & ")
        let script = "do shell script \(command) with administrator privileges"

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let errorPipe = Pipe()
            process.standardError = errorPipe
            process.standardOutput = FileHandle.nullDevice
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    continuation.resume(throwing: HelperError.failed(message.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    enum HelperError: LocalizedError {
        case missingBundle
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .missingBundle: return "앱 번들에 라우팅 도우미 파일이 없습니다."
            case .failed(let message):
                return message.contains("-128") ? "취소했습니다." : "도우미 작업 실패: \(message)"
            }
        }
    }
}
