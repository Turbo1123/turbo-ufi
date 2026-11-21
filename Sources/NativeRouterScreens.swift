import SwiftUI

struct RouterEditor<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    var canClose = true
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(!canClose)
                .foregroundStyle(Palette.green)
                .accessibilityLabel("返回")
                Spacer()
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 13) { content }
                    .frame(maxWidth: 570)
                    .padding(20)
                    .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.paper.ignoresSafeArea())
        .tint(Palette.green)
    }
}

struct RouterField<Input: View>: View {
    let label: String
    @ViewBuilder var input: Input

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
            input
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

struct RouterSave: View {
    var title = "保存设置"
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.subheadline.bold())
                .frame(maxWidth: .infinity, minHeight: 46)
                .foregroundStyle(.white)
                .background(Palette.green.opacity(disabled ? 0.5 : 1), in: RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

struct WiFiEditor: View {
    @EnvironmentObject private var model: AppModel
    @State private var profiles: [WiFiProfile]?
    @State private var index = 0
    @State private var showPassword = false
    @State private var busy = false
    @State private var notice: String?

    var body: some View {
        RouterEditor(title: "Wi-Fi 设置") {
            if let list = Binding($profiles), list.wrappedValue.indices.contains(index) {
                if list.wrappedValue.count > 1 {
                    Picker("热点", selection: $index) {
                        ForEach(list.wrappedValue.indices, id: \.self) { row in
                            Text(list.wrappedValue[row].name).tag(row)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: index) { _, _ in showPassword = false }
                }
                let profile = list[index]
                Card {
                    VStack(spacing: 0) {
                        RouterField(label: "热点名称") {
                            TextField("SSID", text: profile.name).autocorrectionDisabled()
                        }
                        Divider()
                        Picker("加密方式", selection: profile.auth) {
                            ForEach(WiFiProfile.security, id: \.0) { code, name in Text(name).tag(code) }
                            if !WiFiProfile.security.contains(where: { $0.0 == profile.wrappedValue.auth }) {
                                Text(profile.wrappedValue.auth).tag(profile.wrappedValue.auth)
                            }
                        }
                        .padding(12)
                        if profile.wrappedValue.auth != "OPEN" {
                            Divider()
                            RouterField(label: "热点密码") {
                                HStack {
                                    Group {
                                        if showPassword { TextField("密码", text: profile.password) }
                                        else { SecureField("密码", text: profile.password) }
                                    }
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                    Button { showPassword.toggle() } label: {
                                        Image(systemName: showPassword ? "eye.slash" : "eye")
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(showPassword ? "隐藏热点密码" : "显示热点密码")
                                }
                            }
                        }
                        Divider()
                        RouterField(label: "最大接入数") {
                            TextField("设备数", text: profile.maximum).keyboardType(.numberPad)
                        }
                        Divider()
                        Toggle("隐藏 SSID", isOn: profile.hidden).padding(14)
                        Divider()
                        Toggle("客户端隔离", isOn: profile.isolated).padding(14)
                    }
                }
                .disabled(busy)
                InlineNotice(text: "保存后，当前连接的设备可能需要重新连接热点。")
                RouterSave(disabled: busy) {
                    let snapshot = profile.wrappedValue
                    Task { await save(snapshot) }
                }
            } else if profiles?.isEmpty == true {
                InlineNotice(text: "设备当前没有可编辑的启用热点。")
            } else if notice == nil {
                ProgressView().accessibilityLabel("正在读取热点设置")
            }
            if let notice { InlineNotice(text: notice) }
        }
        .task {
            do { profiles = model.demo ? [.demo] : try await model.routerSettingsClient().wifiProfiles() }
            catch { notice = error.localizedDescription }
        }
    }

    private func save(_ profile: WiFiProfile) async {
        busy = true
        notice = nil
        defer { busy = false }
        do {
            try await model.applyRouter(profile.action())
            notice = "已保存。若 Wi-Fi 断开，请用新设置重新连接。"
        } catch { notice = error.localizedDescription }
    }
}

struct LANEditor: View {
    @EnvironmentObject private var model: AppModel
    @State private var settings: LANSettings?
    @State private var notice: String?
    @State private var busy = false

    var body: some View {
        RouterEditor(title: "内网与 DHCP") {
            if let settings = Binding($settings) {
                Card {
                    VStack(spacing: 0) {
                        address("网关地址", settings.gateway)
                        Divider()
                        address("子网掩码", settings.mask)
                        Divider()
                        Toggle("DHCP 服务", isOn: settings.dhcp).padding(14)
                        if settings.wrappedValue.dhcp {
                            Divider()
                            address("地址池起始", settings.start)
                            Divider()
                            address("地址池结束", settings.end)
                            Divider()
                            RouterField(label: "租期（小时）") {
                                TextField("小时", text: settings.lease).keyboardType(.numberPad)
                            }
                        }
                    }
                }
                .disabled(busy)
                InlineNotice(text: "保存可能使设备重启。网关地址更改后，请用新地址连接。", icon: "exclamationmark.triangle")
                RouterSave(disabled: busy) {
                    let snapshot = settings.wrappedValue
                    Task { await save(snapshot) }
                }
            } else if notice == nil {
                ProgressView().accessibilityLabel("正在读取内网设置")
            }
            if let notice { InlineNotice(text: notice) }
        }
        .task {
            do { settings = model.demo ? .demo : try await model.routerSettingsClient().lanSettings() }
            catch { notice = error.localizedDescription }
        }
    }

    private func address(_ label: String, _ value: Binding<String>) -> some View {
        RouterField(label: label) {
            TextField(label, text: value).keyboardType(.decimalPad).font(.body.monospaced())
        }
    }

    private func save(_ settings: LANSettings) async {
        busy = true
        notice = nil
        defer { busy = false }
        do {
            let action = try settings.action()
            try await model.applyRouter(action)
            notice = "已保存。设备可重新连接后，使用 " + settings.gateway + " 访问后台。"
        } catch { notice = error.localizedDescription }
    }
}
