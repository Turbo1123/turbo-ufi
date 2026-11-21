import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

struct SoftwareRelease {
    let name: String
    let version: String
    let url: URL
    let size: Int?
    let modified: String?
    let changelog: String

    func isNewer(than current: String) -> Bool {
        version.compare(current.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")), options: .numeric) == .orderedDescending
    }

    static func read(_ listing: JSONObject) throws -> SoftwareRelease? {
        guard let base = listing.text("base_uri").flatMap(URL.init(string:)), base.scheme == "https",
              base.host != nil, base.user == nil, base.password == nil,
              let body = listing.object("alist_res"), body.number("code") == 200,
              let files = body.object("data")?.array("content") else { throw ConnectionError.invalidResponse }
        let latest = files.compactMap { entry -> SoftwareRelease? in
            guard let name = entry.text("name"), name.lowercased().hasPrefix("ufi-tools"),
                  !name.contains("/"), !name.contains("\\"), name.lowercased().hasSuffix(".apk"),
                  let range = name.range(of: #"(?i)v?[0-9]+\.[0-9]+\.[0-9]+"#, options: .regularExpression) else { return nil }
            let version = String(name[range]).trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let size = entry.number("size").flatMap { (1...100_000_000).contains($0) ? Int($0) : nil }
            let changelog = (listing.text("changelog") ?? "").replacingOccurrences(of: #"(?i)<br\s*/?>"#,
                                                                                      with: "\n", options: .regularExpression)
            return SoftwareRelease(name: name, version: version, url: base.appendingPathComponent(name),
                                   size: size, modified: entry.text("modified"), changelog: changelog)
        }
        return latest.max { lhs, rhs in
            if lhs.version != rhs.version { return lhs.version.compare(rhs.version, options: .numeric) == .orderedAscending }
            return (lhs.modified ?? "") < (rhs.modified ?? "")
        }
    }
}

extension UFIClient {
    func availableRelease() async throws -> SoftwareRelease? {
        try await SoftwareRelease.read(request("/api/check_update", timeout: 25))
    }

    func updateStatus() async throws -> JSONObject {
        try await request("/api/download_apk_status")
    }

    func startUpdateDownload(_ release: SoftwareRelease) async throws {
        guard try await updateStatus().text("status") != "downloading" else {
            throw ConnectionError.validation("设备正在下载更新，请等当前下载结束。")
        }
        let status = try await request("/api/download_apk", body: ["apk_url": release.url.absoluteString])
        guard status.text("result") == "download_started" else { throw ConnectionError.rejected }
    }

    func downloadedAPKHash() async throws -> String {
        // The upstream installer uses this one fixed app-owned staging file.
        let command = "sha256sum /sdcard/Android/data/com.minikano.f50_sms/files/downloaded_app.apk"
        let response = try await request("/api/user_shell", body: ["command": command], timeout: 20)
        let output = response.text("result") ?? response.object("result")?.text("content") ?? ""
        guard let range = output.range(of: #"(?im)^\s*[a-f0-9]{64}(?=\s)"#, options: .regularExpression) else {
            throw ConnectionError.validation("设备未返回安装包校验值，请在原后台检查下载。")
        }
        return output[range].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func requestInstallation() async throws {
        let result = try await request("/api/install_apk", body: [:], timeout: 90)
        guard result.text("result") == "success" else { throw ConnectionError.rejected }
    }
}

struct SoftwareUpdateScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var release: SoftwareRelease?
    @State private var checked = false
    @State private var loading = false
    @State private var updating = false
    @State private var current: String?
    @State private var progress: Double?
    @State private var notice: String?
    @State private var exportFile: APKExport?
    @State private var exporting = false
    @State private var fetchingFile = false

    var body: some View {
        RouterEditor(title: "UFI-TOOLS 软件更新", canClose: !updating) {
            RadioCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("设备当前版本").font(.caption.bold()).foregroundStyle(Palette.lime)
                    Text(version).font(.largeTitle.bold().monospaced())
                }
            }
            if loading { ProgressView().accessibilityLabel("正在检查更新") }
            if let notice { InlineNotice(text: notice).accessibilityIdentifier("ota-notice") }
            if let release {
                releaseCard(release)
                if release.isNewer(than: version), !model.demo {
                    InlineNotice(text: "一键更新会下载、校验并安装设备上的 UFI-TOOLS。安装时后台可能暂时断开。")
                    RouterSave(title: "一键更新", disabled: updating || loading || fetchingFile) { Task { await update(release) } }
                } else if checked {
                    InlineNotice(text: "当前已是此更新源提供的最新版本。")
                }
                Button(fetchingFile ? "正在取得 APK…" : "下载 APK 文件") {
                    Task { await export(release) }
                }
                .font(.subheadline)
                .disabled(updating || fetchingFile || model.demo)
                if !release.changelog.isEmpty {
                    Card {
                        DisclosureGroup("更新日志") {
                            Text(release.changelog).font(.footnote)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 8).textSelection(.enabled)
                        }
                        .font(.subheadline.bold()).padding(14)
                    }
                }
            } else if checked {
                InlineNotice(text: "更新源暂未提供可识别的 UFI-TOOLS 安装包。")
            }
            if let progress {
                ProgressView(value: progress, total: 100) { Text("设备下载 \(Int(progress))%") }
            }
            Button("检查更新") { Task { await check() } }.disabled(updating || loading || fetchingFile)
        }
        .interactiveDismissDisabled(updating)
        .fileExporter(isPresented: $exporting, document: exportFile, contentType: APKExport.type,
                      defaultFilename: release?.name ?? "UFI-TOOLS.apk") { result in
            if case .failure(let error) = result { notice = error.localizedDescription }
            exportFile = nil
        }
        .task { await check() }
    }

    private var version: String { current ?? model.device?.version ?? "—" }

    private func releaseCard(_ release: SoftwareRelease) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 7) {
                Text(release.isNewer(than: version) ? "可用更新" : "源中最新版本")
                    .font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
                Text(release.version).font(.title2.bold().monospaced())
                Text(release.name).font(.caption)
                if let host = release.url.host {
                    Text(host + " · " + formatBytes(release.size.map(Double.init))).font(.caption).foregroundStyle(Palette.muted)
                }
            }
            .padding(15)
        }
    }

    private func check() async {
        guard !loading else { return }
        loading = true
        notice = nil
        defer { loading = false }
        do {
            if model.demo {
                release = SoftwareRelease(name: "UFI-TOOLS_WEB_V4.1.5.apk", version: "4.1.5",
                                          url: URL(string: "https://example.com/UFI-TOOLS.apk")!, size: 22_943_618,
                                          modified: nil, changelog: "演示版本")
            } else {
                let client = try model.routerSettingsClient()
                release = try await client.availableRelease()
                current = try? await client.request("/api/version_info").text("app_ver")
            }
            checked = true
        } catch {
            notice = error.localizedDescription
        }
    }

    private func update(_ release: SoftwareRelease) async {
        guard !updating, !model.demo, release.isNewer(than: version) else { return }
        updating = true
        progress = nil
        defer { updating = false; progress = nil }
        do {
            let client = try model.routerSettingsClient()
            notice = "正在取得更新源的安装包校验值。"
            let expected = try await referenceHash(release)
            try await client.startUpdateDownload(release)
            notice = "设备正在下载安装包。"
            progress = 0
            try await waitForDownload(client)
            notice = "正在校验设备下载的安装包。"
            guard try await client.downloadedAPKHash() == expected else {
                throw ConnectionError.validation("设备下载的安装包与更新源不一致，安装已停止。")
            }
            notice = "已校验，正在请求安装。"
            // The device service can restart before the install response reaches the client.
            var responseError: Error?
            do { try await client.requestInstallation() } catch { responseError = error }
            progress = nil
            for _ in 0..<15 {
                if let info = try? await client.request("/api/version_info", timeout: 3),
                   let installed = info.text("app_ver"),
                   installed.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")) == release.version {
                    current = installed
                    notice = "已验证设备运行新版 " + installed + "。"
                    await model.refresh()
                    return
                }
                try await Task.sleep(for: .seconds(2))
            }
            if let responseError { throw responseError }
            throw ConnectionError.validation("设备已接收安装请求，暂未能核对新版本。")
        } catch { notice = error.localizedDescription }
    }

    private func waitForDownload(_ client: UFIClient) async throws {
        for _ in 0..<180 {
            let status = try await client.updateStatus()
            let phase = status.text("status")
            progress = max(0, min(100, status.number("percent") ?? 0))
            if phase == "done", progress == 100 { return }
            if phase == "error" { throw ConnectionError.validation("设备下载更新失败。") }
            try await Task.sleep(for: .seconds(1))
        }
        throw ConnectionError.timeout
    }

    private func referenceHash(_ release: SoftwareRelease) async throws -> String {
        let file = try await fetchFile(release)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let buffer = try handle.read(upToCount: 1_048_576), !buffer.isEmpty {
            try Task.checkCancellation()
            hash.update(data: buffer)
        }
        return UFIClient.hex(hash.finalize())
    }

    private func fetchFile(_ release: SoftwareRelease) async throws -> URL {
        guard let expectedSize = release.size else {
            throw ConnectionError.validation("更新源没有提供安装包大小，无法核对下载。")
        }
        var request = URLRequest(url: release.url, timeoutInterval: 45)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (file, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.url?.scheme == "https", http.mimeType != "text/html",
              try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == expectedSize else {
            throw ConnectionError.invalidResponse
        }
        return file
    }

    private func export(_ release: SoftwareRelease) async {
        guard !fetchingFile else { return }
        fetchingFile = true
        notice = nil
        defer { fetchingFile = false }
        do {
            let file = try await fetchFile(release)
            exportFile = APKExport(data: try Data(contentsOf: file))
            exporting = true
        } catch { notice = error.localizedDescription }
    }
}

private struct APKExport: FileDocument {
    static let type = UTType(filenameExtension: "apk") ?? .data
    static let readableContentTypes = [type]
    let data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw ConnectionError.invalidResponse }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { .init(regularFileWithContents: data) }
}
