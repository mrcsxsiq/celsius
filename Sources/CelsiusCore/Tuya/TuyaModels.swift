import Foundation

public enum TuyaRegion: String, Codable, Sendable, CaseIterable {
    case westernAmerica
    case easternAmerica
    case centralEurope
    case westernEurope
    case china
    case india
    case singapore

    public var baseURL: URL {
        switch self {
        case .westernAmerica: URL(string: "https://openapi.tuyaus.com")!
        case .easternAmerica: URL(string: "https://openapi-ueaz.tuyaus.com")!
        case .centralEurope: URL(string: "https://openapi.tuyaeu.com")!
        case .westernEurope: URL(string: "https://openapi-weaz.tuyaeu.com")!
        case .china: URL(string: "https://openapi.tuyacn.com")!
        case .india: URL(string: "https://openapi.tuyain.com")!
        case .singapore: URL(string: "https://openapi-sg.iotbing.com")!
        }
    }

    public var title: String {
        switch self {
        case .westernAmerica: "Western America"
        case .easternAmerica: "Eastern America"
        case .centralEurope: "Central Europe"
        case .westernEurope: "Western Europe"
        case .china: "China"
        case .india: "India"
        case .singapore: "Singapore"
        }
    }
}

public struct TuyaCredentials: Codable, Sendable, Equatable {
    public var accessID: String
    public var accessSecret: String
    public var region: TuyaRegion

    public init(accessID: String, accessSecret: String, region: TuyaRegion = .westernAmerica) {
        self.accessID = accessID
        self.accessSecret = accessSecret
        self.region = region
    }
}

struct TuyaSpec: Sendable, Equatable {
    static let fanCodes = ["windspeed", "fan_speed_enum"]

    var modes: [String] = []
    var fanCode: String?
    var fanSpeeds: [String] = []
    var targetRange: ClosedRange<Double>?
    var targetStep: Double = 1
    var targetScale = 0
    var currentScale = 0
    var supportsEco = false
    var supportsSwing = false

    init(json: JSONValue) {
        let functions = json["functions"]?.array ?? []
        let reported = json["status"]?.array ?? []

        func entry(_ code: String, in list: [JSONValue]) -> JSONValue? {
            list.first { $0["code"]?.string == code }
        }

        func values(_ entry: JSONValue?) -> JSONValue? {
            guard let text = entry?["values"]?.string, let data = text.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(JSONValue.self, from: data)
        }

        func range(_ entry: JSONValue?) -> [String] {
            values(entry)?["range"]?.array?.compactMap(\.string) ?? []
        }

        modes = range(entry("mode", in: functions))

        if let code = Self.fanCodes.first(where: { entry($0, in: functions) != nil }) {
            fanCode = code
            fanSpeeds = range(entry(code, in: functions))
        }

        if let target = values(entry("temp_set", in: functions)) {
            targetScale = Int(target["scale"]?.double ?? 0)
            let factor = pow(10, Double(targetScale))
            if let min = target["min"]?.double, let max = target["max"]?.double, min < max {
                targetRange = (min / factor)...(max / factor)
            }
            if let step = target["step"]?.double, step > 0 {
                targetStep = Swift.max(step / factor, targetScale > 0 ? 0.5 : 1)
            }
        }
        let current = values(entry("temp_current", in: reported)) ?? values(entry("temp_current", in: functions))
        currentScale = Int(current?["scale"]?.double ?? 0)

        supportsEco = entry("eco", in: functions) != nil
        supportsSwing = entry("shake", in: functions) != nil
    }

    var capabilities: ACCapabilities {
        let fallback = ACCapabilities.fallback
        return ACCapabilities(
            modes: modes.isEmpty ? fallback.modes : modes.map(TuyaValues.mode),
            fanSpeeds: fanSpeeds.isEmpty ? fallback.fanSpeeds : fanSpeeds.map(TuyaValues.fanSpeed),
            minTemperature: targetRange?.lowerBound ?? fallback.minTemperature,
            maxTemperature: targetRange?.upperBound ?? fallback.maxTemperature,
            temperatureStep: targetStep,
            supportsEco: supportsEco,
            supportsSwing: supportsSwing,
            supportsSleep: false
        )
    }
}

enum TuyaValues {
    private static let modes = ["cold": ACMode.cool, "wet": ACMode.dry, "wind": ACMode.fan, "auto": ACMode.auto, "hot": ACMode.heat]
    private static let fanSpeeds = ["low": "LOW", "mid": "MID", "middle": "MID", "high": "HIGH", "auto": "AUTO"]

    static func mode(_ value: String) -> String { modes[value.lowercased()] ?? value.uppercased() }
    static func fanSpeed(_ value: String) -> String { fanSpeeds[value.lowercased()] ?? value.uppercased() }

    static func raw(_ appValue: String, among declared: [String], translate: (String) -> String) -> String? {
        declared.first { translate($0) == appValue }
    }
}
