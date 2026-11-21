import Charts
import SwiftUI

struct OverviewDetails: View {
    let device: DeviceSnapshot
    let connections: JSONObject?
    let usb: USBStatus?
    let qos: CellularQoS?
    let samples: [MonitorSample]
    @State private var revealIdentifiers = false
    @State private var series: MonitorSeries = .cpu

    var body: some View {
        detail("基本状态", icon: "gauge.with.dots.needle.33percent") {
            rows(basic)
            if let qos {
                monitor("蜂窝 QoS", values: [("QCI", String(qos.qci)), ("下行", formatMetric(qos.down, suffix: " Mbps", digits: 1)),
                                            ("上行", formatMetric(qos.up, suffix: " Mbps", digits: 1))])
            }
        }
        detail("信号参数", icon: "antenna.radiowaves.left.and.right") {
            rows(fields(device.network, [("运营商信号", "network_signalbar"), ("载波聚合", "Lte_ca_status")]))
            signal("5G NR", [
                ("RSRP (dBm)", "Z5g_rsrp"), ("SINR (dB)", "Nr_snr"), ("RSRQ (dB)", "nr_rsrq"),
                ("RSSI (dBm)", "nr_rssi"), ("频段", "Nr_bands"), ("NR-ARFCN", "Nr_fcn"),
                ("带宽", "Nr_bands_widths"), ("PCI", "Nr_pci"), ("小区 ID", "Nr_cell_id")
            ])
            signal("4G LTE", [
                ("RSRP (dBm)", "lte_rsrp"), ("SINR (dB)", "Lte_snr"), ("RSRQ (dB)", "lte_rsrq"),
                ("RSSI (dBm)", "lte_rssi"), ("频段", "Lte_bands"), ("EARFCN", "Lte_fcn"),
                ("带宽", "Lte_bands_widths"), ("PCI", "Lte_pci"), ("小区 ID", "Lte_cell_id")
            ])
        }
        detail("设备属性", icon: "info.circle") {
            rows(attributes)
            if !identifiers.isEmpty {
                Toggle("显示完整设备标识", isOn: $revealIdentifiers).font(.subheadline).padding(13)
                rows(identifiers.map { name, value in
                    (name, revealIdentifiers ? value : "•••• " + String(value.suffix(4)))
                })
                .privacySensitive()
            }
        }
        detail("设备监控", icon: "waveform.path") {
            monitorChart
            rows([("CPU 使用率", formatMetric(device.base.number("cpu_usage"), suffix: "%", digits: 1)),
                  ("内存使用率", formatMetric(device.base.number("mem_usage"), suffix: "%", digits: 1)),
                  ("最高温度", formatMetric(device.temperature, suffix: " °C", digits: 1))])
            monitor("CPU 核心（使用率 · 当前 / 最大频率）", values: cores)
            monitor("内存与交换分区", values: memory)
            monitor("传感器温度", values: temperatures)
            monitor("连接统计", values: fields(connections, [
                ("TCP", "tcp"), ("TCP 活跃", "tcp_active"), ("TCP 其他", "tcp_other"),
                ("TCP IPv6", "tcp6"), ("UDP", "udp"), ("UDP IPv6", "udp6"), ("Unix", "unix")
            ]))
        }
    }

    private var basic: [(String, String)] {
        let base = device.base
        let net = device.network
        let charging = net?.text("battery_charging").map { $0 == "1" ? "充电中" : "未充电" }
        let used = [
            ("运营商", device.carrier), ("网络制式", device.networkType),
            ("蜂窝连接", device.cellularConnected.map { $0 ? "已连接" : "已断开" } ?? "—"),
            ("Wi-Fi 接入", net?.text("wifi_access_sta_num") ?? device.clients.map { String($0.filter { !$0.wired }.count) } ?? "—"),
            ("RSSI", net?.text("rssi") ?? net?.text("network_rssi") ?? "—"),
            ("电池", formatMetric(device.battery, suffix: "%")), ("充电状态", charging ?? "—"),
            ("电流", formatMetric(base.number("current_now").map { $0 / 1000 }, suffix: " mA", digits: 1)),
            ("电压", formatMetric(base.number("voltage_now").map { $0 / 1_000_000 }, suffix: " V", digits: 3)),
            ("本次联网", duration(net?.number("realtime_time"))),
            ("本月联网", duration(net?.number("monthly_time"))),
            ("本月下载", formatBytes(net?.number("monthly_rx_bytes"))),
            ("本月上传", formatBytes(net?.number("monthly_tx_bytes"))),
            ("今日蜂窝用量", formatBytes(base.number("daily_data"))),
            ("本月蜂窝用量", formatBytes(base.number("monthly_data")))
        ]
        let limit = (net?.text("data_volume_limit_size") ?? net?.text("flux_data_volume_limit_size"))?
            .split(separator: "_").compactMap { Double($0) }
        return used + [("套餐流量上限", formatBytes(limit.flatMap { $0.count == 2 ? $0[0] * $0[1] * 1_048_576 : nil }))]
            + fields(net, [("APN", "apn_wan_apn"), ("未读短信", "sms_unread_num")])
    }

