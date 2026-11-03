// SPDX-FileCopyrightText: 2026 GodSeon
// SPDX-License-Identifier: MIT

import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var thrurndisInstalled = false
    @Published private(set) var thrurndisRunning = false
    @Published private(set) var applied = false
    /// ThruRNDIS boots an older VM image than the one in this app.
    @Published private(set) var assetsOutdated = false
    @Published private(set) var guestHost: String?
    @Published private(set) var status: GuestAPI.Status?
    @Published private(set) var scanResults: [GuestAPI.ScanResult] = []
    @Published private(set) var scanning = false
    @Published private(set) var busy: String?
    @Published private(set) var helperInstalled = false
    @Published private(set) var helperOutdated = false
    @Published private(set) var hostLinkUp = false
    @Published private(set) var daemonStatus = RouteHelper.DaemonStatus()
    /// The Mac interface holding 192.168.100.2 (ThruRNDIS's Bond) while up.
    @Published private(set) var hostLinkInterface: String?
    @Published private(set) var savedNetworks: [CredentialStore.Entry] = []
    @Published var lastError: String?

    @Published var routingMode: RoutingMode {
        didSet {
            UserDefaults.standard.set(routingMode.rawValue, forKey: "RoutingMode")
            syncRoutes()
        }
    }
    @Published var extraRoutesText: String {
        didSet {
            UserDefaults.standard.set(extraRoutesText, forKey: "ExtraRoutes")
            syncRoutes()
        }
    }

    let token: String
    let country: String
    private var pollTask: Task<Void, Never>?
    private var autoConnectArmed = true
    private var userDisconnected = false
    private var lastBootID: String?

    init() {
        LegacyVmWifi.migrateDefaults()
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "GuestToken"), !saved.isEmpty {
            token = saved
        } else {
            var bytes = [UInt8](repeating: 0, count: 16)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            token = Hex.encode(Data(bytes))
            defaults.set(token, forKey: "GuestToken")
        }
        country = defaults.string(forKey: "Country") ?? "KR"
        routingMode = RoutingMode(rawValue: defaults.string(forKey: "RoutingMode") ?? "") ?? .split
        extraRoutesText = defaults.string(forKey: "ExtraRoutes") ?? ""
        savedNetworks = CredentialStore.entries()
        startPolling()
    }

    var api: GuestAPI? {
        guestHost.map { GuestAPI(host: $0, token: token) }
    }

    var extraRoutes: [String]? { RouteHelper.parseCIDRList(extraRoutesText) }

    /// Routes the daemon should keep: in split mode the dongle's own subnet
    /// and the extra routes saved for that network, plus whatever the user
    /// listed.
    var desiredRoutes: [String] {
        var routes: [String] = []
        if routingMode == .split, let status, status.uplink == "wlan0", status.isAssociated,
           let subnet = status.subnetCIDR {
            routes.append(subnet)
            let extra = savedNetworks.first { $0.ssid == status.ssid }?.staticIPv4?.routes ?? []
            for route in extra where !routes.contains(route.destination) {
                routes.append(route.destination)
            }
        }
        for cidr in extraRoutes ?? [] where !routes.contains(cidr) {
            routes.append(cidr)
        }
        return routes
    }

    // MARK: Polling

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func refresh() async {
        thrurndisInstalled = ThruRNDISBridge.isInstalled
        thrurndisRunning = ThruRNDISBridge.isRunning
        applied = ThruRNDISBridge.isApplied(token: token)
        assetsOutdated = applied && ThruRNDISBridge.bundledAssetsDiffer
        // A helper installed under the former name counts as installed but
        // outdated, so the menu offers to replace it.
        helperInstalled = RouteHelper.isInstalled || LegacyVmWifi.helperInstalled
        helperOutdated = LegacyVmWifi.helperInstalled || (helperInstalled && RouteHelper.isOutdated)
        LegacyVmWifi.removeSupportDirectoryIfUnused(applied: applied)
        let hostLink = RouteHelper.localIPv4Addresses().first { $0.address == "192.168.100.2" }?.interface
        if hostLink != hostLinkInterface { hostLinkInterface = hostLink }
        hostLinkUp = hostLink != nil
        let daemon = RouteHelper.daemonStatus()
        if daemon != daemonStatus { daemonStatus = daemon }

        guard applied, thrurndisRunning, let host = ThruRNDISBridge.guestAddress() else {
            guestLost()
            return
        }
        guestHost = host
        do {
            let fresh = try await GuestAPI(host: host, token: token).status()
            if fresh != status { status = fresh }
            await autoConnectIfNeeded(fresh)
        } catch {
            guestLost()
        }
        syncRoutes()
    }

    private func guestLost() {
        if status != nil { status = nil }
        if !scanResults.isEmpty { scanResults = [] }
        autoConnectArmed = true
    }

    /// A freshly booted guest has no network configured; hand it the most
    /// recently used saved network once per VM session. A new boot_id marks
    /// a new session even when a quick ThruRNDIS restart never made the
    /// guest unreachable between two polls.
    private func autoConnectIfNeeded(_ status: GuestAPI.Status) async {
        if let boot = status.boot_id, !boot.isEmpty, boot != lastBootID {
            lastBootID = boot
            autoConnectArmed = true
        }
        guard autoConnectArmed, status.device else { return }
        autoConnectArmed = false
        guard status.configured_ssid_hex.isEmpty, !userDisconnected,
              let entry = savedNetworks.first,
              let credential = CredentialStore.credential(for: entry.ssid) else { return }
        try? await api?.connect(credential)
    }

    /// The guest keeps ThruRNDIS's host link up across Wi-Fi drops, so
    /// nothing is routed into it until its uplink is ready again; the daemon
    /// then only keeps the Bond from becoming primary. An unreachable guest
    /// keeps the last config (a missed poll must not make routes blink).
    private func syncRoutes() {
        guard let status else { return }
        if status.route_ready {
            try? RouteHelper.writeConfig(mode: routingMode, routes: desiredRoutes)
        } else {
            try? RouteHelper.writeConfig(mode: .off, routes: [])
        }
    }

    // MARK: Actions

    private func perform(_ label: String, _ work: () async throws -> Void) async {
        busy = label
        lastError = nil
        do {
            try await work()
        } catch {
            lastError = error.localizedDescription
        }
        busy = nil
        await refresh()
    }

    func applyToThruRNDIS() async {
        await perform("ThruRNDIS 에 적용하는 중…") {
            try await ThruRNDISBridge.apply(token: token, country: country)
        }
    }

    func restoreThruRNDIS() async {
        await perform("ThruRNDIS 설정을 되돌리는 중…") {
            try await ThruRNDISBridge.restore()
        }
    }

    func scan() async {
        guard let api, !scanning else { return }
        scanning = true
        lastError = nil
        do {
            scanResults = Self.strongestPerSSID(try await api.scan(trigger: true))
        } catch {
            lastError = error.localizedDescription
        }
        scanning = false
    }

    func loadCachedResults() async {
        guard let api, scanResults.isEmpty else { return }
        if let results = try? await api.scan(trigger: false), !results.isEmpty {
            scanResults = Self.strongestPerSSID(results)
        }
    }

    func connect(_ credential: WiFiCredential) async {
        await perform("\(credential.ssid) 에 연결하는 중…") {
            try credential.validate()
            guard let api else { throw GuestAPI.APIError.server("no-wifi-device") }
            try await api.connect(credential)
            CredentialStore.save(credential)
            savedNetworks = CredentialStore.entries()
            userDisconnected = false
        }
    }

    func connectSaved(_ ssid: String) async {
        guard let credential = CredentialStore.credential(for: ssid) else { return }
        await connect(credential)
    }

    func disconnect() async {
        await perform("연결을 끊는 중…") {
            try await api?.disconnect()
            userDisconnected = true
        }
    }

    func forget(_ ssid: String) {
        CredentialStore.remove(ssid)
        savedNetworks = CredentialStore.entries()
    }

    /// Saves a new password; reconnects when that network is the one the
    /// guest is currently configured for.
    func updatePassword(_ ssid: String, password: String) async {
        guard let entry = savedNetworks.first(where: { $0.ssid == ssid }) else { return }
        let credential = WiFiCredential(ssid: ssid, password: password, hidden: entry.hidden,
                                        staticIPv4: entry.staticIPv4)
        if status?.configuredSSID == ssid {
            await connect(credential)
        } else {
            do {
                try credential.validate()
                CredentialStore.save(credential)
                savedNetworks = CredentialStore.entries()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// Switches a saved network between DHCP (empty address) and a static
    /// address; reconnects when the guest is configured for it.
    func updateStaticIPv4(_ ssid: String, _ fields: StaticIPv4Fields) async {
        let staticIPv4: StaticIPv4?
        do {
            staticIPv4 = try fields.parse()
        } catch {
            lastError = error.localizedDescription
            return
        }
        lastError = nil
        CredentialStore.setStaticIPv4(staticIPv4, for: ssid)
        savedNetworks = CredentialStore.entries()
        if status?.configuredSSID == ssid {
            await connectSaved(ssid)
        }
    }

    /// ThruRNDIS's Bond carries the Mac's default route; the helper keeps
    /// it from doing so in every mode.
    var dongleIsPrimary: Bool {
        guard let hostLinkInterface else { return false }
        return daemonStatus.primary == hostLinkInterface
    }

    /// The configured network's static address, when this Mac itself holds
    /// it on another interface (e.g. its own Wi-Fi joined the same network
    /// with the same manual address).
    var localConflictInterface: String? {
        guard let status, let address = savedNetworks.first(where: { $0.ssid == status.configuredSSID })?
            .staticIPv4?.address else { return nil }
        return RouteHelper.localIPv4Addresses().first { $0.address == address }?.interface
    }

    func installHelper() async {
        await perform("라우팅 도우미 설치 중…") {
            syncRoutes()
            try await RouteHelper.install()
        }
    }

    func uninstallHelper() async {
        await perform("라우팅 도우미 제거 중…") {
            try await RouteHelper.uninstall()
        }
    }

    func openThruRNDIS() {
        Task { try? await ThruRNDISBridge.launch() }
    }

    private static func strongestPerSSID(_ results: [GuestAPI.ScanResult]) -> [GuestAPI.ScanResult] {
        var best: [String: GuestAPI.ScanResult] = [:]
        for result in results where !result.ssid_hex.isEmpty {
            if let current = best[result.ssid_hex], current.signal >= result.signal { continue }
            best[result.ssid_hex] = result
        }
        return best.values.sorted { $0.signal > $1.signal }
    }
}

/// Transient join-form input. Kept in an ObservableObject because the
/// Command Line Tools toolchain lacks the SwiftUI macro plugin behind @State.
@MainActor
final class JoinForm: ObservableObject {
    @Published var selectedSSID: String?
    @Published var password = ""
    @Published var showHidden = false
    @Published var hiddenSSID = ""
    @Published var editingSSID: String?
    @Published var editPassword = ""
    @Published var showSaved = false
    @Published var editingIPSSID: String?
    /// The join forms' "고정 IP" disclosure.
    @Published var joinStaticIP = false
    @Published var ip = StaticIPv4Fields()
}

/// Text of the static IPv4 editor; an empty address means DHCP.
struct StaticIPv4Fields: Equatable {
    var address = ""
    var subnet = ""
    var gateway = ""
    var dns = ""
    var routes: [RouteRow] = []

    /// One 대역 → 게이트웨이 row of the extra routes editor.
    struct RouteRow: Equatable, Identifiable {
        let id = UUID()
        var destination = ""
        var gateway = ""
    }

    init() {}

    init(_ staticIPv4: StaticIPv4?) {
        guard let staticIPv4 else { return }
        address = staticIPv4.address
        subnet = staticIPv4.subnetMask
        gateway = staticIPv4.gateway ?? ""
        dns = staticIPv4.dns.joined(separator: ", ")
        routes = staticIPv4.routes.map { RouteRow(destination: $0.destination, gateway: $0.gateway) }
    }

    func parse() throws -> StaticIPv4? {
        guard !address.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return try StaticIPv4(addressText: address, subnetText: subnet, gatewayText: gateway, dnsText: dns,
                              routeRows: routes.map { ($0.destination, $0.gateway) })
    }
}
