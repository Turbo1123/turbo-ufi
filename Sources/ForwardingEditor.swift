import SwiftUI

enum ForwardingChannel: String, CaseIterable, Identifiable {
    case mail = "SMTP", dingtalk = "DINGTALK", curl = "CURL"
    var id: Self { self }

    var title: String {
        switch self { case .mail: "邮件"; case .dingtalk: "钉钉"; case .curl: "Curl" }
    }

    var route: String {
        switch self {
        case .mail: "/api/sms_forward_mail"
        case .dingtalk: "/api/sms_forward_dingtalk"
        case .curl: "/api/sms_forward_curl"
        }
    }

    var keys: [String] {
        switch self {
        case .mail: ["smtp_host", "smtp_port", "smtp_to", "smtp_username", "smtp_password", "smtp_from", "smtp_from_name", "forward_dev_info"]
        case .dingtalk: ["webhook_url", "secret", "forward_dev_info"]
        case .curl: ["curl_text"]
        }
    }

    func payload(_ form: [String: String]) throws -> [String: String] {
        let values = Dictionary(uniqueKeysWithValues: keys.map {
            ($0, (form[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        })
        switch self {
        case .mail:
            let required = ["smtp_host", "smtp_to", "smtp_username", "smtp_password"]
            guard required.allSatisfy({ values[$0]?.isEmpty == false }),
                  let port = values["smtp_port"].flatMap(Int.init), (1...65535).contains(port) else {
                throw ConnectionError.validation("请填写 SMTP 服务器、有效端口、认证用户名、密码和收件邮箱。")
            }
            if let sender = values["smtp_from"], !sender.isEmpty, !sender.contains("@") {
                throw ConnectionError.validation("发件邮箱格式无效。")
            }
        case .dingtalk:
            guard let url = values["webhook_url"].flatMap(URL.init(string:)), url.scheme == "https",
                  url.host != nil, url.user == nil, url.password == nil else {
                throw ConnectionError.validation("请输入有效的 HTTPS Webhook 地址。")
            }
        case .curl:
            let template = values["curl_text"] ?? ""
            guard ["{{sms-body}}", "{{sms-time}}", "{{sms-from}}"].allSatisfy(template.contains) else {
                throw ConnectionError.validation("模板需要包含短信内容、时间和号码三个占位符。")
            }
        }
        return values
    }
}

extension UFIClient {
    func forwardChannel() async throws -> ForwardingChannel? {
        let result = try await request("/api/sms_forward_method")
        return result.text("sms_forward_method").flatMap(ForwardingChannel.init(rawValue:))
    }

    func forwardingForm(_ channel: ForwardingChannel) async throws -> [String: String] {
        let result = try await request(channel.route)
        return Dictionary(uniqueKeysWithValues: channel.keys.map { key in
            let fallback = key == "smtp_port" ? "465" : key == "forward_dev_info" ? "0" : ""
            return (key, result.text(key) ?? fallback)
        })
    }

    func saveForwarding(_ channel: ForwardingChannel, form: [String: String]) async throws {
        let result = try await request(channel.route, body: channel.payload(form), timeout: 30)
        guard result.text("result") == "success" else { throw ConnectionError.rejected }
    }

    func saveForwardFilters(phones: String, keywords: String) async throws {
        let phones = phones.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phones.range(of: #"^[0-9\n]*$"#, options: .regularExpression) != nil else {
            throw ConnectionError.validation("号码黑名单只接受数字，每行一个号码。")
        }
        let result = try await request("/api/sms_forward_blacklist", body: [
            "phone": phones, "keywords": keywords.trimmingCharacters(in: .whitespacesAndNewlines)
        ])
        guard result.text("result") == "success" else { throw ConnectionError.rejected }
    }
}

struct ForwardingEditor: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: ForwardingChannel = .mail
    @State private var active: ForwardingChannel?
    @State private var drafts: [ForwardingChannel: [String: String]] = [:]
    @State private var phones = ""
    @State private var keywords = ""
    @State private var filtersReady = false
    @State private var loaded = false
    @State private var busy = false
    @State private var notice: String?

    var body: some View {
        RouterEditor(title: "转发设置") {
            RadioCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("当前渠道").font(.caption.bold()).foregroundStyle(Palette.lime)
                    Text(active?.title ?? (loaded ? "未配置" : "正在读取")).font(.title2.bold())
                }
            }
            Picker("转发渠道", selection: $selection) {
                ForEach(ForwardingChannel.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(busy || !loaded)
            if let notice { InlineNotice(text: notice).accessibilityIdentifier("forwarding-notice") }
            if busy { ProgressView().controlSize(.small) }
            if drafts[selection] != nil {
                Card { VStack(spacing: 0) { channelFields } }.disabled(busy)
                InlineNotice(text: "保存会切换设备的转发渠道，并由设备发送一条测试消息。")
                RouterSave(title: "保存并测试", disabled: busy) {
                    let channel = selection
                    let draft = drafts[channel] ?? [:]
                    Task { await save(channel, draft: draft) }
                }
            } else if loaded {
                Button("重新读取渠道") { Task { await loadChannel(selection) } }.disabled(busy)
            } else if !busy {
                Button("重新读取设置") { Task { await load() } }
            }
            if filtersReady {
                Text("转发过滤").font(.headline)
                Card {
                    VStack(spacing: 0) {
                        RouterField(label: "号码黑名单") {
                            TextField("每行一个号码", text: $phones, axis: .vertical)
                                .lineLimit(2...5).autocorrectionDisabled()
                        }
                        Divider()
                        RouterField(label: "关键词黑名单") {
                            TextField("每行一个关键词", text: $keywords, axis: .vertical).lineLimit(2...5)
                        }
                    }
                }
                .disabled(busy)
                RouterSave(title: "保存过滤规则", disabled: busy) { Task { await saveFilters() } }
            }
        }
        .task { await load() }
        .onChange(of: selection) { _, value in
            if drafts[value] == nil { Task { await loadChannel(value) } }
        }
        .privacySensitive()
    }

    @ViewBuilder
    private var channelFields: some View {
        switch selection {
        case .mail:
            field("SMTP 服务器", "smtp_host")
            Divider()
            field("端口", "smtp_port", keyboard: .numberPad)
            Divider()
            field("收件邮箱", "smtp_to", keyboard: .emailAddress)
            Divider()
            field("认证用户名", "smtp_username")
            Divider()
            field("密码或授权码", "smtp_password", secret: true)
            Divider()
            field("发件邮箱（选填）", "smtp_from", keyboard: .emailAddress)
            Divider()
            field("发件人名称（选填）", "smtp_from_name")
            Divider()
            deviceInfo
        case .dingtalk:
            field("机器人 Webhook", "webhook_url", secret: true)
            Divider()
            field("加签密钥（选填）", "secret", secret: true)
            Divider()
            deviceInfo
        case .curl:
            RouterField(label: "Curl 转发模板") {
                TextField("填入现有模板", text: value("curl_text"), axis: .vertical)
                    .lineLimit(4...12).font(.footnote.monospaced())
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            InlineNotice(text: "{{sms-body}} 内容 · {{sms-time}} 时间 · {{sms-from}} 号码")
                .padding(.horizontal, 14)
        }
    }

    private var deviceInfo: some View {
        Toggle("附带设备状态", isOn: Binding(get: { value("forward_dev_info").wrappedValue == "1" },
                                             set: { value("forward_dev_info").wrappedValue = $0 ? "1" : "0" }))
            .font(.subheadline).padding(14)
    }

    private func field(_ label: String, _ key: String, secret: Bool = false, keyboard: UIKeyboardType = .default) -> some View {
        RouterField(label: label) {
            Group {
                if secret { SecureField(label, text: value(key)) }
                else { TextField(label, text: value(key)).keyboardType(keyboard) }
            }
            .autocorrectionDisabled().textInputAutocapitalization(.never)
        }
    }

    private func value(_ key: String) -> Binding<String> {
        let channel = selection
        return Binding(get: { drafts[channel]?[key] ?? "" }, set: { drafts[channel, default: [:]][key] = $0 })
    }

    private func load() async {
        await run {
            if model.demo {
                active = .mail
                filtersReady = true
                drafts[.mail] = ["smtp_host": "smtp.example.com", "smtp_port": "465"]
            } else {
                let client = try model.routerSettingsClient()
                async let rules = try? client.request("/api/sms_forward_blacklist")
                let channel = try await client.forwardChannel()
                active = channel
                selection = channel ?? .mail
                if let data = await rules {
                    phones = data.text("phone") ?? ""
                    keywords = data.text("keywords") ?? ""
                    filtersReady = true
                }
                loaded = true
                drafts[selection] = try await client.forwardingForm(selection)
            }
            loaded = true
        }
    }

    private func loadChannel(_ channel: ForwardingChannel) async {
        await run {
            drafts[channel] = model.demo ? [:] : try await model.routerSettingsClient().forwardingForm(channel)
        }
    }

    private func save(_ channel: ForwardingChannel, draft: [String: String]) async {
        await run {
            if model.demo { _ = try channel.payload(draft) }
            else { try await model.routerSettingsClient().saveForwarding(channel, form: draft) }
            active = channel
            notice = model.demo ? "演示保存完成。" : "已保存，设备已触发测试转发。"
        }
    }

    private func saveFilters() async {
        await run {
            if !model.demo { try await model.routerSettingsClient().saveForwardFilters(phones: phones, keywords: keywords) }
            notice = "已保存转发过滤规则。"
        }
    }

    private func run(_ action: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        notice = nil
        defer { busy = false }
        do { try await action() } catch is CancellationError {} catch { notice = error.localizedDescription }
    }
}
