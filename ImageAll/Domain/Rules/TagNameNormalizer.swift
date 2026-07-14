import Foundation

enum TagNameNormalizer {
    static func validateAndNormalize(_ rawName: String) -> Result<TagNameParts, DomainError> {
        let displayName = trimUnicodeWhiteSpace(rawName.precomposedStringWithCanonicalMapping)
        guard !displayName.isEmpty else {
            return .failure(.invalidName)
        }

        var normalized = rawName.precomposedStringWithCanonicalMapping
        normalized = trimUnicodeWhiteSpace(normalized)
        normalized = foldUnicodeWhiteSpace(normalized)
        normalized = normalized.folding(options: .caseInsensitive, locale: nil)
        normalized = normalized.precomposedStringWithCanonicalMapping

        let normalizedNameKey = Data(normalized.utf8)
        return .success(
            TagNameParts(
                displayName: displayName,
                normalizedName: normalized,
                normalizedNameKey: normalizedNameKey
            )
        )
    }

    static func trimUnicodeWhiteSpace(_ value: String) -> String {
        var start = value.startIndex
        var end = value.endIndex

        while start < end, isUnicodeWhiteSpace(value[start]) {
            start = value.index(after: start)
        }
        while start < end {
            let beforeEnd = value.index(before: end)
            if isUnicodeWhiteSpace(value[beforeEnd]) {
                end = beforeEnd
            } else {
                break
            }
        }

        return String(value[start ..< end])
    }

    static func foldUnicodeWhiteSpace(_ value: String) -> String {
        var result = ""
        var isInWhitespaceRun = false

        for character in value {
            if isUnicodeWhiteSpace(character) {
                if !isInWhitespaceRun {
                    result.append(" ")
                    isInWhitespaceRun = true
                }
            } else {
                result.append(character)
                isInWhitespaceRun = false
            }
        }

        return result
    }

    static func isUnicodeWhiteSpace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(\.properties.isWhitespace)
    }
}
