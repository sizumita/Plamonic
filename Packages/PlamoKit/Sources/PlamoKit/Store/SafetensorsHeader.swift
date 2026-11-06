import Foundation

/// Reads just the JSON header of a .safetensors file.
enum SafetensorsHeader {
    /// Byte size the file must have according to its header, or nil when the header is unreadable.
    static func expectedFileSize(_ url: URL) -> Int64? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let lengthData = try? handle.read(upToCount: 8), lengthData.count == 8 else { return nil }
        let headerLength = lengthData.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
        guard headerLength > 0, headerLength < 100_000_000 else { return nil }
        guard let headerData = try? handle.read(upToCount: Int(headerLength)), headerData.count == Int(headerLength),
            let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any]
        else { return nil }
        var end: Int64 = 0
        for (name, value) in header where name != "__metadata__" {
            guard let entry = value as? [String: Any], let offsets = entry["data_offsets"] as? [NSNumber],
                offsets.count == 2, offsets[0].int64Value >= 0, offsets[0].int64Value <= offsets[1].int64Value
            else { return nil }
            end = max(end, offsets[1].int64Value)
        }
        // headerLength is small, so only the data end can overflow.
        let (size, overflow) = (8 + Int64(headerLength)).addingReportingOverflow(end)
        return overflow ? nil : size
    }

    static func isComplete(_ url: URL) -> Bool {
        guard let expected = expectedFileSize(url),
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = (attrs[.size] as? NSNumber)?.int64Value
        else { return false }
        return size == expected
    }
}
