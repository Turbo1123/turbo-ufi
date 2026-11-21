import SwiftUI
import Charts

struct DataLimitSettings {
    var enabled: Bool
    var forward: Bool
    var limit: String
    var unit = 1_073_741_824.0
    var period: String
    var source: String

    init(_ result: JSONObject) throws {
        guard let value = result.number("data_flow_max_limit"),
              let enabled = result.text("data_flow_limit_enabled") else { throw ConnectionError.invalidResponse }
        self.enabled = enabled == "1" || enabled == "true"
        let forward = result.text("data_limit_status_forward_enabled")
        self.forward = forward == "1" || forward == "true"
        unit = value > 0 && value < 1_073_741_824 ? 1_048_576 : 1_073_741_824
        limit = value > 0 ? (value / unit).formatted(.number.grouping(.never).precision(.fractionLength(0...12))) : ""
        period = result.text("data_flow_check_daily_or_monthly") == "daily" ? "daily" : "monthly"
        source = result.text("data_check_reference") == "android" ? "android" : "default"
    }

    func payload() throws -> [String: Any] {
        let bytes = limit.isEmpty ? -1 : (try? Double(limit, format: .number)).map { $0 * unit } ?? 0
        guard bytes.isFinite, bytes < Double(Int64.max), bytes > 0 || (!enabled && limit.isEmpty) else {
            throw ConnectionError.validation("请输入大于 0 的流量上限。")
        }
        return [
            "data_flow_limit_enabled": enabled ? "1" : "0",
            "data_limit_status_forward_enabled": forward ? "1" : "0",
            "data_flow_max_limit": Int64(bytes.rounded()),
            "data_flow_check_daily_or_monthly": period,
            "data_check_reference": source
        ]
    }

    static let demo = try! Self(JSONObject([
        "data_flow_limit_enabled": "0", "data_flow_max_limit": 21_474_836_480,
        "data_flow_check_daily_or_monthly": "monthly", "data_check_reference": "android"
    ]))
}

struct DataLimitEditor: View {
    @EnvironmentObject private var model: AppModel
    @State private var settings: DataLimitSettings?
    @State private var busy = false
    @State private var notice: String?

    var body: some View {
        RouterEditor(title: "UFI 流量限制") {
            RadioCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("本月流量").font(.caption.weight(.semibold)).foregroundStyle(Palette.lime)
                    Text(formatBytes(model.device?.base.number("monthly_data"))).font(.title.bold().monospaced())
                }
            }
            if let draft = Binding($settings) {
                Card {
                    VStack(spacing: 0) {
                        Toggle("启用流量限制", isOn: draft.enabled).padding(14)
                        Divider()
                        RouterField(label: "流量上限") {
                            HStack {
                                TextField("上限", text: draft.limit).keyboardType(.decimalPad)
                                Picker("单位", selection: draft.unit) {
                                    Text("MiB").tag(1_048_576.0)
                                    Text("GiB").tag(1_073_741_824.0)
                                }
                            }
                        }
                        Divider()
                        Picker("统计周期", selection: draft.period) {
                            Text("每日").tag("daily")
                            Text("每月").tag("monthly")
                        }
                        .padding(14)
                        Divider()
                        Picker("统计口径", selection: draft.source) {
                            Text("Android").tag("android")
                            Text("设备默认").tag("default")
                        }
                        .padding(14)
                        Divider()
                        Toggle("超限时转发提醒", isOn: draft.forward).padding(14)
                    }
                }
                .disabled(busy)
                InlineNotice(text: "启用后，设备达到上限时可能断开蜂窝数据。")
                RouterSave(disabled: busy) {
                    let value = draft.wrappedValue
                    Task { await save(value) }
                }
            } else if notice == nil {
                ProgressView().accessibilityLabel("正在读取流量限制")
            }
            if let notice { InlineNotice(text: notice) }
        }
        .task {
            do {
                settings = model.demo ? .demo : try await DataLimitSettings(model.routerSettingsClient().request("/api/get_data_limit"))
            } catch { notice = error.localizedDescription }
        }
    }

    private func save(_ draft: DataLimitSettings) async {
        busy = true
        notice = nil
        defer { busy = false }
        do {
            let payload = try draft.payload()
            if !model.demo {
                let response = try await model.routerSettingsClient().request("/api/set_data_limit", body: payload)
                guard response.text("result") == "success" else { throw ConnectionError.rejected }
            }
            notice = "已保存流量限制。"
        } catch { notice = error.localizedDescription }
    }
}

struct UsageHistory: View {
    @EnvironmentObject private var model: AppModel
    @State private var start = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
    @State private var end = Date()
    @State private var days: [DailyUsage]?
    @State private var busy = false
    @State private var notice: String?

    var body: some View {
        RouterEditor(title: "流量历史") {
            Card {
                VStack(spacing: 0) {
                    DatePicker("开始日期", selection: $start, in: ...Date(), displayedComponents: .date).padding(12)
                    Divider()
                    DatePicker("结束日期", selection: $end, in: ...Date(), displayedComponents: .date).padding(12)
                }
            }
            RouterSave(title: "查询", disabled: busy) { Task { await query() } }
            if busy { ProgressView().accessibilityLabel("正在查询流量历史") }
            if let notice { InlineNotice(text: notice) }
            if let days, !days.isEmpty {
                RadioCard {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("区间总用量").font(.caption.weight(.semibold)).foregroundStyle(Palette.lime)
                        Text(formatBytes(days.reduce(0) { $0 + $1.bytes })).font(.title2.monospaced().bold())
                    }
                }
                Card {
                    Chart(days.suffix(31)) { day in
                        BarMark(x: .value("日期", String(day.day.suffix(5))), y: .value("流量", day.bytes))
                            .foregroundStyle(Palette.green).cornerRadius(3)
                            .accessibilityValue(formatBytes(day.bytes))
                    }
                    .chartYAxis(.hidden)
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) }
                    .frame(height: 120)
                    .padding(14)
                }
                if days.count > 31 { InlineNotice(text: "图表显示区间内最近 31 天。") }
                Card {
                    LazyVStack(spacing: 0) {
                        ForEach(days.reversed()) { day in
                            LineRow(title: day.day, value: formatBytes(day.bytes), icon: "calendar", mono: true)
                            if day.id != days.first?.id { Divider().padding(.leading, 40) }
                        }
                    }
                }
            } else if days?.isEmpty == true {
                InlineNotice(text: "该日期区间没有流量记录。")
            }
        }
        .task { await query() }
    }

    private func query() async {
        guard !busy else { return }
        busy = true
        days = nil
        notice = nil
        defer { busy = false }
        let calendar = Calendar.current
        let first = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        guard first <= last, calendar.dateComponents([.day], from: first, to: last).day ?? 400 < 400,
              let next = calendar.date(byAdding: .day, value: 1, to: last) else {
            notice = "请选择不超过 400 天的有效日期区间。"
            return
        }
        do {
            days = model.demo ? AdvancedSnapshot.demo.usage : try await model.routerSettingsClient().usage(
                from: first, through: min(Date(), next.addingTimeInterval(-0.001)))
        } catch { notice = error.localizedDescription }
    }
}
