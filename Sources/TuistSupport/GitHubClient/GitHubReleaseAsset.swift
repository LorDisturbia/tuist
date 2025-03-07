import Foundation

public struct GitHubReleaseAsset: Decodable {
    /// The name of the asset..
    public let name: String

    /// The URL to download the asset
    public let browserDownloadUrl: URL

    private enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl
    }

    // MARK: - Init

    public init(name: String,
                browserDownloadUrl: URL)
    {
        self.name = name
        self.browserDownloadUrl = browserDownloadUrl
    }
}
