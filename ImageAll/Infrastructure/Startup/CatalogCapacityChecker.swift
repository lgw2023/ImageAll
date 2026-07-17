import Foundation

protocol CatalogCapacityProviding: Sendable {
    func availableBytes(for url: URL) throws -> UInt64?
}

struct CatalogCapacityRequirement {
    static let minimumMarginBytes: UInt64 = 64 * 1024 * 1024
    static let minimumFootprintBytes: UInt64 = 1024 * 1024

    static func requiredAdditionalBytes(sourceFootprint: UInt64) -> UInt64? {
        let scaledFootprint = max(sourceFootprint, minimumFootprintBytes)
        let tripled = scaledFootprint.multipliedReportingOverflow(by: 3)
        guard !tripled.overflow else { return nil }
        let total = tripled.partialValue.addingReportingOverflow(minimumMarginBytes)
        guard !total.overflow else { return nil }
        return total.partialValue
    }
}

struct FoundationCatalogCapacityProvider: CatalogCapacityProviding {
    func availableBytes(for url: URL) throws -> UInt64? {
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]
        let values = try url.resourceValues(forKeys: keys)
        if let important = values.volumeAvailableCapacityForImportantUsage {
            return UInt64(max(important, 0))
        }
        if let available = values.volumeAvailableCapacity {
            return UInt64(max(available, 0))
        }
        return nil
    }
}

enum CatalogCapacityError: Error, Equatable, Sendable {
    case footprintOverflow
    case requirementOverflow
    case capacityUnavailable
    case insufficientSpace(requiredBytes: UInt64)
}

struct CatalogCapacityChecker: Sendable {
    let provider: CatalogCapacityProviding

    init(provider: CatalogCapacityProviding = FoundationCatalogCapacityProvider()) {
        self.provider = provider
    }

    func databaseFootprintBytes(at databaseURL: URL) throws -> UInt64 {
        let fileManager = FileManager.default
        var total: UInt64 = 0
        let urls = [databaseURL] + CatalogDatabaseSidecarHelpers.sidecarURLs(for: databaseURL)
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                continue
            }
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard let fileSize = values.fileSize, fileSize >= 0 else {
                continue
            }
            let addition = total.addingReportingOverflow(UInt64(fileSize))
            guard !addition.overflow else {
                throw CatalogCapacityError.footprintOverflow
            }
            total = addition.partialValue
        }
        return total
    }

    func assertSufficientSpace(for databaseURL: URL, at volumeURL: URL) throws {
        let footprint = try databaseFootprintBytes(at: databaseURL)
        guard let requiredAdditional = CatalogCapacityRequirement.requiredAdditionalBytes(
            sourceFootprint: footprint
        ) else {
            throw CatalogCapacityError.requirementOverflow
        }
        guard let available = try provider.availableBytes(for: volumeURL) else {
            throw CatalogCapacityError.capacityUnavailable
        }
        guard available >= requiredAdditional else {
            throw CatalogCapacityError.insufficientSpace(requiredBytes: requiredAdditional)
        }
    }
}
