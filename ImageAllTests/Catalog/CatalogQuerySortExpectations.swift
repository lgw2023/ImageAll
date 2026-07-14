import Foundation
@testable import ImageAll

/// Independent hard-coded sort oracle for `CatalogQueryTestSupport.seedCatalogFixture`.
enum CatalogQuerySortExpectations {
    static let currentAssetIDsNewestFirst: [UUID] = [
        UUID(uuidString: "20000000-0000-4000-8000-000000000001")!,
        UUID(uuidString: "20000000-0000-4000-8000-000000000002")!,
        UUID(uuidString: "20000000-0000-4000-8000-00000000000E")!,
        UUID(uuidString: "20000000-0000-4000-8000-000000000009")!,
        UUID(uuidString: "20000000-0000-4000-8000-000000000008")!,
        UUID(uuidString: "20000000-0000-4000-8000-00000000000B")!,
        UUID(uuidString: "20000000-0000-4000-8000-00000000000A")!,
        UUID(uuidString: "20000000-0000-4000-8000-00000000000C")!,
        UUID(uuidString: "20000000-0000-4000-8000-00000000000D")!,
        UUID(uuidString: "20000000-0000-4000-8000-00000000000F")!,
        UUID(uuidString: "20000000-0000-4000-8000-000000000010")!,
        UUID(uuidString: "20000000-0000-4000-8000-000000000011")!,
        UUID(uuidString: "20000000-0000-4000-8000-000000000006")!,
        UUID(uuidString: "20000000-0000-4000-8000-000000000007")!,
        UUID(uuidString: "20000000-0000-4000-8000-000000000003")!,
        UUID(uuidString: "20000000-0000-4000-8000-000000000004")!,
    ]

    static let currentAssetIDsOldestFirst: [UUID] = [
        UUID(uuidString: "20000000-0000-4000-8000-000000000003")!,
        UUID(uuidString: "20000000-0000-4000-8000-000000000007")!,
        UUID(uuidString: "20000000-0000-4000-8000-000000000006")!,
        UUID(uuidString: "20000000-0000-4000-8000-000000000011")!,
        UUID(uuidString: "20000000-0000-4000-8000-000000000010")!,
        UUID(uuidString: "20000000-0000-4000-8000-00000000000F")!,
        UUID(uuidString: "20000000-0000-4000-8000-00000000000D")!,
        UUID(uuidString: "20000000-0000-4000-8000-00000000000C")!,
        UUID(uuidString: "20000000-0000-4000-8000-00000000000A")!,
        UUID(uuidString: "20000000-0000-4000-8000-00000000000B")!,
        UUID(uuidString: "20000000-0000-4000-8000-000000000008")!,
        UUID(uuidString: "20000000-0000-4000-8000-000000000009")!,
        UUID(uuidString: "20000000-0000-4000-8000-00000000000E")!,
        UUID(uuidString: "20000000-0000-4000-8000-000000000002")!,
        UUID(uuidString: "20000000-0000-4000-8000-000000000001")!,
        UUID(uuidString: "20000000-0000-4000-8000-000000000004")!,
    ]

    static let currentAssetIDsFileNameAscending: [UUID] = [
        UUID(uuidString: "20000000-0000-4000-8000-00000000000C")!,
        UUID(uuidString: "20000000-0000-4000-8000-00000000000F")!,
        UUID(uuidString: "20000000-0000-4000-8000-00000000000A")!,
        UUID(uuidString: "20000000-0000-4000-8000-00000000000B")!,
        UUID(uuidString: "20000000-0000-4000-8000-00000000000E")!,
        UUID(uuidString: "20000000-0000-4000-8000-000000000008")!,
        UUID(uuidString: "20000000-0000-4000-8000-000000000009")!,
        UUID(uuidString: "20000000-0000-4000-8000-000000000001")!,
        UUID(uuidString: "20000000-0000-4000-8000-000000000002")!,
        UUID(uuidString: "20000000-0000-4000-8000-000000000003")!,
        UUID(uuidString: "20000000-0000-4000-8000-000000000010")!,
        UUID(uuidString: "20000000-0000-4000-8000-000000000004")!,
        UUID(uuidString: "20000000-0000-4000-8000-000000000006")!,
        UUID(uuidString: "20000000-0000-4000-8000-00000000000D")!,
        UUID(uuidString: "20000000-0000-4000-8000-000000000011")!,
        UUID(uuidString: "20000000-0000-4000-8000-000000000007")!,
    ]

    static func expectedOrder(for sort: AssetPageSort) -> [UUID] {
        switch sort {
        case .newest:
            return currentAssetIDsNewestFirst
        case .oldest:
            return currentAssetIDsOldestFirst
        case .fileNameAscending:
            return currentAssetIDsFileNameAscending
        }
    }
}
