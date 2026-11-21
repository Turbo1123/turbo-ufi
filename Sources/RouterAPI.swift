import CryptoKit
import Foundation

struct FormAction: Equatable {
    let command: String
    var values: [String: String] = [:]

    var parameters: [String: String] {
        var parameters = values
        parameters["goformId"] = command
        return parameters
    }
}

extension UFIClient {
    func routerRead(_ fields: String, cookie: String? = nil) async throws -> JSONObject {
        var request = signedRequest("/api/goform/goform_get_cmd_process", query: [
            .init(name: "cmd", value: fields), .init(name: "multi_data", value: "1"),
            .init(name: "isTest", value: "false"), .init(name: "_", value: String(Int64(Date().timeIntervalSince1970 * 1000)))
        ])
        request.setValue(cookie, forHTTPHeaderField: "Kano-Cookie")
        let (data, _) = try await send(request)
        return try Self.parseJSONObject(data)
    }

    func apply(_ action: FormAction, credentials: DeviceCredentials) async throws {
        let cookie = try await routerLogin(credentials)
        async let version = routerRead("Language,cr_version,wa_inner_version")
        async let challenge = routerRead("RD", cookie: cookie)
        let (firmware, random) = try await (version, challenge)
        guard let webVersion = firmware.text("wa_inner_version"), let modem = firmware.text("cr_version"),
              let rd = random.text("RD") else { throw ConnectionError.invalidResponse }
        var values = action.parameters
        values["AD"] = Self.routerHash(Self.routerHash(webVersion + modem) + rd)
        let (response, _) = try await submitRouterForm(values, cookie: cookie)
        guard response.text("result") == "success" else { throw ConnectionError.rejected }
    }

    func routerLogin(_ credentials: DeviceCredentials) async throws -> String {
        guard !credentials.password.isEmpty else { throw ConnectionError.routerPassword }
        if let cookie = try? await request("/api/get_cookie").text("cookie"), !cookie.isEmpty,
           try await routerRead("loginfo", cookie: cookie).text("loginfo") == "ok" {
            return cookie
        }
        let challenge = try await routerRead("LD")
        guard let ld = challenge.text("LD") else { throw ConnectionError.invalidResponse }
        var form = [
            "goformId": credentials.multiUser ? "LOGIN_MULTI_USER" : "LOGIN",
            "password": Self.routerHash(Self.routerHash(credentials.password) + ld),
            "user": "admin"
        ]
        if credentials.multiUser { form["IP"] = "localhost" }
        let (result, response) = try await submitRouterForm(form, cookie: nil)
        guard result.text("result") != "3",
              let cookie = response.value(forHTTPHeaderField: "kano-cookie")?.split(separator: ";").first,
              cookie.contains("=") else { throw ConnectionError.routerPassword }
        _ = try? await request("/api/set_cookie", body: ["cookie": String(cookie)])
        return String(cookie)
    }

    private func submitRouterForm(_ values: [String: String], cookie: String?) async throws -> (JSONObject, HTTPURLResponse) {
        var request = signedRequest("/api/goform/goform_set_cmd_process", method: "POST", timeout: 25)
        var parameters = values
        parameters["isTest"] = "false"
        request.httpBody = Self.encodeForm(parameters)
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Kano-Cookie")
        let (data, response) = try await send(request)
        return (try Self.parseJSONObject(data), response)
    }

    static func encodeForm(_ values: [String: String]) -> Data {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789*-._")
        func encode(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: unreserved)!.replacingOccurrences(of: "%20", with: "+")
        }
        return Data(values.sorted(by: { $0.key < $1.key }).map { encode($0.key) + "=" + encode($0.value) }.joined(separator: "&").utf8)
    }

    static func routerHash(_ value: String) -> String {
        hex(SHA256.hash(data: Data(value.utf8))).uppercased()
    }
}
