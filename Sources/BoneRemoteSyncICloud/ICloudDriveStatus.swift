import Foundation

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
    public let containerURL: URL?
    public let rootURL: URL?
    public let accountIdentifierAvailable: Bool
    public let isUbiquitous: Bool
    public let downloadState: ICloudDriveDownloadState?
    public let percentDownloaded: Double?

    public init(
        availability: ICloudDriveAvailability,
        containerURL: URL? = nil,
        rootURL: URL? = nil,
        accountIdentifierAvailable: Bool = false,
        isUbiquitous: Bool = false,
        downloadState: ICloudDriveDownloadState? = nil,
        percentDownloaded: Double? = nil
    ) {
        self.availability = availability
        self.containerURL = containerURL
        self.rootURL = rootURL
        self.accountIdentifierAvailable = accountIdentifierAvailable
        self.isUbiquitous = isUbiquitous
        self.downloadState = downloadState
        self.percentDownloaded = percentDownloaded
    }

    public var isAvailable: Bool { availability == .available }
}
