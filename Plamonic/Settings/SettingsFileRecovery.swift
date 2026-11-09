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

        doc.profiles = salvageList(root["profiles"], name: "profiles", key: "bundleID", as: AppProfile.self, &problems)
        doc.sites = salvageList(root["sites"], name: "sites", key: "pattern", as: SiteProfile.self, &problems)
        return Result(document: doc, problems: problems)
    }

    /// The entries of a list of profiles that decode (dropping fields that do not), each needing `key`.
    private static func salvageList<T: Decodable>(
        _ raw: Any?, name: String, key: String, as type: T.Type, _ problems: inout [String]
    ) -> [T] {
        guard let raw else { return [] }
        guard let list = raw as? [Any] else {
            problems.append(name)
            return []
        }
        var values: [T] = []
        for (index, item) in list.enumerated() {
            guard let dict = item as? [String: Any], dict[key] is String,
                let (value, dropped) = salvageObject(dict, as: type, requiredKeys: [key])
            else {
                problems.append("\(name)[\(index)]")
                continue
            }
            values.append(value)
            problems += dropped.map { "\(name)[\(index)].\($0)" }
        }
        return values
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
