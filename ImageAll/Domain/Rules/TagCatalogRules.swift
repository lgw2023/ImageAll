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

    static func renameTag(
        _ tag: Tag,
        rawName: String,
        existingTags: [Tag]
    ) -> Result<Tag, DomainError> {
        guard tag.state == .active else {
            return .failure(.invalidStateTransition)
        }

        let nameParts: TagNameParts
        switch TagNameNormalizer.validateAndNormalize(rawName) {
        case let .success(parts):
            nameParts = parts
        case let .failure(error):
            return .failure(error)
        }

        if existingTags.contains(where: {
            $0.id != tag.id && $0.normalizedNameKey == nameParts.normalizedNameKey
        }) {
            return .failure(.duplicateTag)
        }

        return .success(
            Tag(
                id: tag.id,
                displayName: nameParts.displayName,
                normalizedName: nameParts.normalizedName,
                normalizedNameKey: nameParts.normalizedNameKey,
                state: tag.state
            )
        )
    }

    static func archiveTag(_ tag: Tag) -> Result<Tag, DomainError> {
        guard tag.state == .active else {
            return .failure(.invalidStateTransition)
        }

        return .success(
            Tag(
                id: tag.id,
                displayName: tag.displayName,
                normalizedName: tag.normalizedName,
                normalizedNameKey: tag.normalizedNameKey,
                state: .archived
            )
        )
    }
}
