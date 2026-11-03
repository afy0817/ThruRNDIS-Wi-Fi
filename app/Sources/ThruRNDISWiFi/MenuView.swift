// SPDX-FileCopyrightText: 2026 GodSeon
// SPDX-License-Identifier: MIT

import SwiftUI

struct MenuView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var form: JoinForm

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            setupSection
            if model.assetsOutdated {
                notice("앱에 새 VM 이미지가 들어 있습니다.",
                       detail: "업데이트하면 ThruRNDIS 가 재시작되고 동글 연결이 잠시 끊겼다가 다시 붙습니다.")
                Button("VM 이미지 업데이트") { Task { await model.applyToThruRNDIS() } }
                    .disabled(model.busy != nil)
            }
            if let status = model.status, status.device {
                connectionSection(status)
                networksSection
                Divider()
                routingSection
            }
            if let busy = model.busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.caption)
                }
            }
            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
        .task { await model.loadCachedResults() }
    }

    // MARK: Sections

    private var header: some View {
        HStack {
            Image(systemName: headerSymbol).foregroundStyle(headerColor)
            Text("ThruRNDIS-Wi-Fi").font(.headline)
            Spacer()
            Text(headerText).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var setupSection: some View {
        if !model.thrurndisInstalled {
            notice("ThruRNDIS 가 필요합니다.", detail: "터미널에서 brew install --cask afcoo/tap/thrurndis")
        } else if !model.applied {
            notice("ThruRNDIS 에 ThruRNDIS-Wi-Fi VM 이미지를 적용해야 합니다.",
                   detail: "ThruRNDIS 가 재시작되고, 원래 설정은 백업됩니다.")
            Button("ThruRNDIS 에 적용") { Task { await model.applyToThruRNDIS() } }
                .disabled(model.busy != nil)
        } else if !model.thrurndisRunning {
            notice("ThruRNDIS 가 실행 중이 아닙니다.", detail: nil)
            Button("ThruRNDIS 실행") { model.openThruRNDIS() }
        } else if model.status == nil {
            notice("VM 이 아직 실행되지 않았습니다.",
                   detail: "메뉴 막대의 '가상 머신 액세서리' 에서 USB Wi-Fi 동글을 ThruRNDIS 로 넘기세요.")
        } else if let id = model.status?.usb_unsupported, !id.isEmpty {
            notice("USB 장치 \(id) 를 맡을 드라이버가 VM 에 없습니다.",
                   detail: "지원하지 않는 동글입니다. vm/drivers.conf 에 드라이버를 추가해 다시 빌드할 수 있습니다(README 의 '다른 동글 쓰기').")
        } else if model.status?.device == false {
            notice("VM 은 실행 중이지만 동글이 연결되지 않았습니다.",
                   detail: "'가상 머신 액세서리' 에서 USB Wi-Fi 동글을 ThruRNDIS 로 넘기세요.")
        }
    }

    private func connectionSection(_ status: GuestAPI.Status) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if status.isAssociated {
                HStack {
                    SignalBars(dBm: status.rssi)
                    Text(status.ssid).fontWeight(.semibold)
                    Spacer()
                    Button("연결 끊기") { Task { await model.disconnect() } }
                        .controlSize(.small)
                }
                Text(addressLine(status)).font(.caption).foregroundStyle(.secondary)
                if status.hasIPConflict {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(conflictText(status)).font(.caption).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("다시 시도") { Task { await model.connectSaved(status.configuredSSID) } }
                            .controlSize(.small)
                    }
                } else if status.ipv4.isEmpty {
                    Text("DHCP 서버가 없는 망이면 저장된 네트워크의 'IP' 에서 주소를 직접 지정하세요.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if !status.configured_ssid_hex.isEmpty {
                HStack {
                    if status.auth_error?.isEmpty ?? true {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Text(connectingText(status)).font(.callout)
                    Spacer()
                    Button("취소") { Task { await model.disconnect() } }.controlSize(.small)
                }
                if status.auth_error == "wrong-key" {
                    HStack {
                        SecureField("비밀번호 다시 입력", text: $form.editPassword)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { retryPassword(status.configuredSSID) }
                        Button("다시 연결") { retryPassword(status.configuredSSID) }
                            .disabled(form.editPassword.isEmpty)
                    }
                }
            } else {
                Text("연결된 네트워크 없음").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var networksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("네트워크").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if model.scanning { ProgressView().controlSize(.small) }
                Button("검색") { Task { await model.scan() } }
                    .controlSize(.small)
                    .disabled(model.scanning)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.scanResults) { network in
                        networkRow(network)
                    }
                }
            }
            // A ScrollView inside the menu window collapses to its minimum
            // unless it gets an explicit height.
            .frame(height: listHeight)
            hiddenNetworkRow
            savedNetworksSection
        }
    }

    private var listHeight: CGFloat {
        let rows = CGFloat(model.scanResults.count) * 26
        let routeRows = CGFloat(form.ip.routes.count) * 28 + (form.ip.routes.isEmpty ? 0 : 18)
        let editor: CGFloat = form.selectedSSID == nil ? 0 : 54 + (form.joinStaticIP ? 200 + routeRows : 0)
        return min(max(rows + editor, 26), 480)
    }

    @ViewBuilder
    private var savedNetworksSection: some View {
        if !model.savedNetworks.isEmpty {
            Button(form.showSaved ? "저장된 네트워크 닫기" : "저장된 네트워크 (\(model.savedNetworks.count))…") {
                form.showSaved.toggle()
                form.editingSSID = nil
                form.editPassword = ""
                form.editingIPSSID = nil
            }
            .buttonStyle(.link)
            .font(.caption)
            if form.showSaved {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.savedNetworks) { entry in
                        savedRow(entry)
                    }
                }
            }
        }
    }

    private func savedRow(_ entry: CredentialStore.Entry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Text(entry.ssid)
                        if entry.hidden { Text("숨김").font(.caption2).foregroundStyle(.secondary) }
                    }
                    if let staticIPv4 = entry.staticIPv4 {
                        Text("고정 \(staticIPv4.cidr)" + (staticIPv4.routes.isEmpty ? "" : " · 추가 경로 \(staticIPv4.routes.count)"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("연결") { Task { await model.connectSaved(entry.ssid) } }
                Button("비밀번호") {
                    form.editingSSID = form.editingSSID == entry.ssid ? nil : entry.ssid
                    form.editingIPSSID = nil
                    form.editPassword = ""
                }
                Button("IP") { toggleIPEditor(entry) }
                Button("삭제", role: .destructive) {
                    if form.editingSSID == entry.ssid { form.editingSSID = nil }
                    if form.editingIPSSID == entry.ssid { form.editingIPSSID = nil }
                    model.forget(entry.ssid)
                }
            }
            .controlSize(.small)
            if form.editingSSID == entry.ssid {
                HStack {
                    SecureField("새 비밀번호", text: $form.editPassword)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { savePassword(entry.ssid) }
                    Button("저장") { savePassword(entry.ssid) }
                        .disabled(form.editPassword.isEmpty)
                }
            }
            if form.editingIPSSID == entry.ssid {
                ipEditor(entry.ssid)
            }
        }
    }

    private func ipEditor(_ ssid: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ipFields(addressPrompt: "예: 192.168.50.20 (비우면 DHCP)")
            HStack {
                Text("게이트웨이가 없으면 같은 대역으로만 통신합니다.")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("DHCP 로") {
                    form.ip = StaticIPv4Fields()
                    saveStaticIPv4(ssid)
                }
                Button("저장") { saveStaticIPv4(ssid) }
            }
        }
        .font(.caption)
        .controlSize(.small)
    }

    /// IP 주소 / 서브넷 마스크 / 게이트웨이 / DNS, shared by the saved-network
    /// editor and the join forms. One field per line with its name above, so
    /// a filled-in value still says what it is.
    private func ipFields(addressPrompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            labeledField("IP 주소", prompt: addressPrompt, text: $form.ip.address)
            labeledField("서브넷 마스크", prompt: "255.255.255.0 (비우면 /24)", text: $form.ip.subnet)
            labeledField("게이트웨이 (선택)", prompt: "예: 192.168.50.1", text: $form.ip.gateway)
            labeledField("DNS (선택, 쉼표로 구분)", prompt: "예: 1.1.1.1, 8.8.8.8", text: $form.ip.dns)
            routeRows
        }
        .font(.caption)
    }

    /// 추가 경로 as a small table: 대역 (from) → 게이트웨이 (to) per row,
    /// + adds a row and − removes it.
    private var routeRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("추가 경로 (선택)").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button {
                    form.ip.routes.append(StaticIPv4Fields.RouteRow())
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(form.ip.routes.count >= 8)
                .help("경로 추가")
            }
            if !form.ip.routes.isEmpty {
                HStack(spacing: 4) {
                    Text("대역").frame(maxWidth: .infinity, alignment: .leading)
                    Text("→").hidden()
                    Text("게이트웨이").frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "minus.circle").hidden()
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            ForEach($form.ip.routes) { $row in
                HStack(spacing: 4) {
                    TextField("10.10.0.0/24", text: $row.destination).textFieldStyle(.roundedBorder)
                    Text("→").foregroundStyle(.secondary)
                    TextField("192.168.50.254", text: $row.gateway).textFieldStyle(.roundedBorder)
                    Button {
                        form.ip.routes.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("경로 삭제")
                }
            }
        }
    }

    private func labeledField(_ title: String, prompt: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            TextField(prompt, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private var joinStaticIPToggle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(form.joinStaticIP ? "DHCP 로 받기" : "고정 IP 직접 입력…") {
                form.joinStaticIP.toggle()
                form.ip = StaticIPv4Fields()
            }
            .buttonStyle(.link)
            .font(.caption)
            if form.joinStaticIP {
                ipFields(addressPrompt: "예: 192.168.50.20")
            }
        }
    }

    private func networkRow(_ network: GuestAPI.ScanResult) -> some View {
        let saved = model.savedNetworks.contains { $0.ssid == network.ssid }
        let isCurrent = model.status?.isAssociated == true && model.status?.ssid == network.ssid
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                if saved || !network.isSecured {
                    Task {
                        if saved {
                            await model.connectSaved(network.ssid)
                        } else {
                            await model.connect(WiFiCredential(ssid: network.ssid, password: "", hidden: false))
                        }
                    }
                } else {
                    form.selectedSSID = form.selectedSSID == network.ssid ? nil : network.ssid
                    form.password = ""
                    form.joinStaticIP = false
                }
            } label: {
                HStack {
                    SignalBars(dBm: network.signal)
                    Text(network.ssid).fontWeight(isCurrent ? .semibold : .regular)
                    if isCurrent { Image(systemName: "checkmark").font(.caption) }
                    Spacer()
                    Text(network.freq >= 5900 ? "6GHz" : network.freq >= 4900 ? "5GHz" : "2.4GHz")
                        .font(.caption2).foregroundStyle(.secondary)
                    if network.isSecured { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                if saved { Button("이 네트워크 지우기") { model.forget(network.ssid) } }
            }

            if form.selectedSSID == network.ssid {
                HStack {
                    SecureField("비밀번호", text: $form.password)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { join(network.ssid, hidden: false) }
                    Button("연결") { join(network.ssid, hidden: false) }
                        .disabled(form.password.isEmpty)
                }
                joinStaticIPToggle
            }
        }
        .padding(.vertical, 2)
    }

    private var hiddenNetworkRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(form.showHidden ? "숨김 네트워크 닫기" : "다른 네트워크(숨김)…") {
                form.showHidden.toggle()
                form.hiddenSSID = ""
                form.password = ""
                form.joinStaticIP = false
            }
            .buttonStyle(.link)
            .font(.caption)
            if form.showHidden {
                TextField("SSID", text: $form.hiddenSSID).textFieldStyle(.roundedBorder)
                HStack {
                    SecureField("비밀번호 (개방망이면 비움)", text: $form.password).textFieldStyle(.roundedBorder)
                    Button("연결") { join(form.hiddenSSID, hidden: true) }.disabled(form.hiddenSSID.isEmpty)
                }
                joinStaticIPToggle
            }
        }
    }

    private var routingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("맥 라우팅").font(.subheadline).foregroundStyle(.secondary)
            Picker("", selection: $model.routingMode) {
                ForEach(RoutingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            TextField("추가 대역 (예: 10.0.0.0/24, 192.168.50.0/24)", text: $model.extraRoutesText)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            if model.extraRoutes == nil {
                Text("대역 형식이 잘못되었습니다.").font(.caption2).foregroundStyle(.red)
            }
            Text(routingSummary).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.hostLinkUp {
                ForEach(model.daemonStatus.conflicts, id: \.cidr) { conflict in
                    Text("\(conflict.cidr) 는 맥에 이미 \(conflict.gateway) 경로가 있어 동글로 돌리지 않았습니다.")
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.dongleIsPrimary {
                    Text("맥의 기본 경로가 동글 쪽(\(model.hostLinkInterface ?? ""))으로 넘어가 있습니다."
                         + (model.helperOutdated || !model.helperInstalled ? " 도우미를 설치/업데이트하세요." : ""))
                        .font(.caption2).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Label(helperLabel, systemImage: model.helperInstalled && !model.helperOutdated
                      ? "checkmark.shield" : "exclamationmark.shield")
                    .font(.caption)
                Spacer()
                if model.helperOutdated {
                    Button("업데이트 (관리자 암호)") { Task { await model.installHelper() } }.controlSize(.small)
                }
                if model.helperInstalled {
                    Button("제거") { Task { await model.uninstallHelper() } }.controlSize(.small)
                } else {
                    Button("설치 (관리자 암호)") { Task { await model.installHelper() } }.controlSize(.small)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("ThruRNDIS 열기") { model.openThruRNDIS() }.disabled(!model.thrurndisInstalled)
            if model.applied {
                Button("원래 이미지로") { Task { await model.restoreThruRNDIS() } }
                    .help("ThruRNDIS VM 설정을 ThruRNDIS-Wi-Fi 적용 전으로 되돌립니다.")
            }
            Spacer()
            Button("종료") { NSApplication.shared.terminate(nil) }
        }
        .controlSize(.small)
    }

    // MARK: Helpers

    private func retryPassword(_ ssid: String) {
        let password = form.editPassword
        form.editPassword = ""
        Task { await model.updatePassword(ssid, password: password) }
    }

    private func toggleIPEditor(_ entry: CredentialStore.Entry) {
        guard form.editingIPSSID != entry.ssid else {
            form.editingIPSSID = nil
            return
        }
        form.editingIPSSID = entry.ssid
        form.editingSSID = nil
        form.ip = StaticIPv4Fields(entry.staticIPv4)
    }

    private func saveStaticIPv4(_ ssid: String) {
        let fields = form.ip
        Task {
            await model.updateStaticIPv4(ssid, fields)
            if model.lastError == nil { form.editingIPSSID = nil }
        }
    }

    private func conflictText(_ status: GuestAPI.Status) -> String {
        let address = model.savedNetworks.first { $0.ssid == status.configuredSSID }?.staticIPv4?.address ?? "고정 IP"
        if let interface = model.localConflictInterface {
            return "이 맥의 \(interface) 가 이미 \(address) 를 쓰고 있어 주소를 붙이지 않았습니다. 맥 쪽 연결을 끊거나 다른 IP 를 지정하세요."
        }
        let owner = (status.ip_conflict_mac ?? "").isEmpty ? "다른 장치" : "다른 장치(\(status.ip_conflict_mac!))"
        return "\(owner)가 이미 \(address) 를 쓰고 있어 주소를 붙이지 않았습니다."
    }

    private func savePassword(_ ssid: String) {
        let password = form.editPassword
        form.editPassword = ""
        form.editingSSID = nil
        Task { await model.updatePassword(ssid, password: password) }
    }

    private func connectingText(_ status: GuestAPI.Status) -> String {
        switch status.auth_error {
        case "wrong-key": return "\(status.configuredSSID): 비밀번호가 틀린 것 같습니다"
        case "auth-failed": return "\(status.configuredSSID): 연결 실패, 재시도 중"
        case "not-found": return "\(status.configuredSSID) 를 찾는 중…"
        default: return "\(status.configuredSSID) 에 연결 중… (\(status.wpa_state))"
        }
    }

    private func join(_ ssid: String, hidden: Bool) {
        var credential = WiFiCredential(ssid: ssid, password: form.password, hidden: hidden)
        if form.joinStaticIP {
            do {
                credential.staticIPv4 = try form.ip.parse()
            } catch {
                model.lastError = error.localizedDescription
                return
            }
        }
        form.joinStaticIP = false
        form.selectedSSID = nil
        form.showHidden = false
        form.password = ""
        Task { await model.connect(credential) }
    }

    private func notice(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func addressLine(_ status: GuestAPI.Status) -> String {
        var parts: [String] = []
        if !status.ipv4.isEmpty {
            parts.append("\(status.ipv4)/\(status.prefix ?? 0)" + (status.isStatic ? " (고정)" : ""))
        }
        if !status.gateway.isEmpty { parts.append("GW \(status.gateway)") }
        if let freq = status.freq { parts.append("\(freq) MHz") }
        parts.append(status.route_ready ? "맥 연결 준비됨" : "맥 연결 준비 중")
        return parts.joined(separator: " · ")
    }

    private var routingSummary: String {
        guard model.helperInstalled else {
            return "도우미를 설치하면 아래 경로가 자동으로 잡힙니다."
        }
        guard model.hostLinkUp else {
            return "ThruRNDIS 연결(192.168.100.2) 대기 중"
        }
        if model.status?.route_ready == false {
            return "동글 망이 준비될 때까지 경로 없음 (맥 기본 경로 사용)"
        }
        switch model.routingMode {
        case .off:
            return "동글로 보내는 경로 없음 (맥 기본 경로는 내장 망 유지)"
        case .full:
            let extra = model.desiredRoutes
            return "모든 IPv4 → 동글" + (extra.isEmpty ? "" : " (+ \(extra.joined(separator: ", ")))")
        case .split:
            let routes = model.desiredRoutes
            return routes.isEmpty ? "동글로 보낼 대역 없음" : "동글로: \(routes.joined(separator: ", ")) · 나머지는 맥 기본 경로"
        }
    }

    private var helperLabel: String {
        if !model.helperInstalled { return "도우미 미설치" }
        return model.helperOutdated ? "도우미 업데이트 필요" : "도우미 설치됨"
    }

    private var headerText: String {
        if let status = model.status {
            if status.isAssociated { return status.route_ready ? "연결됨" : "주소 받는 중" }
            return status.device ? "동글 준비됨" : "동글 없음"
        }
        return model.applied ? "VM 대기" : "설정 필요"
    }

    private var headerSymbol: String {
        model.status?.isAssociated == true ? "wifi" : "wifi.exclamationmark"
    }

    private var headerColor: Color {
        guard let status = model.status else { return .secondary }
        return status.isAssociated && status.route_ready ? .green : .orange
    }
}

struct SignalBars: View {
    let dBm: Int?

    private var level: Int {
        guard let dBm else { return 0 }
        switch dBm {
        case (-55)...: return 3
        case (-67)...: return 2
        case (-78)...: return 1
        default: return 0
        }
    }

    var body: some View {
        Image(systemName: "wifi", variableValue: Double(level) / 3)
            .frame(width: 18)
    }
}
