import SwiftUI

struct TailscaleStatus {
    enum State: String {
        case connected, disconnected, notInstalled, anotherVPN

        var title: String {
            switch self {
            case .connected: "已连接"
            case .disconnected: "未连接"
            case .notInstalled: "设备未安装 Tailscale"
            case .anotherVPN: "其他 VPN 正在运行"
            }
        }
    }

    let state: State
    let version: String?
    let ipv4: String?
    let ipv6: String?
    let dnsDomain: String?
    let alwaysOn: Bool

    var running: Bool { state == .connected }

    func checkChange(to running: Bool) throws {
        if state == .notInstalled {
            throw ConnectionError.validation("请先在 U30 Air 安装并登录 Tailscale。")
        }
        if running && state == .anotherVPN {
            throw ConnectionError.validation("设备正在使用另一个 VPN，请先在 Android 上断开它。")
        }
        if !running && alwaysOn {
            throw ConnectionError.validation("请先在 Android VPN 设置中关闭「始终开启」。")
        }
    }

    // Match Android's active VPN owner to the installed package's UID before reading its interface.
    static let androidCommand = #"""
    package_list=$(cmd package list packages --user 0 -U com.tailscale.ipn) || exit 1
    uid=$(printf '%s\n' "$package_list" | awk '$1 == "package:com.tailscale.ipn" && $2 ~ /^uid:[0-9]+$/ { sub(/^uid:/, "", $2); print $2; exit }')
    if [ -z "$uid" ]; then
        printf '@state=notInstalled\n'
        exit 0
    fi

    networks=$(dumpsys -t 3 connectivity 2>/dev/null) || exit 1
    printf '%s\n' "$networks" | grep -q '^Current Networks:' || exit 1
    vpn=$(printf '%s\n' "$networks" | awk '/^[[:space:]]*NetworkAgentInfo/ && /ni[{]VPN CONNECTED /')
    own_vpn=$(printf '%s\n' "$vpn" | awk -v uid="$uid" '$0 ~ ("OwnerUid: " uid "([[:space:]}]|$)") { print; exit }')

    if [ -n "$own_vpn" ]; then
        printf '@state=connected\n'
        interface=$(printf '%s\n' "$own_vpn" | sed -n 's/.*InterfaceName: \([a-zA-Z0-9_.-]*\) .*/\1/p')
        if [ -n "$interface" ]; then
            ipv4=$(ip -o -4 addr show dev "$interface" scope global | awk '{ split($4, address, "/"); print address[1]; exit }')
            ipv6=$(ip -o -6 addr show dev "$interface" scope global | awk '{ split($4, address, "/"); print address[1]; exit }')
            [ -z "$ipv4" ] || printf '@ipv4=%s\n' "$ipv4"
            [ -z "$ipv6" ] || printf '@ipv6=%s\n' "$ipv6"
        fi
        domain=$(printf '%s\n' "$own_vpn" | sed -n 's/.*Domains: \([a-zA-Z0-9.-]*\.ts\.net\) .*/\1/p')
        [ -z "$domain" ] || printf '@dns=%s\n' "$domain"
    elif [ -n "$vpn" ]; then
        printf '@state=anotherVPN\n'
    else
        printf '@state=disconnected\n'
    fi

