import Charts
import SwiftUI

enum SpeedTestMode: String, CaseIterable, Identifiable {
    case local = "内网", cellular = "蜂窝"
    var id: Self { self }
}

struct SpeedReading: Identifiable {
    let seconds: Double
    let bytes: Int
    let megabits: Double
    var id: Double { seconds }
}

extension UFIClient {
    func speedTest(mode: SpeedTestMode, megabytes: Int, threads: Int,
                   update: @escaping @Sendable (SpeedReading) async -> Void) async throws -> SpeedReading {
        guard [8, 16, 32, 64, 128, 256].contains(megabytes), (1...5).contains(threads) else {
            throw ConnectionError.invalidResponse
        }
        let bytes = megabytes * 1_048_576
        let requests: [(URLRequest, Int)]
        if mode == .local {
            requests = [(signedRequest("/api/speedtest", query: [.init(name: "ckSize", value: String(megabytes / 8))], timeout: 35), bytes)]
        } else {
            requests = (0..<threads).map { offset in
                let size = bytes / threads + (offset < bytes % threads ? 1 : 0)
                let query: [URLQueryItem] = [.init(name: "bytes", value: String(size)), .init(name: "t", value: UUID().uuidString)]
                return (signedRequest("/api/proxy/--https://speed.cloudflare.com/__down", query: query, timeout: 35), size)
            }
        }
        let meter = SpeedMeter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (request, size) in requests {
                group.addTask {
                    var received = 0
                    let (session, stream) = SpeedByteStream.open(request)
                    defer { session.invalidateAndCancel() }
                    for try await count in stream {
                        try Task.checkCancellation()
                        let amount = min(count, size - received)
                        received += amount
                        if let reading = await meter.record(amount) { await update(reading) }
                        if received >= size { break }
                    }
                    guard received == size else { throw ConnectionError.validation("测速数据未完整返回，请缩小单次用量后重试。") }
                }
            }
            try await group.waitForAll()
        }
        return await meter.finish()
    }
}

private actor SpeedMeter {
    private let start = ProcessInfo.processInfo.systemUptime
    private var last = ProcessInfo.processInfo.systemUptime
    private var total = 0
    private var lastTotal = 0

    func record(_ bytes: Int) -> SpeedReading? {
        total += bytes
        let now = ProcessInfo.processInfo.systemUptime
        let interval = now - last
        guard interval >= 0.28 else { return nil }
        let result = SpeedReading(seconds: now - start, bytes: total,
                                  megabits: Double(total - lastTotal) * 8 / interval / 1_000_000)
        last = now
        lastTotal = total
        return result
    }

    func finish() -> SpeedReading {
        let seconds = max(ProcessInfo.processInfo.systemUptime - start, 0.001)
        return SpeedReading(seconds: seconds, bytes: total, megabits: Double(total) * 8 / seconds / 1_000_000)
    }
}

private final class SpeedByteStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<Int, Error>.Continuation
    private init(_ continuation: AsyncThrowingStream<Int, Error>.Continuation) { self.continuation = continuation }

    static func open(_ request: URLRequest) -> (URLSession, AsyncThrowingStream<Int, Error>) {
        let (stream, continuation) = AsyncThrowingStream<Int, Error>.makeStream()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 45
        let session = URLSession(configuration: configuration, delegate: SpeedByteStream(continuation), delegateQueue: nil)
        let task = session.dataTask(with: request)
        continuation.onTermination = { _ in task.cancel() }
        task.resume()
        return (session, stream)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            let error = (response as? HTTPURLResponse).map { ConnectionError.http($0.statusCode) } ?? .invalidResponse
            continuation.finish(throwing: error)
            completionHandler(.cancel)
            return
        }
        guard response.mimeType?.lowercased() == "application/octet-stream" else {
            continuation.finish(throwing: ConnectionError.invalidResponse)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation.yield(data.count)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        continuation.finish(throwing: error)
    }
}

