import Charts
import SwiftUI

struct OverviewScreen: View {
    @EnvironmentObject private var model: AppModel
    let device: DeviceSnapshot

    var body: some View {
        VStack(spacing: 13) {
            PageHeading(title: "总览", detail: device.model,
                        status: model.stale ? "更新失败" : model.demo ? nil : "在线", live: !model.stale)
            HStack {
                if let usb = model.usb?.hostLabel {
                    Label(usb, systemImage: "cable.connector")
                        .font(.caption.weight(.semibold)).foregroundStyle(Palette.green)
                        .accessibilityLabel("USB 已连接，" + usb)
                }
                Spacer()
                DevicePowerControl(allowsShutdown: device.network?.text("battery_value") != nil
                                   && device.network?.text("battery_vol_percent") != nil)
            }

            RadioCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text(device.networkType)
                        .font(.system(size: 42, weight: .heavy, design: .default))
                        .tracking(-2)
                        .lineLimit(1).minimumScaleFactor(0.58)
                    Text(device.carrier).font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.78))
                    HStack(spacing: 13) {
                        rate(model.rate?.down, icon: "arrow.down", label: "下载")
                        Rectangle().fill(.white.opacity(0.28)).frame(width: 1, height: 19)
                        rate(model.rate?.up, icon: "arrow.up", label: "上传")
                    }
                    .padding(.top, 10)
                }
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ValueTile(label: "设备电量", value: formatMetric(device.battery, suffix: "%"), icon: "battery.75percent")
                ValueTile(label: "最高温度", value: formatMetric(device.temperature, suffix: " °C", digits: 1), icon: "thermometer.medium")
                Button {
                    model.destination = .clients
                } label: {
                    ValueTile(label: "接入设备", value: device.clients.map { "\($0.count) 台" } ?? "—",
                              icon: "person.2", showsChevron: true)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("打开设备列表")
                .accessibilityIdentifier("overview-connected-devices")
                ValueTile(label: "本月流量", value: formatBytes(device.base.number("monthly_data")), icon: "chart.bar.xaxis")
            }

            OverviewDetails(device: device, connections: model.connectionCounts, usb: model.usb,
                            qos: model.qos, samples: model.monitorSamples)
            RateChart(samples: model.samples)

            if device.network == nil {
                InlineNotice(text: "设备已连通，蜂窝与客户端数据暂时不可用。")
            }
        }
        .accessibilityIdentifier("overview-screen")
    }

    private func rate(_ value: Double?, icon: String, label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption.weight(.semibold)).foregroundStyle(Palette.lime)
            Text(formatMetric(value.map { $0 * 8 / 1_000_000 }, suffix: " Mbps", digits: 2))
                .font(.system(.subheadline, design: .monospaced).weight(.bold))
                .lineLimit(1).minimumScaleFactor(0.68)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(formatMetric(value.map { $0 * 8 / 1_000_000 }, suffix: " Mbps", digits: 2))
    }
}

private struct RateChart: View {
    let samples: [RateSample]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Text("蜂窝实时速率").font(.headline).accessibilityAddTraits(.isHeader)
                    Spacer()
                    legend("下载", Palette.green)
                    legend("上传", Palette.lime)
                }

                if samples.count > 1 {
                    Chart {
                        ForEach(samples) { sample in
                            AreaMark(x: .value("时间", sample.at), y: .value("下载", sample.down * 8 / 1_000_000))
                                .interpolationMethod(.linear)
                                .foregroundStyle(.linearGradient(colors: [Palette.green.opacity(0.3), Palette.green.opacity(0.02)],
                                                                 startPoint: .top, endPoint: .bottom))
                            LineMark(x: .value("时间", sample.at), y: .value("速率", sample.down * 8 / 1_000_000), series: .value("方向", "下载"))
                                .foregroundStyle(Palette.green).lineStyle(.init(lineWidth: 2))
                            LineMark(x: .value("时间", sample.at), y: .value("速率", sample.up * 8 / 1_000_000), series: .value("方向", "上传"))
                                .foregroundStyle(Color(red: 0.51, green: 0.67, blue: 0.25)).lineStyle(.init(lineWidth: 1.6))
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 3)) { value in
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(date.formatted(.dateTime.minute(.twoDigits).second(.twoDigits)))
                                        .font(.caption2)
                                }
                            }
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 4))
                    }
                    .chartYAxisLabel("Mbps")
                    .frame(height: 132)
                    .accessibilityLabel("最近两分钟上下行速率")
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform.path")
                        Text("正在等待新的速率采样")
                    }
                    .frame(maxWidth: .infinity, minHeight: 96)
                    .font(.footnote).foregroundStyle(Palette.muted)
                }
            }
            .padding(15)
        }
    }

    private func legend(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 13, height: 3)
            Text(label).font(.caption2).foregroundStyle(Palette.muted)
        }
    }
}

