import Foundation

enum ProxySelection {
    case node(String)
    case automatic
}

struct ProxyGroup: Identifiable {
    enum Kind: String {
        case selector = "Selector"
        case urlTest = "URLTest"
        case fallback = "Fallback"

        var automaticLabel: String? {
            switch self {
            case .selector: nil
            case .urlTest: "自动测速"
            case .fallback: "故障转移"
            }
        }
    }

    let name: String
    var current: String?
    let nodes: [String]
    var kind: Kind = .selector
    var fixed: String?
    var id: String { name }

    var selected: String? { kind == .selector ? current : fixed }
    var canRestoreAutomatic: Bool { kind != .selector && fixed != nil }

    func canChange(to selection: ProxySelection) -> Bool {
        switch selection {
        case .node(let node): nodes.contains(node) && node != selected
        case .automatic: canRestoreAutomatic
        }
    }

    static let demo = [
        Self(name: "节点选择", current: "香港 01", nodes: ["自动选择", "香港 01", "日本 02", "新加坡 01", "DIRECT"]),
        Self(name: "自动选择", current: "香港 01", nodes: ["香港 01", "日本 02", "新加坡 01"], kind: .urlTest),
        Self(name: "国外媒体", current: "节点选择", nodes: ["节点选择", "日本 02", "新加坡 01", "DIRECT"])
    ]
}

struct ProxyCatalog: Decodable {
    struct Entry: Decodable {
        let type: String
        let now: String?
        let all: [String]?
        let hidden: Bool?
        let fixed: String?
    }

    let proxies: [String: Entry]

    var groups: [ProxyGroup] {
        proxies.compactMap { name, entry in
            guard let kind = ProxyGroup.Kind(rawValue: entry.type), entry.hidden != true,
                  let nodes = entry.all, !nodes.isEmpty else { return nil }
            let fixed = entry.fixed.flatMap { $0.isEmpty ? nil : $0 }
            return ProxyGroup(name: name, current: entry.now, nodes: nodes, kind: kind, fixed: fixed)
        }
        .sorted { lhs, rhs in
            if lhs.name == "GLOBAL" { return false }
            if rhs.name == "GLOBAL" { return true }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
