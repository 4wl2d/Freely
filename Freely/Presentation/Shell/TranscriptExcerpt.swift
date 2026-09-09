import Foundation
import FreelyCore

enum TranscriptExcerpt {
    static func body(segments: [TranscriptSegment], gaps: [AudioDiscontinuity]) -> String {
        func time(_ seconds: Double) -> String { String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
        let speech = segments.map { segment in
            (segment.startTime, "\(segment.source.label) · \(time(segment.startTime))\(segment.finality == .partial ? " · Interim" : "")\n\(segment.text)")
        }
        let missing = gaps.map { gap in
            (gap.startTime, "\(gap.source.label) · \(time(gap.startTime))–\(time(gap.endTime)) · Audio gap\nMissing audio (\(String(format: "%.1f", gap.droppedDuration)) s).")
        }
        return (speech + missing).enumerated().sorted {
            $0.element.0 == $1.element.0 ? $0.offset < $1.offset : $0.element.0 < $1.element.0
        }.map(\.element.1).joined(separator: "\n\n")
    }
}
