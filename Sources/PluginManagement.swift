import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

struct RouterPlugin: Identifiable, Equatable {
    let id = UUID()
    let name: String
    var code: String

    var disabled: Bool {
        code.hasPrefix("<!-- [kano_disabled]\n") && code.hasSuffix("\n[kano_disabled] -->")
    }

    mutating func toggle() {
        if disabled {
            code = String(code.dropFirst("<!-- [kano_disabled]\n".count).dropLast("\n[kano_disabled] -->".count))
        } else {
            code = "<!-- [kano_disabled]\n" + code + "\n[kano_disabled] -->"
        }
    }

    var block: String {
        "<!-- [KANO_PLUGIN_START] " + name + " -->\n" + code + "\n<!-- [KANO_PLUGIN_END] " + name + " -->"
    }
}

struct PluginRegistry {
    let original: String
    let entries: [RouterPlugin]
    private let gaps: [String]

    init(_ source: String) {
        original = source
        var entries: [RouterPlugin] = []
        var gaps: [String] = []
        var end = source.startIndex
        let pattern = #"<!--\s*\[KANO_PLUGIN_START\]\s*([^\r\n]*?)\s*-->([\s\S]*?)<!--\s*\[KANO_PLUGIN_END\]\s*\1\s*-->"#
        let regex = try! NSRegularExpression(pattern: pattern)
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let block = Range(match.range, in: source),
                  let name = Range(match.range(at: 1), in: source),
                  let code = Range(match.range(at: 2), in: source) else { continue }
            let title = source[name].trimmingCharacters(in: .whitespaces)
            guard Self.validName(title) else { continue }
            gaps.append(String(source[end..<block.lowerBound]))
            entries.append(RouterPlugin(name: title, code: source[code].trimmingCharacters(in: .whitespacesAndNewlines)))
            end = block.upperBound
        }
        gaps.append(String(source[end...]))
        self.entries = entries
        self.gaps = gaps
    }

    func rendered(with plugins: [RouterPlugin]) -> String {
        guard plugins != entries else { return original }
        var result = gaps[0]
        for index in entries.indices {
            if plugins.indices.contains(index) { result += plugins[index].block }
            result += gaps[index + 1]
        }
        for plugin in plugins.dropFirst(entries.count) { result += "\n\n" + plugin.block }
        return result
    }

    static func importPlugins(_ source: String, filename: String) throws -> [RouterPlugin] {
        let document = PluginRegistry(source)
        if !document.entries.isEmpty {
            guard document.gaps.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw ConnectionError.validation("插件集合包含未识别的内容，请导入原后台导出的完整文件。")
            }
            return document.entries
        }
        guard validName(filename), !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !source.contains("[KANO_PLUGIN_START]"), !source.contains("[KANO_PLUGIN_END]") else {
            throw ConnectionError.validation("文件不是可识别的 UFI-TOOLS 插件。")
        }
        return [RouterPlugin(name: filename, code: source)]
    }

    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 255
            && !name.contains("-->") && !name.contains("<")
            && name.rangeOfCharacter(from: .controlCharacters) == nil
    }
}

struct MarketPlugin: Identifiable {
    let name: String
    let url: URL
    let updated: String?
    let sha256: String?
    let md5: String?
    var id: String { name }
}

extension UFIClient {
    func pluginRegistry() async throws -> PluginRegistry {
        let value = try await request("/api/get_custom_head")
        guard let text = value.raw["text"] as? String else { throw ConnectionError.invalidResponse }
        return PluginRegistry(text)
    }

    func savePlugins(_ value: String, replacing original: String) async throws {
        guard try JSONSerialization.data(withJSONObject: ["text": value]).count <= 5 * 1024 * 1024 else {
            throw ConnectionError.validation("插件总量超出了设备的 5 MiB 限制。")
        }
        guard try await pluginRegistry().original == original else {
            throw ConnectionError.validation("设备上的插件已发生变化，请重新载入后再保存。")
        }
        let result = try await request("/api/set_custom_head", body: ["text": value], timeout: 25)
        guard result.text("result") == "success" else { throw ConnectionError.rejected }
    }

