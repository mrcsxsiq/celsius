import Foundation
import Testing
@testable import CelsiusCore

private let spec = #"""
{"success":true,"t":1,"result":{"category":"kt","functions":[
{"code":"switch","type":"Boolean","values":"{}"},
{"code":"mode","type":"Enum","values":"{\"range\":[\"auto\",\"cold\",\"hot\",\"wet\",\"wind\"]}"},
{"code":"temp_set","type":"Integer","values":"{\"unit\":\"℃\",\"min\":160,\"max\":300,\"scale\":1,\"step\":10}"},
{"code":"windspeed","type":"Enum","values":"{\"range\":[\"auto\",\"low\",\"mid\",\"high\"]}"},
{"code":"eco","type":"Boolean","values":"{}"},
{"code":"shake","type":"Boolean","values":"{}"}],
"status":[{"code":"temp_current","type":"Integer","values":"{\"unit\":\"℃\",\"min\":-100,\"max\":500,\"scale\":1,\"step\":1}"}]}}
"""#

private let state = #"""
{"success":true,"t":1,"result":[
{"code":"switch","value":true},{"code":"mode","value":"cold"},{"code":"temp_set","value":235},
{"code":"temp_current","value":271},{"code":"windspeed","value":"mid"},{"code":"shake","value":false},
{"code":"eco","value":true},{"code":"fault","value":0}]}
"""#

private let deviceList = #"""
{"success":true,"t":1,"result":{"has_more":false,"devices":[
{"id":"bf1","name":"Sala","category":"kt","product_name":"Elgin Smart AC"},
{"id":"bf2","name":"Lamp","category":"dj","product_name":"Bulb"},
{"id":"bf3","name":"Quarto","category":"kt","product_name":"Elgin Smart AC"}]}}
"""#

private let tokenResponse = #"{"success":true,"t":1,"result":{"access_token":"TOKEN1","expire_time":7200,"refresh_token":"r","uid":"u"}}"#

private final class FakeTuya: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var statusFailures: [String]
    var clock = Date(timeIntervalSince1970: 1_588_925_778)

    init(statusFailures: [String] = []) { self.statusFailures = statusFailures }

    var all: [URLRequest] { lock.withLock { requests } }
    func count(_ path: String) -> Int { all.filter { $0.url?.path == path }.count }
    func bodies(of path: String) -> [JSONValue] {
        all.filter { $0.url?.path == path }.compactMap { try? json($0.httpBody) }
    }

    private func nextStatusFailure() -> String? {
        lock.withLock { statusFailures.isEmpty ? nil : statusFailures.removeFirst() }
    }

    var transport: TuyaClient.Transport {
        { [self] request in
            lock.withLock { requests.append(request) }
            let path = request.url!.path
            let body: String
            switch path {
            case "/v1.0/token": body = tokenResponse
            case "/v1.0/iot-01/associated-users/devices": body = deviceList
            case let p where p.hasSuffix("/specifications"): body = spec
            case let p where p.hasSuffix("/status"): body = nextStatusFailure() ?? state
            case let p where p.hasSuffix("/commands"): body = #"{"success":true,"t":1,"result":true}"#
            default: body = #"{"success":false,"code":404,"msg":"unknown"}"#
            }
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    func client(clock: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_588_925_778) }) -> TuyaClient {
        TuyaClient(
            credentials: TuyaCredentials(accessID: "cid", accessSecret: "secret"),
            transport: transport, now: clock, nonce: { "n1" }
        )
    }
}

private func json(_ data: Data?) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: try #require(data))
}

@Suite struct TuyaSigningTests {
    @Test func signsABusinessRequestOverTheEmptyBodyHash() {
        let sign = TuyaClient.signature(
            secret: "secret", clientID: "cid", token: "tok", timestamp: "1588925778000", nonce: "n1",
            method: "GET", body: nil, url: "/v1.0/devices/d1/status"
        )
        #expect(sign == "F8982FF1663E554C1F4827FB343FAE4107299378380288A43DB2166C1502F78F")
    }

    @Test func signsATokenRequestWithoutAToken() {
        let body = Data(#"{"commands":[{"code":"switch","value":true}]}"#.utf8)
        let sign = TuyaClient.signature(
            secret: "secret", clientID: "cid", token: nil, timestamp: "1588925778000", nonce: "n2",
            method: "POST", body: body, url: "/v1.0/token?grant_type=1"
        )
        #expect(sign == "3C81623FE612790EC1150B5EE391950BD3347B9B29BDCAE8F47F721F692E4CC6")
    }

    @Test func queryParametersAreSortedInTheSignedURL() {
        #expect(TuyaClient.signedURL(path: "/p", query: [("b", "2"), ("a", "1")]) == "/p?a=1&b=2")
        #expect(TuyaClient.signedURL(path: "/p", query: []) == "/p")
    }

    @Test func requestCarriesTheHeadersTuyaExpects() async throws {
        let fake = FakeTuya()
        let request = try await fake.client().makeRequest("GET", "/v1.0/devices/d1/status", token: "tok")
        #expect(request.value(forHTTPHeaderField: "client_id") == "cid")
        #expect(request.value(forHTTPHeaderField: "access_token") == "tok")
        #expect(request.value(forHTTPHeaderField: "t") == "1588925778000")
        #expect(request.value(forHTTPHeaderField: "sign_method") == "HMAC-SHA256")
        #expect(request.value(forHTTPHeaderField: "sign") == "F8982FF1663E554C1F4827FB343FAE4107299378380288A43DB2166C1502F78F")
        #expect(request.url?.host == "openapi.tuyaus.com")
    }
}

@Suite struct TuyaClientTests {
    @Test func listsOnlyAirConditioners() async throws {
        let devices = try await FakeTuya().client().devices()
        #expect(devices.map(\.id) == ["bf1", "bf3"])
        #expect(devices.allSatisfy { $0.isAirConditioner })
        #expect(devices.first?.displayName == "Sala")
    }

    @Test func capabilitiesComeFromTheInstructionSet() async throws {
        let caps = try await FakeTuya().client().capabilities(deviceID: "bf1")
        #expect(caps.modes == [ACMode.auto, ACMode.cool, ACMode.heat, ACMode.dry, ACMode.fan])
        #expect(caps.fanSpeeds == ["AUTO", "LOW", "MID", "HIGH"])
        #expect(caps.minTemperature == 16)
        #expect(caps.maxTemperature == 30)
        #expect(caps.temperatureStep == 1)
        #expect(caps.supportsEco && caps.supportsSwing)
        #expect(!caps.supportsSleep)
    }

    @Test func statusAppliesTheTemperatureScale() async throws {
        let status = try await FakeTuya().client().status(deviceID: "bf1")
        #expect(status == ACStatus(
            isOn: true, mode: ACMode.cool, currentTemperature: 27.1, targetTemperature: 23.5,
            fanSpeed: "MID", swing: false, eco: true, sleepMinutesLeft: nil, hasError: false
        ))
    }

    @Test func commandsUseTheUnitsOwnCodesAndValues() async throws {
        let fake = FakeTuya()
        let client = fake.client()
        let cases: [(ACCommand, String)] = [
            (.power(true), #"{"code":"switch","value":true}"#),
            (.mode(ACMode.cool), #"{"code":"mode","value":"cold"}"#),
            (.mode(ACMode.dry), #"{"code":"mode","value":"wet"}"#),
            (.targetTemperature(22.5), #"{"code":"temp_set","value":225}"#),
            (.fanSpeed("HIGH"), #"{"code":"windspeed","value":"high"}"#),
            (.swing(true), #"{"code":"shake","value":true}"#),
            (.eco(false), #"{"code":"eco","value":false}"#),
        ]
        for (command, _) in cases { try await client.send(command, deviceID: "bf1") }
        let sent = fake.bodies(of: "/v1.0/devices/bf1/commands")
        #expect(sent.count == cases.count)
        for (body, expected) in zip(sent, cases.map(\.1)) {
            let instruction = try json(Data(expected.utf8))
            #expect(body == .object(["commands": .array([instruction])]))
        }
    }

    @Test func sleepTimerIsRejectedBecauseTheUnitHasNone() async throws {
        let client = FakeTuya().client()
        await #expect(throws: ThinQError.self) { try await client.send(.sleep(hours: 2), deviceID: "bf1") }
    }

    @Test func tokenIsFetchedOnceAndReused() async throws {
        let fake = FakeTuya()
        let client = fake.client()
        _ = try await client.status(deviceID: "bf1")
        _ = try await client.status(deviceID: "bf1")
        #expect(fake.count("/v1.0/token") == 1)
        #expect(fake.count("/v1.0/devices/bf1/specifications") == 1)
    }

    @Test func expiredTokenIsRenewedBeforeItIsUsed() async throws {
        let fake = FakeTuya()
        let clock = Clock()
        let client = fake.client(clock: { clock.now.addingTimeInterval(1_588_925_778) })
        _ = try await client.status(deviceID: "bf1")
        clock.now = Date(timeIntervalSinceReferenceDate: 7_200)
        _ = try await client.status(deviceID: "bf1")
        #expect(fake.count("/v1.0/token") == 2)
    }

    @Test func aRefusedTokenIsRenewedAndTheRequestRepeated() async throws {
        let fake = FakeTuya(statusFailures: [#"{"success":false,"code":1010,"msg":"token invalid"}"#])
        let status = try await fake.client().status(deviceID: "bf1")
        #expect(status.isOn)
        #expect(fake.count("/v1.0/token") == 2)
    }

    @Test func aTokenRefusedTwiceMeansTheKeysAreWrong() async throws {
        let refused = #"{"success":false,"code":1010,"msg":"token invalid"}"#
        let client = FakeTuya(statusFailures: [refused, refused]).client()
        await #expect(throws: ThinQError.unauthorized) { try await client.status(deviceID: "bf1") }
    }

    @Test(arguments: [
        (#"{"success":false,"code":1004,"msg":"sign invalid"}"#, ThinQError.unauthorized),
        (#"{"success":false,"code":1106,"msg":"permission deny"}"#, ThinQError.unauthorized),
        (#"{"success":false,"code":2001,"msg":"device is offline"}"#, ThinQError.deviceOffline),
        (#"{"success":false,"code":2008,"msg":"command or value not support"}"#, ThinQError.rejected("command or value not support")),
        (#"{"success":false,"code":9999,"msg":"boom"}"#, ThinQError.api(code: "9999", message: "boom")),
    ])
    func apiErrorsAreMapped(body: String, expected: ThinQError) async throws {
        let client = FakeTuya(statusFailures: [body]).client()
        await #expect(throws: expected) { try await client.status(deviceID: "bf1") }
    }
}

@MainActor
@Suite struct TuyaStoreTests {
    private func makeStore(settings: InMemorySettings, fake: FakeTuya) -> ACStore {
        ACStore(
            settings: settings,
            makeTuyaClient: { TuyaClient(credentials: $0, transport: fake.transport, nonce: { "n1" }) }
        )
    }

    @Test func connectingSavesTheKeysAndReadsTheFirstUnit() async throws {
        let settings = InMemorySettings()
        let store = makeStore(settings: settings, fake: FakeTuya())
        #expect(store.connection == .needsSetup)

        await store.connect(tuya: TuyaCredentials(accessID: " cid ", accessSecret: "secret\n", region: .westernAmerica))

        #expect(settings.provider == .tuya)
        #expect(settings.tuyaCredentials == TuyaCredentials(accessID: "cid", accessSecret: "secret"))
        #expect(store.connection == .connected)
        #expect(store.device?.id == "bf1")
        #expect(store.status?.targetTemperature == 23.5)
        #expect(store.hasCredentials)
    }

    @Test func commandsGoToTheTuyaUnit() async throws {
        let fake = FakeTuya()
        let store = makeStore(settings: InMemorySettings(), fake: fake)
        await store.connect(tuya: TuyaCredentials(accessID: "cid", accessSecret: "secret"))
        store.perform(.power(false))
        for _ in 0..<50 where fake.count("/v1.0/devices/bf1/commands") == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fake.count("/v1.0/devices/bf1/commands") == 1)
    }

    @Test func signingOutForgetsBothClouds() async throws {
        let settings = InMemorySettings(token: "tok")
        let store = makeStore(settings: settings, fake: FakeTuya())
        await store.connect(tuya: TuyaCredentials(accessID: "cid", accessSecret: "secret"))
        store.signOut()
        #expect(settings.token == nil)
        #expect(settings.tuyaCredentials == nil)
        #expect(store.connection == .needsSetup)
        #expect(!store.hasCredentials)
    }

    @Test func switchingToThinQLeavesTheTuyaKeysAlone() async throws {
        let settings = InMemorySettings(provider: .tuya, tuyaCredentials: TuyaCredentials(accessID: "cid", accessSecret: "secret"))
        let store = makeStore(settings: settings, fake: FakeTuya())
        #expect(store.hasCredentials)
        #expect(store.provider == .tuya)
    }
}
