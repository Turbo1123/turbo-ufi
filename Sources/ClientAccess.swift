import Foundation

struct ClientAccess {
    struct Blocked: Identifiable {
        let id: String
        let name: String
    }

    let mode: String
    let allowMAC: String
    let allowName: String
    let blocked: [Blocked]

    init(_ result: JSONObject) throws {
        guard let mode = result.raw["AclMode"] as? String else { throw ConnectionError.invalidResponse }
        self.mode = mode
        allowMAC = result.text("WhiteMacList") ?? ""
        allowName = result.text("WhiteNameList") ?? ""
        let names = (result.text("BlackNameList") ?? "").components(separatedBy: ";")
        blocked = (result.text("BlackMacList") ?? "").components(separatedBy: ";").enumerated().compactMap { offset, mac in
            guard !mac.isEmpty else { return nil }
            return Blocked(id: mac, name: names.indices.contains(offset) ? names[offset] : "")
        }
    }

    func action(mac: String, name: String? = nil) -> FormAction {
        var devices = blocked.filter { $0.id.caseInsensitiveCompare(mac) != .orderedSame }
        if let name {
            devices.insert(Blocked(id: mac, name: name.replacingOccurrences(of: ";", with: " ")), at: 0)
        }
        return FormAction(command: "setDeviceAccessControlList", values: [
            "AclMode": mode, "WhiteMacList": allowMAC, "WhiteNameList": allowName,
            "BlackMacList": devices.map(\.id).joined(separator: ";"),
            "BlackNameList": devices.map(\.name).joined(separator: ";")
        ])
    }
}

extension UFIClient {
    func clientAccess() async throws -> ClientAccess {
        try await ClientAccess(routerRead("queryDeviceAccessControlList"))
    }
}
