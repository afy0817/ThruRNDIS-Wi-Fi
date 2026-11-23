// SPDX-FileCopyrightText: 2026 GodSeon
// SPDX-License-Identifier: MIT

import Foundation

/// What this build is: the app's version (Info.plist, which app/build_app.sh fills from the git
/// tag and commit) and the VM image it carries, a GodseonDongle-VM release (vm_assets/manifest.json).
enum BuildInfo {
    struct Image: Equatable {
        var version: String
        var kernel: String
        var commit: String

        /// manifest.json of a VM asset folder; nil when it is missing or unreadable.
        init?(manifest url: URL) {
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = json["version"] as? String, !version.isEmpty
            else { return nil }
            self.version = version
            kernel = json["kernel"] as? String ?? ""
            commit = json["commit"] as? String ?? ""
        }
    }

    static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    /// Short git commit the app was built from ("-dirty" with uncommitted changes); empty for a
    /// build outside a git checkout.
    static let appCommit = Bundle.main.object(forInfoDictionaryKey: "ThruRNDISWiFiCommit") as? String ?? ""
    static let bundledImage: Image? = Bundle.main
        .url(forResource: "manifest", withExtension: "json", subdirectory: "vm_assets")
        .flatMap { Image(manifest: $0) }

    /// "0.3.0 (7d44a4b)"
    static var appLabel: String { appCommit.isEmpty ? appVersion : "\(appVersion) (\(appCommit))" }
}