    private var attributes: [(String, String)] {
        let base = device.base
        let internalStorage = storage(total: base.number("internal_total_storage"), used: base.number("internal_used_storage"),
                                      available: base.number("internal_available_storage"))
        let externalStorage = storage(total: base.number("external_total_storage"), used: base.number("external_used_storage"),
                                      available: base.number("external_available_storage"))
        return [("设备型号", device.model), ("UFI-TOOLS", device.version),
                ("某兴固件", device.network?.text("cr_version") ?? "—"),
                ("运行时间", duration(base.number("boot_time").map { $0 / 1_000 })),
                ("内部存储", internalStorage), ("外部存储", externalStorage),
                ("访问端 IP", base.text("client_ip") ?? "—"), ("USB", usb?.hostLabel ?? usb?.modeName ?? "—")]
            + fields(device.network, [("网关", "lan_ipaddr"), ("IPv4", "wan_ipaddr"), ("IPv6", "ipv6_wan_ipaddr"), ("SIM 卡槽", "sim_slot")])
    }

    private var identifiers: [(String, String)] {
        fields(device.network, [("IMEI", "imei"), ("ICCID", "iccid"), ("IMSI", "imsi"), ("MAC", "mac_address")])
            + [( "手机号", device.network?.text("msisdn") ?? device.network?.text("sim_msisdn") ?? "—")]
                .filter { $0.1 != "—" }
    }

    private var cores: [(String, String)] {
        let freq = device.base.embeddedObject("cpuFreqInfo")
        let usage = device.base.embeddedObject("cpuUsageInfo")
        let keys = Set(freq?.raw.keys.map { $0 } ?? []).union(usage?.raw.keys.map { $0 } ?? [])
        return keys.filter { $0.range(of: "^cpu[0-9]+$", options: .regularExpression) != nil }.sorted().map { core in
            let entry = freq?.object(core)
            let utilization = formatMetric(usage?.number(core), suffix: "%", digits: 1)
            let frequency = (entry?.text("cur") ?? "—") + " / " + (entry?.text("max") ?? "—") + " MHz"
            return (core.uppercased(), utilization + " · " + frequency)
        }
    }

    private var temperatures: [(String, String)] {
        (device.base.embeddedArray("cpu_temp_list") ?? []).compactMap { item in
            guard let name = item.text("type"), let temp = DeviceSnapshot.celsius(item.number("temp")) else { return nil }
            return (name.replacingOccurrences(of: "-thmzone", with: ""), formatMetric(temp, suffix: " °C", digits: 1))
        }
    }

    private var memory: [(String, String)] {
        let memory = device.base.embeddedObject("memInfo")
        return [("总内存", "mem_total_kb"), ("可用", "mem_available_kb"), ("已用", "mem_used_kb"),
                ("交换容量", "swap_total_kb"), ("交换已用", "swap_used_kb"), ("交换可用", "swap_free_kb")]
            .compactMap { title, key in memory?.number(key).map { (title, formatBytes($0 * 1024)) } }
            + fields(memory, [("交换使用率 (%)", "swap_usage_percent")])
    }

