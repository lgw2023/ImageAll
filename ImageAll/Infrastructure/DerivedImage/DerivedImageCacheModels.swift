import Foundation

struct DerivedImageVolumeFacts: Equatable, Sendable {
    let availableBytes: UInt64
    let totalBytes: UInt64
}

protocol DerivedImageVolumeCapacityReading: Sendable {
    func volumeFacts(at url: URL) throws -> DerivedImageVolumeFacts?
}

struct FoundationDerivedImageVolumeCapacityReader: DerivedImageVolumeCapacityReading {
    func volumeFacts(at url: URL) throws -> DerivedImageVolumeFacts? {
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey,
        ]
        let values = try url.resourceValues(forKeys: keys)
        guard let availableRaw = values.volumeAvailableCapacityForImportantUsage,
              let totalRaw = values.volumeTotalCapacity,
              availableRaw >= 0,
              totalRaw > 0
        else {
            return nil
        }
        return DerivedImageVolumeFacts(
            availableBytes: UInt64(availableRaw),
            totalBytes: UInt64(totalRaw)
        )
    }
}

enum DerivedImageQuotaPolicy {
    static let publishedQuotaBytes: UInt64 = 20 * 1024 * 1024 * 1024
    static let minimumReserveBytes: UInt64 = 5 * 1024 * 1024 * 1024

    static func reserveBytes(totalVolumeBytes: UInt64) -> UInt64? {
        let fivePercent = totalVolumeBytes / 20
        let chosen = max(minimumReserveBytes, fivePercent)
        guard chosen <= totalVolumeBytes else {
            return nil
        }
        return chosen
    }

    static func adding(_ lhs: UInt64, _ rhs: UInt64) -> UInt64? {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { return nil }
        return result.partialValue
    }

    static func subtracting(_ lhs: UInt64, _ rhs: UInt64) -> UInt64? {
        guard lhs >= rhs else { return nil }
        return lhs - rhs
    }
}

enum DownloadedPreviewCachePolicy {
    static let publishedQuotaBytes: UInt64 = 512 * 1024 * 1024
}

struct DerivedImageCacheEntryRow: Equatable, Sendable {
    let id: UUID
    let assetID: UUID
    let contentRevision: Int
    let representationVersion: Int
    let variant: DerivedImageVariant
    let storageFormat: DerivedImageStorageFormat
    let pixelWidth: Int
    let pixelHeight: Int
    let byteSize: Int64
    let encodedSHA256: Data
    let createdAtMs: Int64
    let lastAccessedAtMs: Int64
}

struct DerivedImageAssetGenerationContext: Equatable, Sendable {
    let assetID: UUID
    let sourceID: UUID
    let contentRevision: Int
    let relativePath: String
    let fileName: String
    let mediaType: String
    let availability: String
    let locatorState: String
    let locatorKind: String
    let sourceState: String
    let sourceKind: String
    let fingerprintSizeBytes: Int64
    let fingerprintModifiedAtNs: Int64
    let fingerprintResourceID: Data?
}

struct DerivedImageOpenedFingerprint: Equatable, Sendable {
    let sizeBytes: Int64
    let modifiedAtNs: Int64
    let resourceID: Data?
}

struct DerivedImageEncodedArtifact: Equatable, Sendable {
    let bytes: Data
    let byteSize: Int64
    let sha256: Data
    let storageFormat: DerivedImageStorageFormat
    let pixelWidth: Int
    let pixelHeight: Int
}