struct SpeedTestScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State var mode: SpeedTestMode
    @State private var size = 16
    @State private var threads = 1
    @State private var continuous = false
    @State private var task: Task<Void, Never>?
    @State private var readings: [SpeedReading] = []
    @State private var value: SpeedReading?
    @State private var notice: String?
    @State private var finished = false

    var body: some View {
        RouterEditor(title: "网络测速") {
            Picker("链路", selection: $mode) {
                ForEach(SpeedTestMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(task != nil)
            .onChange(of: mode) { _, _ in value = nil; readings = []; finished = false; notice = nil }

            RadioCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text(finished ? "平均下载速率" : "下载速率").font(.caption.bold()).foregroundStyle(Palette.lime)
                    Text(formatMetric(value?.megabits, suffix: " Mbps", digits: 1))
                        .font(.largeTitle.monospaced().bold()).accessibilityIdentifier("speed-result")
                    if let value {
                        Text(formatBytes(Double(value.bytes)) + " · " + formatMetric(value.seconds, suffix: " 秒", digits: 1))
                            .font(.footnote)
                    }
                }
            }
            if readings.count > 1 {
                Card {
                    Chart(readings) { point in
                        LineMark(x: .value("秒", point.seconds), y: .value("Mbps", point.megabits))
                            .foregroundStyle(Palette.green)
                    }
                    .chartYAxisLabel("Mbps")
                    .frame(height: 125).padding(14)
                }
            }
            Card {
                VStack(spacing: 0) {
                    setting("单次测试用量") {
                        Picker("单次测试用量", selection: $size) {
                            ForEach([8, 16, 32, 64, 128, 256], id: \.self) { Text("\($0) MiB").tag($0) }
                        }.labelsHidden()
                    }
                    if mode == .cellular {
                        Divider()
                        setting("并发连接") {
                            Picker("并发连接", selection: $threads) {
                                ForEach(1...5, id: \.self) { Text(String($0)).tag($0) }
                            }.labelsHidden()
                        }
                    }
                    Divider()
                    Toggle("循环测速", isOn: $continuous).font(.subheadline).padding(14)
                }
            }
            .disabled(task != nil)
            if mode == .cellular {
                InlineNotice(text: "由 U30 Air 访问 Cloudflare 测速地址。每轮最多使用 \(size) MiB 蜂窝流量。",
                             icon: "antenna.radiowaves.left.and.right")
            } else {
                InlineNotice(text: "测量 iPhone 与 U30 Air 之间的下载速率。")
            }
            if let notice { InlineNotice(text: notice) }
            if task != nil {
                RouterSave(title: "停止测速") { task?.cancel() }
            } else {
                RouterSave(title: "开始测速") { start() }
            }
        }
        .onDisappear { task?.cancel() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { task?.cancel() } }
        #if DEBUG
        .task {
            if ProcessInfo.processInfo.arguments.contains("--run-speed") { start() }
        }
        #endif
    }

    private func setting<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label).font(.subheadline.weight(.medium))
            Spacer()
            content()
        }
        .padding(14)
    }

    private func start() {
        guard task == nil else { return }
        task = Task {
            defer { task = nil }
            do {
                repeat {
                    readings = []
                    value = nil
                    notice = nil
                    finished = false
                    if model.demo {
                        for item in 1...6 {
                            try await Task.sleep(for: .milliseconds(200))
                            accept(SpeedReading(seconds: Double(item) / 5, bytes: item * 1_000_000, megabits: Double(62 + item * 3)))
                        }
                    } else {
                        value = try await model.routerSettingsClient().speedTest(mode: mode, megabytes: size, threads: threads) {
                            await accept($0)
                        }
                    }
                    finished = true
                    if continuous { try await Task.sleep(for: .seconds(2)) }
                } while continuous && !Task.isCancelled
            } catch {
                notice = Task.isCancelled ? "测速已停止。" : error.localizedDescription
            }
        }
    }

    private func accept(_ reading: SpeedReading) {
        guard !Task.isCancelled, value == nil || reading.seconds > (value?.seconds ?? 0) else { return }
        readings.append(reading)
        value = reading
    }
}