    private func detail<Content: View>(_ title: String, icon: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        Card {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 0) { content() }.padding(.top, 5)
            } label: {
                Label(title, systemImage: icon).font(.subheadline.weight(.semibold)).padding(.vertical, 6)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    private func signal(_ title: String, _ keys: [(String, String)]) -> some View {
        monitor(title, values: keys.map { ($0.0, device.network?.text($0.1) ?? "—") })
    }

    @ViewBuilder
    private var monitorChart: some View {
        if samples.count > 1 {
            Picker("监控曲线", selection: $series) {
                ForEach(MonitorSeries.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).padding(.vertical, 8)
            Chart(samples) { sample in
                if let value = sample[keyPath: series.keyPath] {
                    LineMark(x: .value("时间", sample.at), y: .value(series.rawValue, value))
                        .foregroundStyle(Palette.green)
                }
            }
            .chartYAxisLabel(series == .temperature ? "°C" : "%")
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
            .frame(height: 112).padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private func monitor(_ title: String, values: [(String, String)]) -> some View {
        Text(title).font(.caption.bold()).foregroundStyle(Palette.green).padding(.top, 13).padding(.bottom, 4)
        rows(values.isEmpty ? [("状态", "设备暂未返回")] : values)
    }

    private func rows(_ values: [(String, String)]) -> some View {
        ForEach(Array(values.enumerated()), id: \.offset) { index, row in
            if index > 0 { Divider() }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { Text(row.0); Spacer(minLength: 8); value(row.1) }
                VStack(alignment: .leading, spacing: 4) { Text(row.0); value(row.1) }
            }
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        }
    }

    private func value(_ text: String) -> some View {
        Text(text).foregroundStyle(Palette.muted).monospaced().textSelection(.enabled)
    }

    private func fields(_ object: JSONObject?, _ keys: [(String, String)]) -> [(String, String)] {
        keys.compactMap { title, key in object?.text(key).map { (title, $0) } }
            .filter { $0.1 != "null" }
    }

    private func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds >= 0, seconds < Double(Int.max) else { return "—" }
        return Duration.seconds(Int(seconds)).formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
    }

    private func storage(total: Double?, used: Double?, available: Double?) -> String {
        guard let total, total > 0 else { return "—" }
        return formatBytes(used ?? available.map { total - $0 }) + " / " + formatBytes(total)
    }
}

private enum MonitorSeries: String, CaseIterable, Identifiable {
    case cpu = "CPU", memory = "内存", temperature = "温度"
    var id: Self { self }

    var keyPath: KeyPath<MonitorSample, Double?> {
        switch self { case .cpu: \.cpu; case .memory: \.memory; case .temperature: \.temperature }
    }
}

struct DevicePowerControl: View {
    @EnvironmentObject private var model: AppModel
    let allowsShutdown: Bool
    @State private var pending: Command?
    @State private var stage = 0
    @State private var notice: String?
    @State private var busy = false

    private enum Command: String {
        case restart = "重启"
        case shutdown = "关机"
        var action: FormAction { .init(command: self == .restart ? "REBOOT_DEVICE" : "SHUTDOWN_DEVICE") }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            if let pending {
                HStack {
                    Button("取消") { reset() }.font(.caption)
                    Button((stage == 1 ? "确认" : "再次确认") + pending.rawValue, role: .destructive) {
                        if stage == 1 { stage = 2 }
                        else {
                            reset()
                            Task { await execute(pending) }
                        }
                    }
                    .buttonStyle(.bordered).font(.caption.bold())
                }
            } else {
                Menu {
                    Button("重启设备", systemImage: "arrow.clockwise", role: .destructive) { begin(.restart) }
                    if allowsShutdown {
                        Button("关闭设备", systemImage: "power", role: .destructive) { begin(.shutdown) }
                    }
                } label: {
                    Label("电源", systemImage: "power")
                        .font(.caption.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 9)
                        .background(Palette.white, in: Capsule())
                }
                .disabled(busy || model.demo)
            }
            if let notice { Text(notice).font(.caption).foregroundStyle(Palette.muted) }
        }
        .task(id: stage) {
            guard stage > 0 else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { reset() }
        }
    }

    private func begin(_ command: Command) {
        notice = command == .restart ? "重启期间热点会断开。" : "关机后需要在设备上重新开机。"
        pending = command
        stage = 1
    }

    private func reset() {
        pending = nil
        stage = 0
        notice = nil
    }

    private func execute(_ command: Command) async {
        busy = true
        defer { busy = false }
        do {
            try await model.applyRouter(command.action)
            notice = "设备已接受" + command.rawValue + "请求。"
        } catch {
            notice = error.localizedDescription
        }
    }
}
