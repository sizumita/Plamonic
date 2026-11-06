import Foundation

/// Recovers what it can from a settings file that no longer decodes as a whole
/// (an unknown enum value, a wrong type in one field, a broken profile, ...).
enum SettingsFileRecovery {
    struct Result {
        var document: SettingsDocument
        /// Human-readable list of dropped fields / profiles (English, for logs).
        var problems: [String]
    }

    /// Returns nil when the data is not a JSON object at all (truncated, empty, garbage).
    static func salvage(_ data: Data) -> Result? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var doc = SettingsDocument()
        var problems: [String] = []

        if let version = root["version"] as? Int { doc.version = version }

        if let rawGlobal = root["global"] {
            if let dict = rawGlobal as? [String: Any],
                let (global, dropped) = salvageObject(dict, as: GlobalSettings.self, requiredKeys: [])
            {
                doc.global = global
                problems += dropped.map { "global.\($0)" }
            } else {
                problems.append("global")
            }
        }

        if let rawProfiles = root["profiles"] {
            guard let list = rawProfiles as? [Any] else {
                problems.append("profiles")
                return Result(document: doc, problems: problems)
            }
            for (index, item) in list.enumerated() {
                guard let dict = item as? [String: Any], dict["bundleID"] is String,
                    let (profile, dropped) = salvageObject(dict, as: AppProfile.self, requiredKeys: ["bundleID"])
                else {
                    problems.append("profiles[\(index)]")
                    continue
                }
                doc.profiles.append(profile)
                problems += dropped.map { "profiles[\(index)].\($0)" }
            }
        }
        return Result(document: doc, problems: problems)
    }

    /// Decodes `T` from `dict`, dropping keys whose values do not decode. Returns nil if even the required keys fail.
    private static func salvageObject<T: Decodable>(
        _ dict: [String: Any], as type: T.Type, requiredKeys: Set<String>
    ) -> (T, [String])? {
        if let value = decode(dict, as: type) { return (value, []) }
        var kept = dict.filter { requiredKeys.contains($0.key) }
        var dropped: [String] = []
        for key in dict.keys.sorted() where !requiredKeys.contains(key) {
            var trial = kept
            trial[key] = dict[key]
            if decode(trial, as: type) != nil {
                kept = trial
            } else {
                dropped.append(key)
            }
        }
        guard let value = decode(kept, as: type) else { return nil }
        return (value, dropped)
    }

    private static func decode<T: Decodable>(_ dict: [String: Any], as type: T.Type) -> T? {
        guard JSONSerialization.isValidJSONObject(dict),
            let data = try? JSONSerialization.data(withJSONObject: dict)
        else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
