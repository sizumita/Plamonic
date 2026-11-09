import Foundation
import Security

/// Where the bridge socket lives.
///
/// The Safari extension is sandboxed and can only reach its App Group container, so the socket goes there when
/// this build may use the group: it claims the group in its entitlements and is signed by the team the group
/// belongs to (the group ID starts with the team ID). Other builds (ad hoc, another team) would make macOS ask
/// for permission to touch another app's data, so they use Application Support, which only the Chrome host
/// reaches.
enum BridgeLocation {
    static let socketName = "bridge.sock"
    /// `sockaddr_un.sun_path` holds 104 bytes including the terminator.
    static let maxPathBytes = 103

    static func socketURL() -> URL {
        if let group = usableAppGroup(),
            let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        {
            return container.appending(path: socketName)
        }
        return fallbackDirectory().appending(path: socketName)
    }

    static func fallbackDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Plamonic")
    }

    /// The first App Group this process is entitled to, when its ID starts with the signing team's ID.
    static func usableAppGroup() -> String? {
        guard let team = signingTeamID(), let group = entitledAppGroups().first, group.hasPrefix(team + ".")
        else { return nil }
        return group
    }

    private static func entitledAppGroups() -> [String] {
        guard let task = SecTaskCreateFromSelf(nil),
            let value = SecTaskCopyValueForEntitlement(
                task, "com.apple.security.application-groups" as CFString, nil)
        else { return [] }
        return value as? [String] ?? []
    }

    private static func signingTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
            == errSecSuccess,
            let dictionary = info as? [String: Any]
        else { return nil }
        let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        return team?.isEmpty == false ? team : nil
    }
}
