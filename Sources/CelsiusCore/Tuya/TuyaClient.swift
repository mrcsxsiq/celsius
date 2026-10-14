import CryptoKit
import Foundation
import os

public actor TuyaClient: ACService {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private static let log = Logger(subsystem: "com.gabrielvillarinho.celsius", category: "tuya")
    private static let airConditionerCategory = "kt"
    private static let emptyBodyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    private static let maxDevicePages = 10
    private static let tokenMargin: TimeInterval = 60

    private struct Token {
        var value: String
        var expires: Date
    }

    private struct TokenRejected: Error {}

    private let credentials: TuyaCredentials
    private let transport: Transport
    private let now: @Sendable () -> Date
    private let nonce: @Sendable () -> String
    private var token: Token?
    private var specs: [String: TuyaSpec] = [:]

    public init(
        credentials: TuyaCredentials,
        transport: Transport? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        nonce: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.credentials = credentials
        self.transport = transport ?? { request in
            try await URLSession.shared.data(for: request)
        }
        self.now = now
        self.nonce = nonce
    }

    public func devices() async throws -> [ThinQDevice] {
        var found: [ThinQDevice] = []
        var lastRowKey: String?
        for _ in 0..<Self.maxDevicePages {
            let query = lastRowKey.map { [("last_row_key", $0)] } ?? []
            let page = try await call("GET", "/v1.0/iot-01/associated-users/devices", query: query)
            for device in page["devices"]?.array ?? [] {
                guard device["category"]?.string == Self.airConditionerCategory, let id = device["id"]?.string else { continue }
                found.append(ThinQDevice(
                    deviceId: id,
                    deviceInfo: .init(
                        deviceType: "DEVICE_AIR_CONDITIONER",
                        modelName: device["product_name"]?.string,
                        alias: device["name"]?.string
                    )
                ))
            }
            guard page["has_more"]?.bool == true, let next = page["last_row_key"]?.string, !next.isEmpty else { break }
            lastRowKey = next
        }
        return found
    }

    public func capabilities(deviceID: String) async throws -> ACCapabilities {
        try await loadSpec(deviceID, refresh: true).capabilities
    }

    public func status(deviceID: String) async throws -> ACStatus {
        let spec = try await loadSpec(deviceID)
        let result = try await call("GET", "/v1.0/devices/\(deviceID)/status")
        var values: [String: JSONValue] = [:]
        for entry in result.array ?? [] {
            if let code = entry["code"]?.string, let value = entry["value"] { values[code] = value }
        }

        func scaled(_ value: JSONValue?, _ scale: Int) -> Double? {
            value?.double.map { $0 / pow(10, Double(scale)) }
        }

        return ACStatus(
            isOn: values["switch"]?.bool ?? false,
            mode: values["mode"]?.string.map(TuyaValues.mode),
            currentTemperature: scaled(values["temp_current"], spec.currentScale),
            targetTemperature: scaled(values["temp_set"], spec.targetScale),
            fanSpeed: spec.fanCode.flatMap { values[$0]?.string }.map(TuyaValues.fanSpeed),
            swing: values["shake"]?.bool,
            eco: values["eco"]?.bool,
            sleepMinutesLeft: nil,
            hasError: (values["fault"]?.double ?? 0) > 0
        )
    }

    public func send(_ command: ACCommand, deviceID: String) async throws {
        let spec = try await loadSpec(deviceID)
        let body: JSONValue = .object(["commands": .array([try instruction(for: command, spec: spec)])])
        _ = try await call("POST", "/v1.0/devices/\(deviceID)/commands", body: body)
    }

    private func instruction(for command: ACCommand, spec: TuyaSpec) throws -> JSONValue {
        func make(_ code: String, _ value: JSONValue) -> JSONValue { ["code": .string(code), "value": value] }

        switch command {
        case .power(let on):
            return make("switch", .bool(on))
        case .mode(let mode):
            let raw = TuyaValues.raw(mode, among: spec.modes, translate: TuyaValues.mode) ?? mode.lowercased()
            return make("mode", .string(raw))
        case .targetTemperature(let value):
            return make("temp_set", .number((value * pow(10, Double(spec.targetScale))).rounded()))
        case .fanSpeed(let speed):
            guard let code = spec.fanCode else { throw ThinQError.rejected("This unit has no fan speed control") }
            let raw = TuyaValues.raw(speed, among: spec.fanSpeeds, translate: TuyaValues.fanSpeed) ?? speed.lowercased()
            return make(code, .string(raw))
        case .swing(let on):
            guard spec.supportsSwing else { throw ThinQError.rejected("This unit has no swing control") }
            return make("shake", .bool(on))
        case .eco(let on):
            guard spec.supportsEco else { throw ThinQError.rejected("This unit has no eco mode") }
            return make("eco", .bool(on))
        case .sleep:
            throw ThinQError.rejected("The sleep timer isn't available on this unit")
        }
    }

    private func loadSpec(_ deviceID: String, refresh: Bool = false) async throws -> TuyaSpec {
        if !refresh, let spec = specs[deviceID] { return spec }
        let spec = TuyaSpec(json: try await call("GET", "/v1.0/devices/\(deviceID)/specifications"))
        specs[deviceID] = spec
        return spec
    }

    private func call(
        _ method: String, _ path: String, query: [(String, String)] = [], body: JSONValue? = nil
    ) async throws -> JSONValue {
        do {
            return try await perform(method, path, query: query, body: body, token: try await accessToken())
        } catch is TokenRejected {
            token = nil
            do {
                return try await perform(method, path, query: query, body: body, token: try await accessToken())
            } catch is TokenRejected {
                throw ThinQError.unauthorized
            }
        }
    }

    private func accessToken() async throws -> String {
        if let token, token.expires > now().addingTimeInterval(Self.tokenMargin) { return token.value }
        let result: JSONValue
        do {
            result = try await perform("GET", "/v1.0/token", query: [("grant_type", "1")], body: nil, token: nil)
        } catch is TokenRejected {
            throw ThinQError.unauthorized
        }
        guard let value = result["access_token"]?.string, let lifetime = result["expire_time"]?.double else {
            throw ThinQError.invalidResponse
        }
        token = Token(value: value, expires: now().addingTimeInterval(lifetime))
        return value
    }

    private func perform(
        _ method: String, _ path: String, query: [(String, String)], body: JSONValue?, token: String?
    ) async throws -> JSONValue {
        let request = try makeRequest(method, path, query: query, body: body, token: token)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch let error as URLError {
            Self.log.error("\(method, privacy: .public) \(path, privacy: .public) failed: \(error.code.rawValue, privacy: .public)")
            throw ThinQError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let envelope = try? JSONDecoder().decode(JSONValue.self, from: data)

        if envelope?["success"]?.bool == true, let result = envelope?["result"] {
            return result
        }
        if let envelope, envelope["success"]?.bool == false {
            let code = Int(envelope["code"]?.double ?? 0)
            Self.log.error("\(method, privacy: .public) \(path, privacy: .public) status \(status, privacy: .public) code \(code, privacy: .public)")
            throw try Self.failure(code: code, message: envelope["msg"]?.string ?? "Request failed", status: status)
        }
        Self.log.error("\(method, privacy: .public) \(path, privacy: .public) status \(status, privacy: .public)")
        if status >= 500 { throw ThinQError.serverError(status) }
        throw status == 429 ? ThinQError.rateLimited : ThinQError.invalidResponse
    }

    private static func failure(code: Int, message: String, status: Int) throws -> any Error {
        switch code {
        case 1002, 1010: return TokenRejected()
        case 1001, 1004, 1106, 28841002, 28841105: return ThinQError.unauthorized
        case 2001: return ThinQError.deviceOffline
        case 2008: return ThinQError.rejected(message)
        default:
            if status >= 500 { return ThinQError.serverError(status) }
            return ThinQError.api(code: String(code), message: message)
        }
    }

    func makeRequest(
        _ method: String, _ path: String, query: [(String, String)] = [], body: JSONValue? = nil, token: String?
    ) throws -> URLRequest {
        let payload = try body.map { try JSONEncoder().encode($0) }
        let timestamp = String(Int(now().timeIntervalSince1970 * 1000))
        let nonce = nonce()
        let sorted = query.sorted { $0.0 < $1.0 }
        let signedURL = Self.signedURL(path: path, query: sorted)

        var components = URLComponents(url: credentials.region.baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        components.queryItems = sorted.isEmpty ? nil : sorted.map { URLQueryItem(name: $0.0, value: $0.1) }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.httpBody = payload
        request.setValue(credentials.accessID, forHTTPHeaderField: "client_id")
        request.setValue(timestamp, forHTTPHeaderField: "t")
        request.setValue(nonce, forHTTPHeaderField: "nonce")
        request.setValue("HMAC-SHA256", forHTTPHeaderField: "sign_method")
        if let token { request.setValue(token, forHTTPHeaderField: "access_token") }
        if payload != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue(
            Self.signature(
                secret: credentials.accessSecret, clientID: credentials.accessID, token: token,
                timestamp: timestamp, nonce: nonce, method: method, body: payload, url: signedURL
            ),
            forHTTPHeaderField: "sign"
        )
        return request
    }

    static func signedURL(path: String, query: [(String, String)]) -> String {
        guard !query.isEmpty else { return path }
        return path + "?" + query.sorted { $0.0 < $1.0 }.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }

    static func signature(
        secret: String, clientID: String, token: String?, timestamp: String, nonce: String,
        method: String, body: Data?, url: String
    ) -> String {
        let bodyHash = body.map { SHA256.hash(data: $0).hex } ?? emptyBodyHash
        let stringToSign = [method, bodyHash, "", url].joined(separator: "\n")
        let message = clientID + (token ?? "") + timestamp + nonce + stringToSign
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(secret.utf8)))
        return Data(mac).hex.uppercased()
    }
}

private extension Sequence where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
