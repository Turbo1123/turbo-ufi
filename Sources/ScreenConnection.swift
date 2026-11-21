import CryptoKit
import Foundation
import Security

struct ScreenPairing: Codable, Sendable {
    let version: Int
    let host: String
    let port: Int
    let certificateSHA256: String
    var ticket: String?

    func isValid(for endpoint: Endpoint) -> Bool {
        version == 1 && host == endpoint.host && (1024...65535).contains(port)
            && Self.isToken(certificateSHA256) && (ticket.map(Self.isToken) ?? true)
    }

    static func isToken(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

struct ScreenCredentials: Codable, Sendable {
    var pairing: ScreenPairing
    let key: String

    static let service = "com.turbo.ufi.android-screen"
    static let importFilename = "turbo-ufi-screen-pairing.json"

    static func load(_ endpoint: Endpoint) -> ScreenCredentials? {
        LocalKeychain.load(service: service, account: endpoint.host)
    }

    func save(for endpoint: Endpoint) -> Bool {
        LocalKeychain.save(self, service: Self.service, account: endpoint.host)
    }

    static func importPairing(from url: URL, endpoint: Endpoint) throws -> Self {
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= 4096 else {
            throw ScreenError.pairing
        }
        let pairing = try JSONDecoder().decode(ScreenPairing.self, from: Data(contentsOf: url))
        guard pairing.isValid(for: endpoint), pairing.ticket != nil else { throw ScreenError.pairing }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { UFIClient.hex($0) }
        return Self(pairing: pairing, key: key)
    }
}

enum ScreenError: LocalizedError {
    case pairing, keychain, rejected, disconnected, untrusted, orientationChanged, rateLimit, badResponse, http(Int)

    var errorDescription: String? {
        switch self {
        case .pairing: "配对文件无效，或与当前 U30 Air 的地址不匹配。"
        case .keychain: "无法保存配对凭据，请先解锁手机。"
        case .rejected: "设备拒绝鉴权。会话可能已过期，或配对已被撤销。"
        case .disconnected: "无法连接 Android 桌面，请确认 iPhone 已连到 U30 Air 热点。"
        case .untrusted: "设备证书与配对时不一致，请核对设备后重新配对。"
        case .orientationChanged: "Android 屏幕方向已变化，请等待画面刷新。"
        case .rateLimit: "当前取帧过快。"
        case .badResponse: "Android 桌面服务返回了无效数据。"
        case .http(let code): "Android 桌面服务返回 HTTP \(code)。"
        }
    }
}

struct ScreenLease: Decodable, Sendable {
    let session: String
    let seconds: Int
}

struct ScreenFrame: Sendable {
    let data: Data
    let revision: UInt64
}

struct ScreenAction: Encodable, Sendable {
    enum Kind: String, Encodable {
        case tap, swipe, back, home, recents, wake
    }

    struct Point: Encodable, Sendable {
        let x: Double
        let y: Double
    }

    let kind: Kind
    var start: Point?
    var end: Point?
    var revision: UInt64?
}

struct ScreenConnection: Sendable {
    private let endpoint: URL
    private let session: URLSession

    init(_ pairing: ScreenPairing) {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = pairing.host
        parts.port = pairing.port
        endpoint = parts.url!
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForResource = 7
        session = URLSession(configuration: config, delegate: ScreenServerTrust(pairing), delegateQueue: nil)
    }

    func enroll(ticket: String, key: String) async throws {
        _ = try await request("enroll", method: "POST", key: ticket, body: JSONEncoder().encode(["key": key]))
    }

    func open(key: String) async throws -> ScreenLease {
        let (data, _) = try await request("session", method: "POST", key: key)
        let lease = try JSONDecoder().decode(ScreenLease.self, from: data)
        guard ScreenPairing.isToken(lease.session), (1...600).contains(lease.seconds) else {
            throw ScreenError.badResponse
        }
        return lease
    }

    func close(_ lease: ScreenLease) async {
        _ = try? await request("session", method: "DELETE", key: lease.session)
    }

    func frame(_ lease: ScreenLease) async throws -> ScreenFrame {
        let (data, response) = try await request("frame", method: "GET", key: lease.session)
        guard response.mimeType == "image/png", data.count <= 2 * 1024 * 1024,
              let value = response.value(forHTTPHeaderField: "X-Screen-Revision"), let revision = UInt64(value) else {
            throw ScreenError.badResponse
        }
        return ScreenFrame(data: data, revision: revision)
    }

    func action(_ command: ScreenAction, lease: ScreenLease) async throws {
        _ = try await request("action", method: "POST", key: lease.session, body: JSONEncoder().encode(command))
    }

    func invalidate() { session.invalidateAndCancel() }

    private func request(_ route: String, method: String, key: String,
                         body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        let url = endpoint.appendingPathComponent("v1").appendingPathComponent(route)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.httpMethod = method
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch let error as URLError {
            switch error.code {
            case .cancelled:
                if Task.isCancelled { throw CancellationError() }
                throw ScreenError.untrusted
            case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .secureConnectionFailed, .userCancelledAuthentication:
                throw ScreenError.untrusted
            default: throw ScreenError.disconnected
            }
        }
        guard let http = response as? HTTPURLResponse else { throw ScreenError.badResponse }
        switch http.statusCode {
        case 200..<300: return (data, http)
        case 401: throw ScreenError.rejected
        case 409: throw ScreenError.orientationChanged
        case 429: throw ScreenError.rateLimit
        default: throw ScreenError.http(http.statusCode)
        }
    }
}

private final class ScreenServerTrust: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let pairing: ScreenPairing
    init(_ pairing: ScreenPairing) { self.pairing = pairing }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let protection = challenge.protectionSpace
        // The out-of-band record binds the exact device certificate to this hotspot
        // address. Evaluate that pinned certificate as a private X.509 trust anchor.
        guard protection.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              protection.host == pairing.host, protection.port == pairing.port,
              let trust = protection.serverTrust,
              let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = certificates.first,
              UFIClient.hex(SHA256.hash(data: SecCertificateCopyData(leaf) as Data)) == pairing.certificateSHA256,
              SecTrustSetPolicies(trust, SecPolicyCreateBasicX509()) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [leaf] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
