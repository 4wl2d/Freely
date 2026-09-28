import Foundation

enum NativeSelection {
    /// Preserve an unchanged selection across a correction or transcript eviction. UTF-16
    /// offsets match NSTextView; context disambiguates repeated words in different segments.
    static func restoring(_ range: NSRange, from old: String, to new: String) -> NSRange {
        let before = old as NSString, after = new as NSString
        guard range.length > 0, NSMaxRange(range) <= before.length else {
            return NSRange(location: min(range.location, after.length), length: 0)
        }
        let oldUnits = Array(old.utf16), newUnits = Array(new.utf16)
        var prefix = 0, suffix = 0
        while prefix < min(oldUnits.count, newUnits.count), oldUnits[prefix] == newUnits[prefix] { prefix += 1 }
        while suffix < min(oldUnits.count, newUnits.count) - prefix,
              oldUnits[oldUnits.count - suffix - 1] == newUnits[newUnits.count - suffix - 1] { suffix += 1 }
        if NSMaxRange(range) <= prefix { return range }
        if range.location >= before.length - suffix {
            return NSRange(location: range.location + after.length - before.length, length: range.length)
        }
        let left = max(0, range.location - 32), end = min(before.length, NSMaxRange(range) + 32)
        let context = before.substring(with: NSRange(location: left, length: end - left))
        let contextMatch = after.range(of: context)
        if contextMatch.location != NSNotFound {
            return NSRange(location: contextMatch.location + range.location - left, length: range.length)
        }
        let selected = before.substring(with: range)
        // If surrounding text changed too, prefer a nearby occurrence, never the first
        // unrelated occurrence at the beginning of a long transcript.
        let searchStart = max(0, min(range.location, after.length) - 256)
        let searchEnd = min(after.length, max(searchStart, range.location + range.length + 256))
        let candidate = after.range(of: selected, range: NSRange(location: searchStart, length: searchEnd - searchStart))
        return candidate.location == NSNotFound ? NSRange(location: min(range.location, after.length), length: 0) : candidate
    }
}
