import Foundation

/// The running build's version and update key, as its Info.plist states them.
struct BuildInfo: Equatable, Sendable {
    /// CFBundleShortVersionString: "X.Y.Z" for a release, "X.Y.Z-beta.N" for a beta.
    var version: String
    /// CFBundleVersion: grows with every build. Sparkle compares this number.
    var build: String
    /// SUPublicEDKey. Empty for builds from source: they never update themselves.
    var sparklePublicKey: String

    init(version: String, build: String, sparklePublicKey: String) {
        self.version = version
        self.build = build
        self.sparklePublicKey = sparklePublicKey
    }

    init(infoDictionary info: [String: Any]?) {
        version = Self.value(info?["CFBundleShortVersionString"])
        build = Self.value(info?["CFBundleVersion"])
        sparklePublicKey = Self.value(info?["SUPublicEDKey"])
    }

    static var main: BuildInfo { BuildInfo(infoDictionary: Bundle.main.infoDictionary) }

    /// A beta build: its version has a "-beta" suffix.
    var isBeta: Bool { version.range(of: "-beta", options: .caseInsensitive) != nil }

    /// Only a build that carries Sparkle's public key updates itself.
    var updatesItself: Bool { !sparklePublicKey.isEmpty }

    /// "0.2.0-beta.3（ビルド 57）"
    var displayVersion: String {
        let version = version.isEmpty ? "不明" : version
        return build.isEmpty ? version : "\(version)（ビルド \(build)）"
    }

    /// Trimmed text. A build setting left unexpanded ("$(…)") counts as missing.
    private static func value(_ raw: Any?) -> String {
        guard let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.hasPrefix("$(")
        else { return "" }
        return text
    }
}

/// The feed Sparkle reads.
enum UpdateChannel: String, Equatable, Sendable {
    /// The latest release.
    case stable
    /// The prerelease "beta", built from every push to main. Its feed also lists the latest release,
    /// so a beta user gets a newer release too.
    case beta

    static let stableFeedURL = URL(string: "https://github.com/sizumita/Plamonic/releases/latest/download/appcast.xml")!
    static let betaFeedURL = URL(string: "https://github.com/sizumita/Plamonic/releases/download/beta/appcast.xml")!

    var feedURL: URL {
        switch self {
        case .stable: Self.stableFeedURL
        case .beta: Self.betaFeedURL
        }
    }

    /// ベータ版を受け取る decides. Unset, a beta build reads the beta feed and a release the stable one.
    static func current(receiveBetaUpdates: Bool?, build: BuildInfo) -> UpdateChannel {
        (receiveBetaUpdates ?? build.isBeta) ? .beta : .stable
    }
}
