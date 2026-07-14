import Foundation

enum CatalogQuerySQLHelpers {
    static let timeEmptyMarkerSQL = """
        (CASE WHEN asset.media_created_at_ms IS NOT NULL OR asset.media_modified_at_ms IS NOT NULL THEN 0 ELSE 1 END)
        """

    static let coalescedMediaTimeSQL = "coalesce(asset.media_created_at_ms, asset.media_modified_at_ms)"

    static let fileNamePresenceSQL = "(CASE WHEN asset.file_name IS NOT NULL THEN 0 ELSE 1 END)"

    static let maxSelectionSize = 10_000
    static let minPageLimit = 1
    static let maxPageLimit = 200
    static let sqliteBindChunkSize = 500

    static func normalizedSearchText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = TagNameNormalizer.trimUnicodeWhiteSpace(raw)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func escapeLikePattern(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            if character == "%" || character == "_" || character == "\\" {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }

    static func lowercaseUUID(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

    static func parseUUID(_ raw: String) -> UUID? {
        UUID(uuidString: raw)
    }
}
