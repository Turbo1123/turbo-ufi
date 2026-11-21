import SwiftUI

struct APNConfiguration: Identifiable {
    let id: Int
    var name = ""
    var apn = ""
    var user = ""
    var password = ""
    var authentication = "none"
    var protocolName = "IPv4v6"

    func saveAction() throws -> FormAction {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let apn = apn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !apn.isEmpty, !name.contains("($)"), !apn.contains("($)"),
              ["IP", "IPv6", "IPv4v6"].contains(protocolName) else {
            throw ConnectionError.validation("请填写配置名称和 APN，并选择有效协议。")
        }
        let base = [
            "apn_mode": "manual", "apn_action": "save", "index": String(id),
            "profile_name": name, "wan_dial": "*99#", "apn_wan_dial": "*99#", "apn_select": "manual",
            "apn_pdp_type": protocolName, "pdp_type": protocolName, "apn_pdp_select": "auto",
            "apn_pdp_addr": "", "pdp_select": "auto", "pdp_addr": ""
        ]
        var fields = base
        for prefix in ["", "ipv6_"] where (prefix.isEmpty && protocolName != "IPv6") || (!prefix.isEmpty && protocolName != "IP") {
            let values = ["wan_apn": apn, "ppp_auth_mode": authentication, "ppp_username": user,
                          "ppp_passwd": password]
            for (name, value) in values {
                fields[prefix + name] = value
                fields["apn_" + prefix + name] = value
            }
            fields[prefix + "dns_mode"] = "auto"
            fields[prefix + "prefer_dns_manual"] = ""
            fields[prefix + "standby_dns_manual"] = ""
        }
        return FormAction(command: "APN_PROC_EX", values: fields)
    }
}

struct APNState {
    let mode: String
    let currentName: String?
    let activeAPN: String?
    var profiles: [APNConfiguration]

    static func parse(_ response: JSONObject) throws -> APNState {
        guard let mode = response.text("apn_mode") else { throw ConnectionError.invalidResponse }
        let profiles: [APNConfiguration] = (0..<20).compactMap { index in
            guard let parts = response.text("APN_config\(index)")?.components(separatedBy: "($)"),
                  parts.count >= 8, !parts[0].isEmpty else { return nil }
            let ipv6 = response.text("ipv6_APN_config\(index)")?.components(separatedBy: "($)")
            let source = parts[7] == "IPv6" && (ipv6?.count ?? 0) >= 8 ? (ipv6 ?? parts) : parts
            return APNConfiguration(id: index, name: parts[0], apn: source[1], user: source[5],
                                    password: source[6], authentication: source[4], protocolName: parts[7])
        }
        return APNState(mode: mode, currentName: response.text("m_profile_name") ?? response.text("profile_name"),
                        activeAPN: response.text("apn_wan_apn") ?? response.text("apn_ipv6_wan_apn"),
                        profiles: profiles)
    }

    static let demo = APNState(mode: "auto", currentName: "中国移动", activeAPN: "CMNET",
                               profiles: [APNConfiguration(id: 0, name: "中国移动", apn: "CMNET")])
}

extension UFIClient {
    func apnSettings() async throws -> APNState {
        let profileKeys = (0..<20).flatMap { ["APN_config\($0)", "ipv6_APN_config\($0)"] }
        let fields = ["apn_mode", "m_profile_name", "profile_name", "apn_wan_apn", "apn_ipv6_wan_apn"] + profileKeys
        return try await APNState.parse(routerRead(fields.joined(separator: ",")))
    }
}

struct APNEditor: View {
    @EnvironmentObject private var model: AppModel
    @State private var state: APNState?
    @State private var draft: APNConfiguration?
    @State private var deletion: APNConfiguration?
    @State private var busy = false
    @State private var notice: String?

