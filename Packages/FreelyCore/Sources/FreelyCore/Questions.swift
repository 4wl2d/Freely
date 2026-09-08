import Foundation

public enum IntentHeuristics {
    public static func materialText(_ text: String) -> String {
        let scalars = Array(text.lowercased().unicodeScalars)
        let operators = CharacterSet(charactersIn: "=<>+*/%&|^~")
        let alphanumerics = CharacterSet.alphanumerics
        return scalars.enumerated().map { index, scalar in
            if alphanumerics.contains(scalar) || operators.contains(scalar) { return String(scalar) }
            if scalar == "!", index + 1 < scalars.count, scalars[index + 1] == "=" { return "!" }
            if [".", "-", "_"].contains(scalar), index > 0, index + 1 < scalars.count,
               alphanumerics.contains(scalars[index - 1]), alphanumerics.contains(scalars[index + 1]) { return String(scalar) }
            return " "
        }.joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    public static func classify(_ text: String, hasAntecedent: Bool) -> QuestionTrigger? {
        if let trigger = classifyLeading(text, hasAntecedent: hasAntecedent) { return trigger }
        // Speech recognition often joins a statement and the actual question with a comma.
        // Keep the whole turn as context, but also examine its final clause for direct intent.
        let clauses = text.split { ",;.!?\n—".contains($0) }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard clauses.count > 1, let final = clauses.last else { return nil }
        return classifyLeading(final, hasAntecedent: hasAntecedent)
    }
    private static func classifyLeading(_ text: String, hasAntecedent: Bool) -> QuestionTrigger? {
        let words = materialText(text).split(separator: " ").map(String.init)
        guard let first = words.first else { return nil }
        let normalized = words.joined(separator: " ")
        if hasAntecedent && ["why", "why not", "how so", "what else", "what next", "and then"].contains(normalized) { return .followUp }
        if words.count == 3, ["vs", "versus"].contains(words[1]) { return .imperative }
        if normalized.hasPrefix("difference between "), words.count >= 4 { return .imperative }
        if words.count >= 2, ["explain", "compare", "describe", "implement", "design", "write", "demonstrate", "outline", "discuss"].contains(first) { return .imperative }
        guard words.count >= 3 else { return nil }
        let followups = ["and what", "what about", "how about", "now assume", "now suppose", "and if", "but what", "would your previous", "would that", "does that", "could that", "what if"]
        if hasAntecedent && followups.contains(where: normalized.hasPrefix) { return .followUp }
        if ["what", "why", "how", "when", "where", "which", "who"].contains(first) { return .interrogative }
        if ["can", "could", "would", "should", "will", "do", "does", "did", "is", "are", "have", "has"].contains(first) {
            let second = words[1]
            if ["you", "we", "i", "it", "this", "that", "there", "the", "a", "an", "your", "our", "these", "those"].contains(second) {
                return .interrogative
            }
        }
        if ["explain", "compare", "describe", "implement", "design", "write", "demonstrate", "show", "tell", "walk", "outline", "discuss"].contains(first) { return .imperative }
        if normalized.hasPrefix("please ") { return classify(words.dropFirst().joined(separator: " "), hasAntecedent: hasAntecedent) }
        return nil
    }
}

public struct QuestionDetector: Sendable {
    public var triggerLocalSpeech = false
    public private(set) var questions: [QuestionState] = []
    private var byTurn: [TurnID: QuestionState] = [:]
    private var questionRevisions: [TurnID: UInt64] = [:]
    private var revisionOrder: [TurnID] = []
    private let maximumQuestions: Int
    private let maximumBytes: Int
    public init(maximumQuestions: Int = 20, maximumBytes: Int = 128 * 1_024) {
        self.maximumQuestions = max(1, maximumQuestions); self.maximumBytes = max(256, maximumBytes)
    }
    public mutating func evaluate(_ turns: [ConversationTurn]) -> (question: QuestionState?, invalidated: [QuestionID]) {
        let turnIDs = Set(turns.map(\.id))
        var invalidated: [QuestionID] = []
        // Missing turns may be evicted history. Existing history remains useful, but stale maps are bounded.
        byTurn = byTurn.filter { turnIDs.contains($0.key) }
        var changed: Set<QuestionID> = []
        var preceding = questions.last { question in !question.supportingTurnIDs.contains(where: turnIDs.contains) }
        for turn in turns where turn.isStable && (turn.source == .systemAudio || triggerLocalSpeech) {
            if turn.hasAudioGap {
                invalidated += retract(turnIDs: [turn.id])
                preceding = nil
                continue
            }
            let old = byTurn[turn.id]
            guard let trigger = IntentHeuristics.classify(turn.text, hasAntecedent: preceding != nil || old?.antecedent != nil) else {
                if let old = byTurn.removeValue(forKey: turn.id) {
                    questions.removeAll { $0.id == old.id }; invalidated.append(old.id)
                }
                continue
            }
            let related = trigger == .followUp ? preceding : nil
            // Keep the original subject through omitted-subject chains, with the immediately prior constraint.
            let newAntecedent = related.map { value in
                [value.antecedent, value.text].compactMap { $0 }.joined(separator: "\n")
            } ?? (trigger == .followUp ? old?.antecedent : nil)
            let antecedent = boundedAntecedent(newAntecedent)
            if let old, IntentHeuristics.materialText(old.text) == IntentHeuristics.materialText(turn.text),
               IntentHeuristics.materialText(old.antecedent ?? "") == IntentHeuristics.materialText(antecedent ?? "") {
                preceding = old; continue
            }
            let nextRevision = (questionRevisions[turn.id] ?? old?.revision ?? 0) + 1
            if questionRevisions[turn.id] == nil { revisionOrder.append(turn.id) }
            questionRevisions[turn.id] = nextRevision
            while revisionOrder.count > 2_000 { questionRevisions[revisionOrder.removeFirst()] = nil }
            let value = QuestionState(id: old?.id ?? .init(turn.id.rawValue), revision: nextRevision,
                supportingTurnIDs: [turn.id], text: turn.text, triggerReason: trigger,
                relatedPriorQuestion: related?.id ?? (trigger == .followUp ? old?.relatedPriorQuestion : nil), antecedent: antecedent, source: turn.source)
            if let old, let index = questions.firstIndex(where: { $0.id == old.id }) {
                questions[index] = value; invalidated.append(old.id)
            } else { questions.append(value) }
            byTurn[turn.id] = value; changed.insert(value.id); preceding = value
        }
        while questions.count > maximumQuestions || questions.reduce(0, { $0 + $1.text.utf8.count + ($1.antecedent?.utf8.count ?? 0) }) > maximumBytes {
            guard !questions.isEmpty else { break }
            let removed = questions.removeFirst()
            _ = removed // The bounded turn map remembers deduplication even after question-history eviction.
        }
        return (preceding.flatMap { changed.contains($0.id) ? $0 : nil }, invalidated)
    }
    public mutating func retract(segmentIDs: Set<SegmentID>) -> [QuestionID] {
        retract(turnIDs: Set(segmentIDs.map { .init($0.rawValue) }))
    }
    public mutating func retract(turnIDs: Set<TurnID>) -> [QuestionID] {
        let removed = questions.filter { question in
            question.supportingTurnIDs.contains(where: turnIDs.contains)
        }
        var ids = Set(removed.map(\.id))
        var priorCount = -1
        while priorCount != ids.count {
            priorCount = ids.count
            for question in questions where question.relatedPriorQuestion.map(ids.contains) ?? false { ids.insert(question.id) }
        }
        questions.removeAll { ids.contains($0.id) }; byTurn = byTurn.filter { !ids.contains($0.value.id) }
        return Array(ids)
    }
    private func boundedAntecedent(_ value: String?) -> String? {
        guard let value else { return nil }
        // Never create a silently cut half-sentence. Keep complete earlier references within the allocation.
        var lines = value.split(separator: "\n").map(String.init)
        while lines.joined(separator: "\n").utf8.count > 1_000, lines.count > 1 { lines.remove(at: 1) }
        return lines.joined(separator: "\n")
    }
}
