import Foundation

struct WiFiProfile: Identifiable {
    let chip: String
    let accessPoint: String
    var name: String
    var password: String
    var auth: String
    var maximum: String
    var hidden: Bool
    var isolated: Bool

    var id: String { chip + ":" + accessPoint }

    static let security = [
        ("OPEN", "开放"), ("WPA2PSK", "WPA2"), ("WPA3PSK", "WPA3"), ("WPA2PSKWPA3PSK", "WPA2 / WPA3")
    ]

    init?(_ values: JSONObject) {
        guard values.text("AccessPointSwitchStatus") == "1", let chip = values.text("ChipIndex"),
              let accessPoint = values.text("AccessPointIndex"), let name = values.text("SSID"),
              let auth = values.text("AuthMode"), let maximum = values.text("ApMaxStationNumber") else { return nil }
        self.chip = chip
        self.accessPoint = accessPoint
        self.name = name
        self.auth = auth
        self.maximum = maximum
        password = values.text("Password").flatMap { encoded in
            let padded = encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4)
            return Data(base64Encoded: padded).map { String(decoding: $0, as: UTF8.self) }
        } ?? ""
        hidden = values.text("ApBroadcastDisabled") == "1"
        isolated = values.text("ApIsolate") == "1"
    }

    func action() throws -> FormAction {
        let ssid = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...32).contains(ssid.utf8.count) else {
            throw ConnectionError.validation("热点名称应为 1–32 字节。")
        }
        guard Int(maximum).map({ $0 > 0 }) == true else {
            throw ConnectionError.validation("最大接入数必须大于 0。")
        }
        guard Self.security.contains(where: { $0.0 == auth }) else {
            throw ConnectionError.validation("请选择设备支持的加密方式。")
        }
        guard auth == "OPEN" || (8...63).contains(pass.utf8.count) else {
            throw ConnectionError.validation("加密热点的密码应为 8–63 字节。")
        }
        var values = [
            "SSID": ssid, "ChipIndex": chip, "AccessPointIndex": accessPoint, "AuthMode": auth,
            "EncrypType": auth == "OPEN" ? "NONE" : "CCMP",
            "ApMaxStationNumber": maximum, "ApBroadcastDisabled": hidden ? "1" : "0",
            "ApIsolate": isolated ? "1" : "0"
        ]
        if auth != "OPEN" { values["Password"] = Data(pass.utf8).base64EncodedString() }
        return FormAction(command: "setAccessPointInfo", values: values)
    }

    static let demo = WiFiProfile(JSONObject([
        "AccessPointSwitchStatus": "1", "ChipIndex": "0", "AccessPointIndex": "0", "SSID": "U30 Air",
        "AuthMode": "WPA2PSK", "Password": Data("demo-1234".utf8).base64EncodedString(), "ApMaxStationNumber": "16"
    ]))!
}

struct LANSettings {
    var gateway: String
    var mask: String
    var dhcp: Bool
    var start: String
    var end: String
    var lease: String

    init?(_ values: JSONObject) {
        guard let gateway = values.text("lan_ipaddr"), let mask = values.text("lan_netmask"),
              let dhcp = values.text("dhcpEnabled") else { return nil }
        self.gateway = gateway
        self.mask = mask
        self.dhcp = dhcp == "1"
        start = values.text("dhcpStart") ?? ""
        end = values.text("dhcpEnd") ?? ""
        lease = values.text("dhcpLease_hour")?.replacingOccurrences(of: "h", with: "") ?? ""
    }

    func action() throws -> FormAction {
        let gateway = gateway.trimmingCharacters(in: .whitespacesAndNewlines)
        let mask = mask.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = start.trimmingCharacters(in: .whitespacesAndNewlines)
        let end = end.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (try? Endpoint(gateway)) != nil, let router = Self.ipv4(gateway),
              let subnetMask = Self.ipv4(mask), subnetMask.nonzeroBitCount > 0 else {
            throw ConnectionError.validation("请输入局域网 IPv4 地址和子网掩码。")
        }
        let hostMask = ~subnetMask
        guard hostMask & (hostMask &+ 1) == 0 else {
            throw ConnectionError.validation("子网掩码必须由连续的网络位组成。")
        }
        let network = router & subnetMask
        let broadcast = network | hostMask
        guard router > network, router < broadcast else {
            throw ConnectionError.validation("网关不能使用网络地址或广播地址。")
        }
        if dhcp {
            guard let first = Self.ipv4(start), let last = Self.ipv4(end),
                  router < first, first < last, last < broadcast else {
                throw ConnectionError.validation("地址池必须和网关在同一子网，起始地址大于网关且小于结束地址。")
            }
            guard Int(lease).map({ $0 > 0 }) == true else {
                throw ConnectionError.validation("DHCP 租期必须大于 0 小时。")
            }
        }
        return FormAction(command: "DHCP_SETTING", values: [
            "lanIp": gateway, "lanNetmask": mask, "lanDhcpType": dhcp ? "SERVER" : "DISABLE",
            "dhcpStart": dhcp ? start : "", "dhcpEnd": dhcp ? end : "", "dhcpLease": dhcp ? lease : "",
            "dhcp_reboot_flag": "1", "mac_ip_reset": dhcp ? "1" : "0"
        ])
    }

