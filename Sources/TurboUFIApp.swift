import SwiftUI
import WebKit

@main
struct TurboUFIApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            AppScreen()
                .environmentObject(model)
                .preferredColorScheme(.light)
                .task(id: model.refreshKey(for: scenePhase)) {
                    guard scenePhase == .active else { return }
                    await model.poll()
                }
                .task(id: model.rateRefreshKey(for: scenePhase)) {
                    guard scenePhase == .active, model.destination == .overview else { return }
                    await model.pollOverview()
                }
                .task(id: scenePhase == .active) {
                    guard scenePhase == .active else { return }
                    await TurboWiFiReminder.shared.watchWhileActive()
                }
                #if DEBUG
                .task { await model.launchForVerification() }
                #endif
        }
    }
}

enum Destination: String, CaseIterable, Identifiable {
    case overview, network, clients, proxy, advanced, settings

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "总览"
        case .network: "网络"
        case .clients: "设备"
        case .proxy: "代理"
        case .advanced: "高级"
        case .settings: "设置"
        }
    }

    var icon: String {
        switch self {
        case .overview: "rectangle.grid.2x2"
        case .network: "antenna.radiowaves.left.and.right"
        case .clients: "laptopcomputer"
        case .proxy: "point.3.connected.trianglepath.dotted"
        case .advanced: "slider.horizontal.3"
        case .settings: "gearshape"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var destination: Destination = .overview
    @Published private(set) var device: DeviceSnapshot?
    @Published private(set) var proxy: ProxyStatus?
    @Published private(set) var proxyInstalled = false
    @Published private(set) var policyGroups: [ProxyGroup] = []
    @Published private(set) var policyLoading = false
    @Published private(set) var policyIssue: String?
    @Published private(set) var samples: [RateSample] = []
    @Published private(set) var rate: RateSample?
    @Published private(set) var usb: USBStatus?
    @Published private(set) var connectionCounts: JSONObject?
    @Published private(set) var qos: CellularQoS?
    @Published private(set) var monitorSamples: [MonitorSample] = []
    @Published private(set) var probes: [Probe] = []
    @Published private(set) var connecting = false
    @Published private(set) var refreshing = false
    @Published private(set) var proxyBusy = false
    @Published private(set) var proxyLoading = false
    @Published private(set) var demo = false
    @Published private(set) var stale = false
    @Published private(set) var connectionIssue: String?
    @Published private(set) var proxyIssue: String?
    @Published private(set) var session = UUID()
    @Published var browser: ManagementPage?
    @Published var credentialNotice: String?

    private var client: UFIClient?
    private(set) var credentials = DeviceCredentials()
    private(set) lazy var browserData = WKWebsiteDataStore.nonPersistent()
    private var proxyRevision = UUID()
    private var lastProxyCheck: Date?
    private var checkPluginInProgress = false
    var endpoint: Endpoint? { client?.endpoint }

    func refreshKey(for phase: ScenePhase) -> String {
        session.uuidString + (phase == .active ? ":active" : ":background")
    }

    func rateRefreshKey(for phase: ScenePhase) -> String {
        refreshKey(for: phase) + ":" + destination.rawValue
    }

    func connect(address: String, token: String, password: String = "", multiUser: Bool = false,
                 rememberCredentials: Bool = false, rememberAddress: Bool = true) async {
        guard !connecting else { return }
        connecting = true
        connectionIssue = nil
        defer { connecting = false }

        do {
            let endpoint = try Endpoint(address)
            let entered = DeviceCredentials(token: token.trimmingCharacters(in: .whitespacesAndNewlines),
                                            password: password.trimmingCharacters(in: .whitespacesAndNewlines),
                                            multiUser: multiUser)
            let newClient = UFIClient(endpoint: endpoint, token: entered.token)
            let snapshot = try await newClient.snapshot()
            try Task.checkCancellation()
            client = newClient
            credentials = entered
            credentialNotice = nil
            if rememberCredentials, !CredentialStore.save(entered, for: endpoint) {
                credentialNotice = "当前已连接。钥匙串保存失败，下次连接时需要重新输入。"
            } else if rememberAddress && !rememberCredentials {
                CredentialStore.forget(endpoint)
            }
            destination = .overview
            accept(snapshot)
            if rememberAddress { UserDefaults.standard.set(endpoint.address, forKey: "lastDeviceAddress") }
            session = UUID()
            if rememberAddress {
                await TurboWiFiReminder.shared.register(endpoint: endpoint, model: snapshot.model)
            }
            await refreshPluginAvailability()
        } catch is CancellationError {
        } catch {
            connectionIssue = error.localizedDescription
        }
    }

    func disconnect() {
        session = UUID()
        browser = nil
        browserData = .nonPersistent()
        credentials = DeviceCredentials()
        credentialNotice = nil
        client = nil
        device = nil
        proxy = nil
        proxyInstalled = false
        checkPluginInProgress = false
        policyGroups = []
        policyLoading = false
        policyIssue = nil
        samples = []
        rate = nil
        usb = nil
        connectionCounts = nil
        qos = nil
        monitorSamples = []
        probes = []
        demo = false
        stale = false
        refreshing = false
        proxyLoading = false
        proxyBusy = false
        lastProxyCheck = nil
        connectionIssue = nil
        proxyIssue = nil
    }

    func enterDemo() {
        disconnect()
        demo = true
        destination = .overview
        device = .demo
        proxyInstalled = true
        policyGroups = ProxyGroup.demo
        proxy = .demo
        let now = Date()
        let values: [Double] = [5.9, 6.4, 7.7, 6.9, 7.2, 6.8, 5.8, 6.7, 8.4, 7.5, 7.2, 8.3]
        samples = values.enumerated().map { index, item in
            RateSample(at: now.addingTimeInterval(Double(index - values.count) * 5),
                       down: item * 1_000, up: Double(3 + index % 4) * 100)
        }
        rate = samples.last
        probes = [
            Probe(id: "demo-gstatic", name: "Google 静态资源", code: 204, time: 0.14),
            Probe(id: "demo-google", name: "Google", code: 204, time: 0.17),
            Probe(id: "demo-github", name: "GitHub", code: 200, time: 0.32)
        ]
    }

    func poll() async {
        guard client != nil else { return }
        await refreshPluginAvailability()
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            await refresh()
            if destination == .proxy { await refreshProxy(force: false) }
        }
    }

    func pollOverview() async {
        guard let client else { return }
        let current = session
        rate = nil
        async let speed: Void = pollRate(client, session: current)
        async let details: Void = pollConnectionDetails(client, session: current)
        async let qos: Void = pollQoS(client, session: current)
        _ = await (speed, details, qos)
    }

    private func pollRate(_ client: UFIClient, session current: UUID) async {
        let clock = ContinuousClock()
        while !Task.isCancelled, session == current {
            let deadline = clock.now.advanced(by: .seconds(1))
            let fresh = try? await client.readRates()
            guard !Task.isCancelled, session == current else { return }
            rate = fresh
            if let fresh {
                samples = samples.filter { fresh.at.timeIntervalSince($0.at) <= 120 }
                samples.append(fresh)
            }
            do { try await clock.sleep(until: deadline) } catch { return }
        }
    }

    private func pollConnectionDetails(_ client: UFIClient, session current: UUID) async {
        while !Task.isCancelled, session == current {
            async let usb = try? client.usbStatus()
            async let counts = try? client.request("/api/connInfo", timeout: 4).object("data")
            let (newUSB, newCounts) = await (usb, counts)
            guard !Task.isCancelled, session == current else { return }
            self.usb = newUSB
            connectionCounts = newCounts
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
        }
    }

    private func pollQoS(_ client: UFIClient, session current: UUID) async {
        while !Task.isCancelled, session == current {
            let currentDevice = device
            let read = try? await client.cellularQoS(network: currentDevice?.network, model: currentDevice?.model)
            guard !Task.isCancelled, session == current else { return }
            qos = read
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
        }
    }

    func refreshPluginAvailability() async {
        guard let client, !checkPluginInProgress else { return }
        let current = session
        checkPluginInProgress = true
        defer { if session == current { checkPluginInProgress = false } }
        guard let found = try? await client.hasMaomaoPlugin(), session == current, !Task.isCancelled else { return }
        proxyInstalled = found
        if !found {
            if destination == .proxy { destination = .overview }
            proxy = nil
            policyGroups = []
            lastProxyCheck = nil
        }
    }

    func refresh() async {
        guard let client, !refreshing else { return }
        let current = session
        refreshing = true
        defer { if session == current { refreshing = false } }
        do {
            let snapshot = try await client.snapshot()
            guard session == current, !Task.isCancelled else { return }
            accept(snapshot)
        } catch {
            guard session == current, !Task.isCancelled else { return }
            stale = true
        }
    }

    func refreshProxy(force: Bool = true) async {
        guard let client, proxyInstalled, !proxyBusy, !proxyLoading else { return }
        if !force, let lastProxyCheck, Date().timeIntervalSince(lastProxyCheck) < 20 { return }
        let current = session
        let revision = proxyRevision
        proxyLoading = true
        defer { if session == current { proxyLoading = false } }
        do {
            let result = try await client.proxyStatus()
            guard session == current, proxyInstalled, proxyRevision == revision, !Task.isCancelled else { return }
            proxy = result
            lastProxyCheck = Date()
            proxyIssue = nil
        } catch {
            guard session == current, proxyRevision == revision, !Task.isCancelled else { return }
            lastProxyCheck = Date()
            proxyIssue = error.localizedDescription
        }
    }

    func switchProxy() async {
        guard let running = proxy?.running else { return }
        if demo {
            proxy?.running.toggle()
            if running { probes = [] }
            return
        }
        await proxyOperation { client, current in
            proxyRevision = UUID()
            let updated = try await client.setProxyRunning(!running)
            guard session == current else { return }
            proxy = updated
            if running { probes = [] }
        }
    }

    func refreshPolicyGroups() async {
        guard !demo, proxy?.running == true else { return }
        await updatePolicyGroups { client in try await client.policyGroups() }
    }

    func setProxyAutostart(_ enabled: Bool) async {
        if demo {
            proxy?.autostart = enabled
            return
        }
        await proxyOperation { client, current in
            proxyRevision = UUID()
            let updated = try await client.setProxyAutostart(enabled)
            if session == current { proxy = updated }
        }
    }

    func deviceAlias() async throws -> String {
        guard let client else { throw ConnectionError.timeout }
        return try await client.deviceAlias()
    }

    func setDeviceAlias(_ nickname: String) async throws {
        guard let client else { throw ConnectionError.timeout }
        let value = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 255 else { throw ConnectionError.invalidResponse }
        try await client.setDeviceAlias(value)
    }

    func changePolicySelection(_ selection: ProxySelection, in group: ProxyGroup) async {
        guard proxy?.running == true, let index = policyGroups.firstIndex(where: { $0.id == group.id }) else { return }
        let latest = policyGroups[index]
        guard latest.canChange(to: selection) else { return }
        if demo {
            switch selection {
            case .node(let node):
                policyGroups[index].current = node
                if latest.kind != .selector { policyGroups[index].fixed = node }
            case .automatic:
                policyGroups[index].fixed = nil
                policyGroups[index].current = latest.nodes.first
            }
        } else {
            await updatePolicyGroups { client in try await client.changePolicySelection(selection, in: latest) }
        }
    }

    private func updatePolicyGroups(_ operation: (UFIClient) async throws -> [ProxyGroup]) async {
        guard let client, proxyInstalled, !policyLoading, !proxyBusy else { return }
        let current = session
        policyLoading = true
        policyIssue = nil
        defer { if session == current { policyLoading = false } }
        do {
            let groups = try await operation(client)
            if session == current, proxyInstalled, !Task.isCancelled { policyGroups = groups }
        } catch {
            if session == current, proxyInstalled, !Task.isCancelled { policyIssue = error.localizedDescription }
        }
    }

    func runProbes() async {
        if demo {
            probes = [Probe(id: "demo-gstatic", name: "Google 静态资源", code: 204, time: 0.14),
                      Probe(id: "demo-google", name: "Google", code: 204, time: 0.17),
                      Probe(id: "demo-github", name: "GitHub", code: 200, time: 0.32)]
            return
        }
        await proxyOperation { client, current in
            let results = try await client.testProxy()
            guard !results.isEmpty else { throw ConnectionError.invalidResponse }
            if session == current { probes = results }
        }
    }

    func openPanel() async {
        await proxyOperation { client, current in
            let url = try await client.panelURL()
            if session == current { browser = .init(url: url, title: "Mihomo 管理面板") }
        }
    }

    func openManagement(_ feature: ManagementFeature? = nil) {
        guard let endpoint else { return }
        browser = .init(url: endpoint.url(), title: "UFI-TOOLS", feature: feature)
    }

    func managementClosed() async {
        await refreshPluginAvailability()
        if destination == .proxy { await refreshPolicyGroups() }
    }

    func readAdvanced() async -> AdvancedSnapshot {
        if demo { return .demo }
        guard let client else { return .unavailable }
        return await client.advancedSnapshot()
    }

    func readInbox() async throws -> [SMSMessage] {
        if demo { return SMSMessage.demo }
        guard let client else { throw ConnectionError.timeout }
        return try await client.inbox()
    }

    func routerSettingsClient() throws -> UFIClient {
        guard let client else { throw ConnectionError.timeout }
        return client
    }

    func applyRouter(_ action: FormAction) async throws {
        if demo { return }
        let client = try routerSettingsClient()
        try await client.apply(action, credentials: credentials)
    }

    func forgetDeviceCredentials() {
        guard let endpoint else { return }
        credentialNotice = CredentialStore.forget(endpoint) ? "已从钥匙串移除保存的凭据。" : "钥匙串移除失败，请重试。"
    }

    private func proxyOperation(_ operation: (UFIClient, UUID) async throws -> Void) async {
        guard let client, proxyInstalled, !proxyBusy, !policyLoading else { return }
        let current = session
        proxyBusy = true
        proxyIssue = nil
        defer { if session == current { proxyBusy = false } }
        do { try await operation(client, current) }
        catch { if session == current { proxyIssue = error.localizedDescription } }
    }

    private func accept(_ snapshot: DeviceSnapshot) {
        device = snapshot
        stale = false
        let sample = MonitorSample(at: Date(), cpu: snapshot.base.number("cpu_usage"),
                                   memory: snapshot.base.number("mem_usage"), temperature: snapshot.temperature)
        monitorSamples = Array((monitorSamples + [sample]).suffix(25))
    }

    #if DEBUG
    private var didVerifyLaunch = false

    func launchForVerification() async {
        guard !didVerifyLaunch else { return }
        didVerifyLaunch = true
        let process = ProcessInfo.processInfo
        if process.arguments.contains("--demo") { enterDemo() }
        if let address = process.environment["TURBO_UFI_TEST_ENDPOINT"],
           let token = process.environment["TURBO_UFI_TEST_TOKEN"] {
            await connect(address: address, token: token,
                          password: process.environment["TURBO_UFI_TEST_ROUTER_PASSWORD"] ?? "",
                          rememberAddress: false)
        }
        if let index = process.arguments.firstIndex(of: "--page"),
           process.arguments.indices.contains(index + 1),
           let page = Destination(rawValue: process.arguments[index + 1]), page != .proxy || proxyInstalled {
            destination = page
        }
        if process.arguments.contains("--probe"), client != nil {
            await refreshProxy()
            await runProbes()
        }
        if process.arguments.contains("--web") { openManagement(.localSpeed) }
        if process.arguments.contains("--mihomo") { await openPanel() }
        if process.arguments.contains("--switch-demo"), demo, let group = policyGroups.first, let node = group.nodes.last {
            await changePolicySelection(.node(node), in: group)
        }
    }
    #endif
}
