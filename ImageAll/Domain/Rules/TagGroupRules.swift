import Foundation

enum TagGroupRules {
    static func createGroup(
        rawName: String,
        existingGroups: [TagGroup],
        id: UUID = UUID(),
        sortOrder: Int
    ) -> Result<TagGroup, DomainError> {
        let nameParts: TagNameParts
        switch TagNameNormalizer.validateAndNormalize(rawName) {
        case let .success(parts):
            nameParts = parts
        case let .failure(error):
            return .failure(error)
        }

        if existingGroups.contains(where: {
            $0.displayName.caseInsensitiveCompare(nameParts.displayName) == .orderedSame
        }) {
            return .failure(.duplicateTag)
        }

        return .success(
            TagGroup(
                id: id,
                displayName: nameParts.displayName,
                sortOrder: sortOrder,
                isSystem: false
            )
        )
    }

    static func renameGroup(
        _ group: TagGroup,
        rawName: String,
        existingGroups: [TagGroup]
    ) -> Result<TagGroup, DomainError> {
        guard !group.isSystem else {
            return .failure(.invalidStateTransition)
        }

        let nameParts: TagNameParts
        switch TagNameNormalizer.validateAndNormalize(rawName) {
        case let .success(parts):
            nameParts = parts
        case let .failure(error):
            return .failure(error)
        }

        if existingGroups.contains(where: {
            $0.id != group.id
                && $0.displayName.caseInsensitiveCompare(nameParts.displayName) == .orderedSame
        }) {
            return .failure(.duplicateTag)
        }

        return .success(
            TagGroup(
                id: group.id,
                displayName: nameParts.displayName,
                sortOrder: group.sortOrder,
                isSystem: group.isSystem
            )
        )
    }

    static func deleteGroup(_ group: TagGroup) -> Result<Void, DomainError> {
        guard !group.isSystem else {
            return .failure(.invalidStateTransition)
        }
        return .success(())
    }
}