    var body: some View {
        RouterEditor(title: "APN 设置") {
            if let state {
                RadioCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(state.activeAPN ?? "当前 APN").font(.title2.bold())
                        Text(state.mode == "auto" ? "自动选用" : "手动配置").font(.caption).foregroundStyle(Palette.lime)
                    }
                }
                if state.mode != "auto" {
                    RouterSave(title: "切换为自动", disabled: busy || model.demo) {
                        Task { await change(.init(command: "APN_PROC_EX", values: ["apn_mode": "auto"])) }
                    }
                }
                InlineNotice(text: "更改当前 APN 可能使蜂窝网络重新连接。")
                if let draft = Binding($draft) {
                    form(draft)
                } else {
                    RouterSave(title: "新增配置", disabled: busy || state.profiles.count >= 20) {
                        draft = APNConfiguration(id: (0..<20).first { candidate in !state.profiles.contains { $0.id == candidate } } ?? 19)
                    }
                }
                ForEach(state.profiles) { profile in
                    profileCard(profile, active: state.mode != "auto" && profile.name == state.currentName)
                }
            } else if notice == nil {
                ProgressView().accessibilityLabel("正在读取 APN")
            }
            if let notice { InlineNotice(text: notice) }
        }
        .task { await load() }
        .alert("删除 APN 配置？", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }),
               presenting: deletion) { profile in
            Button("删除", role: .destructive) {
                Task {
                    await change(.init(command: "APN_PROC_EX", values: [
                        "apn_action": "delete", "apn_mode": "manual", "index": String(profile.id)
                    ]))
                }
            }
            Button("取消", role: .cancel) {}
        } message: { profile in
            Text(profile.name)
        }
    }

    private func profileCard(_ profile: APNConfiguration, active: Bool) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(profile.name).font(.headline)
                    Spacer()
                    if active { StatusChip(text: "当前") }
                }
                Text(profile.apn + " · " + profile.protocolName).font(.subheadline).foregroundStyle(Palette.muted)
                HStack {
                    Button("设为当前") {
                        Task {
                            await change(.init(command: "APN_PROC_EX", values: [
                                "apn_mode": "manual", "apn_action": "set_default", "set_default_flag": "1",
                                "apn_pdp_type": "", "index": String(profile.id)
                            ]))
                        }
                    }
                    .disabled(active)
                    Button("编辑") { draft = profile }
                    Spacer()
                    Button("删除", role: .destructive) { deletion = profile }
                }
                .buttonStyle(.borderless)
                .disabled(busy || model.demo)
            }
            .padding(15)
        }
    }

    private func form(_ draft: Binding<APNConfiguration>) -> some View {
        VStack(spacing: 10) {
            Card {
                VStack(spacing: 0) {
                    RouterField(label: "配置名称") { TextField("名称", text: draft.name) }
                    Divider()
                    RouterField(label: "接入点") {
                        TextField("APN", text: draft.apn).autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                    Divider()
                    Picker("IP 协议", selection: draft.protocolName) {
                        Text("IPv4").tag("IP")
                        Text("IPv6").tag("IPv6")
                        Text("IPv4 / IPv6").tag("IPv4v6")
                    }
                    .padding(14)
                    Divider()
                    Picker("认证方式", selection: draft.authentication) {
                        Text("无").tag("none")
                        Text("PAP").tag("pap")
                        Text("CHAP").tag("chap")
                    }
                    .padding(14)
                    if draft.wrappedValue.authentication != "none" {
                        Divider()
                        RouterField(label: "用户名") { TextField("选填", text: draft.user) }
                        Divider()
                        RouterField(label: "密码") { SecureField("选填", text: draft.password) }
                    }
                }
            }
            HStack {
                Button("取消") { self.draft = nil }.padding(.horizontal, 12)
                RouterSave(title: "保存配置", disabled: busy) {
                    let entry = draft.wrappedValue
                    do {
                        let operation = try entry.saveAction()
                        Task { if await change(operation) { self.draft = nil } }
                    } catch { notice = error.localizedDescription }
                }
            }
        }
        .disabled(busy)
    }

    private func load() async {
        do { state = model.demo ? .demo : try await model.routerSettingsClient().apnSettings() }
        catch { notice = error.localizedDescription }
    }

    @discardableResult
    private func change(_ action: FormAction) async -> Bool {
        guard !busy else { return false }
        busy = true
        notice = nil
        defer { busy = false }
        do {
            try await model.applyRouter(action)
            notice = "设备已接受设置。"
            await load()
            return true
        } catch {
            notice = error.localizedDescription
            return false
        }
    }
}
