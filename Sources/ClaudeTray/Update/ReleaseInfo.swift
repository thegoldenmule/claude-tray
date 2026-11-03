import Foundation

/// The running app's version, from its Info.plist. `swift run`/`swift test` have no app
/// Info.plist, so both fields can be nil there.
struct AppVersionInfo: Sendable, Equatable {
    /// `CFBundleShortVersionString`, e.g. `0.3.1`.
    var shortVersion: String?
    /// `CFBundleVersion`, e.g. `114`.
    var build: String?

    init(shortVersion: String?, build: String?) {
        self.shortVersion = shortVersion?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        self.build = build?.trimmingCharacters(in: .whitespaces).nilIfEmpty
    }

    init(infoDictionary: [String: Any]?) {
        self.init(shortVersion: infoDictionary?["CFBundleShortVersionString"] as? String,
                  build: infoDictionary?["CFBundleVersion"] as? String)
    }

    static var main: AppVersionInfo { AppVersionInfo(infoDictionary: Bundle.main.infoDictionary) }

    /// nil if the short version isn't a semantic version (then no update is ever claimed).
    var version: SemanticVersion? { shortVersion.flatMap(SemanticVersion.init) }

    /// "ClaudeTray 0.3.1 (114)"; "ClaudeTray (development build)" without a version.
    var displayString: String {
        guard let shortVersion else { return "ClaudeTray (development build)" }
        guard let build, build != shortVersion else { return "ClaudeTray \(shortVersion)" }
        return "ClaudeTray \(shortVersion) (\(build))"
    }
}

/// A published GitHub release, reduced to what the menu needs.
struct ReleaseInfo: Sendable, Equatable, Codable {
    /// The tag as published, e.g. `v0.3.1`.
    var tag: String
    var version: SemanticVersion
    /// The release page (notes + downloads).
    var pageURL: URL
    /// The `ClaudeTray-X.Y.Z.dmg` asset, if the release has one.
    var dmgURL: URL?
    var publishedAt: Date?

    init(tag: String, version: SemanticVersion, pageURL: URL, dmgURL: URL? = nil, publishedAt: Date? = nil) {
        self.tag = tag
        self.version = version
        self.pageURL = pageURL
        self.dmgURL = dmgURL
        self.publishedAt = publishedAt
    }

    enum DecodeError: Error, Equatable, CustomStringConvertible {
        case malformed
        /// The release is a draft or pre-release (`releases/latest` never returns one).
        case notARelease
        case unrecognizedTag(String)

        var description: String {
            switch self {
            case .malformed: "unexpected response from GitHub"
            case .notARelease: "latest release is a draft or pre-release"
            case .unrecognizedTag(let tag): "unrecognized release tag \(tag)"
            }
        }
    }

    /// Decodes GitHub's `GET /repos/{owner}/{repo}/releases/latest` JSON.
    static func decodeGitHubRelease(_ data: Data) throws(DecodeError) -> ReleaseInfo {
        struct Asset: Decodable {
            var name: String
            var browser_download_url: URL?
        }
        struct Release: Decodable {
            var tag_name: String
            var html_url: URL
            var draft: Bool?
            var prerelease: Bool?
            var published_at: String?
            var assets: [Asset]?
        }
        let release: Release
        do {
            release = try JSONDecoder().decode(Release.self, from: data)
        } catch {
            throw .malformed
        }
        if release.draft == true || release.prerelease == true { throw .notARelease }
        guard let version = SemanticVersion(release.tag_name) else { throw .unrecognizedTag(release.tag_name) }
        if version.isPrerelease { throw .notARelease }
        let assets = release.assets ?? []
        let dmg = assets.first { $0.name == "ClaudeTray-\(version).dmg" }
            ?? assets.first { $0.name.hasSuffix(".dmg") }
        return ReleaseInfo(
            tag: release.tag_name, version: version, pageURL: release.html_url,
            dmgURL: dmg?.browser_download_url,
            publishedAt: release.published_at.flatMap { try? Date.ISO8601FormatStyle().parse($0) })
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
