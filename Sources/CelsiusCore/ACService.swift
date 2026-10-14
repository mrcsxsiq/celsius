import Foundation

public enum ACProvider: String, Codable, Sendable, CaseIterable {
    case thinQ
    case tuya
}

public protocol ACService: Sendable {
    func devices() async throws -> [ThinQDevice]
    func capabilities(deviceID: String) async throws -> ACCapabilities
    func status(deviceID: String) async throws -> ACStatus
    func send(_ command: ACCommand, deviceID: String) async throws
}

extension ThinQClient: ACService {}
