import CoreImage.CIFilterBuiltins
import SwiftUI

struct WiFiQRCodeSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var networks: [WiFiProfile] = []
    @State private var selection = ""
    @State private var issue: String?
    @State private var attempt = 0

    var body: some View {
        RouterEditor(title: "Wi-Fi 二维码") {
            if let network = networks.first(where: { $0.id == selection }) {
                if networks.count > 1 {
                    Picker("热点", selection: $selection) {
                        ForEach(networks) { Text($0.name).tag($0.id) }
                    }
                    .pickerStyle(.menu)
                }
                codeCard(for: network)
            } else if let issue {
                InlineNotice(text: issue)
                Button("重新读取") { attempt += 1 }
                    .frame(minHeight: 44)
            } else {
                ProgressView("正在读取热点设置…")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }
        }
        .task(id: attempt) { await load() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { dismiss() }
        }
    }

    private func codeCard(for network: WiFiProfile) -> some View {
        Card {
            VStack(spacing: 14) {
                Text(network.name)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                if let code = WiFiQRCode.image(for: network) {
                    Image(code, scale: 1, label: Text("加入此热点的二维码"))
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 224)
                        .padding(24)
                        .background(.white, in: RoundedRectangle(cornerRadius: 14))
                        .privacySensitive()
                    Text("用另一台手机扫描，按提示加入 Wi-Fi")
                        .font(.footnote)
                        .foregroundStyle(Palette.muted)
                        .multilineTextAlignment(.center)
                } else {
                    InlineNotice(text: "当前热点的加密方式或密码无法生成二维码。")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(16)
        }
    }

    private func load() async {
        issue = nil
        do {
            let profiles = model.demo ? [.demo] : try await model.routerSettingsClient().wifiProfiles()
            try Task.checkCancellation()
            networks = profiles
            selection = (profiles.first(where: { $0.id == "0:0" }) ?? profiles.first)?.id ?? ""
            if profiles.isEmpty { issue = "设备当前没有已启用的 Wi-Fi 热点。" }
        } catch is CancellationError {
        } catch {
            issue = error.localizedDescription
        }
    }
}

private enum WiFiQRCode {
    private static let context = CIContext()

    static func image(for profile: WiFiProfile) -> CGImage? {
        let security: String
        switch profile.auth {
        case "OPEN": security = "nopass"
        case "WPA2PSK", "WPA2PSKWPA3PSK": security = "WPA"
        case "WPA3PSK": security = "SAE"
        default: return nil
        }
        guard security == "nopass" || !profile.password.isEmpty else { return nil }

        var payload = "WIFI:T:\(security);S:\(escaped(profile.name));"
        if security != "nopass" { payload += "P:\(escaped(profile.password));" }
        if profile.hidden { payload += "H:true;" }
        payload += ";"

        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return context.createCGImage(output, from: output.extent)
    }

    private static func escaped(_ value: String) -> String {
        let reserved = CharacterSet(charactersIn: "\\;,\":")
        var escaped = ""
        for scalar in value.unicodeScalars {
            if reserved.contains(scalar) { escaped.append("\\") }
            escaped.unicodeScalars.append(scalar)
        }
        return escaped
    }
}