    func pluginMarket() async throws -> [MarketPlugin] {
        let list = try await request("/api/plugins_store", timeout: 20)
        guard let base = list.text("download_url").flatMap(URL.init(string:)), base.scheme == "https",
              base.host != nil, base.user == nil, base.password == nil,
              let response = list.object("res"), response.number("code") == 200,
              let files = response.object("data")?.array("content") else {
            throw ConnectionError.validation("设备的插件源暂不可用。")
        }
        var seen = Set<String>()
        return files.compactMap { item in
            guard let name = item.text("name"), PluginRegistry.validName(name),
                  name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
                  ["js", "txt", "html"].contains((name as NSString).pathExtension.lowercased()),
                  seen.insert(name).inserted else { return nil }
            let hashes = item.object("hash_info")
            return MarketPlugin(name: name, url: base.appendingPathComponent(name), updated: item.text("modified"),
                                sha256: hashes?.text("sha256"), md5: hashes?.text("md5"))
        }
    }
}

struct PluginExport: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]
    var text: String

    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, let text = String(data: data, encoding: .utf8) else {
            throw ConnectionError.invalidResponse
        }
        self.text = text
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { .init(regularFileWithContents: Data(text.utf8)) }
}

struct PluginsScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var registry: PluginRegistry?
    @State private var entries: [RouterPlugin] = []
    @State private var market: [MarketPlugin]?
    @State private var marketMode = false
    @State private var editOrder = false
    @State private var query = ""
    @State private var busy = false
    @State private var importing = false
    @State private var exporting = false
    @State private var notice: String?

    private let maxSize = 5 * 1024 * 1024

    var body: some View {
        RouterEditor(title: "插件管理") {
            Picker("内容", selection: $marketMode) {
                Text("已安装").tag(false)
                Text("插件市场").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(busy)
            if let notice { InlineNotice(text: notice) }
            if busy { ProgressView().controlSize(.small) }
            if marketMode { marketList }
            else { localList }
        }
        .task { await load() }
        .task(id: marketMode) { if marketMode && market == nil { await loadMarket() } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxSize else {
                    throw ConnectionError.validation("请选择不超过 5 MiB 的插件文件。")
                }
                let text = try String(contentsOf: url, encoding: .utf8)
                stage(try PluginRegistry.importPlugins(text, filename: url.lastPathComponent))
            } catch { notice = error.localizedDescription }
        }
        .fileExporter(isPresented: $exporting, document: PluginExport(text: registry?.rendered(with: entries) ?? ""),
                      contentType: .plainText, defaultFilename: "UFI-TOOLS-plugins.txt") { result in
            if case .failure(let error) = result { notice = error.localizedDescription }
        }
    }

    private var localList: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let registry {
                HStack {
                    Button("导入", systemImage: "plus") { importing = true }
                    Button("导出", systemImage: "square.and.arrow.up") { exporting = true }
                    Spacer()
                    Button(editOrder ? "完成排序" : "排序") { editOrder.toggle() }.disabled(entries.count < 2)
                }
                .font(.subheadline.weight(.semibold)).disabled(busy)
                if entries.isEmpty { InlineNotice(text: "没有已安装的插件。") }
                ForEach(entries) { entry in pluginRow(entry) }
                if entries != registry.entries {
                    InlineNotice(text: "保存后会更新设备上的插件列表。")
                    RouterSave(title: "保存到设备", disabled: busy) { Task { await save() } }
                    Button("撤销未保存修改") { entries = registry.entries; notice = nil }.disabled(busy)
                }
                if !entries.isEmpty {
                    Button("清空列表", role: .destructive) {
                        entries = []
                        notice = "已暂存清空操作，请保存到设备后生效。"
                    }
                    .font(.caption).disabled(busy)
                }
            }
            Button("重新载入") { Task { await load() } }.font(.subheadline).disabled(busy)
        }
    }

    private func pluginRow(_ plugin: RouterPlugin) -> some View {
        Card {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(plugin.name).font(.subheadline.bold())
                    Text(plugin.disabled ? "已停用" : "已启用").font(.caption)
                        .foregroundStyle(plugin.disabled ? Palette.muted : Palette.green)
                }
                Spacer()
                if editOrder, let index = entries.firstIndex(where: { $0.id == plugin.id }) {
                    Button { entries.swapAt(index, index - 1) } label: { Image(systemName: "arrow.up") }
                        .disabled(index == 0).accessibilityLabel("上移")
                    Button { entries.swapAt(index, index + 1) } label: { Image(systemName: "arrow.down") }
                        .disabled(index + 1 == entries.count).accessibilityLabel("下移")
                } else {
                    Menu {
                        Button(plugin.disabled ? "启用" : "停用") {
                            if let index = entries.firstIndex(where: { $0.id == plugin.id }) { entries[index].toggle() }
                        }
                        Button("删除", role: .destructive) { entries.removeAll { $0.id == plugin.id } }
                    } label: {
                        Image(systemName: "ellipsis.circle").frame(width: 38, height: 40)
                    }
                    .accessibilityLabel("管理 " + plugin.name)
                }
            }
            .padding(13)
            .disabled(busy)
        }
    }

    private var marketList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Card {
                TextField("搜索官方插件", text: $query).padding(13).autocorrectionDisabled()
            }
            if let market {
                if let host = market.first?.url.host { InlineNotice(text: "插件源 " + host) }
                let matches = market.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
                if matches.isEmpty { InlineNotice(text: "暂无匹配的插件。") }
                LazyVStack(spacing: 8) {
                    ForEach(matches) { item in
                        Card {
                            HStack {
                                Text(item.name).font(.subheadline.weight(.semibold))
                                Spacer(minLength: 10)
                                Button(entries.contains { $0.name == item.name } ? "重新导入" : "导入") {
                                    Task { await download(item) }
                                }
                                .font(.subheadline.bold()).disabled(busy || registry == nil)
                            }
                            .padding(13)
                        }
                    }
                }
            }
            Button("刷新插件市场") { Task { await loadMarket() } }.disabled(busy)
        }
    }

    private func stage(_ plugins: [RouterPlugin]) {
        for plugin in plugins {
            if let index = entries.firstIndex(where: { $0.name == plugin.name }) { entries[index] = plugin }
            else { entries.append(plugin) }
        }
        marketMode = false
        notice = "已导入到列表，保存到设备后生效。"
    }

    private func load() async {
        await operation {
            let result = model.demo ? PluginRegistry(RouterPlugin(name: "猫猫 TProxy Plus", code: "// Demo").block)
                : try await model.routerSettingsClient().pluginRegistry()
            registry = result
            entries = result.entries
        }
    }

    private func loadMarket() async {
        await operation {
            market = model.demo ? [] : try await model.routerSettingsClient().pluginMarket()
        }
    }

    private func save() async {
        guard let registry else { return }
        await operation {
            let value = registry.rendered(with: entries)
            if !model.demo { try await model.routerSettingsClient().savePlugins(value, replacing: registry.original) }
            let saved = PluginRegistry(value)
            self.registry = saved
            entries = saved.entries
            notice = "已保存插件列表。"
            await model.refreshPluginAvailability()
        }
    }

    private func download(_ item: MarketPlugin) async {
        await operation {
            let (stream, response) = try await URLSession.shared.bytes(from: item.url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  http.url?.scheme == "https", response.expectedContentLength <= maxSize else { throw ConnectionError.invalidResponse }
            var data = Data()
            for try await byte in stream {
                if data.count >= maxSize { throw ConnectionError.validation("插件超过 5 MiB。") }
                data.append(byte)
            }
            if let sha = item.sha256, UFIClient.hex(SHA256.hash(data: data)) != sha.lowercased() {
                throw ConnectionError.validation("插件的 SHA-256 校验不匹配。")
            }
            if let md5 = item.md5, UFIClient.hex(Insecure.MD5.hash(data: data)) != md5.lowercased() {
                throw ConnectionError.validation("插件的 MD5 校验不匹配。")
            }
            guard let source = String(data: data, encoding: .utf8) else { throw ConnectionError.invalidResponse }
            stage(try PluginRegistry.importPlugins(source, filename: item.name))
        }
    }

    private func operation(_ body: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        notice = nil
        defer { busy = false }
        do { try await body() } catch is CancellationError { } catch { notice = error.localizedDescription }
    }
}
