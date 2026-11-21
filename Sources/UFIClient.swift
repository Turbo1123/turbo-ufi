import CryptoKit
import Foundation

enum ConnectionError: LocalizedError {
    case address, unauthorized, invalidResponse, serviceUnavailable, timeout, http(Int), routerPassword, rejected, validation(String)

    var errorDescription: String? {
        switch self {
        case .address: "请输入局域网 IPv4 地址，可附加端口，例如 192.168.0.1:2333。"
        case .unauthorized: "UFI-TOOLS 口令不正确，请重新输入。"
        case .invalidResponse: "此地址没有返回可识别的 UFI-TOOLS 数据。"
        case .serviceUnavailable: "设备未响应猫猫服务。请检查插件和 UFI-TOOLS 高级功能。"
        case .timeout: "无法访问后台。请确认已连接热点，并允许 Turbo UFI 访问本地网络。"
        case .http(let code): "设备返回 HTTP \(code)。"
        case .routerPassword: "请在连接设置中填写正确的某兴后台密码。"
        case .rejected: "设备未接受这项操作。"
        case .validation(let message): message
        }
    }
}

struct Endpoint: Sendable {
    let host: String
    let port: Int

    init(_ input: String) throws {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard let parts = URLComponents(string: address),
              parts.scheme == "http", parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              let host = parts.host, Self.isLocalIPv4(host),
              (1...65535).contains(parts.port ?? 2333) else { throw ConnectionError.address }
        self.host = host
        port = parts.port ?? 2333
    }

    var address: String { "\(host):\(port)" }

    func url(path: String = "/", port override: Int? = nil,
             query: [URLQueryItem] = [], fragment: String? = nil) -> URL {
        var parts = URLComponents()
        parts.scheme = "http"
        parts.host = host
        parts.port = override ?? port
        parts.path = path
        parts.queryItems = query.isEmpty ? nil : query
        parts.fragment = fragment
        // The host and port are checked when creating the endpoint.
        return parts.url!
    }

    private static func isLocalIPv4(_ host: String) -> Bool {
        let pieces = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = pieces.compactMap { piece -> Int? in
            guard let value = Int(piece), String(value) == piece, (0...255).contains(value) else { return nil }
            return value
        }
        guard pieces.count == 4, octets.count == 4 else { return false }
        #if DEBUG
        if octets == [127, 0, 0, 1] { return true }
        #endif
        return octets[0] == 10
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
    }
}

private final class RejectRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct UFIClient: Sendable {
    let endpoint: Endpoint
    private let authorization: String?

