import SwiftUI

struct DeviceControls: View {
    @EnvironmentObject private var model: AppModel
    @State private var values: JSONObject?
    @State private var busy = false
    @State private var notice: String?
    @State private var rebootStep = 0

    private let fields = "net_select,ppp_status,roam_setting_option,dial_roam_setting_option,indicator_light_switch,usb_network_protocal,samba_switch"
    private let networkModes = [
        ("WL_AND_5G", "5G / 4G / 3G 自动"), ("LTE_AND_5G", "5G NSA"), ("Only_5G", "5G SA"),
        ("WCDMA_AND_LTE", "4G / 3G"), ("Only_LTE", "仅 4G"), ("Only_WCDMA", "仅 3G")
    ]

    var body: some View {
        RouterEditor(title: "蜂窝与设备") {
            if let values {
                if busy { ProgressView().controlSize(.small).accessibilityLabel("正在应用设置") }
                Text("蜂窝网络").font(.headline)
                Card {
                    VStack(spacing: 0) {
                        menu("网络制式", current: values.text("net_select"), choices: networkModes) { mode in
                            FormAction(command: "SET_BEARER_PREFERENCE", values: ["BearerPreference": mode])
                        }
                        if let status = values.text("ppp_status") {
                            Divider()
                            toggle("蜂窝数据", on: status != "ppp_disconnected") { enabled in
                                FormAction(command: enabled ? "CONNECT_NETWORK" : "DISCONNECT_NETWORK")
                            }
                        }
                        if let roam = values.text("dial_roam_setting_option") ?? values.text("roam_setting_option") {
                            Divider()
                            toggle("数据漫游", on: roam == "on") { enabled in
                                let value = enabled ? "on" : "off"
                                return FormAction(command: "SET_CONNECTION_MODE", values: [
                                    "ConnectionMode": "auto_dial", "roam_setting_option": value,
                                    "dial_roam_setting_option": value
                                ])
                            }
                        }
                    }
                }
                Text("设备选项").font(.headline)
                Card {
                    VStack(spacing: 0) {
                        if let light = values.text("indicator_light_switch") {
                            toggle("指示灯", on: light == "1") { enabled in
                                FormAction(command: "INDICATOR_LIGHT_SETTING", values: ["indicator_light_switch": enabled ? "1" : "0"])
                            }
                            Divider()
                        }
                        if let smb = values.text("samba_switch") {
                            toggle("SMB 文件共享", on: smb == "1") { enabled in
                                FormAction(command: "SAMBA_SETTING", values: ["samba_switch": enabled ? "1" : "0"])
                            }
                            Divider()
                        }
                        menu("USB 上网协议", current: values.text("usb_network_protocal"),
                             choices: [("0", "自动"), ("1", "RNDIS"), ("2", "CDC-ECM")]) { value in
                            FormAction(command: "SET_USB_NETWORK_PROTOCAL", values: ["usb_network_protocal": value])
                        }
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Button(rebootTitle, role: .destructive) {
                            if rebootStep < 2 { rebootStep += 1 }
                            else {
                                rebootStep = 0
                                Task { await apply(.init(command: "REBOOT_DEVICE")) }
                            }
                        }
                        .disabled(busy || model.demo)
                        if rebootStep > 0 {
                            Text("重启会暂时断开 Wi-Fi 和蜂窝网络。")
                                .font(.caption).foregroundStyle(Palette.muted)
                            Button("取消") { rebootStep = 0 }.font(.caption)
                        }
                    }
                    .padding(14)
                }
                .task(id: rebootStep) {
                    guard rebootStep > 0 else { return }
                    try? await Task.sleep(for: .seconds(3))
                    if !Task.isCancelled { rebootStep = 0 }
                }
            } else if notice == nil {
                ProgressView().accessibilityLabel("正在读取设备设置")
            }
            if let notice { InlineNotice(text: notice) }
        }
        .task { await load() }
    }

    private var rebootTitle: String {
        switch rebootStep {
        case 1: "确认重启"
        case 2: "再次确认重启"
        default: "重启设备"
        }
    }

    private func toggle(_ label: String, on: Bool, action: @escaping (Bool) -> FormAction) -> some View {
        Toggle(label, isOn: Binding(get: { on }, set: { enabled in
            if enabled != on { Task { await apply(action(enabled)) } }
        }))
        .padding(14)
        .disabled(busy || model.demo)
    }

    private func menu(_ label: String, current: String?, choices: [(String, String)],
                      action: @escaping (String) -> FormAction) -> some View {
        HStack {
            Text(label).font(.subheadline.weight(.semibold))
            Spacer()
            Menu {
                ForEach(choices, id: \.0) { code, name in
                    Button {
                        if code != current { Task { await apply(action(code)) } }
                    } label: {
                        if current == code { Label(name, systemImage: "checkmark") }
                        else { Text(name) }
                    }
                }
            } label: {
                Label(choices.first { $0.0 == current }?.1 ?? "未返回", systemImage: "chevron.up.chevron.down")
                    .font(.subheadline)
            }
            .disabled(current == nil || busy || model.demo)
        }
        .padding(14)
    }

    private func load() async {
        do {
            if model.demo {
                values = JSONObject(["net_select": "WL_AND_5G", "ppp_status": "ipv4_ipv6_connected",
                                     "roam_setting_option": "off", "indicator_light_switch": "1",
                                     "usb_network_protocal": "0", "samba_switch": "0"])
            } else {
                values = try await model.routerSettingsClient().routerRead(fields)
            }
        } catch { notice = error.localizedDescription }
    }

    private func apply(_ action: FormAction) async {
        guard !busy else { return }
        busy = true
        notice = nil
        defer { busy = false }
        do {
            try await model.applyRouter(action)
            if action.command == "CONNECT_NETWORK" || action.command == "DISCONNECT_NETWORK" {
                try await Task.sleep(for: .seconds(2))
            }
            notice = "设备已接受设置。"
            await load()
        } catch { notice = error.localizedDescription }
    }
}
