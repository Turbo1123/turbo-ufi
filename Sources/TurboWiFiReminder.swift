import ActivityKit
import AppIntents
import Foundation
import Network

@MainActor
final class TurboWiFiReminder {
    static let shared = TurboWiFiReminder()
    static let enabledKey = "turboWiFiReminderEnabled"
    private static let targetKey = "turboWiFiReminderTarget"

    private struct Target: Codable, Equatable {
        let address: String
        let model: String
    }

    enum Result {
        case connected, away, unverified, needsDevice, disabled, activitiesDisabled, unavailable

        var message: LocalizedStringResource {
            switch self {
            case .connected: "已连接 Turbo Wi-Fi"
            case .away: "当前 Wi-Fi 不是已登记的随身热点"
            case .unverified: "暂时无法确认 Turbo Wi-Fi"
            case .needsDevice: "请先在 Turbo UFI 里连接一次随身热点"
            case .disabled: "Turbo Wi-Fi 提醒已关闭"
            case .activitiesDisabled: "请在 iPhone 设置中允许 Turbo UFI 使用实时活动"
            case .unavailable: "暂时无法显示 Turbo Wi-Fi 提醒"
            }
        }
    }

    private var revision = UUID()
    private var wasConfirmed = false
    private static let refreshInterval: TimeInterval = 25
    private static let staleInterval: TimeInterval = 90

    private var enabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    private var target: Target? {
        UserDefaults.standard.data(forKey: Self.targetKey).flatMap {
            try? JSONDecoder().decode(Target.self, from: $0)
        }
    }

    func register(endpoint: Endpoint, model: String) async {
        let path = await Self.currentWiFiPath()
        guard !Task.isCancelled, let path, Self.isWiFiGateway(endpoint.host, on: path) else { return }
        let newTarget = Target(address: endpoint.address, model: model)
        if newTarget != target, let data = try? JSONEncoder().encode(newTarget) {
            revision = UUID()
            wasConfirmed = false
            UserDefaults.standard.set(data, forKey: Self.targetKey)
        }
        _ = await synchronize(path)
    }

    func preferenceChanged() async {
        if enabled {
            _ = await check(allowRestart: true)
        } else {
            revision = UUID()
            await clear()
        }
    }

    func check(allowRestart: Bool = false) async -> Result {
        let path = await Self.currentWiFiPath()
        return await synchronize(path, allowRestart: allowRestart)
    }

    private static func currentWiFiPath() async -> NWPath? {
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        let paths = Self.paths(from: monitor)
        defer { monitor.cancel() }
        return await withTaskGroup(of: NWPath?.self) { group in
            group.addTask {
                var iterator = paths.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return nil
            }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
    }

    func watchWhileActive() async {
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        let paths = Self.paths(from: monitor)
        defer { monitor.cancel() }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                for await path in paths {
                    _ = await self.synchronize(path)
                }
            }
            group.addTask { @MainActor in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(Self.refreshInterval)) }
                    catch { return }
                    _ = await self.synchronize(monitor.currentPath)
                }
            }
        }
    }

    private func synchronize(_ path: NWPath?, allowRestart: Bool = false) async -> Result {
        guard !Task.isCancelled else { return .unavailable }
        let checkID = UUID()
        revision = checkID
        guard enabled else { await clear(); return .disabled }
        guard let target, let endpoint = try? Endpoint(target.address) else {
            await clear()
            return .needsDevice
        }
        guard let path else { return .unverified }
        guard Self.isWiFiGateway(endpoint.host, on: path) else {
            await clear()
            return .away
        }
        let reportedModel = try? await UFIClient.publicDeviceModel(at: endpoint)
        guard !Task.isCancelled, revision == checkID else { return .unavailable }
        guard reportedModel == target.model else {
            await clear()
            return reportedModel == nil ? .unverified : .away
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return .activitiesDisabled }

        let now = Date()
        let content = ActivityContent(state: TurboWiFiActivity.ContentState(confirmedAt: now),
                                      staleDate: now.addingTimeInterval(Self.staleInterval))
        if let activity = Activity<TurboWiFiActivity>.activities.first {
            wasConfirmed = true
            if now.timeIntervalSince(activity.content.state.confirmedAt) >= 10 {
                await activity.update(content)
            }
        } else if !wasConfirmed || allowRestart {
            do {
                _ = try Activity<TurboWiFiActivity>.request(attributes: TurboWiFiActivity(), content: content)
                wasConfirmed = true
            } catch {
                return .unavailable
            }
        }
        return .connected
    }

    private func clear() async {
        wasConfirmed = false
        for activity in Activity<TurboWiFiActivity>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private static func isWiFiGateway(_ address: String, on path: NWPath) -> Bool {
        guard path.status == .satisfied, path.usesInterfaceType(.wifi), let ip = IPv4Address(address) else { return false }
        return path.gateways.contains {
            guard case .hostPort(host: .ipv4(let gateway), port: _) = $0 else { return false }
            return gateway == ip
        }
    }

    private static func paths(from monitor: NWPathMonitor) -> AsyncStream<NWPath> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            monitor.pathUpdateHandler = { continuation.yield($0) }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "TurboUFI.WiFiReminder"))
        }
    }
}

struct CheckTurboWiFiIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "检查 Turbo Wi-Fi"
    static let description = IntentDescription("根据当前 Wi-Fi 更新灵动岛和锁屏上的随身热点提醒。")
    static var openAppWhenRun: Bool { false }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = await TurboWiFiReminder.shared.check(allowRestart: true)
        return .result(value: String(localized: result.message))
    }
}