    // UFI-TOOLS publishes this protocol constant in API_Doc.md. Device access still requires its own token.
    private static let signingKey = SymmetricKey(data: Data("minikano_kOyXz0Ciz4V7wR0IeKmJFYFQ20jd".utf8))
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpShouldUsePipelining = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 12
        return URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
    }()

    init(endpoint: Endpoint, token: String) {
        self.endpoint = endpoint
        authorization = token.isEmpty ? nil : Self.hex(SHA256.hash(data: Data(token.utf8)))
    }

    func snapshot() async throws -> DeviceSnapshot {
        async let device = request("/api/baseDeviceInfo")
        async let network = request("/api/goform/goform_get_cmd_process", query: [
            URLQueryItem(name: "multi_data", value: "1"),
            URLQueryItem(name: "isTest", value: "false"),
            URLQueryItem(name: "cmd", value: Self.networkFields),
            URLQueryItem(name: "_", value: String(Int64(Date().timeIntervalSince1970 * 1000))),
        ])
        let base = try await device
        guard let model = base.text("model"), let version = base.text("app_ver") else {
            throw ConnectionError.invalidResponse
        }

        do {
            return DeviceSnapshot(model: model, version: version, base: base, network: try await network)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return DeviceSnapshot(model: model, version: version, base: base, network: nil)
        }
    }

    func readRates() async throws -> RateSample {
        let value = try await request("/api/goform/goform_get_cmd_process", query: [
            .init(name: "multi_data", value: "1"), .init(name: "isTest", value: "false"),
            .init(name: "cmd", value: "realtime_rx_thrpt,realtime_tx_thrpt"),
            .init(name: "_", value: String(Int64(Date().timeIntervalSince1970 * 1000)))
        ], timeout: 3)
        guard let down = value.number("realtime_rx_thrpt"), let up = value.number("realtime_tx_thrpt"),
              down >= 0, up >= 0 else { throw ConnectionError.invalidResponse }
        return RateSample(at: Date(), down: down, up: up)
    }

    func proxyStatus() async throws -> ProxyStatus {
        let values = Self.fields(try await shell(.status))
        guard let state = values["state"] else { throw ConnectionError.serviceUnavailable }
        return ProxyStatus(
            running: state == "running",
            version: values["core_version"]?.split(separator: " ").first(where: { $0.hasPrefix("v") }).map(String.init),
            ipv6: values["MM_IPV6"] == "1",
            autostart: values["autostart"] == "1",
            hasConfig: values["config"] == "present"
        )
    }

    func hasMaomaoPlugin() async throws -> Bool {
        let values = try await request("/api/get_custom_head")
        guard let source = values.raw["text"] as? String else { throw ConnectionError.invalidResponse }
        return Self.containsMaomaoPlugin(source)
    }

    static func containsMaomaoPlugin(_ source: String) -> Bool {
        let start = "<!-- [KANO_PLUGIN_START] "
        for line in source.split(whereSeparator: \.isNewline) where line.hasPrefix(start) && line.hasSuffix(" -->") {
            let name = String(line.dropFirst(start.count).dropLast(4))
            let lowered = name.lowercased()
            let isMaomao = lowered.hasPrefix("maomao-tproxy-plus")
                || (lowered.contains("猫猫") && lowered.contains("tproxy"))
            if isMaomao && source.contains("<!-- [KANO_PLUGIN_END] " + name + " -->") { return true }
        }
        return false
    }

    func setProxyRunning(_ running: Bool) async throws -> ProxyStatus {
        let output = try await shell(running ? .start : .stop)
        guard Self.fields(output)["exit"] == "0" else { throw ConnectionError.serviceUnavailable }
        return try await proxyStatus()
    }

    func setProxyAutostart(_ enabled: Bool) async throws -> ProxyStatus {
        _ = try await shell(enabled ? .autostartOn : .autostartOff)
        let updated = try await proxyStatus()
        guard updated.autostart == enabled else { throw ConnectionError.serviceUnavailable }
        return updated
    }

    func tailscaleStatus() async throws -> TailscaleStatus {
        let fields = Self.fields(try await shell(.tailscaleStatus, timeout: 8))
        guard let state = fields["state"].flatMap(TailscaleStatus.State.init(rawValue:)) else {
            throw ConnectionError.validation("设备暂时无法读取 Android VPN 状态。")
        }
        return TailscaleStatus(state: state, version: fields["version"], ipv4: fields["ipv4"],
                               ipv6: fields["ipv6"], dnsDomain: fields["dns"], alwaysOn: fields["always_on"] == "1")
    }

    func setTailscaleRunning(_ running: Bool) async throws -> TailscaleStatus {
        let current = try await tailscaleStatus()
        try current.checkChange(to: running)
        if current.running == running { return current }

        let result = Self.fields(try await shell(running ? .tailscaleConnect : .tailscaleDisconnect, timeout: 8))
        guard result["exit"] == "0" else { throw ConnectionError.rejected }

        for _ in 0..<12 {
            try await Task.sleep(for: .seconds(1))
            let updated = try await tailscaleStatus()
            if updated.running == running { return updated }
        }
        throw ConnectionError.validation(running
            ? "设备尚未建立 Tailscale 连接。请在 Android 桌面检查登录和 VPN 授权。"
            : "设备尚未断开 Tailscale，请刷新状态后再确认。")
    }

    func deviceAlias() async throws -> String {
        let values = try await request("/api/version_info")
        guard let nickname = values.raw["nickname"] as? String else { throw ConnectionError.invalidResponse }
        return nickname
    }

    func setDeviceAlias(_ nickname: String) async throws {
        let values = try await request("/api/set_nickname", body: ["nickname": nickname])
        guard values.text("result") == "success" else { throw ConnectionError.invalidResponse }
    }

    func testProxy() async throws -> [Probe] {
        try await shell(.connectivity, timeout: 76).split(separator: "\n").compactMap { line in
            guard line.hasPrefix("@test via=proxy ") else { return nil }
            let fields = Dictionary(line.split(separator: " ").dropFirst().compactMap { part -> (String, String)? in
                let pair = part.split(separator: "=", maxSplits: 1)
                guard pair.count == 2 else { return nil }
                return (String(pair[0]), String(pair[1]))
            }, uniquingKeysWith: { _, last in last })
            guard let address = fields["url"], let host = URL(string: address)?.host else { return nil }
            let name = host.contains("github") ? "GitHub" : host.contains("gstatic") ? "Google 静态资源" : "Google"
            return Probe(id: address, name: name, code: Int(fields["code"] ?? "") ?? 0,
                         time: Double(fields["time"] ?? ""))
        }
    }

    func panelURL() async throws -> URL {
        let secret = try await controllerSecret()
        return endpoint.url(path: "/ui/", port: 7788, fragment: "secret=" + secret)
    }

    func policyGroups() async throws -> [ProxyGroup] {
        let secret = try await controllerSecret()
        return try await policyGroups(secret: secret)
    }

    func changePolicySelection(_ selection: ProxySelection, in group: ProxyGroup) async throws -> [ProxyGroup] {
        guard group.canChange(to: selection), group.name != ".", group.name != ".." else {
            throw ConnectionError.invalidResponse
        }
        let secret = try await controllerSecret()
        let pathCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let name = group.name.addingPercentEncoding(withAllowedCharacters: pathCharacters),
              var components = URLComponents(url: endpoint.url(port: 7788), resolvingAgainstBaseURL: false) else {
            throw ConnectionError.invalidResponse
        }
        components.percentEncodedPath = "/proxies/" + name
        guard let url = components.url else { throw ConnectionError.invalidResponse }
        let (_, code): (Data, Int)
        switch selection {
        case .node(let node):
            (_, code) = try await controllerRequest(url, secret: secret, method: "PUT", node: node)
        case .automatic:
            (_, code) = try await controllerRequest(url, secret: secret, method: "DELETE")
        }
        guard code == 204 else { throw ConnectionError.invalidResponse }
        return try await policyGroups(secret: secret)
    }

    private func policyGroups(secret: String) async throws -> [ProxyGroup] {
        let (data, _) = try await controllerRequest(endpoint.url(path: "/proxies", port: 7788), secret: secret)
        guard let payload = try? JSONDecoder().decode(ProxyCatalog.self, from: data) else {
            throw ConnectionError.invalidResponse
        }
        return payload.groups
    }

    private func controllerRequest(_ url: URL, secret: String, method: String = "GET",
                                   node: String? = nil) async throws -> (Data, Int) {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = method
        request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
        if let node {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["name": node])
        }
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ConnectionError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ConnectionError.http(http.statusCode) }
        return (data, http.statusCode)
    }

    private func controllerSecret() async throws -> String {
        let output = try await shell(.secret)
        guard let secret = Self.fields(output)["secret"],
              secret.range(of: "^[a-f0-9]{48}$", options: .regularExpression) != nil else {
            throw ConnectionError.serviceUnavailable
        }
        return secret
    }

    func inbox() async throws -> [SMSMessage] {
        let values = try await request("/api/goform/goform_get_cmd_process", query: [
            .init(name: "multi_data", value: "1"), .init(name: "isTest", value: "false"),
            .init(name: "cmd", value: "sms_data_total"), .init(name: "page", value: "0"),
            .init(name: "data_per_page", value: "100"), .init(name: "mem_store", value: "1"),
            .init(name: "tags", value: "100"), .init(name: "order_by", value: "order by id desc"),
            .init(name: "_", value: String(Int64(Date().timeIntervalSince1970 * 1000)))
        ])
        guard let messages = values.array("messages") else { throw ConnectionError.invalidResponse }
        var seen = Set<String>()
        return messages.compactMap(SMSMessage.init).filter { seen.insert($0.id).inserted }
    }

    func advancedSnapshot() async -> AdvancedSnapshot {
        async let usage = try? weeklyUsage()
        async let usb = try? usbStatus()
        return await AdvancedSnapshot(usage: usage, usb: usb)
    }

    private func weeklyUsage() async throws -> [DailyUsage] {
        let now = Date()
        let calendar = Calendar.current
        guard let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) else {
            throw ConnectionError.invalidResponse
        }
        return try await usage(from: start, through: now)
    }

    func usage(from start: Date, through end: Date) async throws -> [DailyUsage] {
        let data = try await request("/api/cellularUsage", query: [
            .init(name: "method", value: "date-range"),
            .init(name: "startTime", value: String(Int64(start.timeIntervalSince1970 * 1000))),
            .init(name: "endTime", value: String(Int64(end.timeIntervalSince1970 * 1000)))
        ], timeout: 35)
        guard let usage = data.array("usage") else { throw ConnectionError.invalidResponse }
        return usage.compactMap { item in
            guard let day = item.text("date"), let bytes = item.number("usage"), bytes >= 0 else { return nil }
            return DailyUsage(day: day, bytes: bytes)
        }
    }

    func usbStatus() async throws -> USBStatus {
        let data = try await request("/api/usb_status")
        guard let details = data.object("details"), let mode = details.text("typec_mode") else {
            throw ConnectionError.invalidResponse
        }
        let peripherals = details.array("devices")?.compactMap { device -> USBStatus.Peripheral? in
            guard let path = device.text("path") else { return nil }
            let speed = device.text("speed").map { $0 + " Mbps" }
            return .init(id: path, product: device.text("product") ?? path, speed: speed)
        }
        return USBStatus(mode: mode, speed: details.text("gadget_speed"), devices: peripherals)
    }

    private enum Command: String {
        case status, start, stop, connectivity, secret, autostartOn, autostartOff
        case tailscaleStatus, tailscaleConnect, tailscaleDisconnect

        var statement: String {
            let service = "/data/clash/Scripts/Clash.Service"
            switch self {
            case .status: return "\(service) info; \(service) live"
            case .start, .stop:
                return "\(service) \(rawValue); printf '\\n@exit=%s\\n' \"$?\""
            case .connectivity, .secret: return "\(service) \(rawValue)"
            case .autostartOn: return service + " autostart on"
            case .autostartOff: return service + " autostart off"
            case .tailscaleStatus: return TailscaleStatus.androidCommand
            case .tailscaleConnect, .tailscaleDisconnect:
                let action = self == .tailscaleConnect ? "CONNECT_VPN" : "DISCONNECT_VPN"
                return "/system/bin/am broadcast --user 0 --receiver-foreground -a com.tailscale.ipn.\(action) -n com.tailscale.ipn/.IPNReceiver; printf '\\n@exit=%s\\n' \"$?\""
            }
        }
    }

    private func shell(_ command: Command, timeout: TimeInterval = 25) async throws -> String {
        let values = try await request("/api/root_shell",
            body: ["command": command.statement, "timeout": Int(timeout * 1_000)],
            timeout: timeout + 4)
        if let text = values.text("result") { return text }
        if let result = values.object("result"),
           let content = result.text("content"), result.raw["done"] as? Bool != false {
            return content
        }
        throw ConnectionError.serviceUnavailable
    }

    func request(_ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil,
                         timeout: TimeInterval = 10) async throws -> JSONObject {
        var request = signedRequest(path, query: query, method: body == nil ? "GET" : "POST", timeout: timeout)
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, _) = try await send(request)
        return try Self.parseJSONObject(data)
    }

    func signedRequest(_ path: String, query: [URLQueryItem] = [], method: String = "GET",
                       timeout: TimeInterval = 10) -> URLRequest {
        let timestamp = String(Int64(Date().timeIntervalSince1970 * 1_000))
        let digest = Array(HMAC<Insecure.MD5>.authenticationCode(
            for: Data("minikano\(method)\(path)\(timestamp)".utf8), using: Self.signingKey))
        let first = SHA256.hash(data: Data(digest.prefix(8)))
        let second = SHA256.hash(data: Data(digest.suffix(8)))
        var request = URLRequest(url: endpoint.url(path: path, query: query), timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue(timestamp, forHTTPHeaderField: "kano-t")
        request.setValue(Self.hex(SHA256.hash(data: Data(Array(first) + Array(second)))), forHTTPHeaderField: "kano-sign")
        request.setValue(authorization, forHTTPHeaderField: "authorization")
        return request
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch let urlError as URLError where urlError.code != .cancelled {
            throw ConnectionError.timeout
        }
        guard let response = response as? HTTPURLResponse else { throw ConnectionError.invalidResponse }
        if response.statusCode == 401 || response.statusCode == 403 { throw ConnectionError.unauthorized }
        guard (200..<300).contains(response.statusCode) else { throw ConnectionError.http(response.statusCode) }
        return (data, response)
    }

    static func parseJSONObject(_ data: Data) throws -> JSONObject {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConnectionError.invalidResponse
        }
        return JSONObject(value)
    }

    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func fields(_ text: String) -> [String: String] {
        Dictionary(text.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("@") else { return nil }
            let pair = line.dropFirst().split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { return nil }
            return (String(pair[0]), String(pair[1]))
        }, uniquingKeysWith: { _, last in last })
    }

    private static let networkFields = [
        "network_provider", "network_type", "network_signalbar", "Z5g_rsrp", "Nr_bands",
        "Nr_snr", "nr_rsrq", "Lte_bands", "lte_rsrp", "Lte_snr", "lte_rsrq", "ppp_status",
        "station_list", "lan_station_list", "apn_mode", "apn_wan_apn",
        "Lte_fcn", "Lte_bands_widths", "Lte_pci", "lte_rssi", "Lte_cell_id", "Lte_ca_status",
        "Nr_fcn", "Nr_bands_widths", "Nr_pci", "nr_rssi", "Nr_cell_id", "rssi", "network_rssi",
        "battery_charging", "battery_value", "battery_vol_percent", "sms_unread_num", "sim_slot", "dual_sim_support",
        "wifi_access_sta_num", "cr_version", "iccid", "imei", "imsi", "msisdn", "sim_msisdn",
        "ipv6_wan_ipaddr", "wan_ipaddr", "lan_ipaddr", "mac_address",
        "realtime_time", "monthly_time", "monthly_tx_bytes", "monthly_rx_bytes",
        "data_volume_limit_size", "flux_data_volume_limit_size", "data_volume_alert_percent"
    ].joined(separator: ",")
}

