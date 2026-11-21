import SwiftUI

struct ForwardingControls: View {
    @EnvironmentObject private var model: AppModel
    @State private var sms: Bool?
    @State private var power: Bool?
    @State private var busy = false
    @State private var notice: String?
    let edit: () -> Void

    var body: some View {
        Card {
            VStack(spacing: 0) {
                if let sms {
                    toggle("转发新短信", value: sms, route: "/api/sms_forward_enabled")
                    Divider()
                }
                if let power {
                    toggle("转发电量信息", value: power, route: "/api/power_status_forward_enabled")
                    Divider()
                }
                Button(action: edit) {
                    ManagementRow(title: "转发渠道设置", icon: "arrowshape.turn.up.right")
                }
                .buttonStyle(.plain)
                if let notice {
                    InlineNotice(text: notice).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14)
                }
            }
        }
        .task { await read() }
    }

    private func toggle(_ title: String, value: Bool, route: String) -> some View {
        Toggle(title, isOn: Binding(get: { value }, set: { enabled in
            if value != enabled { Task { await change(route: route, enabled: enabled) } }
        }))
        .font(.subheadline.weight(.semibold))
        .padding(14)
        .disabled(busy || model.demo)
    }

    private func read() async {
        if model.demo { sms = false; power = false; return }
        guard let client = try? model.routerSettingsClient() else { return }
        async let smsResult = try? client.request("/api/sms_forward_enabled").text("enabled")
        async let powerResult = try? client.request("/api/power_status_forward_enabled").text("enabled")
        let (sms, power) = await (smsResult, powerResult)
        self.sms = sms.map { $0 == "1" }
        self.power = power.map { $0 == "1" }
    }

    private func change(route: String, enabled: Bool) async {
        guard !busy else { return }
        busy = true
        notice = nil
        defer { busy = false }
        do {
            let client = try model.routerSettingsClient()
            let result = try await client.request(route, query: [.init(name: "enable", value: enabled ? "1" : "0")], body: [:])
            guard result.text("result") == "success" else { throw ConnectionError.rejected }
            await read()
        } catch { notice = error.localizedDescription }
    }
}
