import Foundation

struct DailyUsage: Identifiable {
    let day: String
    let bytes: Double
    var id: String { day }
}

struct USBStatus {
    struct Peripheral: Identifiable {
        let id: String
        let product: String
        let speed: String?
    }

    let mode: String
    let speed: String?
    let devices: [Peripheral]?

    var connectedToHost: Bool {
        mode.lowercased() == "gadget"
    }

    var hostLabel: String? {
        guard connectedToHost else { return nil }
        guard let speed, !speed.localizedCaseInsensitiveContains("unknown") else { return "USB 已连接" }
        return speed.components(separatedBy: " (").first ?? "USB 已连接"
    }

    var modeName: String {
        switch mode.lowercased() {
        case "gadget": "设备模式"
        case "host": "主机模式"
        default: mode
        }
    }
}

struct AdvancedSnapshot {
    let usage: [DailyUsage]?
    let usb: USBStatus?

    static let unavailable = Self(usage: nil, usb: nil)
    static let demo = Self(
        usage: [85, 145, 118, 220, 70, 162, 348].enumerated().map {
            DailyUsage(day: "2026-11-" + String(15 + $0.offset), bytes: Double($0.element) * 1_000_000)
        },
        usb: USBStatus(mode: "gadget", speed: "High-Speed", devices: [])
    )
}

struct SMSMessage: Identifiable {
    let id: String
    let sender: String
    let date: String
    let text: String
    let unread: Bool

    init(id: String, sender: String, date: String, text: String, unread: Bool) {
        self.id = id
        self.sender = sender
        self.date = date
        self.text = text
        self.unread = unread
    }

    init?(_ row: JSONObject) {
        guard let id = row.text("id"), let tag = row.text("tag"), tag == "0" || tag == "1" else { return nil }
        let rawDate = row.text("date") ?? ""
        let parts = rawDate.split(separator: ",")
        let date = parts.count >= 5
            ? parts.prefix(3).joined(separator: "-") + " " + parts.dropFirst(3).prefix(2).joined(separator: ":")
            : rawDate
        let encoded = row.text("content") ?? ""
        let padded = encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        let decoded = Data(base64Encoded: padded).map { String(decoding: $0, as: UTF8.self) }
        self.init(id: id, sender: row.text("number") ?? "未知号码", date: date,
                  text: decoded.flatMap { $0.isEmpty ? nil : $0 } ?? "（无可显示内容）", unread: tag == "1")
    }

    static let demo = [
        SMSMessage(id: "1", sender: "10086", date: "26-11-21 10:30", text: "您的本月套餐用量可以在运营商 App 中查询。", unread: true),
        SMSMessage(id: "2", sender: "10086", date: "26-11-20 08:42", text: "您的流量使用情况已更新。", unread: false)
    ]
}
