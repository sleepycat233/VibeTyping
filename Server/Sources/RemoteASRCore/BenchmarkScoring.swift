import Foundation

private struct EditDistanceCell {
    var cost: Int
    var substitutions: Int
    var insertions: Int
    var deletions: Int
}

public struct EditDistanceBreakdown: Codable, Equatable, Sendable {
    public let substitutions: Int
    public let insertions: Int
    public let deletions: Int
    public let referenceUnits: Int

    public init(substitutions: Int, insertions: Int, deletions: Int, referenceUnits: Int) {
        self.substitutions = substitutions
        self.insertions = insertions
        self.deletions = deletions
        self.referenceUnits = referenceUnits
    }

    public var errors: Int { substitutions + insertions + deletions }
    public var errorRate: Double {
        referenceUnits > 0 ? Double(errors) / Double(referenceUnits) : (errors == 0 ? 0 : 1)
    }
}

public enum BenchmarkScoring {
    public static func normalizeChinese(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .lowercased()
            .unicodeScalars
            .filter { scalar in
                !CharacterSet.whitespacesAndNewlines.contains(scalar)
                    && !CharacterSet.punctuationCharacters.contains(scalar)
                    && !CharacterSet.symbols.contains(scalar)
            }
            .map(String.init)
            .joined()
    }

    public static func normalizeEnglish(_ text: String) -> String {
        let normalized = text.precomposedStringWithCompatibilityMapping.lowercased()
        let mapped = normalized.unicodeScalars.map { scalar -> String in
            if CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar)
                || CharacterSet.whitespacesAndNewlines.contains(scalar)
            {
                return " "
            }
            return String(scalar)
        }.joined()
        return mapped.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    }

    public static func score(reference: String, hypothesis: String, language: String) -> (
        metric: String,
        normalizedReference: String,
        normalizedHypothesis: String,
        breakdown: EditDistanceBreakdown
    ) {
        if isChinese(language) {
            let normalizedReference = normalizeChinese(reference)
            let normalizedHypothesis = normalizeChinese(hypothesis)
            return (
                "CER",
                normalizedReference,
                normalizedHypothesis,
                editDistance(
                    reference: normalizedReference.map(String.init),
                    hypothesis: normalizedHypothesis.map(String.init)
                )
            )
        }

        let normalizedReference = normalizeEnglish(reference)
        let normalizedHypothesis = normalizeEnglish(hypothesis)
        return (
            "WER",
            normalizedReference,
            normalizedHypothesis,
            editDistance(
                reference: normalizedReference.split(separator: " ").map(String.init),
                hypothesis: normalizedHypothesis.split(separator: " ").map(String.init)
            )
        )
    }

    public static func isChinese(_ language: String) -> Bool {
        let value = language.lowercased()
        return value.hasPrefix("zh") || value == "cmn" || value == "chinese"
    }

    public static func editDistance<T: Equatable>(
        reference: [T],
        hypothesis: [T]
    ) -> EditDistanceBreakdown {
        var previous = (0...hypothesis.count).map {
            EditDistanceCell(cost: $0, substitutions: 0, insertions: $0, deletions: 0)
        }
        var current = previous

        for referenceIndex in reference.indices {
            current[0] = EditDistanceCell(
                cost: referenceIndex + 1,
                substitutions: 0,
                insertions: 0,
                deletions: referenceIndex + 1
            )
            for hypothesisIndex in hypothesis.indices {
                if reference[referenceIndex] == hypothesis[hypothesisIndex] {
                    current[hypothesisIndex + 1] = previous[hypothesisIndex]
                    continue
                }

                var substitution = previous[hypothesisIndex]
                substitution.cost += 1
                substitution.substitutions += 1

                var insertion = current[hypothesisIndex]
                insertion.cost += 1
                insertion.insertions += 1

                var deletion = previous[hypothesisIndex + 1]
                deletion.cost += 1
                deletion.deletions += 1

                current[hypothesisIndex + 1] = [substitution, insertion, deletion].min {
                    if $0.cost != $1.cost { return $0.cost < $1.cost }
                    if $0.substitutions != $1.substitutions {
                        return $0.substitutions < $1.substitutions
                    }
                    if $0.deletions != $1.deletions { return $0.deletions < $1.deletions }
                    return $0.insertions < $1.insertions
                }!
            }
            swap(&previous, &current)
        }

        let result = previous[hypothesis.count]
        return EditDistanceBreakdown(
            substitutions: result.substitutions,
            insertions: result.insertions,
            deletions: result.deletions,
            referenceUnits: reference.count
        )
    }
}
