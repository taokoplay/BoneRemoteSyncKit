import Foundation

/// Non-secret configuration for an iCloud Drive container.
///
/// The host application must declare the matching iCloud entitlement and container.
/// `containerIdentifier == nil` uses the app's default ubiquitous container.
public struct ICloudDriveConfiguration: Sendable, Codable, Equatable, Hashable {
    public static let standard = try! Self()

    public let containerIdentifier: String?
    public let directoryPath: String
    public let downloadTimeout: TimeInterval
    public let pollInterval: TimeInterval

    private enum CodingKeys: String, CodingKey { case containerIdentifier, directoryPath, downloadTimeout, pollInterval }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(containerIdentifier: values.decodeIfPresent(String.self, forKey: .containerIdentifier),
                      directoryPath: values.decode(String.self, forKey: .directoryPath),
                      downloadTimeout: values.decode(TimeInterval.self, forKey: .downloadTimeout),
                      pollInterval: values.decode(TimeInterval.self, forKey: .pollInterval))
    }

    public init(
        containerIdentifier: String? = nil,
        directoryPath: String = "/",
        downloadTimeout: TimeInterval = 120,
        pollInterval: TimeInterval = 0.25
    ) throws {
        let normalized = Self.normalizeDirectory(directoryPath)
        guard Self.validIdentifier(containerIdentifier),
              normalized != nil,
              downloadTimeout.isFinite, downloadTimeout > 0, downloadTimeout <= 86_400,
              pollInterval.isFinite, pollInterval > 0, pollInterval <= 60 else {
            throw ICloudDriveError.invalidContainer
        }
        self.containerIdentifier = containerIdentifier
        self.directoryPath = normalized!
        self.downloadTimeout = downloadTimeout
        self.pollInterval = pollInterval
    }

    private static func validIdentifier(_ identifier: String?) -> Bool {
        guard let identifier else { return true }
        return !identifier.isEmpty && identifier.utf8.count <= 255
            && !identifier.utf8.contains(0)
            && !identifier.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "\\" })
    }

    private static func normalizeDirectory(_ raw: String) -> String? {
        guard !raw.isEmpty, !raw.utf8.contains(0), !raw.contains("\\") else { return nil }
        let parts = raw.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.contains(where: { $0 == "." || $0 == ".." || $0.contains(":") }) else { return nil }
        let result = "/" + parts.joined(separator: "/")
        guard result.utf8.count <= 16 * 1024 else { return nil }
        return result
    }
}
