// SPDX-FileCopyrightText: 2026 GodSeon
// SPDX-License-Identifier: MIT

import Foundation

/// The app was called VmWifi before 2026-11. Its settings are carried over
/// once, its passwords on first use (CredentialStore), and its root helper
/// is replaced by install.sh.
enum LegacyVmWifi {
    static let bundleID = "io.github.afy0817.VmWifi"
    static let keychainService = bundleID
    static let helperPlist = "/Library/LaunchDaemons/io.github.afy0817.vmwifi.routed.plist"

    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VmWifi", isDirectory: true)
    }

    static var helperInstalled: Bool {
        FileManager.default.fileExists(atPath: helperPlist)
    }

    private static let migratedKey = "MigratedFromVmWifi"
    private static let keys = ["GuestToken", "Country", "RoutingMode", "ExtraRoutes", "SavedNetworks", "ThruRNDISBackup"]

    /// Copies the old preferences (saved networks, guest token, routing,
    /// the ThruRNDIS settings backup) where this app has none of its own.
    static func migrateDefaults() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedKey) else { return }
        if let old = defaults.persistentDomain(forName: bundleID) {
            for key in keys where defaults.object(forKey: key) == nil {
                if let value = old[key] { defaults.set(value, forKey: key) }
            }
        }
        defaults.set(true, forKey: migratedKey)
    }

    /// The old copy of the VM image and routes.conf are unused once
    /// ThruRNDIS boots the new image and the old helper is gone.
    static func removeSupportDirectoryIfUnused(applied: Bool) {
        guard applied, !helperInstalled,
              FileManager.default.fileExists(atPath: supportDirectory.path) else { return }
        try? FileManager.default.removeItem(at: supportDirectory)
    }
}