struct JSONObject: @unchecked Sendable {
    let raw: [String: Any]
    init(_ raw: [String: Any]) { self.raw = raw }

    func text(_ key: String) -> String? {
        if let value = raw[key] as? String {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return (raw[key] as? NSNumber)?.stringValue
    }

    func number(_ key: String) -> Double? {
        text(key).flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil }
    }

    func object(_ key: String) -> JSONObject? {
        (raw[key] as? [String: Any]).map(JSONObject.init)
    }

    func array(_ key: String) -> [JSONObject]? {
        (raw[key] as? [[String: Any]])?.map(JSONObject.init)
    }

    func embeddedObject(_ key: String) -> JSONObject? {
        if let value = object(key) { return value }
        guard let value = text(key) else { return nil }
        return try? UFIClient.parseJSONObject(Data(value.utf8))
    }

    func embeddedArray(_ key: String) -> [JSONObject]? {
        if let value = array(key) { return value }
        guard let value = text(key), let decoded = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [[String: Any]] else { return nil }
        return decoded.map(JSONObject.init)
    }
}

struct DeviceSnapshot {
    let model: String
    let version: String
    let base: JSONObject
    let network: JSONObject?

    var networkType: String {
        let type = network?.text("network_type") ?? "—"
        return ["ENDC": "5G NSA", "LTE": "4G LTE", "20": "5G", "13": "4G LTE"][type] ?? type
    }

