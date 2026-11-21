import SwiftUI
import Charts

struct AdvancedScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var details: AdvancedSnapshot?
    @State private var reload = 0
    @State private var showInbox = false
    @State private var openSMSManagement = false
    @State private var nativeTool: ManagementFeature?

    let device: DeviceSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            PageHeading(title: "高级", status: device.model, live: !model.stale)

            Button { model.openManagement() } label: {
                RadioCard {
                    HStack(spacing: 12) {
                        Image(systemName: "wifi.router").foregroundStyle(Palette.lime)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("UFI-TOOLS 高级后台").font(.headline)
                            Text("完整功能").font(.caption).foregroundStyle(.white.opacity(0.8))
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .buttonStyle(.plain)
            .disabled(model.endpoint == nil)

            HStack(spacing: 10) {
                ActionTile(title: "短信收件箱", icon: "envelope") { showInbox = true }
                ActionTile(title: "流量限制", icon: "chart.bar.xaxis") { nativeTool = .quota }
            }

            usageCard

            section("无线与蜂窝", [.wifi, .lan, .apn, .clients, .networkControls, .band, .cell])
            section("测速与流量", [.usage, .officialQuota, .localSpeed, .cellularSpeed])
            Text("转发").font(.headline).accessibilityAddTraits(.isHeader)
            ForwardingControls { nativeTool = .smsForward }
            section("系统与维护", [.androidDesktop, .tailscale, .plugins, .schedule, .advanced, .update])
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("advanced-screen")
        .task(id: reload) {
            let result = await model.readAdvanced()
            if !Task.isCancelled { details = result }
        }
        #if DEBUG
        .task {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--inbox") { showInbox = true }
            if let index = arguments.firstIndex(of: "--native"), arguments.indices.contains(index + 1),
               let feature = ManagementFeature(rawValue: arguments[index + 1]), feature.hasNativeEditor {
                nativeTool = feature
            }
        }
        #endif
        .fullScreenCover(item: $nativeTool) { feature in
            nativeEditor(feature).environmentObject(model)
        }
        .fullScreenCover(isPresented: $showInbox, onDismiss: {
            if openSMSManagement {
                openSMSManagement = false
                model.openManagement(.sms)
            }
        }) {
            InboxScreen {
                openSMSManagement = true
                showInbox = false
            }
            .environmentObject(model)
        }
    }

    private var usageCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("最近七天流量").font(.headline)
                    Spacer()
                    Button {
                        details = nil
                        reload += 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(Palette.green)
                            .padding(8)
                    }
                    .accessibilityLabel("刷新流量和 USB 状态")
                    .disabled(details == nil)
                }
                if let days = details?.usage, !days.isEmpty {
                    Text(formatBytes(days.reduce(0) { $0 + $1.bytes })).font(.title2.monospaced().bold())
                    Chart(days) { day in
                        BarMark(
                            x: .value("日期", String(day.day.suffix(5))),
                            y: .value("流量", day.bytes)
                        )
                        .foregroundStyle(Palette.green)
                        .cornerRadius(3)
                        .accessibilityValue(formatBytes(day.bytes))
                    }
                    .chartYAxis(.hidden)
                    .chartXAxis { AxisMarks { AxisValueLabel().foregroundStyle(Palette.muted) } }
                    .frame(height: 80)
                } else if details == nil {
                    ProgressView().controlSize(.small).accessibilityLabel("正在读取流量")
                } else {
                    InlineNotice(text: details?.usage?.isEmpty == true ? "暂无流量记录" : "设备未返回流量记录")
                }
                Divider()
                if let devices = details?.usb?.devices, !devices.isEmpty {
                    DisclosureGroup {
                        ForEach(devices) { device in
                            LineRow(title: device.product, value: device.speed ?? "—", icon: "externaldrive")
                        }
                    } label: {
                        LineRow(title: "USB", value: usbSummary, icon: "cable.connector")
                            .padding(.horizontal, -15)
                    }
                } else {
                    LineRow(title: "USB", value: usbSummary, icon: "cable.connector")
                        .padding(.horizontal, -15)
                }
            }
            .padding(.horizontal, 15)
            .padding(.top, 10)
        }
    }

    private var usbSummary: String {
        guard let usb = details?.usb else { return details == nil ? "读取中…" : "设备未返回状态" }
        return [usb.modeName, usb.speed, usb.devices.map { "\($0.count) 个设备" }].compactMap { $0 }.joined(separator: " · ")
    }

    private func section(_ title: String, _ features: [ManagementFeature]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            Card {
                VStack(spacing: 0) {
                    ForEach(features) { feature in
                        Button {
                            if feature == .clients { model.destination = .clients }
                            else if feature.hasNativeEditor { nativeTool = feature }
                            else { model.openManagement(feature) }
                        } label: {
                            ManagementRow(title: feature.title, icon: feature.icon)
                        }
                        .disabled(model.endpoint == nil && feature != .clients && !feature.hasNativeEditor)
                        if feature != features.last { Divider().padding(.leading, 45) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func nativeEditor(_ feature: ManagementFeature) -> some View {
        switch feature {
        case .wifi: WiFiEditor()
        case .lan: LANEditor()
        case .networkControls: DeviceControls()
        case .schedule: ScheduledTasks()
        case .apn: APNEditor()
        case .quota: DataLimitEditor()
        case .usage: UsageHistory()
        case .band, .cell: RadioSettings(showCells: feature == .cell)
        case .plugins: PluginsScreen()
        case .localSpeed, .cellularSpeed:
            SpeedTestScreen(mode: feature == .cellularSpeed ? .cellular : .local)
        case .update: SoftwareUpdateScreen()
        case .smsForward: ForwardingEditor()
        case .androidDesktop: AndroidDesktop()
        case .tailscale: TailscaleScreen()
        default: EmptyView()
        }
    }
}

struct ManagementRow: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 21).foregroundStyle(Palette.green).accessibilityHidden(true)
            Text(title).font(.subheadline.weight(.semibold))
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                .foregroundStyle(Palette.muted).accessibilityHidden(true)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

private struct InboxScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var messages: [SMSMessage]?
    @State private var issue: String?
    @State private var reload = 0
    @State private var loading = false
    @State private var composing = false
    @State private var recipient = ""
    @State private var bodyText = ""
    @State private var sending = false
    @State private var deleting: SMSMessage?
    @State private var statusMessage: String?

    let manage: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").frame(width: 44, height: 44)
                }
                .accessibilityLabel("返回")
                Spacer()
                Text("短信").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button { reload += 1 } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                }
                .accessibilityLabel("刷新短信")
                .disabled(loading)
            }
            .padding(.horizontal, 12)
            .foregroundStyle(Palette.green)

            ScrollView {
                VStack(spacing: 12) {
                    RadioCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("SIM 收件箱", systemImage: "envelope").font(.title2.bold())
                            if let messages {
                                Text("最近读取 \(messages.count) 条").font(.subheadline).foregroundStyle(Palette.lime)
                            }
                        }
                    }

                    if composing {
                        composeCard
                    } else {
                        RouterSave(title: "发短信", disabled: sending) { composing = true }
                    }
                    if loading && messages == nil {
                        ProgressView().padding(20).accessibilityLabel("正在读取短信")
                    }
                    if let issue { InlineNotice(text: issue, icon: "exclamationmark.circle") }
                    if let statusMessage { InlineNotice(text: statusMessage, icon: "checkmark.circle") }
                    if let messages, messages.isEmpty {
                        InlineNotice(text: "SIM 卡里暂无收到的短信", icon: "envelope.open")
                    }
                    if let messages, !messages.isEmpty {
                        Card {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(messages) { message in
                                    VStack(alignment: .leading, spacing: 7) {
                                        HStack {
                                            if message.unread {
                                                Circle().fill(Palette.green).frame(width: 7, height: 7)
                                                    .accessibilityLabel("未读")
                                            }
                                            Text(message.sender).font(.subheadline.bold())
                                            Spacer()
                                            Text(message.date).font(.caption.monospaced()).foregroundStyle(Palette.muted)
                                        }
                                        Text(message.text).font(.subheadline).textSelection(.enabled)
                                        HStack {
                                            if message.unread {
                                                Button("标记已读") {
                                                    Task { await change(message, command: "SET_MSG_READ") }
                                                }
                                            }
                                            Spacer()
                                            Button("删除", role: .destructive) { deleting = message }
                                        }
                                        .font(.caption.weight(.semibold))
                                        .disabled(sending)
                                    }
                                    .padding(14)
                                    if message.id != messages.last?.id { Divider().padding(.horizontal, 14) }
                                }
                            }
                        }
                        .privacySensitive()
                    }

                    Card { Button(action: manage) { ManagementRow(title: "短信管理", icon: "square.and.pencil") } }
                        .disabled(model.endpoint == nil)
                }
                .frame(maxWidth: 570)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .refreshable { await load() }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.ink)
        .background(Palette.paper.ignoresSafeArea())
        .task(id: reload) { await load() }
        .alert("确认删除短信？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
               presenting: deleting) { message in
            Button("删除", role: .destructive) { Task { await change(message, command: "DELETE_SMS") } }
            Button("取消", role: .cancel) {}
        } message: { message in
            Text("来自 " + message.sender + " 的这条短信将从设备删除。")
        }
        .accessibilityIdentifier("inbox-screen")
    }

    private var composeCard: some View {
        Card {
            VStack(spacing: 0) {
                RouterField(label: "收件号码") {
                    TextField("手机号", text: $recipient).keyboardType(.phonePad)
                }
                Divider()
                RouterField(label: "短信内容") {
                    TextField("输入短信", text: $bodyText, axis: .vertical)
                        .lineLimit(3...6)
                }
                HStack {
                    Button("取消") { composing = false }.padding(12)
                    RouterSave(title: "发送", disabled: sending || bodyText.isEmpty || recipient.isEmpty) {
                        Task { await sendMessage() }
                    }
                }
                .padding(12)
            }
            .disabled(sending)
        }
    }

    private func sendMessage() async {
        let number = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard number.range(of: "^\\+?[0-9]{1,20}$", options: .regularExpression) != nil, !text.isEmpty else {
            issue = "请输入有效的收件号码和短信内容。"
            return
        }
        let hex = text.utf16.map { String(format: "%04x", $0) }.joined()
        sending = true
        statusMessage = nil
        issue = nil
        defer { sending = false }
        do {
            try await model.applyRouter(.init(command: "SEND_SMS", values: ["Number": number, "MessageBody": hex]))
            bodyText = ""
            recipient = ""
            composing = false
            statusMessage = model.demo ? "演示发送完成。" : "设备已接受短信发送请求。"
        } catch { issue = error.localizedDescription }
    }

    private func change(_ message: SMSMessage, command: String) async {
        guard !sending else { return }
        sending = true
        statusMessage = nil
        issue = nil
        defer { sending = false }
        do {
            try await model.applyRouter(.init(command: command, values: ["msg_id": message.id, "notCallback": "true"]))
            if model.demo, let index = messages?.firstIndex(where: { $0.id == message.id }) {
                if command == "DELETE_SMS" { messages?.remove(at: index) }
                else {
                    messages?[index] = SMSMessage(id: message.id, sender: message.sender, date: message.date,
                                                  text: message.text, unread: false)
                }
            } else {
                await load()
            }
        } catch { issue = error.localizedDescription }
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        issue = nil
        defer { loading = false }
        do {
            let result = try await model.readInbox()
            if !Task.isCancelled { messages = result }
        } catch {
            if !Task.isCancelled { issue = error.localizedDescription }
        }
    }
}
