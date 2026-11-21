import SwiftUI
import UniformTypeIdentifiers

@MainActor
private final class DesktopSession: ObservableObject {
    @Published private(set) var paired = false
    @Published private(set) var activated = false
    @Published private(set) var starting = false
    @Published private(set) var picture: UIImage?
    @Published private(set) var revision: UInt64?
    @Published private(set) var issue: String?
    @Published private(set) var buttonBusy = false

    private var credentials: ScreenCredentials?
    private var transport: ScreenConnection?
    private var lease: ScreenLease?
    private var connectTask: Task<Void, Never>?
    private var frameTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?

    func prepare(_ endpoint: Endpoint) {
        let stored = ScreenCredentials.load(endpoint)
        if let stored, stored.pairing.isValid(for: endpoint), ScreenPairing.isToken(stored.key) {
            credentials = stored
            paired = true
            activated = stored.pairing.ticket == nil
            return
        }
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let staged = documents.appendingPathComponent(ScreenCredentials.importFilename)
        if FileManager.default.fileExists(atPath: staged.path) { importFile(staged, endpoint: endpoint, remove: true) }
    }

    func importFile(_ url: URL, endpoint: Endpoint, remove: Bool = false) {
        do {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let imported = try ScreenCredentials.importPairing(from: url, endpoint: endpoint)
            guard imported.save(for: endpoint) else { throw ScreenError.keychain }
            credentials = imported
            paired = true
            activated = false
            issue = nil
            if remove { try? FileManager.default.removeItem(at: url) }
        } catch {
            issue = error.localizedDescription
        }
    }

    func report(_ error: Error) { issue = error.localizedDescription }

    func start(_ endpoint: Endpoint) {
        guard !starting, lease == nil, var credentials else { return }
        issue = nil
        starting = true
        let connection = ScreenConnection(credentials.pairing)
        transport = connection
        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                let session: ScreenLease
                do {
                    session = try await connection.open(key: credentials.key)
                } catch ScreenError.rejected {
                    guard let ticket = credentials.pairing.ticket else { throw ScreenError.rejected }
                    try await connection.enroll(ticket: ticket, key: credentials.key)
                    session = try await connection.open(key: credentials.key)
                }
                guard !Task.isCancelled else {
                    await connection.close(session)
                    return
                }
                credentials.pairing.ticket = nil
                _ = credentials.save(for: endpoint)
                self.credentials = credentials
                activated = true
                self.lease = session
                do { try await connection.action(.init(kind: .wake), lease: session) }
                catch {
                    if !Task.isCancelled { issue = error.localizedDescription }
                }
                guard !Task.isCancelled else { return }
                starting = false
                poll(connection, lease: session)
            } catch {
                if !Task.isCancelled {
                    stop()
                    issue = error.localizedDescription
                }
            }
        }
    }

    func send(_ input: ScreenAction) {
        guard !buttonBusy, !starting, let transport, let lease else { return }
        buttonBusy = true
        actionTask = Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { buttonBusy = false } }
            do {
                try await transport.action(input, lease: lease)
                if !Task.isCancelled { issue = nil }
            } catch ScreenError.rejected {
                if !Task.isCancelled { stop(); issue = ScreenError.rejected.errorDescription }
            } catch {
                if !Task.isCancelled { issue = error.localizedDescription }
            }
        }
    }

    func stop() {
        connectTask?.cancel()
        frameTask?.cancel()
        actionTask?.cancel()
        connectTask = nil
        frameTask = nil
        actionTask = nil
        starting = false
        picture = nil
        revision = nil
        buttonBusy = false
        let old = transport
        let formerLease = lease
        lease = nil
        transport = nil
        Task {
            if let formerLease { await old?.close(formerLease) }
            old?.invalidate()
        }
    }

    private func poll(_ connection: ScreenConnection, lease: ScreenLease) {
        frameTask = Task { [weak self] in
            let clock = ContinuousClock()
            var errors = 0
            while !Task.isCancelled {
                let next = clock.now.advanced(by: .milliseconds(280))
                do {
                    let frame = try await connection.frame(lease)
                    guard let image = UIImage(data: frame.data), !Task.isCancelled else { break }
                    self?.picture = image
                    self?.revision = frame.revision
                    errors = 0
                } catch ScreenError.rateLimit {
                    // A new poll may follow the previous session's last frame.
                } catch ScreenError.rejected {
                    if !Task.isCancelled { self?.stop(); self?.issue = "会话已到期，请重新连接。" }
                    break
                } catch {
                    if Task.isCancelled { break }
                    errors += 1
                    if errors >= 2 {
                        self?.stop()
                        self?.issue = error.localizedDescription
                        break
                    }
                }
                do { try await clock.sleep(until: next) } catch { break }
            }
        }
    }
}