    version=$(dumpsys -t 2 package com.tailscale.ipn 2>/dev/null | sed -n 's/^[[:space:]]*versionName=\([0-9.]*\).*/\1/p' | head -n 1)
    [ -z "$version" ] || printf '@version=%s\n' "$version"
    if [ "$(settings --user 0 get secure always_on_vpn_app)" = com.tailscale.ipn ]; then
        printf '@always_on=1\n'
    fi
    """#
}

struct TailscaleScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var status: TailscaleStatus?
    @State private var refreshing = false
    @State private var changing = false
    @State private var confirmDisconnect = false
    @State private var notice: String?

    var body: some View {
        RouterEditor(title: "Tailscale", canClose: !changing) {
            RadioCard {
                VStack(alignment: .leading, spacing: 7) {
                    Label(model.device?.model ?? "U30 Air", systemImage: "network")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.lime)
                    Text(status?.state.title ?? (refreshing ? "正在读取状态…" : "状态不可用"))
                        .font(.title2.bold())
                    if let ipv4 = status?.ipv4 {
                        Text(ipv4).font(.title3.monospaced()).textSelection(.enabled)
                    }
                }
                .accessibilityIdentifier("tailscale-status")
            }

            if let status {
                details(status)
                if status.state == .disconnected {
                    RouterSave(title: changing ? "正在连接…" : "连接 Tailscale", disabled: busy || model.demo) {
                        Task { await change(to: true) }
                    }
                }
            }

            HStack(spacing: 14) {
                if let ipv4 = status?.ipv4 {
                    Button("复制 IPv4", systemImage: "document.on.document") {
                        UIPasteboard.general.string = ipv4
                        notice = "已复制 Tailscale IPv4。"
                    }
                }
                Button("刷新状态", systemImage: "arrow.clockwise") {
                    Task { await refresh() }
                }
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.bordered)
            .disabled(busy)

            if let status, status.running {
                if status.alwaysOn {
                    InlineNotice(text: "Android 的「始终开启 VPN」已启用。")
                } else {
                    Button(changing ? "正在断开…" : "断开 Tailscale", role: .destructive) {
                        confirmDisconnect = true
                    }
                    .tint(Palette.warning)
                    .font(.subheadline.weight(.semibold))
                    .disabled(busy || model.demo)
                }
            }
            if changing { ProgressView().controlSize(.small).accessibilityLabel("正在等待设备确认") }
            if let notice { InlineNotice(text: notice) }
        }
        .interactiveDismissDisabled(changing)
        .alert("断开 Tailscale？", isPresented: $confirmDisconnect) {
            Button("取消", role: .cancel) {}
            Button("确认断开", role: .destructive) { Task { await change(to: false) } }
        } message: {
            Text("通过 Tailscale 访问这台 U30 Air 的连接会中断。重新连接时，可以使用 U30 Air 热点打开这一页。")
        }
        .task { await refresh() }
    }

    private var busy: Bool { refreshing || changing }

    @ViewBuilder
    private func details(_ status: TailscaleStatus) -> some View {
        if status.version != nil || status.ipv6 != nil || status.dnsDomain != nil {
            Card {
                VStack(spacing: 0) {
                    if let version = status.version {
                        LineRow(title: "版本", value: version, icon: "info.circle", mono: true)
                    }
                    if let ipv6 = status.ipv6 {
                        if status.version != nil { Divider().padding(.horizontal, 15) }
                        LineRow(title: "IPv6", value: ipv6, icon: "number", mono: true)
                    }
                    if let domain = status.dnsDomain {
                        if status.version != nil || status.ipv6 != nil { Divider().padding(.horizontal, 15) }
                        LineRow(title: "MagicDNS 域", value: domain, icon: "globe", mono: true)
                    }
                }
            }
        }
    }

    private func refresh() async {
        guard !busy else { return }
        refreshing = true
        notice = nil
        defer { refreshing = false }
        do {
            if model.demo {
                status = .init(state: .connected, version: "1.104.7", ipv4: "100.96.0.25",
                               ipv6: "fd7a:115c:a1e0::25", dnsDomain: "example.ts.net", alwaysOn: false)
            } else {
                status = try await model.routerSettingsClient().tailscaleStatus()
            }
        } catch {
            if !Task.isCancelled {
                status = nil
                notice = error.localizedDescription
            }
        }
    }

    private func change(to running: Bool) async {
        guard !busy, !model.demo else { return }
        changing = true
        notice = nil
        defer { changing = false }
        do {
            let client = try model.routerSettingsClient()
            do {
                status = try await client.setTailscaleRunning(running)
            } catch {
                if !Task.isCancelled { status = try? await client.tailscaleStatus() }
                throw error
            }
        } catch {
            if !Task.isCancelled { notice = error.localizedDescription }
        }
    }
}