struct NetworkScreen: View {
    let device: DeviceSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            PageHeading(title: "网络", status: device.networkType == "—" ? nil : device.networkType)
            RadioCard {
                VStack(alignment: .leading, spacing: 7) {
                    Text("蜂窝连接").font(.caption.weight(.semibold)).foregroundStyle(Palette.lime)
                    Text(device.carrier).font(.title3.weight(.semibold))
                    Text(formatMetric(device.network?.number("Z5g_rsrp") ?? device.network?.number("lte_rsrp"), suffix: " dBm"))
                        .font(.system(size: 36, weight: .heavy, design: .monospaced))
                        .tracking(-1.4)
                    Text(connectionStatus).font(.caption).foregroundStyle(.white.opacity(0.78))
                }
            }

            Text("信号参数").font(.headline).accessibilityAddTraits(.isHeader).padding(.top, 3)
            radioRow(kind: "5G", prefix: "N", band: "Nr_bands", power: "Z5g_rsrp", noise: "Nr_snr", quality: "nr_rsrq")
            radioRow(kind: "4G", prefix: "B", band: "Lte_bands", power: "lte_rsrp", noise: "Lte_snr", quality: "lte_rsrq")

            Card {
                VStack(spacing: 0) {
                    LineRow(title: "APN", value: device.network?.text("apn_wan_apn") ?? "—", icon: "network", mono: true)
                    Divider().padding(.leading, 44)
                    LineRow(title: "接入点模式", value: apnMode, icon: "switch.2")
                }
            }