    var carrier: String {
        let carrier = network?.text("network_provider") ?? "—"
        return ["CMCC": "中国移动", "CHINA MOBILE": "中国移动",
                "CUCC": "中国联通", "CHN-UNICOM": "中国联通", "CTCC": "中国电信"][carrier.uppercased()] ?? carrier
    }

    var cellularConnected: Bool? {
        network?.text("ppp_status").map { $0 != "ppp_disconnected" && $0.hasSuffix("_connected") }
    }

    var clients: [ClientDevice]? {
        guard let network,
              network.array("station_list") != nil || network.array("lan_station_list") != nil else { return nil }
        let wired = (network.array("lan_station_list") ?? []).compactMap { ClientDevice($0, wired: true) }
        let wireless = (network.array("station_list") ?? []).compactMap { ClientDevice($0, wired: false) }
        var seen = Set<String>()
        return (wireless + wired).filter { seen.insert($0.id).inserted }
    }

    var temperature: Double? { Self.celsius(base.number("cpu_temp")) }
    var battery: Double? { network?.number("battery_value") ?? network?.number("battery_vol_percent") ?? base.number("battery") }

    static func celsius(_ reported: Double?) -> Double? {
        guard let reported else { return nil }
        let value = abs(reported) >= 1_000 ? reported / 1_000 : reported
        return (-60...160).contains(value) ? value : nil
    }

