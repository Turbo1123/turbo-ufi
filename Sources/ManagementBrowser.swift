import SwiftUI
import WebKit

struct ManagementBrowser: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: ManagementWebSession
    let page: ManagementPage

    init(page: ManagementPage, endpoint: Endpoint, dataStore: WKWebsiteDataStore, credentials: DeviceCredentials) {
        self.page = page
        _session = StateObject(wrappedValue: ManagementWebSession(page: page, endpoint: endpoint, dataStore: dataStore,
                                                                 credentials: credentials))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                toolbarButton("关闭", "xmark") { dismiss() }
                Spacer(minLength: 6)
                VStack(spacing: 3) {
                    Text(page.title).font(.subheadline.bold()).lineLimit(1)
                    Text(page.address).font(.caption2.monospaced()).foregroundStyle(Palette.muted)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 6)
                toolbarButton("返回上一页", "chevron.left") { session.back() }
                    .disabled(!session.canGoBack)
                toolbarButton("重新加载", "arrow.clockwise") { session.reload() }
            }
            .padding(.horizontal, 8)

            if let feature = page.feature {
                HStack {
                    Label(feature.title, systemImage: feature.icon).font(.caption.weight(.semibold))
                    Spacer()
                    Button("打开功能") { session.openFeature() }
                        .font(.caption.weight(.bold))
                        .disabled(session.loading || session.jumping)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Palette.lime.opacity(0.42))
            }
            if let message = session.message {
                InlineNotice(text: message).padding(.horizontal, 15)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ZStack(alignment: .top) {
                EmbeddedManagementView(webView: session.webView)
                if session.loading {
                    ProgressView().progressViewStyle(.linear).accessibilityLabel("正在加载后台")
                } else {
                    Rectangle().fill(Palette.border).frame(height: 1)
                }
            }
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.paper.ignoresSafeArea())
        .tint(Palette.green)
        .onAppear { session.start() }
        .accessibilityIdentifier("management-browser")
    }

    private func toolbarButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
    }
}

private struct EmbeddedManagementView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

