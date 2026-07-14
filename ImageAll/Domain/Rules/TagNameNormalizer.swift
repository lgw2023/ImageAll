import Foundation

enum TagNameNormalizer {
    static func validateAndNormalize(_ rawName: String) -> Result<TagNameParts, DomainError> {
        let displayName = trimUnicodeWhiteSpace(rawName)
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
        let scalars = Array(value.unicodeScalars)
        var start = 0
        var end = scalars.count

        while start < end, scalars[start].properties.isWhitespace {
            start += 1
        }
        while start < end, scalars[end - 1].properties.isWhitespace {
            end -= 1
        }

        return String(String.UnicodeScalarView(scalars[start ..< end]))
    }

    static func foldUnicodeWhiteSpace(_ value: String) -> String {
        var resultScalars: [Unicode.Scalar] = []
        var isInWhitespaceRun = false

        for scalar in value.unicodeScalars {
            if scalar.properties.isWhitespace {
                if !isInWhitespaceRun {
                    resultScalars.append(Unicode.Scalar(0x20)!)
                    isInWhitespaceRun = true
                }
            } else {
                resultScalars.append(scalar)
                isInWhitespaceRun = false
            }
        }

        return String(String.UnicodeScalarView(resultScalars))
    }
}
