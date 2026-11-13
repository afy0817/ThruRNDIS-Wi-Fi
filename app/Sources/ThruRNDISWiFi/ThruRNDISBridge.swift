// SPDX-FileCopyrightText: 2026 GodSeon
// SPDX-License-Identifier: MIT

import AppKit
import Foundation

/// Everything ThruRNDIS-Wi-Fi does to the installed (officially signed) ThruRNDIS:
/// point its manual VM asset selection at the ThruRNDIS-Wi-Fi guest, add the ThruRNDIS-Wi-Fi
/// kernel arguments, restart it, and read its log to find the running guest.
/// ThruRNDIS itself is never modified; restore() puts its settings back.
enum ThruRNDISBridge {
    static let bundleID = "com.afcoo.thrurndis" as CFString

    private static let managedKeys = [
        "VMAssets.selectionSource",
        "VMAssets.folderURLPath",
        "VMAssets.kernelURLPath",
        "VMAssets.initialRamdiskURLPath",
        "VMAssets.kernelOverrideURLPath",
        "VMAssets.initialRamdiskOverrideURLPath",
        "VMAssets.managedReleaseDirectoryURLPath",
        "VM.kernelCommandLine",
    ]
    private static let backupKey = "ThruRNDISBackup"

    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ThruRNDIS-Wi-Fi", isDirectory: true)
    }

    static var assetsDirectory: URL {
        supportDirectory.appendingPathComponent("vm_assets", isDirectory: true)
    }

    private static var logsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.afcoo.thrurndis/Logs", isDirectory: true)
    }

    static var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID as String)
    }

    static var isInstalled: Bool { appURL != nil }

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID as String).isEmpty
    }

    private static func value(_ key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, bundleID)
    }

    private static func set(_ key: String, _ value: Any?) {
        CFPreferencesSetAppValue(key as CFString, value as CFPropertyList?, bundleID)
    }

    static var kernelCommandLine: String {
        (value("VM.kernelCommandLine") as? String) ?? ""
    }

    /// True when ThruRNDIS will boot the ThruRNDIS-Wi-Fi guest with our token.
    static func isApplied(token: String) -> Bool {
        (value("VMAssets.folderURLPath") as? String) == assetsDirectory.standardizedFileURL.path
            && kernelCommandLine.split(separator: " ").contains("thrurndis-wifi.token=\(token)")
    }

    // MARK: Assets

    /// The guest bundled in this app differs from the copy ThruRNDIS boots,
    /// e.g. after an app update or a rebuild with more drivers.
    static var bundledAssetsDiffer: Bool {
        guard let bundled = Bundle.main.url(forResource: "vm_assets", withExtension: nil),
              let bundledSums = try? Data(contentsOf: bundled.appendingPathComponent("SHA256SUMS"))
        else { return false }
        return (try? Data(contentsOf: assetsDirectory.appendingPathComponent("SHA256SUMS"))) != bundledSums
    }

    /// Copies the guest bundled in ThruRNDIS-Wi-Fi.app when the installed copy differs.
    static func installBundledAssets() throws {
        guard let bundled = Bundle.main.url(forResource: "vm_assets", withExtension: nil) else {
            throw BridgeError.missingBundledAssets
        }
        let fileManager = FileManager.default
        let installedSums = try? Data(contentsOf: assetsDirectory.appendingPathComponent("SHA256SUMS"))
        let bundledSums = try Data(contentsOf: bundled.appendingPathComponent("SHA256SUMS"))
        if installedSums == bundledSums { return }

        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let staging = supportDirectory.appendingPathComponent("vm_assets.staging", isDirectory: true)
        try? fileManager.removeItem(at: staging)
        try fileManager.copyItem(at: bundled, to: staging)
        try? fileManager.removeItem(at: assetsDirectory)
        try fileManager.moveItem(at: staging, to: assetsDirectory)
    }

    // MARK: Apply / restore

    static func apply(token: String, country: String) async throws {
        guard isInstalled else { throw BridgeError.notInstalled }
        try installBundledAssets()
        try await quit()

        if UserDefaults.standard.dictionary(forKey: backupKey) == nil {
            var backup: [String: Any] = [:]
            for key in managedKeys {
                if let value = value(key) { backup[key] = value }
            }
            UserDefaults.standard.set(backup, forKey: backupKey)
        }

        let folder = assetsDirectory.standardizedFileURL
        set("VMAssets.selectionSource", "manual")
        set("VMAssets.folderURLPath", folder.path)
        set("VMAssets.kernelURLPath", folder.appendingPathComponent("Image-lts").path)
        set("VMAssets.initialRamdiskURLPath", folder.appendingPathComponent("initramfs-thrurndis-wifi").path)
        set("VMAssets.kernelOverrideURLPath", nil)
        set("VMAssets.initialRamdiskOverrideURLPath", nil)
        set("VMAssets.managedReleaseDirectoryURLPath", nil)
        set("VM.kernelCommandLine", "console=hvc0 thrurndis-wifi.token=\(token) thrurndis-wifi.country=\(country)")
        CFPreferencesAppSynchronize(bundleID)
        try await launch()
    }

    static func restore() async throws {
        guard let backup = UserDefaults.standard.dictionary(forKey: backupKey) else { throw BridgeError.noBackup }
        let wasRunning = isRunning
        try await quit()
        for key in managedKeys {
            set(key, backup[key])
        }
        CFPreferencesAppSynchronize(bundleID)
        UserDefaults.standard.removeObject(forKey: backupKey)
        if wasRunning { try await launch() }
    }

    static func quit() async throws {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID as String)
        guard !running.isEmpty else { return }
        running.forEach { $0.terminate() }
        // While a USB device is attached or routing is up, ThruRNDIS asks before
        // quitting and then spends up to 9 s cleaning up; leave time to answer.
        for _ in 0..<240 {
            if running.allSatisfy(\.isTerminated) { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw BridgeError.quitTimedOut
    }

    static func launch() async throws {
        guard let appURL else { throw BridgeError.notInstalled }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        // Right after quit() LaunchServices can still be tearing down the old
        // instance and refuses the launch (-609), so try a few more times.
        for attempt in 1...6 {
            do {
                _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
                return
            } catch where attempt < 6 {
                try await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: Guest discovery

    /// The guest's VZNAT address from the newest ThruRNDIS log, falling back
    /// to the vmnet DHCP lease of ThruRNDIS's fixed guest MAC.
    static func guestAddress() -> String? {
        if let fromLog = guestAddressFromLog() { return fromLog }
        return guestAddressFromLeases()
    }

    private static func guestAddressFromLog() -> String? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: logsDirectory.path) else { return nil }
        // A session logs to <yyyyMMdd-HHmmss>.log, then -2.log, -3.log, ... as it rotates; plain
        // name order would sort its later files before the first. Older sessions are a past VM.
        let logs = names.filter { $0.hasSuffix(".log") }.map { name -> (stem: String, sequence: Int, name: String) in
            let base = name.dropLast(4)
            let rest = base.dropFirst(15)
            return (String(base.prefix(15)), rest.hasPrefix("-") ? Int(rest.dropFirst()) ?? 0 : 1, name)
        }.sorted { ($0.stem, $0.sequence) < ($1.stem, $1.sequence) }
        guard let session = logs.last?.stem else { return nil }
        for log in logs.reversed() where log.stem == session {
            if let address = guestAddress(inLog: log.name) { return address }
        }
        return nil
    }

    private static func guestAddress(inLog name: String) -> String? {
        guard let text = try? String(contentsOf: logsDirectory.appendingPathComponent(name), encoding: .utf8)
        else { return nil }
        let marker = "Guest VZNAT network discovered: guest="
        guard let line = text.components(separatedBy: "\n").last(where: { $0.contains(marker) }),
              let range = line.range(of: marker) else { return nil }
        let address = line[range.upperBound...].prefix { $0.isNumber || $0 == "." }
        return address.isEmpty ? nil : String(address)
    }

    private static func guestAddressFromLeases() -> String? {
        guard let text = try? String(contentsOfFile: "/var/db/dhcpd_leases", encoding: .utf8) else { return nil }
        var address: String?
        for block in text.components(separatedBy: "}") {
            guard block.contains("hw_address=1,2:0:5e:10:0:2\n") else { continue }
            if let line = block.components(separatedBy: "\n").first(where: { $0.contains("ip_address=") }) {
                address = line.components(separatedBy: "=").last?.trimmingCharacters(in: .whitespaces)
            }
        }
        return address
    }

    enum BridgeError: LocalizedError {
        case notInstalled, missingBundledAssets, quitTimedOut, noBackup
        var errorDescription: String? {
            switch self {
            case .notInstalled: return "ThruRNDIS 가 설치되어 있지 않습니다. (brew install --cask afcoo/tap/thrurndis)"
            case .missingBundledAssets: return "앱에 VM 이미지가 들어 있지 않습니다. build_app.sh 로 다시 빌드하세요."
            case .quitTimedOut:
                return "ThruRNDIS 가 종료되지 않았습니다. ThruRNDIS 가 종료를 물으면 'ThruRNDIS 종료' 를 누른 뒤 다시 시도하세요."
            case .noBackup: return "되돌릴 원래 설정이 없습니다. ThruRNDIS 설정의 VM 에셋에서 이미지를 직접 고르세요."
            }
        }
    }
}
