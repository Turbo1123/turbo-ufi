import SwiftUI

struct RadioSettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var page: Page
    @State private var lte: Set<Int> = []
    @State private var nr: Set<Int> = []
    @State private var nrBands = [1, 5, 8, 28, 41, 78]
    @State private var cells: JSONObject?
    @State private var rat = "16"
    @State private var pci = ""
    @State private var channel = ""
    @State private var ready = false
    @State private var busy = false
    @State private var notice: String?

    private enum Page: String, CaseIterable { case bands = "频段", cells = "基站" }
    private let lteBands = [1, 3, 5, 8, 34, 38, 39, 40, 41]

    init(showCells: Bool) {
        _page = State(initialValue: showCells ? .cells : .bands)
    }

    var body: some View {
        RouterEditor(title: "锁频与基站") {
            Picker("视图", selection: $page) {
                ForEach(Page.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(busy)
            InlineNotice(text: "限制频段或基站可能影响信号。解除锁定后恢复自动选择。", icon: "antenna.radiowaves.left.and.right")
            if busy { ProgressView().controlSize(.small).accessibilityLabel("正在读取设备") }
            if let notice { InlineNotice(text: notice) }
            switch page {
            case .bands:
                if ready { bandEditor }
            case .cells:
                cellEditor
            }
        }
        .task(id: page) { await refresh() }
    }

    private var bandEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            bandGroup("4G LTE", prefix: "B", bands: Set(lteBands).union(lte).sorted(), selected: $lte)
            bandGroup("5G NR", prefix: "n", bands: Set(nrBands).union(nr).sorted(), selected: $nr)
            RouterSave(title: "保存并刷新网络", disabled: busy) { Task { await saveBands(lte: lte, nr: nr) } }
            Button("解除全部锁频") { Task { await saveBands(lte: [], nr: []) } }.disabled(busy)
        }
    }

    private func bandGroup(_ title: String, prefix: String, bands: [Int], selected: Binding<Set<Int>>) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 60))], spacing: 8) {
                    ForEach(bands, id: \.self) { band in
                        let active = selected.wrappedValue.contains(band)
                        Button {
                            if active { selected.wrappedValue.remove(band) }
                            else { selected.wrappedValue.insert(band) }
                        } label: {
                            Text(prefix + String(band)).font(.callout.monospaced().bold())
                                .frame(maxWidth: .infinity, minHeight: 42)
                                .background(active ? Palette.lime : Palette.paper, in: RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(active ? .isSelected : [])
                    }
                }
            }
            .padding(14)
        }
        .disabled(busy)
    }

    private var cellEditor: some View {
        VStack(alignment: .leading, spacing: 11) {
            if let cells {
                Text("已锁基站").font(.headline)
                cellList(cells.array("locked_cell_info") ?? [], useAsChoice: false)
                Button("解锁全部基站") { Task { await changeCell(.init(command: "UNLOCK_ALL_CELL")) } }
                    .disabled(busy || (cells.array("locked_cell_info") ?? []).isEmpty)
                Text("选定基站").font(.headline)
                Card {
                    VStack(spacing: 0) {
                        Picker("制式", selection: $rat) {
                            Text("4G LTE").tag("12")
                            Text("5G NR").tag("16")
                        }
                        .padding(14)
                        Divider()
                        RouterField(label: "PCI") {
                            TextField("物理小区 ID", text: $pci).keyboardType(.numberPad)
                        }
                        Divider()
                        RouterField(label: "EARFCN / NR-ARFCN") {
                            TextField("信道编号", text: $channel).keyboardType(.numberPad)
                        }
                    }
                }
                .disabled(busy)
                RouterSave(title: "锁定基站", disabled: busy || pci.isEmpty || channel.isEmpty) {
                    guard let cell = Int(pci), (0...(rat == "12" ? 503 : 1007)).contains(cell),
                          let frequency = Int(channel), (0...3_279_165).contains(frequency) else {
                        notice = "请输入对应制式有效的 PCI 和信道编号。"
                        return
                    }
                    Task { await changeCell(.init(command: "CELL_LOCK", values: [
                        "pci": String(cell), "earfcn": String(frequency), "rat": rat
                    ])) }
                }
                HStack {
                    Text("邻区列表").font(.headline)
                    Spacer()
                    Button("刷新") { Task { await refresh() } }.disabled(busy)
                }
                cellList(cells.array("neighbor_cell_info") ?? [], useAsChoice: true)
            }
        }
    }

    @ViewBuilder
    private func cellList(_ cells: [JSONObject], useAsChoice: Bool) -> some View {
        if cells.isEmpty { InlineNotice(text: "没有基站记录") }
        else {
            Card {
                VStack(spacing: 0) {
                    ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                        let band = cell.text("band") ?? (cell.text("rat") == "12" ? "4G" : "5G")
                        let detail = "PCI " + (cell.text("pci") ?? "—") + " · " + (cell.text("earfcn") ?? "—")
                        Button {
                            pci = cell.text("pci") ?? ""
                            channel = cell.text("earfcn") ?? ""
                            if cell.text("rat") == "12" || band.hasPrefix("B") { rat = "12" }
                            if cell.text("rat") == "16" || band.hasPrefix("n") { rat = "16" }
                        } label: {
                            LineRow(title: band, value: detail, icon: "antenna.radiowaves.left.and.right", mono: true)
                        }
                        .buttonStyle(.plain)
                        .disabled(!useAsChoice || busy)
                        if index < cells.count - 1 { Divider().padding(.leading, 44) }
                    }
                }
            }
        }
    }

    private func refresh() async {
        guard !busy else { return }
        busy = true
        notice = nil
        defer { busy = false }
        do {
            if page == .bands {
                if model.demo { lte = [3]; nr = [41] }
                else {
                    let client = try model.routerSettingsClient()
                    let state = try await client.routerRead("lte_band_lock,nr_band_lock")
                    guard state.raw["lte_band_lock"] != nil, state.raw["nr_band_lock"] != nil else {
                        throw ConnectionError.invalidResponse
                    }
                    lte = Self.bandValues(state.text("lte_band_lock"))
                    nr = Self.bandValues(state.text("nr_band_lock"))
                    if let supported = try? await client.request("/api/getSupportNrBandList", query: [.init(name: "slot", value: "0")]),
                       let list = supported.raw["band_list"] as? [Int], !list.isEmpty { nrBands = list }
                }
                ready = true
            } else {
                cells = model.demo ? Self.demoCells : try await model.routerSettingsClient().routerRead("neighbor_cell_info,locked_cell_info")
            }
        } catch {
            notice = error.localizedDescription
        }
    }

    private static func bandValues(_ value: String?) -> Set<Int> {
        Set((value ?? "").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
    }

    private func saveBands(lte: Set<Int>, nr: Set<Int>) async {
        guard !busy else { return }
        busy = true
        notice = nil
        var applied = 0
        do {
            for (command, field, values) in [("LTE_BAND_LOCK", "lte_band_lock", lte), ("NR_BAND_LOCK", "nr_band_lock", nr)] {
                try await model.applyRouter(.init(command: command, values: [
                    field: values.sorted().map(String.init).joined(separator: ",")
                ]))
                applied += 1
            }
            if !model.demo {
                let client = try model.routerSettingsClient()
                // Always attempt to restore the modem even if a response is lost while stopping it.
                let stopped = await cycleRadio("5", client: client)
                let started = await cycleRadio("4", client: client)
                guard stopped && started else { throw ConnectionError.rejected }
            }
            self.lte = lte
            self.nr = nr
            notice = "设备已接受锁频设置。"
        } catch {
            notice = applied == 0 ? error.localizedDescription : "部分设置可能已生效。请重新打开此页核对。"
        }
        busy = false
    }

    private func cycleRadio(_ function: String, client: UFIClient) async -> Bool {
        var primary = false
        for slot in ["0", "1"] {
            if let result = try? await client.request("/api/AT", query: [
                .init(name: "command", value: "AT+SFUN=" + function), .init(name: "slot", value: slot)
            ]), slot == "0" {
                primary = result.raw["error"] == nil
            }
        }
        return primary
    }

    private func changeCell(_ action: FormAction) async {
        guard !busy else { return }
        busy = true
        notice = nil
        do {
            try await model.applyRouter(action)
            busy = false
            if !model.demo { await refresh() }
            notice = "设备已接受基站设置。"
        } catch {
            busy = false
            notice = error.localizedDescription
        }
    }

    private static let demoCells = JSONObject([
        "neighbor_cell_info": [["pci": "211", "earfcn": "504990", "band": "n41"]],
        "locked_cell_info": []
    ])
}
