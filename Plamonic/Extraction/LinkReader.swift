import ApplicationServices
import Foundation

/// Reads where links lead (AXURL, one call per link element) and keeps it across scans. Not thread-safe: used
/// from the scan queue via TextExtractor.
final class LinkReader {
    private struct Entry {
        var url: URL?
        var fetchedAt: CFAbsoluteTime
        var usedAt: CFAbsoluteTime
    }

    /// A link without a URL is asked again after this long (the app may fill it in later).
    var retryAfter: TimeInterval = 30
    /// A found URL is read again after this long (a reused element may lead elsewhere).
    var refreshAfter: TimeInterval = 120

    private var cache: [AXElement: Entry] = [:]

    init() {}

    /// The cached URL, or a fresh read when `budget` allows (each read decrements it).
    func url(of element: AXElement, now: CFAbsoluteTime, budget: inout Int) -> URL? {
        if var entry = cache[element] {
            let age = now - entry.fetchedAt
            let fresh = entry.url != nil ? age < refreshAfter : age < retryAfter
            if fresh || budget <= 0 {
                entry.usedAt = now
                cache[element] = entry
                return entry.url
            }
        }
        let previous = cache[element]?.url
        guard budget > 0 else { return previous }
        budget -= 1
        switch element.copyAttribute(AXAttr.url) {
        case .success(let value):
            let url = Self.decode(value)
            cache[element] = Entry(url: url ?? previous, fetchedAt: now, usedAt: now)
            return url ?? previous
        case .failure(let error):
            // A timeout is not remembered: the next scan asks again.
            if !error.isTimeout { cache[element] = Entry(url: previous, fetchedAt: now, usedAt: now) }
            return previous
        }
    }

    static func decode(_ value: AnyObject) -> URL? {
        if let url = value as? URL { return url }
        if let s = value as? String { return URL(string: s) }
        return nil
    }

    /// Drops entries not used for a while (call once per scan).
    func prune(now: CFAbsoluteTime) {
        guard cache.count > 1024 else { return }
        cache = cache.filter { now - $0.value.usedAt < 60 }
    }

    func invalidate(pid: pid_t? = nil) {
        guard let pid else {
            cache.removeAll()
            return
        }
        cache = cache.filter { $0.key.pid != pid }
    }
}
