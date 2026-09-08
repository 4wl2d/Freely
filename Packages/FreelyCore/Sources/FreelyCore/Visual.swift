import Foundation

public struct VisualSnapshot: Identifiable, Sendable {
    public let id: VisualSnapshotID
    public let sourceSelection: String
    public let captureTime: TimeInterval
    public let selectionEpoch: SelectionEpoch
    public let sessionEpoch: SessionEpoch
    public let questionID: QuestionID?
    public let questionRevision: UInt64?
    public let width: Int
    public let height: Int
    public let contentHash: String
    public let image: Data
    public let mimeType: String
    public let ocr: String?
    public init(id: VisualSnapshotID = .init(), sourceSelection: String, captureTime: TimeInterval,
                selectionEpoch: SelectionEpoch, sessionEpoch: SessionEpoch, questionID: QuestionID? = nil,
                questionRevision: UInt64? = nil, width: Int, height: Int, contentHash: String,
                image: Data, mimeType: String = "image/png", ocr: String? = nil) {
        self.id = id; self.sourceSelection = sourceSelection; self.captureTime = captureTime
        self.selectionEpoch = selectionEpoch; self.sessionEpoch = sessionEpoch
        self.questionID = questionID; self.questionRevision = questionRevision
        self.width = width; self.height = height; self.contentHash = contentHash
        self.image = image; self.mimeType = mimeType; self.ocr = ocr
    }
}
public enum ScreenContextMode: String, CaseIterable, Sendable, Codable { case off, manual, automatic }
public struct VisualContextState: Sendable {
    public private(set) var mode: ScreenContextMode = .off
    public private(set) var selectionEpoch = SelectionEpoch()
    public private(set) var active: VisualSnapshot?
    public private(set) var selectedSource: String?
    public init() {}
    public mutating func configure(mode: ScreenContextMode, selectedSource: String?) {
        if self.mode != mode || self.selectedSource != selectedSource {
            selectionEpoch = .init(selectionEpoch.rawValue &+ 1); active = nil
        }
        self.mode = mode; self.selectedSource = selectedSource
    }
    @discardableResult public mutating func accept(_ snapshot: VisualSnapshot, sessionEpoch: SessionEpoch,
        question: QuestionState? = nil, now: TimeInterval) -> Bool {
        guard mode != .off, snapshot.selectionEpoch == selectionEpoch, snapshot.sessionEpoch == sessionEpoch,
              snapshot.sourceSelection == selectedSource, snapshot.width > 0, snapshot.height > 0,
              max(snapshot.width, snapshot.height) <= 2_048, snapshot.image.count <= 4 * 1_024 * 1_024,
              !snapshot.image.isEmpty, !snapshot.contentHash.isEmpty,
              ["image/png", "image/jpeg"].contains(snapshot.mimeType),
              now >= snapshot.captureTime, now - snapshot.captureTime <= 30 else { return false }
        if let question {
            guard snapshot.questionID == question.id, snapshot.questionRevision == question.revision else { return false }
        }
        active = snapshot; return true
    }
    public func selectedImage(sessionEpoch: SessionEpoch, question: QuestionState, now: TimeInterval) -> VisualSnapshot? {
        guard mode != .off, let active, active.selectionEpoch == selectionEpoch,
              active.sessionEpoch == sessionEpoch, active.questionID == question.id,
              active.questionRevision == question.revision, now >= active.captureTime,
              now - active.captureTime <= 30 else { return nil }
        return active
    }
    public mutating func purge() { active = nil; selectionEpoch = .init(selectionEpoch.rawValue &+ 1) }
}
public struct PixelCrop: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
}
public enum CropGeometry {
    /// Inputs use top-left logical coordinates within the selected surface, not global AppKit coordinates.
    /// Per-axis scales handle rotated or resized source bounds without borrowing another display's scale.
    public static func pixels(x: Double, y: Double, width: Double, height: Double,
        logicalWidth: Double, logicalHeight: Double, pixelWidth: Int, pixelHeight: Int) -> PixelCrop? {
        guard [x, y, width, height, logicalWidth, logicalHeight].allSatisfy(\.isFinite),
              logicalWidth > 0, logicalHeight > 0, pixelWidth > 0, pixelHeight > 0, width > 0, height > 0 else { return nil }
        let left = max(0, x), top = max(0, y)
        let right = min(logicalWidth, x + width), bottom = min(logicalHeight, y + height)
        guard right > left, bottom > top else { return nil }
        let sx = Double(pixelWidth) / logicalWidth, sy = Double(pixelHeight) / logicalHeight
        let px = Int(floor(left * sx)), py = Int(floor(top * sy))
        return .init(x: px, y: py, width: min(pixelWidth, Int(ceil(right * sx))) - px,
                     height: min(pixelHeight, Int(ceil(bottom * sy))) - py)
    }
}

public struct SpeculationGate: Sendable {
    public var enabled = false
    public private(set) var activePrefix: String?
    public private(set) var identity: GenerationIdentity?
    public init(enabled: Bool = false) { self.enabled = enabled }
    public mutating func begin(question: QuestionState, sessionEpoch: SessionEpoch, highConfidence: Bool) -> GenerationIdentity? {
        guard enabled, highConfidence, identity == nil,
              IntentHeuristics.classify(question.text, hasAntecedent: question.antecedent != nil) != nil else { return nil }
        let value = GenerationIdentity(sessionEpoch: sessionEpoch, questionID: question.id, questionRevision: question.revision)
        identity = value; activePrefix = IntentHeuristics.materialText(question.text); return value
    }
    @discardableResult public mutating func update(question: QuestionState, sessionEpoch: SessionEpoch) -> Bool {
        guard let identity, identity.sessionEpoch == sessionEpoch, identity.questionID == question.id,
              identity.questionRevision == question.revision,
              IntentHeuristics.materialText(question.text) == activePrefix else {
            cancel(); return false
        }
        return true
    }
    public mutating func cancel() { activePrefix = nil; identity = nil }
}