@MainActor
private final class ManagementWebSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published private(set) var loading = true
    @Published private(set) var canGoBack = false
    @Published private(set) var jumping = false
    @Published private(set) var message: String?

    let webView: WKWebView
    private let page: ManagementPage
    private let endpoint: Endpoint
    private let credentials: DeviceCredentials
    private var started = false
    private var jumpOnLoad: Bool
    private var attemptedLogin = false

    init(page: ManagementPage, endpoint: Endpoint, dataStore: WKWebsiteDataStore, credentials: DeviceCredentials) {
        self.page = page
        self.endpoint = endpoint
        self.credentials = credentials
        jumpOnLoad = page.feature != nil
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        #if DEBUG
        webView.isInspectable = true
        #endif
    }

    func start() {
        guard !started else { return }
        started = true
        webView.load(URLRequest(url: page.url, timeoutInterval: 14))
    }

    func reload() {
        message = nil
        if webView.url != nil {
            webView.reload()
        } else {
            started = false
            start()
        }
    }

    func back() {
        message = nil
        webView.goBack()
    }

    func openFeature() {
        guard let feature = page.feature, !jumping, !loading else { return }
        guard webView.url?.host == endpoint.host, webView.url?.port == endpoint.port,
              webView.url?.path == "/" else {
            jumpOnLoad = true
            webView.load(URLRequest(url: page.url, timeoutInterval: 14))
            return
        }
        message = nil
        jumping = true
        Task { [weak self] in
            guard let self else { return }
            defer { jumping = false }
            await loginIfNeeded()
            let arguments: [String: Any] = [
                "origin": "http://" + endpoint.address, "controlID": feature.controlID,
                "disclosureID": feature.disclosureID ?? "", "needsLogin": feature.needsLogin,
                "scrollOnly": feature == .maomao
            ]
            do {
                let result = try await webView.callAsyncJavaScript(Self.openControl, arguments: arguments,
                    in: nil, contentWorld: .defaultClient) as? String
                switch result {
                case "opened": break
                case "login": message = "请先登录原后台，再点「打开功能」。"
                default: message = "后台入口有变化，请在功能列表中打开。"
                }
            } catch {
                message = "请在原后台的功能列表中打开。"
            }
        }
    }

    private func loginIfNeeded() async {
        guard !attemptedLogin, !credentials.password.isEmpty, webView.url?.port == endpoint.port,
              webView.url?.host == endpoint.host, webView.url?.path == "/" else { return }
        attemptedLogin = true
        let arguments: [String: Any] = [
            "origin": "http://" + endpoint.address, "token": credentials.token,
            "password": credentials.password, "method": credentials.multiUser ? "1" : "0"
        ]
        _ = try? await webView.callAsyncJavaScript(Self.submitLogin, arguments: arguments, in: nil, contentWorld: .defaultClient)
    }

    // The upstream form still verifies both credentials and establishes the session.
    private static let submitLogin = """
        if (location.origin !== origin || location.pathname !== "/") return false;
        if (localStorage.getItem("kano_sms_pwd")) return true;
        const dialog = document.getElementById("tokenModal");
        const pw = document.getElementById("PWDINPUT");
        const tk = document.getElementById("TOKEN");
        const mode = document.getElementById("login_method");
        const submit = dialog?.querySelector('button[onclick="onTokenConfirm()"]');
        if (!dialog || !pw || !tk || !mode || !submit) return false;
        if (getComputedStyle(dialog).display === "none") document.getElementById("CLEAR")?.click();
        const remember = document.getElementById("loginRememberMe");
        if (remember) remember.checked = false;
        pw.value = password;
        tk.value = token;
        mode.value = method;
        submit.click();
        for (let attempt = 0; attempt < 36; attempt++) {
            if (localStorage.getItem("kano_sms_pwd")) return true;
            await new Promise(resolve => setTimeout(resolve, 180));
        }
        return false;
        """

    // IDs correspond to navigation and modal controls in UFI-TOOLS 4.1.5. No form
    // submission, arbitrary script bridge, or device action is exposed here.
    private static let openControl = """
        if (location.origin !== origin || location.pathname !== "/") return "unavailable";
        if (needsLogin && !localStorage.getItem("kano_sms_pwd")) {
            const dialog = document.getElementById("tokenModal");
            if (dialog && getComputedStyle(dialog).display === "none") {
                document.getElementById("CLEAR")?.click();
            }
            return "login";
        }
        for (let attempt = 0; attempt < 20; attempt++) {
            const control = document.getElementById(controlID);
            if (scrollOnly && control) {
                control.scrollIntoView({ block: "start" });
                return "opened";
            }
            if (disclosureID) {
                const disclosure = disclosureID === "collapseBtn_menu"
                    ? document.querySelector(".functions-container.collapse_menu")
                    : document.getElementById(disclosureID);
                const toggle = control?.querySelector(".Switch input[type=checkbox]");
                if (disclosure?.dataset.name && toggle) {
                    if (!toggle.checked) toggle.click();
                    control.scrollIntoView({ block: "start" });
                    return "opened";
                }
            } else if (!scrollOnly && control instanceof HTMLButtonElement && !control.disabled) {
                control.click();
                return "opened";
            }
            await new Promise(resolve => setTimeout(resolve, 180));
        }
        return "unavailable";
        """

    private func permits(_ url: URL) -> Bool {
        url.scheme == "http" && url.host == endpoint.host && url.user == nil && url.password == nil
            && [endpoint.port, 7788, 8080].contains(url.port ?? 80)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, permits(url) else {
            if action.navigationType == .linkActivated {
                message = "当前面板只打开这台设备的本地地址。"
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, let url = action.request.url, permits(url) { webView.load(action.request) }
        return nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true
        message = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        canGoBack = webView.canGoBack
        if jumpOnLoad {
            jumpOnLoad = false
            openFeature()
        } else if page.feature == nil {
            Task { await loginIfNeeded() }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loading = false
        message = "后台页面已中断，点右上角重新加载。"
    }

    private func navigationFailed(_ error: Error) {
        loading = false
        canGoBack = webView.canGoBack
        guard (error as? URLError)?.code != .cancelled else { return }
        message = "无法打开后台。请确认手机已连接设备的 Wi-Fi，然后重新加载。"
    }
}
