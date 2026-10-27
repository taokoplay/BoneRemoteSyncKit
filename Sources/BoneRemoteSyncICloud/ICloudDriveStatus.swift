import Foundation

/// Why the configured iCloud Drive view is unavailable.
public enum ICloudDriveAvailabilityReason: String, Sendable, Codable, Equatable {
    /// No ubiquity identity is available to this process; not a probe of system Settings.
    case notSignedIn
    /// Drive may be disabled, or container/entitlement/service resolution may be unavailable.
    case driveUnavailable
    case containerNotFound
    case directoryNotFound
    case unknown
}

/// The local availability state of the configured ubiquitous container.
public enum ICloudDriveAvailability: String, Sendable, Codable, Equatable {
    case unavailable
    case available
}

/// Download state reported by Foundation for an iCloud Drive item.
public enum ICloudDriveDownloadState: String, Sendable, Codable, Equatable {
    case current
    case downloaded
    case downloading
    case notDownloaded
    case unknown
}

/// A stable, public snapshot of iCloud Drive state. It describes the local view;
/// it is not a promise that another device has finished uploading its changes.
public struct ICloudDriveStatus: Sendable, Codable, Equatable {
    public let availability: ICloudDriveAvailability
    /// Present when `availability == .unavailable`; nil for an available view.
    public let unavailableReason: ICloudDriveAvailabilityReason?
    public let containerURL: URL?
    public let rootURL: URL?
    public let accountIdentifierAvailable: Bool
    public let isUbiquitous: Bool
    public let downloadState: ICloudDriveDownloadState?
    public let percentDownloaded: Double?

    public init(
        availability: ICloudDriveAvailability,
        unavailableReason: ICloudDriveAvailabilityReason? = nil,
        containerURL: URL? = nil,
        rootURL: URL? = nil,
        accountIdentifierAvailable: Bool = false,
        isUbiquitous: Bool = false,
        downloadState: ICloudDriveDownloadState? = nil,
        percentDownloaded: Double? = nil
    ) {
        self.availability = availability
        self.unavailableReason = availability == .available ? nil : (unavailableReason ?? .unknown)
        self.containerURL = containerURL
        self.rootURL = rootURL
        self.accountIdentifierAvailable = accountIdentifierAvailable
        self.isUbiquitous = isUbiquitous
        self.downloadState = downloadState
        self.percentDownloaded = percentDownloaded
    }

    public var isAvailable: Bool { availability == .available }

    private enum CodingKeys: String, CodingKey {
        case availability, unavailableReason, containerURL, rootURL
        case accountIdentifierAvailable, isUbiquitous, downloadState, percentDownloaded
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            availability: try values.decode(ICloudDriveAvailability.self, forKey: .availability),
            unavailableReason: try values.decodeIfPresent(ICloudDriveAvailabilityReason.self, forKey: .unavailableReason),
            containerURL: try values.decodeIfPresent(URL.self, forKey: .containerURL),
            rootURL: try values.decodeIfPresent(URL.self, forKey: .rootURL),
            accountIdentifierAvailable: try values.decode(Bool.self, forKey: .accountIdentifierAvailable),
            isUbiquitous: try values.decode(Bool.self, forKey: .isUbiquitous),
            downloadState: try values.decodeIfPresent(ICloudDriveDownloadState.self, forKey: .downloadState),
            percentDownloaded: try values.decodeIfPresent(Double.self, forKey: .percentDownloaded)
        )
    }
}
