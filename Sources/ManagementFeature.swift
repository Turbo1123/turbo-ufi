import Foundation

enum ManagementFeature: String, Identifiable {
    case wifi, lan, apn, clients, networkControls, band, cell
    case quota, officialQuota, usage, localSpeed, cellularSpeed, sms, smsForward
    case plugins, maomao, schedule, usb, advanced, update, androidDesktop, tailscale

    var id: Self { self }

    var title: String {
        switch self {
        case .wifi: "Wi-Fi 设置"
        case .lan: "内网与 DHCP"
        case .apn: "APN 设置"
        case .clients: "接入设备与黑白名单"
        case .networkControls: "蜂窝与设备"
        case .band: "锁定频段"
        case .cell: "锁定基站"
        case .quota: "UFI 流量限制"
        case .officialQuota: "某兴套餐与流量校准"
        case .usage: "流量历史"
        case .localSpeed: "内网测速"
        case .cellularSpeed: "蜂窝测速"
        case .sms: "短信管理"
        case .smsForward: "短信转发"
        case .plugins: "插件管理"
        case .maomao: "猫猫插件设置"
        case .schedule: "定时任务"
        case .usb: "USB 状态详情"
        case .advanced: "高级功能与系统选项"
        case .update: "UFI-TOOLS 软件更新"
        case .androidDesktop: "Android 桌面"
        case .tailscale: "Tailscale"
        }
    }

    var icon: String {
        switch self {
        case .wifi: "wifi"
        case .lan: "network"
        case .apn: "simcard"
        case .clients: "laptopcomputer"
        case .networkControls: "cellularbars"
        case .band: "waveform.path"
        case .cell: "antenna.radiowaves.left.and.right"
        case .quota, .officialQuota, .usage: "chart.bar.xaxis"
        case .localSpeed, .cellularSpeed: "speedometer"
        case .sms: "envelope"
        case .smsForward: "arrowshape.turn.up.right"
        case .plugins, .maomao: "puzzlepiece.extension"
        case .schedule: "clock"
        case .usb: "cable.connector"
        case .advanced: "gearshape.2"
        case .update: "arrow.down.circle"
        case .androidDesktop: "rectangle.and.hand.point.up.left"
        case .tailscale: "network.badge.shield.half.filled"
        }
    }

    var controlID: String {
        switch self {
        case .wifi: "WIFIManagement"
        case .lan: "LANManagement"
        case .apn: "APNManagement"
        case .clients: "ClientManagement"
        case .networkControls: "collapseBtn_menu"
        case .band: "collapse_lkband_btn"
        case .cell: "collapse_lkcell_btn"
        case .quota, .officialQuota: "DataManagement"
        case .usage: "DataUsageHistory"
        case .localSpeed: "SpeedTestBtn"
        case .cellularSpeed: "CellularSpeedTestBtn"
        case .sms: "SMS"
        case .smsForward: "smsForward"
        case .plugins: "PLUGIN_SETTING"
        case .maomao: "kano-mm-tproxy"
        case .schedule: "ScheduledTaskManagement"
        case .usb: "USBStatusManagement"
        case .advanced: "ADVANCE"
        case .update: "OTA"
        case .androidDesktop, .tailscale: ""
        }
    }

    var disclosureID: String? {
        switch self {
        case .networkControls: "collapseBtn_menu"
        case .band: "collapse_lkband"
        case .cell: "collapse_lkcell"
        default: nil
        }
    }

    var needsLogin: Bool {
        switch self {
        case .localSpeed, .networkControls, .band, .cell: false
        default: true
        }
    }

    var hasNativeEditor: Bool {
        switch self {
        case .wifi, .lan, .networkControls, .schedule, .apn, .quota, .usage, .cell, .band,
             .plugins, .localSpeed, .cellularSpeed, .update, .smsForward, .androidDesktop, .tailscale: true
        default: false
        }
    }
}

struct ManagementPage: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    var feature: ManagementFeature?

    var address: String {
        guard let host = url.host, let port = url.port else { return "" }
        return "\(host):\(port)"
    }
}