            Card {
                VStack(spacing: 0) {
                    LineRow(title: "今日用量", value: formatBytes(device.base.number("daily_data")), icon: "clock")
                    Divider().padding(.leading, 44)
                    LineRow(title: "本月用量", value: formatBytes(device.base.number("monthly_data")), icon: "calendar")
                }
            }
        }
        .accessibilityIdentifier("network-screen")
    }

    private var connectionStatus: String {
        switch device.cellularConnected {
        case .some(true): "蜂窝已连接"
        case .some(false): "蜂窝未连接"
        case nil: "连接状态暂不可用"
        }
    }

    private var apnMode: String {
        switch device.network?.text("apn_mode") {
        case "auto": "自动"
        case "manual": "手动"
        default: "—"
        }
    }

    private func radioRow(kind: String, prefix: String, band: String, power: String, noise: String, quality: String) -> some View {
        let bandText = device.network?.text(band).map { " " + prefix + $0 } ?? ""
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                StatusChip(text: kind + bandText)
                HStack(spacing: 9) {
                    radioMetric("RSRP", power, "dBm")
                    radioMetric("SINR", noise, "dB")
                    radioMetric("RSRQ", quality, "dB")
                }
            }
            .padding(14)
        }
    }

    private func radioMetric(_ label: String, _ key: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption2.weight(.medium)).foregroundStyle(Palette.muted)
            Text(formatMetric(device.network?.number(key), suffix: " " + unit))
                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct ClientScreen: View {
    @EnvironmentObject private var model: AppModel
    let device: DeviceSnapshot
    @State private var query = ""
    @State private var access: ClientAccess?
    @State private var editing: ClientDevice?
    @State private var name = ""
    @State private var pendingBlock: ClientDevice?
    @State private var busy = false
    @State private var notice: String?

    private var matches: [ClientDevice] {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let clients = device.clients ?? []
        guard !key.isEmpty else { return clients }
        return clients.filter {
            $0.name.localizedCaseInsensitiveContains(key) || $0.ip.contains(key) || ($0.mac?.localizedCaseInsensitiveContains(key) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            PageHeading(title: "设备", detail: "当前热点客户端")

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.clients.map { String($0.count) } ?? "—")
                        .font(.system(size: 55, weight: .heavy, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text("台在线").font(.subheadline.weight(.medium))
                }
                .layoutPriority(1)
                Spacer()
                HStack(spacing: 10) {
                    Image(systemName: "iphone")
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 22))
                    Image(systemName: "laptopcomputer")
                }
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Palette.green)
                .accessibilityHidden(true)
            }
            .padding(.horizontal, 21).padding(.vertical, 17)
            .frame(maxWidth: .infinity)
            .background(Palette.lime, in: RoundedRectangle(cornerRadius: 21))
            .accessibilityElement(children: .combine)

            Card {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.green)
                    TextField("搜索设备", text: $query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("clients-search")
                    if !query.isEmpty {
                        Button("清除搜索", systemImage: "xmark.circle.fill") { query = "" }.labelStyle(.iconOnly)
                    }
                }
                .padding(14)
            }

            if matches.isEmpty {
                InlineNotice(text: device.clients == nil ? "当前无法读取客户端列表。" :
                                query.isEmpty ? "没有在线设备。" : "没有匹配的设备。", icon: "laptopcomputer")
            }
            if let notice { InlineNotice(text: notice) }

            ForEach(matches) { client in
                Card {
                    HStack(spacing: 12) {
                        Image(systemName: client.wired ? "cable.connector" : "wifi")
                            .foregroundStyle(Palette.green)
                            .frame(width: 41, height: 41)
                            .background(Palette.lime.opacity(0.65), in: RoundedRectangle(cornerRadius: 11))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(client.name).font(.subheadline.weight(.bold)).lineLimit(1)
                            Text(client.ip)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Palette.muted)
                        }
                        Spacer(minLength: 2)
                        StatusChip(text: client.wired ? "USB" : "Wi-Fi", filled: false)
                        if client.mac != nil, !model.demo {
                            Menu {
                                Button("改名", systemImage: "pencil") {
                                    name = client.name
                                    editing = client
                                }
                                if access != nil, access?.blocked.contains(where: { $0.id.lowercased() == client.id }) == false {
                                    Button("加入黑名单", systemImage: "hand.raised", role: .destructive) {
                                        pendingBlock = client
                                    }
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle").frame(width: 35, height: 38)
                            }
                            .disabled(busy)
                            .accessibilityLabel("管理 " + client.name)
                        }
                    }
                    .padding(13)
                    .accessibilityElement(children: .combine)
                }
                .contextMenu {
                    if client.ip != "—" { Button("复制 IP 地址", systemImage: "document.on.document") { UIPasteboard.general.string = client.ip } }
                    if let mac = client.mac { Button("复制 MAC 地址", systemImage: "document.on.document") { UIPasteboard.general.string = mac } }
                }
            }
            if let access, !access.blocked.isEmpty {
                Text("黑名单").font(.headline).accessibilityAddTraits(.isHeader)
                Card {
                    VStack(spacing: 0) {
                        ForEach(access.blocked) { blocked in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    if !blocked.name.isEmpty { Text(blocked.name).font(.subheadline.bold()) }
                                    Text(blocked.id).font(.caption.monospaced()).foregroundStyle(Palette.muted)
                                }
                                Spacer()
                                Button("移除") { Task { await changeAccess(mac: blocked.id) } }.disabled(busy)
                            }
                            .padding(14)
                            if blocked.id != access.blocked.last?.id { Divider().padding(.leading, 14) }
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("clients-screen")
        .task { await loadAccess() }
        .alert("修改设备名称", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } }),
               presenting: editing) { client in
            TextField("设备名称", text: $name)
            Button("保存") {
                let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if let mac = client.mac {
                    Task { await rename(mac: mac, to: value) }
                }
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("加入黑名单？",
                            isPresented: Binding(get: { pendingBlock != nil }, set: { if !$0 { pendingBlock = nil } }),
                            presenting: pendingBlock) { client in
            Button("阻止 " + client.name, role: .destructive) {
                if let mac = client.mac { Task { await changeAccess(mac: mac, name: client.name) } }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func loadAccess() async {
        guard !model.demo else { return }
        access = try? await model.routerSettingsClient().clientAccess()
    }

    private func rename(mac: String, to name: String) async {
        guard !name.isEmpty, name.count <= 64, name.rangeOfCharacter(from: CharacterSet(charactersIn: "<>;\n\r")) == nil else {
            notice = "请输入 1–64 个字符的设备名称。"
            return
        }
        await apply(.init(command: "EDIT_HOSTNAME", values: ["mac": mac, "hostname": name]))
    }

    private func changeAccess(mac: String, name: String? = nil) async {
        guard !busy else { return }
        do {
            let current = try await model.routerSettingsClient().clientAccess()
            await apply(current.action(mac: mac, name: name))
        } catch { notice = error.localizedDescription }
    }

    private func apply(_ action: FormAction) async {
        guard !busy else { return }
        busy = true
        notice = nil
        defer { busy = false }
        do {
            try await model.applyRouter(action)
            await model.refresh()
            await loadAccess()
            notice = "设备已保存设置。"
        } catch { notice = error.localizedDescription }
    }
}

struct ProxyScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            PageHeading(title: "代理", detail: "猫猫 TProxy Plus")

            RadioCard {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Mihomo").font(.caption.weight(.semibold)).foregroundStyle(Palette.lime)
                    Text(model.proxy.map { $0.running ? "运行中" : "已停止" } ??
                         (model.proxyLoading ? "读取状态…" : "待连接"))
                        .font(.largeTitle.weight(.heavy)).tracking(-0.8)
                    if let version = model.proxy?.version {
                        Text(version).font(.system(.subheadline, design: .monospaced)).foregroundStyle(.white.opacity(0.76))
                    }
                    if let status = model.proxy {
                        Button { confirm = true } label: {
                            Label(status.running ? "停止代理" : "启动代理", systemImage: status.running ? "stop.fill" : "play.fill")
                                .font(.subheadline.weight(.bold))
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(Palette.paper, in: RoundedRectangle(cornerRadius: 11))
                                .foregroundStyle(Palette.deep)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 6)
                        .disabled(model.proxyBusy || model.policyLoading || (!status.running && !status.hasConfig))
                    }
                }
            }

            if let status = model.proxy {
                Card {
                    VStack(spacing: 0) {
                        LineRow(title: "透明代理", value: status.ipv6 ? "IPv4 / IPv6" : "IPv4", icon: "point.topleft.down.to.point.bottomright.curvepath")
                        Divider().padding(.leading, 44)
                        Button {
                            Task { await model.setProxyAutostart(!status.autostart) }
                        } label: {
                            HStack(spacing: 0) {
                                LineRow(title: "开机自启", value: status.autostart ? "开启" : "关闭", icon: "power")
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                    .foregroundStyle(Palette.muted).padding(.trailing, 14).accessibilityHidden(true)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(status.autostart ? "关闭开机自启" : "开启开机自启")
                        .disabled(model.proxyBusy || model.policyLoading)
                    }
                }

                HStack(spacing: 10) {
                    ActionTile(title: "管理面板", icon: "macwindow") {
                        Task { await model.openPanel() }
                    }.disabled(model.demo)
                    ActionTile(title: "连接测试", icon: "link") {
                        Task { await model.runProbes() }
                    }
                }
                .disabled(!status.running || model.proxyBusy || model.policyLoading)
            }

            Card {
                Button { model.openManagement(.maomao) } label: {
                    ManagementRow(title: "猫猫插件设置", icon: "slider.horizontal.3")
                }
                .buttonStyle(.plain)
                .disabled(model.demo)
            }

            if model.proxy?.running == true { ProxyGroupsSection() }

            if model.proxyBusy {
                HStack(spacing: 9) { ProgressView().controlSize(.small); Text("等待设备响应…") }
                    .font(.footnote).foregroundStyle(Palette.muted).padding(.vertical, 8)
            }

            if let issue = model.proxyIssue {
                InlineNotice(text: issue, icon: "exclamationmark.circle")
                Button("重试状态检测") { Task { await model.refreshProxy() } }
                    .font(.subheadline.weight(.semibold)).disabled(model.proxyLoading)
            }

            if !model.probes.isEmpty {
                Text("连接结果").font(.headline).accessibilityAddTraits(.isHeader).padding(.top, 4)
                Card {
                    VStack(spacing: 0) {
                        ForEach(model.probes) { probe in
                            HStack(spacing: 9) {
                                Image(systemName: "globe").foregroundStyle(Palette.green)
                                Text(probe.name).font(.subheadline.weight(.medium))
                                Spacer()
                                StatusChip(text: probe.code > 0 ? String(probe.code) : "失败", filled: probe.passed)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            if probe.id != model.probes.last?.id { Divider().padding(.leading, 40) }
                        }
                    }
                }
            }
        }
        .task { await model.refreshProxy() }
        .task(id: model.proxy?.running) { await model.refreshPolicyGroups() }
        .confirmationDialog(model.proxy?.running == true ? "停止代理？" : "启动代理？",
                            isPresented: $confirm, titleVisibility: .visible) {
            Button(model.proxy?.running == true ? "停止" : "启动") { Task { await model.switchProxy() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会更改连接到该热点的设备的流量接管状态。")
        }
        .accessibilityIdentifier("proxy-screen")
    }
}

struct SettingsScreen: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(TurboWiFiReminder.enabledKey) private var wifiReminder = true
    @State private var confirm = false
    @State private var editingAlias = false
    @State private var alias = ""
    @State private var aliasBusy = false
    @State private var aliasIssue: String?
    @State private var showingAbout = false
    let device: DeviceSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            PageHeading(title: "设置")

            RadioCard {
                HStack(spacing: 14) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Palette.lime)
                        .frame(width: 41)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(device.model).font(.title2.weight(.bold)).lineLimit(1)
                        Text("UFI-TOOLS " + device.version).font(.caption.monospaced()).foregroundStyle(.white.opacity(0.78))
                    }
                    Spacer(minLength: 4)
                    StatusChip(text: model.demo ? "演示" : model.stale ? "更新失败" : "已连接", filled: !model.stale)
                }
            }

            Text("连接").font(.headline).accessibilityAddTraits(.isHeader)
            Card {
                VStack(spacing: 0) {
                    LineRow(title: "后台地址", value: model.endpoint?.address ?? "192.168.0.1:2333", icon: "network", mono: true)
                    Divider().padding(.leading, 44)
                    LineRow(title: "当前设备", value: device.model, icon: "wifi.router")
                    Divider().padding(.leading, 44)
                    Button {
                        Task { await loadAlias() }
                    } label: {
                        settingRow("修改设备别名", "pencil")
                    }
                    .disabled(model.demo || aliasBusy)
                }
            }
            if let aliasIssue { InlineNotice(text: aliasIssue, icon: "exclamationmark.circle") }

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Turbo Wi-Fi 连接提醒", isOn: $wifiReminder)
                        .font(.subheadline.weight(.semibold))
                        .disabled(model.demo)
                    Text("连接随身热点时显示在灵动岛和锁屏。可在快捷指令中设置 Wi-Fi 自动化，运行「检查 Turbo Wi-Fi」。")
                        .font(.caption)
                        .foregroundStyle(Palette.muted)
                }
                .padding(15)
            }

            Text("维护").font(.headline).accessibilityAddTraits(.isHeader)
            Card {
                VStack(spacing: 0) {
                    Button { model.openManagement() } label: {
                        settingRow("打开高级后台", "macwindow")
                    }
                    .disabled(model.endpoint == nil)
                    Divider().padding(.leading, 44)
                    Button { Task { await model.refresh() } } label: { settingRow("刷新设备信息", "arrow.clockwise") }
                        .disabled(model.refreshing || model.demo)
                    Divider().padding(.leading, 44)
                    Button { model.forgetDeviceCredentials() } label: { settingRow("清除钥匙串中的后台凭据", "key") }
                        .disabled(model.demo)
                    Divider().padding(.leading, 44)
                    Button { confirm = true } label: {
                        settingRow(model.demo ? "退出演示" : "断开连接", "rectangle.portrait.and.arrow.right", color: Palette.warning)
                    }
                }
            }

            if let credentialNotice = model.credentialNotice { InlineNotice(text: credentialNotice) }
            Card {
                Button { showingAbout = true } label: {
                    HStack(spacing: 11) {
                        Image(systemName: "info.circle")
                            .frame(width: 21).foregroundStyle(Palette.green)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("关于 Turbo UFI").font(.subheadline.weight(.semibold))
                            Text("github.com/Turbo1123").font(.caption).foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                            .foregroundStyle(Palette.muted).accessibilityHidden(true)
                    }
                    .padding(15)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("settings-about")
            }
        }
        .buttonStyle(.plain)
        .onChange(of: wifiReminder) { _, _ in Task { await TurboWiFiReminder.shared.preferenceChanged() } }
        .fullScreenCover(isPresented: $showingAbout) { AboutScreen() }
        .confirmationDialog(model.demo ? "退出演示？" : "断开设备连接？", isPresented: $confirm, titleVisibility: .visible) {
            Button(model.demo ? "退出" : "断开", role: .destructive) { model.disconnect() }
            Button("取消", role: .cancel) {}
        }
        .alert("设备别名", isPresented: $editingAlias) {
            TextField(device.model, text: $alias)
            Button("保存") { Task { await saveAlias() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("留空将恢复设备型号作为名称。")
        }
        .accessibilityIdentifier("settings-screen")
    }

    private func loadAlias() async {
        aliasBusy = true
        aliasIssue = nil
        defer { aliasBusy = false }
        do {
            alias = try await model.deviceAlias()
            editingAlias = true
        } catch {
            aliasIssue = error.localizedDescription
        }
    }

    private func saveAlias() async {
        aliasBusy = true
        aliasIssue = nil
        defer { aliasBusy = false }
        do { try await model.setDeviceAlias(alias) }
        catch { aliasIssue = error.localizedDescription }
    }

    private func settingRow(_ title: String, _ icon: String, color: Color = Palette.ink) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon).frame(width: 21).foregroundStyle(color).accessibilityHidden(true)
            Text(title).font(.subheadline.weight(.medium))
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted).accessibilityHidden(true)
        }
        .foregroundStyle(color)
        .padding(15)
        .contentShape(Rectangle())
    }
}