    private static func ipv4(_ value: String) -> UInt32? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { UInt8($0) }
        guard parts.count == 4, octets.count == 4 else { return nil }
        return octets.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    static let demo = LANSettings(JSONObject([
        "lan_ipaddr": "192.168.0.1", "lan_netmask": "255.255.255.0", "dhcpEnabled": "1",
        "dhcpStart": "192.168.0.100", "dhcpEnd": "192.168.0.200", "dhcpLease_hour": "24h"
    ]))!
}

struct RouterTask: Identifiable, Decodable {
    let id: String
    let time: String
    let repeatDaily: Bool
    let actionMap: [String: String]
    let lastRunTimestamp: Int64?
    let hasTriggered: Bool?

    var preset: TaskPreset? { TaskPreset.allCases.first { $0.action.parameters == actionMap } }
    var title: String { preset?.title ?? actionMap["goformId"] ?? "自定义动作" }

    static let demo = [
        RouterTask(id: "夜间关闭指示灯", time: "22:30", repeatDaily: true,
                   actionMap: TaskPreset.lightOff.action.parameters, lastRunTimestamp: nil, hasTriggered: false)
    ]
}

enum TaskPreset: String, CaseIterable, Identifiable {
    case lightOn, lightOff, cellularOn, cellularOff, networkAuto, networkLTE, restart
    var id: Self { self }
    var title: String {
        switch self {
        case .lightOn: "开启指示灯"
        case .lightOff: "关闭指示灯"
        case .cellularOn: "连接蜂窝数据"
        case .cellularOff: "断开蜂窝数据"
        case .networkAuto: "切换到 5G / 4G 自动"
        case .networkLTE: "切换到仅 4G"
        case .restart: "重启设备"
        }
    }
    var action: FormAction {
        switch self {
        case .lightOn, .lightOff:
            FormAction(command: "INDICATOR_LIGHT_SETTING", values: ["indicator_light_switch": self == .lightOn ? "1" : "0"])
        case .cellularOn: FormAction(command: "CONNECT_NETWORK")
        case .cellularOff: FormAction(command: "DISCONNECT_NETWORK")
        case .networkAuto, .networkLTE:
            FormAction(command: "SET_BEARER_PREFERENCE", values: ["BearerPreference": self == .networkAuto ? "WL_AND_5G" : "Only_LTE"])
        case .restart: FormAction(command: "REBOOT_DEVICE")
        }
    }
}

extension UFIClient {
    func wifiProfiles() async throws -> [WiFiProfile] {
        let values = try await routerRead("queryWiFiModuleSwitch,queryAccessPointInfo")
        if values.text("WiFiModuleSwitch") == "0" { return [] }
        guard let profiles = values.array("ResponseList") else { throw ConnectionError.invalidResponse }
        return profiles.compactMap(WiFiProfile.init)
    }

    func lanSettings() async throws -> LANSettings {
        let values = try await routerRead("lan_ipaddr,lan_netmask,dhcpEnabled,dhcpStart,dhcpEnd,dhcpLease_hour")
        guard let settings = LANSettings(values) else { throw ConnectionError.invalidResponse }
        return settings
    }

    func listTasks() async throws -> [RouterTask] {
        let wrapper = try await request("/api/list_tasks")
        guard let raw = wrapper.raw["tasks"] as? [[String: Any]] else { throw ConnectionError.invalidResponse }
        return try JSONDecoder().decode([RouterTask].self, from: JSONSerialization.data(withJSONObject: raw)).reversed()
    }

    func saveTask(_ task: RouterTask, credentials: DeviceCredentials) async throws {
        // The device-side scheduler needs the same admin credential used by the web UI.
        if task.actionMap["goformId"] != nil {
            _ = try await routerLogin(credentials)
            let saved = try await request("/api/update_admin_pwd", body: ["password": credentials.password])
            guard saved.text("result") == "success" else { throw ConnectionError.rejected }
        }
        let response = try await request("/api/add_task", body: [
            "id": task.id, "time": task.time, "repeatDaily": task.repeatDaily, "action": task.actionMap
        ])
        guard response.text("result") == "success" else { throw ConnectionError.rejected }
    }

    func deleteTask(_ task: RouterTask) async throws {
        let response = try await request("/api/remove_task", body: ["id": task.id])
        guard response.text("result") == "removed" else { throw ConnectionError.rejected }
    }
}