struct AndroidDesktop: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session = DesktopSession()
    @State private var importing = false
    @State private var showingDesktop = false

    var body: some View {
        Group {
            if showingDesktop, let endpoint = model.endpoint {
                DesktopDisplay(session: session, reconnect: { session.start(endpoint) }, exit: closeDesktop)
            } else {
                pairingPage
            }
        }
        .statusBarHidden(showingDesktop)
        .task { if let endpoint = model.endpoint { session.prepare(endpoint) } }
        .onDisappear(perform: session.stop)
        .onChange(of: scenePhase) { _, phase in if phase != .active { closeDesktop() } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard let endpoint = model.endpoint else { return }
            do { session.importFile(try result.get(), endpoint: endpoint) }
            catch { session.report(error) }
        }
    }

    private var pairingPage: some View {
        RouterEditor(title: "Android 桌面") {
            RadioCard {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Android 桌面", systemImage: "rectangle.inset.filled.and.person.filled")
                        .font(.title2.bold())
                    Text(session.activated ? "设备已配对" : session.paired ? "已导入配对文件" : "使用配对文件连接 U30 Air")
                        .font(.subheadline).foregroundStyle(Palette.lime)
                }
            }
            if let endpoint = model.endpoint {
                if session.paired {
                    RouterSave(title: "连接 Android 桌面") {
                        showingDesktop = true
                        session.start(endpoint)
                    }
                }
                Button(session.activated ? "重新配对…" : "导入配对文件") { importing = true }
                    .font(.subheadline.weight(.semibold))
            }
            if let issue = session.issue { InlineNotice(text: issue, icon: "exclamationmark.circle") }
        }
    }

    private func closeDesktop() {
        guard showingDesktop else { return }
        session.stop()
        showingDesktop = false
    }
}

private struct DesktopDisplay: View {
    @ObservedObject var session: DesktopSession
    let reconnect: () -> Void
    let exit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            display
                .overlay(alignment: .bottom) {
                    if session.picture != nil, let issue = session.issue {
                        Text(issue)
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .padding(10)
                            .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                }
            controls
        }
        .foregroundStyle(.white)
        .background(Color.black)
        .accessibilityAction(.escape, exit)
    }

    private var display: some View {
        GeometryReader { geometry in
            ZStack {
                if let image = session.picture {
                    Image(uiImage: image)
                        .resizable().scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onEnded { gesture in
                            sendGesture(gesture, in: geometry.size)
                        })
                        .accessibilityLabel("Android 显示画面")
                        .accessibilityIdentifier("android-desktop-display")
                } else if let issue = session.issue, !session.starting {
                    VStack(spacing: 16) {
                        Text(issue).font(.subheadline).multilineTextAlignment(.center)
                        Button("重新连接", action: reconnect).buttonStyle(.bordered)
                    }
                    .padding(24)
                } else {
                    ProgressView("正在获取 Android 画面").tint(.white)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .privacySensitive()
    }

    private var controls: some View {
        HStack(spacing: 0) {
            control("返回", "chevron.left", .back)
            control("首页", "house", .home)
            control("最近", "rectangle.stack", .recents)
            control("唤醒", "sun.max", .wake)
            controlButton("退出", "xmark", action: exit)
        }
        .padding(.horizontal, 8)
        .background(Color(white: 0.09).ignoresSafeArea(edges: .bottom))
    }

    private func control(_ title: String, _ symbol: String, _ command: ScreenAction.Kind) -> some View {
        controlButton(title, symbol) { session.send(.init(kind: command)) }
            .disabled(session.buttonBusy || session.picture == nil)
    }

    private func controlButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.subheadline.weight(.semibold)).accessibilityHidden(true)
                Text(title).font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .tint(.white)
    }

    private func sendGesture(_ gesture: DragGesture.Value, in bounds: CGSize) {
        guard let image = session.picture, let revision = session.revision else { return }
        let size = image.size
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let width = size.width * scale, height = size.height * scale
        let left = (bounds.width - width) / 2, top = (bounds.height - height) / 2
        let start = gesture.startLocation
        guard CGRect(x: left, y: top, width: width, height: height).contains(start) else { return }
        func normalize(_ point: CGPoint) -> ScreenAction.Point {
            .init(x: Double(min(1, max(0, (point.x - left) / width))),
                  y: Double(min(1, max(0, (point.y - top) / height))))
        }
        if hypot(gesture.translation.width, gesture.translation.height) >= 12 {
            session.send(.init(kind: .swipe, start: normalize(start), end: normalize(gesture.location), revision: revision))
        } else {
            session.send(.init(kind: .tap, start: normalize(start), revision: revision))
        }
    }
}
