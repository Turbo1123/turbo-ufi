import SwiftUI

struct AppScreen: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if let device = model.device {
                VStack(spacing: 0) {
                    toolbar
                    ScrollView {
                        page(device)
                            .frame(maxWidth: 570)
                            .padding(.horizontal, 20)
                            .padding(.top, 9)
                            .padding(.bottom, 20)
                            .frame(maxWidth: .infinity)
                    }
                    .id(model.destination)
                    .refreshable {
                        await model.refresh()
                        await model.refreshPluginAvailability()
                        if model.destination == .proxy { await model.refreshProxy() }
                    }
                    .scrollIndicators(.hidden)
                    tabBar
                }
            } else {
                ConnectionScreen()
            }
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.paper.ignoresSafeArea())
        .tint(Palette.green)
        .fullScreenCover(item: $model.browser, onDismiss: { Task { await model.managementClosed() } }) { page in
            if let endpoint = model.endpoint {
                ManagementBrowser(page: page, endpoint: endpoint, dataStore: model.browserData,
                                  credentials: model.credentials)
            }
        }
    }

    @ViewBuilder
    private func page(_ device: DeviceSnapshot) -> some View {
        switch model.destination {
        case .overview: OverviewScreen(device: device)
        case .network: NetworkScreen(device: device)
        case .clients: ClientScreen(device: device)
        case .proxy: ProxyScreen()
        case .advanced: AdvancedScreen(device: device)
        case .settings: SettingsScreen(device: device)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 9) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.green)
                .accessibilityHidden(true)
            Text("Turbo UFI").font(.system(size: 19, weight: .heavy, design: .default)).tracking(-0.55)
            Spacer()
            if model.demo { StatusChip(text: "演示", filled: false) }
            Button {
                Task {
                    await model.refresh()
                    await model.refreshPluginAvailability()
                    if model.destination == .proxy { await model.refreshProxy() }
                }
            } label: {
                Group {
                    if model.refreshing { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise").font(.system(size: 17, weight: .semibold)) }
                }
                .frame(width: 42, height: 42)
                .foregroundStyle(Palette.green)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("刷新设备信息")
            .disabled(model.refreshing || model.demo)
        }
        .padding(.leading, 21)
        .padding(.trailing, 12)
        .frame(maxWidth: 590)
        .frame(maxWidth: .infinity)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Destination.allCases.filter { $0 != .proxy || model.proxyInstalled }) { tab in
                Button {
                    model.destination = tab
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tab.icon).font(.system(size: 18, weight: .semibold))
                        Text(tab.title).font(.system(.caption2).weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(model.destination == tab ? Palette.deep : Palette.muted)
                    .background {
                        if model.destination == tab {
                            RoundedRectangle(cornerRadius: 14).fill(Palette.lime)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tab-" + tab.rawValue)
                .accessibilityAddTraits(model.destination == tab ? .isSelected : [])
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 3)
        .frame(maxWidth: 590)
        .frame(maxWidth: .infinity)
        .background {
            Palette.paper
                .overlay(alignment: .top) { Rectangle().fill(Palette.border).frame(height: 1) }
                .ignoresSafeArea(edges: .bottom)
        }
    }
}

struct ConnectionScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var address = UserDefaults.standard.string(forKey: "lastDeviceAddress") ?? "192.168.0.1:2333"
    @State private var token = ""
    @State private var password = ""
    @State private var remember = true
    @State private var multiUser = false
    @State private var storedAddress: String?
    @State private var reveal = false
    @FocusState private var field: Field?

    private enum Field: Hashable { case address, token, password }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                HStack(spacing: 9) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Palette.green)
                        .accessibilityHidden(true)
                    Text("Turbo UFI").font(.title2.weight(.heavy)).tracking(-0.5)
                }
                .padding(.bottom, 9)

                PageHeading(title: "连接设备", detail: "连接随身 Wi-Fi 后开始管理。")

                GeometryReader { geo in
                    if UIImage(named: "ConnectionHero") != nil {
                        Image("ConnectionHero")
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                    } else {
                        RadioBackdrop()
                    }
                }
                .frame(height: 166)
                .clipShape(RoundedRectangle(cornerRadius: 21))
                .accessibilityHidden(true)

                Card {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("后台地址").font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
                        TextField("192.168.0.1:2333", text: $address)
                            .font(.system(.body, design: .monospaced).weight(.medium))
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($field, equals: .address)
                            .accessibilityLabel("后台地址")
                            .submitLabel(.next)
                            .onSubmit { field = .token }
                    }
                    .padding(14)
                }

                Card {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("UFI-TOOLS 口令").font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
                        HStack {
                            Group {
                                if reveal { TextField("输入后台口令", text: $token) }
                                else { SecureField("输入后台口令", text: $token) }
                            }
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($field, equals: .token)
                            .submitLabel(.next).onSubmit { field = .password }
                            .accessibilityLabel("UFI-TOOLS 口令")
                            Button {
                                reveal.toggle()
                            } label: {
                                Image(systemName: reveal ? "eye.slash" : "eye")
                                    .foregroundStyle(Palette.green)
                                    .padding(.horizontal, 5)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(reveal ? "隐藏口令" : "显示口令")
                        }
                    }
                    .padding(14)
                }

                Card {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("某兴后台密码").font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
                        SecureField("填写后可修改路由器设置", text: $password)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($field, equals: .password).submitLabel(.go).onSubmit(connect)
                            .accessibilityLabel("某兴后台密码")
                    }
                    .padding(14)
                }
                Toggle("保存到钥匙串", isOn: $remember).font(.subheadline.weight(.semibold))
                DisclosureGroup("登录方式") {
                    Toggle("某兴新版登录方式", isOn: $multiUser).font(.footnote)
                        .padding(.top, 6)
                }
                .font(.caption)

                if let issue = model.connectionIssue {
                    InlineNotice(text: issue, icon: "exclamationmark.circle")
                        .foregroundStyle(Palette.warning)
                        .accessibilityIdentifier("connection-error")
                }

                Button(action: connect) {
                    HStack {
                        if model.connecting { ProgressView().tint(.white) }
                        Text(model.connecting ? "连接中" : "连接设备").font(.headline)
                    }
                    .frame(maxWidth: .infinity, minHeight: 53)
                    .foregroundStyle(.white)
                    .background(Palette.green, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .disabled(model.connecting)
                .accessibilityIdentifier("connect-device")

                Button { model.enterDemo() } label: {
                    Text("体验演示").font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 38)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.green)
                .disabled(model.connecting)
                .accessibilityIdentifier("enter-demo")

                HStack(spacing: 7) {
                    Image(systemName: "lock").accessibilityHidden(true)
                    Text("设备数据留在本地网络")
                }
                .font(.caption)
                .foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: 500)
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear { loadSavedCredentials() }
        .onChange(of: address) { _, _ in loadSavedCredentials() }
    }

    private func connect() {
        let credentials = DeviceCredentials(token: token, password: password, multiUser: multiUser)
        field = nil
        Task {
            await model.connect(address: address, token: credentials.token, password: credentials.password,
                                multiUser: credentials.multiUser, rememberCredentials: remember)
            if model.device != nil { token = ""; password = "" }
        }
    }

    private func loadSavedCredentials() {
        let endpoint = try? Endpoint(address)
        if let prior = storedAddress, prior != endpoint?.address {
            token = ""
            password = ""
            multiUser = false
            storedAddress = nil
        }
        guard let endpoint, storedAddress != endpoint.address,
              let saved = CredentialStore.load(endpoint) else { return }
        token = saved.token
        password = saved.password
        multiUser = saved.multiUser
        remember = true
        storedAddress = endpoint.address
    }
}
