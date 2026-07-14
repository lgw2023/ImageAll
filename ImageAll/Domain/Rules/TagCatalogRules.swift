import Foundation

enum TagCatalogRules {
    static func createTag(
        rawName: String,
        existingTags: [Tag],
        id: UUID = UUID()
    ) -> Result<Tag, DomainError> {
        let nameParts: TagNameParts
        switch TagNameNormalizer.validateAndNormalize(rawName) {
        case let .success(parts):
            nameParts = parts
        case let .failure(error):
            return .failure(error)
        }

        if existingTags.contains(where: { $0.normalizedNameKey == nameParts.normalizedNameKey }) {
            return .failure(.duplicateTag)
        }

        return .success(
            Tag(
                id: id,
                displayName: nameParts.displayName,
                normalizedName: nameParts.normalizedName,
                normalizedNameKey: nameParts.normalizedNameKey,
                state: .active
            )
        )
    }
}