    static let demo = DeviceSnapshot(model: "U30 Air", version: "4.1.5", base: JSONObject([
        "battery": 100, "cpu_temp": 55.2, "monthly_data": 378_450_000, "daily_data": 348_100_000,
        "cpu_usage": 5.2, "mem_usage": 59.3
    ]), network: JSONObject([
        "network_type": "ENDC", "network_provider": "CMCC", "ppp_status": "ipv4_ipv6_connected",
        "network_signalbar": 4, "realtime_rx_thrpt": 8_300, "realtime_tx_thrpt": 420,
        "Z5g_rsrp": -103, "Nr_snr": 2, "nr_rsrq": -18, "Nr_bands": 41,
        "lte_rsrp": -87, "Lte_snr": 13, "lte_rsrq": -8, "Lte_bands": 3,
        "apn_mode": "auto", "apn_wan_apn": "NET",
        "station_list": [["hostname": "iPhone", "ip_addr": "192.168.0.101"], ["hostname": "MacBook Air", "ip_addr": "192.168.0.102"]]
    ]))
}

struct ClientDevice: Identifiable {
    let id: String
    let name: String
    let ip: String
    let mac: String?
    let wired: Bool

    init?(_ object: JSONObject, wired: Bool) {
        let mac = object.text("mac_addr")
        let ip = object.text("ip_addr")
        guard let id = mac?.lowercased() ?? ip else { return nil }
        self.id = id
        self.name = object.text("hostname") ?? (wired ? "有线设备" : "未知设备")
        self.ip = ip ?? "—"
        self.mac = mac
        self.wired = wired
    }
}

struct ProxyStatus {
    var running: Bool
    let version: String?
    let ipv6: Bool
    var autostart: Bool
    let hasConfig: Bool
    static let demo = ProxyStatus(running: true, version: "v1.19.32", ipv6: true, autostart: true, hasConfig: true)
}

struct Probe: Identifiable {
    let id: String
    let name: String
    let code: Int
    let time: Double?
    var passed: Bool { (200..<400).contains(code) }
}

struct RateSample: Identifiable {
    let id = UUID()
    let at: Date
    let down: Double
    let up: Double
}
