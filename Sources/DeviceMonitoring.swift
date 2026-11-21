import Foundation

struct MonitorSample: Identifiable {
    let at: Date
    let cpu: Double?
    let memory: Double?
    let temperature: Double?
    var id: Date { at }
}

struct CellularQoS {
    let qci: Int
    let down: Double
    let up: Double

    static func parse(_ text: String) -> Self? {
        guard let line = text.components(separatedBy: .newlines).first(where: { $0.contains("+CGEQOSRDP:") }),
              let fields = line.split(separator: ":", maxSplits: 1).last?.components(separatedBy: ","),
              fields.count >= 8 else { return nil }
        let values = fields.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let qci = Int(values[1]), let down = Double(values[6]), let up = Double(values[7]),
              down.isFinite, up.isFinite else { return nil }
        return .init(qci: qci, down: down / 1000, up: up / 1000)
    }
}

extension UFIClient {
    func cellularQoS(network: JSONObject?, model: String?) async throws -> CellularQoS? {
        let dualSIM = network?.text("dual_sim_support") == "1"
        let slot: String
        switch dualSIM ? network?.text("sim_slot") : nil {
        case "1", "2": slot = "1"
        case "11" where model == "MU3356": slot = "1"
        default: slot = "0"
        }
        let first = try await readQoS(slot: slot)
        if first?.contains("ERROR") == true && !dualSIM { return try await readQoS(slot: "1").flatMap(CellularQoS.parse) }
        return first.flatMap(CellularQoS.parse)
    }

    private func readQoS(slot: String) async throws -> String? {
        try await request("/api/AT", query: [
            .init(name: "command", value: "AT+CGEQOSRDP=1"), .init(name: "slot", value: slot)
        ], timeout: 4).text("result")
    }
}
