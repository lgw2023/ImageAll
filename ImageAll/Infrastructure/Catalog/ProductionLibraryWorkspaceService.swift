import AppKit
import CryptoKit
import Darwin
import Foundation
import GRDB
import MapKit

enum ProductionLibraryWorkspaceError: Error {
    case reconcileFailed
    case librarySlimmingMaintenanceFailed
    case librarySlimmingAnalysisInProgress
    case worldMapLocationBackfillSourceUnavailable
}

protocol AppOwnedAssetCachePurging: Sendable {
    func purge(assetID: UUID) throws
}

extension AppOwnedAssetPixelCachePurger: AppOwnedAssetCachePurging {}

final class WorldMapSnapshotCache: @unchecked Sendable {
    private struct Payload: Codable {
        let schemaVersion: Int
        let query: WorldMapCatalogQuery
        let snapshot: WorldMapCatalogSnapshot
    }

    private static let schemaVersion = 1
    private static let maximumMemoryEntryCount = 12
    private static let maximumPersistentByteCount = 4 * 1_024 * 1_024

    private let lock = NSLock()
    private let fileURL: URL
    private var snapshots: [WorldMapCatalogQuery: WorldMapCatalogSnapshot]
    private var recency: [WorldMapCatalogQuery]

    init(cachesDirectory: URL) {
        fileURL = cachesDirectory
            .appendingPathComponent("WorldMap", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("global-snapshot.json", isDirectory: false)
        if let snapshot = Self.loadGlobalSnapshot(from: fileURL) {
            snapshots = [.global: snapshot]
            recency = [.global]
        } else {
            snapshots = [:]
            recency = []
        }
    }

    func snapshot(for query: WorldMapCatalogQuery) -> WorldMapCatalogSnapshot? {
        lock.withLock {
            guard let snapshot = snapshots[query] else { return nil }
            touch(query)
            return snapshot
        }
    }

    func store(_ snapshot: WorldMapCatalogSnapshot, for query: WorldMapCatalogQuery) {
        guard Self.isValid(snapshot) else { return }
        lock.withLock {
            snapshots[query] = snapshot
            touch(query)
            trimMemoryEntriesIfNeeded()
        }
        guard query == .global else { return }
        Self.persist(snapshot, to: fileURL)
    }

    private func touch(_ query: WorldMapCatalogQuery) {
        recency.removeAll { $0 == query }
        recency.append(query)
    }

    private func trimMemoryEntriesIfNeeded() {
        while recency.count > Self.maximumMemoryEntryCount {
            let removalIndex = recency.firstIndex { $0 != .global } ?? 0
            let evicted = recency.remove(at: removalIndex)
            snapshots.removeValue(forKey: evicted)
        }
    }

    private static func loadGlobalSnapshot(from fileURL: URL) -> WorldMapCatalogSnapshot? {
        let directories = trustedDirectoryURLs(for: fileURL)
        guard directories.allSatisfy({ !DerivedImageSecureIO.isSymlink(at: $0) }) else {
            return nil
        }
        do {
            let fd = try DerivedImageSecureIO.openReadOnlyNoFollow(at: fileURL)
            defer { Darwin.close(fd) }
            let facts = try DerivedImageSecureIO.fstatRegularFile(fd: fd)
            guard facts.sizeBytes > 0,
                  facts.sizeBytes <= Int64(maximumPersistentByteCount)
            else {
                return nil
            }
            let data = try DerivedImageSecureIO.readAllBytes(from: fd)
            guard Int64(data.count) == facts.sizeBytes,
                  let payload = try? JSONDecoder().decode(Payload.self, from: data),
                  payload.schemaVersion == schemaVersion,
                  payload.query == .global,
                  isValid(payload.snapshot)
            else {
                return nil
            }
            return payload.snapshot
        } catch {
            return nil
        }
    }

    private static func persist(_ snapshot: WorldMapCatalogSnapshot, to fileURL: URL) {
        let payload = Payload(
            schemaVersion: schemaVersion,
            query: .global,
            snapshot: snapshot
        )
        guard let data = try? JSONEncoder().encode(payload),
              data.count <= maximumPersistentByteCount
        else {
            return
        }
        do {
            for directoryURL in trustedDirectoryURLs(for: fileURL) {
                try DerivedImageSecureIO.ensureDirectory(at: directoryURL)
                guard !DerivedImageSecureIO.isSymlink(at: directoryURL) else {
                    throw DerivedImageSecureIOError.unsafePath
                }
            }
            if FileManager.default.fileExists(atPath: fileURL.path),
               !DerivedImageSecureIO.isRegularFile(at: fileURL)
            {
                throw DerivedImageSecureIOError.unsafePath
            }
            try data.write(to: fileURL, options: .atomic)
            guard DerivedImageSecureIO.isRegularFile(at: fileURL) else {
                throw DerivedImageSecureIOError.unsafePath
            }
        } catch {
            // The catalog remains authoritative. Cache write failures only remove
            // the instant-start optimization and must not break the live map.
        }
    }

    private static func trustedDirectoryURLs(for fileURL: URL) -> [URL] {
        let versionDirectory = fileURL.deletingLastPathComponent()
        let worldMapDirectory = versionDirectory.deletingLastPathComponent()
        let cachesDirectory = worldMapDirectory.deletingLastPathComponent()
        return [cachesDirectory, worldMapDirectory, versionDirectory]
    }

    private static func isValid(_ snapshot: WorldMapCatalogSnapshot) -> Bool {
        guard snapshot.clusters.count <= WorldMapCatalogQuery.maximumClusterLimit,
              snapshot.eligiblePhotoCount >= 0,
              snapshot.locatedPhotoCount >= 0,
              snapshot.unlocatedPhotoCount >= 0,
              snapshot.locatedPhotoCount <= snapshot.eligiblePhotoCount,
              snapshot.unlocatedPhotoCount
                == snapshot.eligiblePhotoCount - snapshot.locatedPhotoCount
        else {
            return false
        }
        return snapshot.clusters.allSatisfy { cluster in
            !cluster.id.isEmpty
                && cluster.id.utf8.count <= 160
                && !cluster.displayName.isEmpty
                && cluster.displayName.utf8.count <= 512
                && cluster.latitude.isFinite
                && cluster.longitude.isFinite
                && (-90 ... 90).contains(cluster.latitude)
                && (-180 ... 180).contains(cluster.longitude)
                && cluster.photoCount > 0
                && cluster.gpsCount >= 0
                && cluster.tagCount >= 0
                && cluster.gpsCount + cluster.tagCount == cluster.photoCount
                && isValid(cluster.selectionQuery)
        }
    }

    private static func isValid(_ query: WorldMapCatalogSelectionQuery) -> Bool {
        guard query.cellDegrees.isFinite,
              (0.002 ... 360).contains(query.cellDegrees),
              query.longitudeBucket >= 0,
              Double(query.longitudeBucket) * query.cellDegrees <= 360.000_001,
              query.latitudeBucket >= 0,
              Double(query.latitudeBucket) * query.cellDegrees <= 180.000_001,
              (1 ... WorldMapCatalogSelectionQuery.maximumAssetLimit)
                .contains(query.maximumAssets)
        else {
            return false
        }
        guard let bounds = query.bounds else { return true }
        return bounds.west.isFinite
            && bounds.south.isFinite
            && bounds.east.isFinite
            && bounds.north.isFinite
            && (-180 ... 180).contains(bounds.west)
            && (-180 ... 180).contains(bounds.east)
            && (-90 ... 90).contains(bounds.south)
            && (-90 ... 90).contains(bounds.north)
            && bounds.south <= bounds.north
    }
}

struct GRDBWorldMapCatalogRepository: Sendable {
    let database: CatalogDatabase

    func fetchSnapshot(query: WorldMapCatalogQuery) throws -> WorldMapCatalogSnapshot {
        let normalized = try NormalizedWorldMapCatalogQuery(query)
        return try database.pool.read { db in
            let eligiblePhotoCount = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM asset
                WHERE \(Self.eligiblePhotoWhereSQL)
                """
            ) ?? 0
            let locatedPhotoCount = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM asset
                JOIN asset_location AS location ON location.asset_id = asset.id
                WHERE \(Self.eligiblePhotoWhereSQL)
                  AND location.latitude IS NOT NULL
                  AND location.longitude IS NOT NULL
                """
            ) ?? 0

            var arguments = StatementArguments([
                normalized.cellDegrees,
                normalized.cellDegrees,
            ])
            let spatialWhereSQL = Self.spatialWhereSQL(
                bounds: normalized.bounds,
                arguments: &arguments
            )
            arguments += [normalized.maximumClusters]

            let rows = try Row.fetchAll(
                db,
                sql: """
                WITH bucketed AS (
                    SELECT
                        location.latitude,
                        location.longitude,
                        location.source_kind,
                        place.canonical_name AS place_name,
                        CAST((location.longitude + 180.0) / ? AS INTEGER)
                            AS longitude_bucket,
                        CAST((location.latitude + 90.0) / ? AS INTEGER)
                            AS latitude_bucket
                    FROM asset
                    JOIN asset_location AS location ON location.asset_id = asset.id
                    LEFT JOIN place ON place.id = location.place_id
                    WHERE \(Self.eligiblePhotoWhereSQL)
                      AND location.latitude IS NOT NULL
                      AND location.longitude IS NOT NULL
                      \(spatialWhereSQL)
                )
                SELECT
                    longitude_bucket,
                    latitude_bucket,
                    AVG(longitude) AS longitude,
                    AVG(latitude) AS latitude,
                    COUNT(*) AS photo_count,
                    SUM(CASE
                        WHEN source_kind IN ('embeddedGPS', 'photosGPS') THEN 1
                        ELSE 0
                    END) AS gps_count,
                    SUM(CASE WHEN source_kind = 'placeTag' THEN 1 ELSE 0 END)
                        AS tag_count,
                    CASE
                        WHEN COUNT(DISTINCT place_name) = 1 THEN MAX(place_name)
                        ELSE NULL
                    END AS place_name
                FROM bucketed
                GROUP BY longitude_bucket, latitude_bucket
                ORDER BY photo_count DESC, latitude_bucket, longitude_bucket
                LIMIT ?
                """,
                arguments: arguments
            )
            let cellKey = Int((normalized.cellDegrees * 1_000_000).rounded())
            let clusters = rows.map { row -> WorldMapCatalogCluster in
                let longitude: Double = row["longitude"]
                let latitude: Double = row["latitude"]
                let longitudeBucket: Int = row["longitude_bucket"]
                let latitudeBucket: Int = row["latitude_bucket"]
                let photoCount: Int = row["photo_count"]
                let gpsCount: Int = row["gps_count"]
                let tagCount: Int = row["tag_count"]
                let placeName: String? = row["place_name"]
                return WorldMapCatalogCluster(
                    id: "cell-\(cellKey)-\(longitudeBucket)-\(latitudeBucket)",
                    longitude: longitude,
                    latitude: latitude,
                    photoCount: photoCount,
                    gpsCount: gpsCount,
                    tagCount: tagCount,
                    displayName: placeName ?? String(
                        format: "坐标 %.2f°, %.2f°",
                        latitude,
                        longitude
                    ),
                    selectionQuery: WorldMapCatalogSelectionQuery(
                        cellDegrees: normalized.cellDegrees,
                        longitudeBucket: longitudeBucket,
                        latitudeBucket: latitudeBucket,
                        bounds: normalized.selectionBounds
                    )
                )
            }
            return WorldMapCatalogSnapshot(
                clusters: clusters,
                eligiblePhotoCount: eligiblePhotoCount,
                locatedPhotoCount: locatedPhotoCount,
                unlocatedPhotoCount: max(0, eligiblePhotoCount - locatedPhotoCount)
            )
        }
    }

    func fetchSelection(
        query: WorldMapCatalogSelectionQuery
    ) throws -> WorldMapCatalogSelection {
        try Self.validate(query)
        let normalizedBounds = try NormalizedWorldMapCatalogQuery(
            WorldMapCatalogQuery(bounds: query.bounds)
        ).bounds
        return try database.pool.read { db in
            var bucketArguments: StatementArguments = [
                query.cellDegrees,
                query.longitudeBucket,
                query.cellDegrees,
                query.latitudeBucket,
            ]
            let spatialWhereSQL = Self.spatialWhereSQL(
                bounds: normalizedBounds,
                arguments: &bucketArguments
            )
            let totalPhotoCount = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM asset
                JOIN asset_location AS location ON location.asset_id = asset.id
                WHERE \(Self.eligiblePhotoWhereSQL)
                  AND location.latitude IS NOT NULL
                  AND location.longitude IS NOT NULL
                  AND CAST((location.longitude + 180.0) / ? AS INTEGER) = ?
                  AND CAST((location.latitude + 90.0) / ? AS INTEGER) = ?
                  \(spatialWhereSQL)
                """,
                arguments: bucketArguments
            ) ?? 0
            var assetArguments = bucketArguments
            assetArguments += [query.maximumAssets]
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT asset.id AS asset_id, asset.file_name AS file_name
                FROM asset
                JOIN asset_location AS location ON location.asset_id = asset.id
                WHERE \(Self.eligiblePhotoWhereSQL)
                  AND location.latitude IS NOT NULL
                  AND location.longitude IS NOT NULL
                  AND CAST((location.longitude + 180.0) / ? AS INTEGER) = ?
                  AND CAST((location.latitude + 90.0) / ? AS INTEGER) = ?
                  \(spatialWhereSQL)
                ORDER BY
                    COALESCE(
                        asset.media_created_at_ms,
                        asset.media_modified_at_ms,
                        asset.record_updated_at_ms
                    ) DESC,
                    asset.id
                LIMIT ?
                """,
                arguments: assetArguments
            )
            let assets = try rows.map { row -> WorldMapCatalogAsset in
                guard let rawAssetID: String = row["asset_id"],
                      let assetID = UUID(uuidString: rawAssetID)
                else {
                    throw WorldMapCatalogError.persistenceFailure
                }
                return WorldMapCatalogAsset(
                    assetID: assetID,
                    fileName: row["file_name"]
                )
            }
            return WorldMapCatalogSelection(
                assets: assets,
                totalPhotoCount: totalPhotoCount
            )
        }
    }

    private static func spatialWhereSQL(
        bounds: NormalizedWorldMapCatalogQuery.Bounds?,
        arguments: inout StatementArguments
    ) -> String {
        guard let bounds else { return "" }
        var sql = " AND location.latitude BETWEEN ? AND ?"
        arguments += [bounds.south, bounds.north]
        guard !bounds.coversEveryLongitude else { return sql }
        if bounds.crossesAntimeridian {
            sql += " AND (location.longitude >= ? OR location.longitude <= ?)"
        } else {
            sql += " AND location.longitude BETWEEN ? AND ?"
        }
        arguments += [bounds.west, bounds.east]
        return sql
    }

    private static func validate(_ query: WorldMapCatalogSelectionQuery) throws {
        guard query.cellDegrees.isFinite,
              (0.002 ... 360).contains(query.cellDegrees),
              query.longitudeBucket >= 0,
              Double(query.longitudeBucket) * query.cellDegrees <= 360.000_001,
              query.latitudeBucket >= 0,
              Double(query.latitudeBucket) * query.cellDegrees <= 180.000_001,
              (1 ... WorldMapCatalogSelectionQuery.maximumAssetLimit)
              .contains(query.maximumAssets)
        else {
            throw WorldMapCatalogError.invalidQuery
        }
    }

    private static let eligiblePhotoWhereSQL = """
    asset.locator_state = 'current'
    AND asset.availability = 'available'
    AND asset.media_kind = 'image'
    AND asset.id NOT IN (
        SELECT recycle.asset_id
        FROM recycle_entry AS recycle
        WHERE recycle.asset_id IS NOT NULL
          AND recycle.state IN (
              'pending', 'recycled', 'restoring', 'purging', 'purged'
          )
    )
    """
}

struct GRDBWorldMapLocationBackfillRepository: Sendable {
    let database: CatalogDatabase

    func fetchSnapshots() throws -> [WorldMapLocationBackfillSnapshot] {
        try database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT
                    source.id,
                    source.kind,
                    source.display_name,
                    source.state,
                    COUNT(asset.id) AS total_photo_count,
                    COUNT(location.asset_id) AS inspected_photo_count,
                    COALESCE(SUM(CASE
                        WHEN location.latitude IS NOT NULL
                         AND location.longitude IS NOT NULL THEN 1
                        ELSE 0
                    END), 0) AS located_photo_count
                FROM source
                LEFT JOIN asset
                  ON asset.source_id = source.id
                 AND asset.locator_state = 'current'
                 AND asset.availability = 'available'
                 AND asset.media_kind = 'image'
                 AND NOT EXISTS (
                    SELECT 1
                    FROM recycle_entry AS recycle
                    WHERE recycle.asset_id = asset.id
                      AND recycle.state IN (
                        'pending', 'recycled', 'restoring', 'purging', 'purged'
                      )
                 )
                LEFT JOIN asset_location AS location ON location.asset_id = asset.id
                WHERE source.kind IN ('folder', 'photos')
                GROUP BY source.id, source.kind, source.display_name, source.state
                ORDER BY source.created_at_ms, source.id
                """
            ).compactMap { row in
                guard let sourceID = UUID(uuidString: row["id"]),
                      let sourceKind = SourceKind(rawValue: row["kind"]),
                      let sourceState = SourceState(rawValue: row["state"])
                else {
                    return nil
                }
                let totalPhotoCount: Int = row["total_photo_count"]
                let inspectedPhotoCount: Int = row["inspected_photo_count"]
                let job = try latestReconcileJob(
                    sourceID: sourceID,
                    sourceKind: sourceKind,
                    db: db
                )
                return WorldMapLocationBackfillSnapshot(
                    sourceID: sourceID,
                    sourceKind: sourceKind,
                    sourceDisplayName: row["display_name"],
                    sourceState: sourceState,
                    phase: phase(
                        sourceState: sourceState,
                        totalPhotoCount: totalPhotoCount,
                        inspectedPhotoCount: inspectedPhotoCount,
                        job: job
                    ),
                    totalPhotoCount: totalPhotoCount,
                    inspectedPhotoCount: inspectedPhotoCount,
                    locatedPhotoCount: row["located_photo_count"],
                    activeJobID: job?.state.isTerminal == false ? job?.id : nil,
                    scanProgress: job?.state.isTerminal == false ? job?.progress : nil
                )
            }
        }
    }

    private func latestReconcileJob(
        sourceID: UUID,
        sourceKind: SourceKind,
        db: Database
    ) throws -> JobRecordSnapshot? {
        let kind = sourceKind == .photos
            ? PhotosReconcileJobFactory.kind
            : FolderReconcileJobFactory.kind
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT *
            FROM job
            WHERE source_id = ? AND kind = ?
            ORDER BY
                CASE WHEN state IN (
                    'pending', 'running', 'paused', 'retryableFailed'
                ) THEN 0 ELSE 1 END,
                updated_at_ms DESC,
                created_at_ms DESC
            LIMIT 1
            """,
            arguments: [sourceID.uuidString.lowercased(), kind]
        ) else {
            return nil
        }
        return try JobPersistenceMapping.snapshot(from: row)
    }

    private func phase(
        sourceState: SourceState,
        totalPhotoCount: Int,
        inspectedPhotoCount: Int,
        job: JobRecordSnapshot?
    ) -> WorldMapLocationBackfillPhase {
        guard sourceState == .active else { return .unavailable }
        if let job, !job.state.isTerminal {
            if job.controlRequest == .cancel { return .cancelling }
            switch job.state {
            case .pending: return .queued
            case .running: return .running
            case .paused, .retryableFailed: return .retryableFailed
            case .completed, .terminalFailed, .cancelled: break
            }
        }
        if inspectedPhotoCount >= totalPhotoCount {
            return .completed
        }
        switch job?.state {
        case .cancelled: return .cancelled
        case .terminalFailed: return .terminalFailed
        default: return .ready
        }
    }
}

struct WorldMapLocationBackfillControl {
    let repository: GRDBWorldMapLocationBackfillRepository
    let queue: GRDBJobQueue
    let clock: any JobClock
    let enqueueFolder: (UUID) throws -> Void
    let requestPhotosFullRepair: (UUID) throws -> Void

    func start(sourceID: UUID) throws {
        guard let snapshot = try repository.fetchSnapshots().first(where: {
            $0.sourceID == sourceID
        }), snapshot.sourceState == .active
        else {
            throw ProductionLibraryWorkspaceError.worldMapLocationBackfillSourceUnavailable
        }

        if let jobID = snapshot.activeJobID {
            switch snapshot.phase {
            case .retryableFailed:
                _ = try queue.applyStateCommand(
                    JobStateCommand(
                        jobID: jobID,
                        operation: .resume(notBeforeMs: clock.nowMs)
                    )
                )
            case .queued, .running, .cancelling:
                break
            case .ready, .completed, .cancelled, .terminalFailed, .unavailable:
                break
            }
            return
        }

        guard snapshot.phase != .completed else { return }
        if snapshot.sourceKind == .photos {
            try requestPhotosFullRepair(sourceID)
        } else {
            try enqueueFolder(sourceID)
        }
    }

    func cancel(sourceID: UUID) throws {
        guard let jobID = try repository.fetchSnapshots().first(where: {
            $0.sourceID == sourceID
        })?.activeJobID
        else {
            return
        }
        _ = try queue.applyStateCommand(
            JobStateCommand(jobID: jobID, operation: .cancel)
        )
    }
}

struct WorldMapPlaceResolutionService: Sendable {
    static let resolverVersion = 4
    static let maximumCandidateCount = 8

    let database: CatalogDatabase
    let resolver: any WorldMapPlaceResolving
    let clock: any JobClock

    func resolveTag(tagID: UUID) async throws -> WorldMapPlaceTagResolution {
        if try cachedResolverVersion(tagID: tagID) == Self.resolverVersion,
           let cached = try fetchResolution(tagID: tagID),
           cached.status != .unresolved,
           cached.status != .failed
        {
            return cached
        }
        let tagName = try await eligibleTagName(tagID: tagID)
        return try await resolveTag(tagID: tagID, normalizedQuery: tagName)
    }

    func resolveTag(
        tagID: UUID,
        query: String
    ) async throws -> WorldMapPlaceTagResolution {
        _ = try await eligibleTagName(tagID: tagID)
        let normalizedQuery = query
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !normalizedQuery.isEmpty,
              normalizedQuery.count <= WorldMapPlaceSearchPolicy.maximumQueryLength
        else {
            throw WorldMapPlaceResolutionError.invalidQuery
        }
        // A user-authored query is always a fresh search. This is the escape hatch
        // from an irrelevant cached result produced by the shorter tag name.
        return try await resolveTag(tagID: tagID, normalizedQuery: normalizedQuery)
    }

    private func eligibleTagName(tagID: UUID) async throws -> String {
        try await database.pool.read { db -> String in
            guard let name = try String.fetchOne(
                db,
                sql: """
                SELECT tag.name
                FROM tag
                WHERE tag.id = ?
                  AND tag.state = 'active'
                  AND EXISTS (
                      SELECT 1 FROM asset_tag_decision decision
                      WHERE decision.tag_id = tag.id AND decision.decision = 'accepted'
                  )
                """,
                arguments: [tagID.uuidString.lowercased()]
            ) else {
                throw WorldMapPlaceResolutionError.tagUnavailable
            }
            return name
        }
    }

    private func resolveTag(
        tagID: UUID,
        normalizedQuery: String
    ) async throws -> WorldMapPlaceTagResolution {
        let candidates: [WorldMapPlaceCandidate]
        do {
            candidates = try await resolver.resolve(query: normalizedQuery)
        } catch {
            throw WorldMapPlaceResolutionError.resolverFailed
        }
        guard candidates.count <= Self.maximumCandidateCount,
              candidates.allSatisfy(Self.isValid)
        else {
            throw WorldMapPlaceResolutionError.invalidCandidate
        }

        try await database.pool.write { db in
            for candidate in candidates {
                try Self.upsertPlace(db, candidate: candidate, nowMs: clock.nowMs)
            }
            let status: WorldMapPlaceBindingStatus = switch candidates.count {
            case 0: .failed
            case 1: .resolved
            default: .ambiguous
            }
            let confirmed = candidates.count == 1 ? candidates[0] : nil
            try db.execute(
                sql: """
                INSERT INTO tag_place_binding (
                    tag_id, place_id, status, resolver_version, resolved_at_ms, updated_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(tag_id) DO UPDATE SET
                    place_id = excluded.place_id,
                    status = excluded.status,
                    resolver_version = excluded.resolver_version,
                    resolved_at_ms = excluded.resolved_at_ms,
                    updated_at_ms = excluded.updated_at_ms
                """,
                arguments: [
                    tagID.uuidString.lowercased(),
                    confirmed?.placeID,
                    status.rawValue,
                    Self.resolverVersion,
                    confirmed == nil ? nil : clock.nowMs,
                    clock.nowMs,
                ]
            )
            try db.execute(
                sql: "DELETE FROM tag_place_candidate WHERE tag_id = ?",
                arguments: [tagID.uuidString.lowercased()]
            )
            for (rank, candidate) in candidates.enumerated() {
                try db.execute(
                    sql: """
                    INSERT INTO tag_place_candidate (tag_id, place_id, rank)
                    VALUES (?, ?, ?)
                    """,
                    arguments: [tagID.uuidString.lowercased(), candidate.placeID, rank]
                )
            }
            // Re-search can replace a previously resolved place with a new place,
            // an ambiguous set, or no result. Recalculate in every case so stale
            // placeTag coordinates never survive an explicit user correction.
            try Self.refreshCanonicalLocations(
                db,
                assetIDs: Self.acceptedAssetIDs(db, tagID: tagID),
                nowMs: clock.nowMs
            )
        }
        guard let resolved = try fetchResolution(tagID: tagID) else {
            throw WorldMapPlaceResolutionError.persistenceFailure
        }
        return resolved
    }

    func fetchResolution(tagID: UUID) throws -> WorldMapPlaceTagResolution? {
        try database.pool.read { db in
            try Self.fetchResolution(db, tagID: tagID)
        }
    }

    func listTagResolutions() throws -> [WorldMapPlaceTagResolution] {
        try database.pool.read { db in
            let tagIDs = try String.fetchAll(
                db,
                sql: """
                SELECT tag.id
                FROM tag
                JOIN asset_tag_decision decision
                    ON decision.tag_id = tag.id AND decision.decision = 'accepted'
                LEFT JOIN tag_group ON tag_group.id = tag.group_id
                WHERE tag.state = 'active'
                GROUP BY tag.id
                ORDER BY
                    CASE WHEN tag.group_id = ? THEN 0 ELSE 1 END,
                    COALESCE(tag_group.sort_order, 999),
                    tag.normalized_name COLLATE BINARY,
                    tag.id
                """,
                arguments: [TagGroupSeed.placesAndScenes.id.uuidString.lowercased()]
            )
            return try tagIDs.compactMap { rawID in
                guard let tagID = UUID(uuidString: rawID) else {
                    throw WorldMapPlaceResolutionError.persistenceFailure
                }
                return try Self.fetchResolution(db, tagID: tagID)
            }
        }
    }

    func confirmCandidate(
        tagID: UUID,
        placeID: String
    ) throws -> WorldMapPlaceTagResolution {
        try database.pool.write { db in
            let isCandidate = try Bool.fetchOne(
                db,
                sql: """
                SELECT EXISTS(
                    SELECT 1
                    FROM tag_place_candidate candidate
                    JOIN tag_place_binding binding ON binding.tag_id = candidate.tag_id
                    WHERE candidate.tag_id = ?
                      AND candidate.place_id = ?
                      AND binding.status = 'ambiguous'
                )
                """,
                arguments: [tagID.uuidString.lowercased(), placeID]
            ) ?? false
            guard isCandidate else {
                throw WorldMapPlaceResolutionError.candidateUnavailable
            }
            try db.execute(
                sql: """
                UPDATE tag_place_binding
                SET place_id = ?, status = 'resolved', resolved_at_ms = ?, updated_at_ms = ?
                WHERE tag_id = ?
                """,
                arguments: [
                    placeID,
                    clock.nowMs,
                    clock.nowMs,
                    tagID.uuidString.lowercased(),
                ]
            )
            try Self.refreshCanonicalLocations(
                db,
                assetIDs: Self.acceptedAssetIDs(db, tagID: tagID),
                nowMs: clock.nowMs
            )
        }
        guard let resolution = try fetchResolution(tagID: tagID) else {
            throw WorldMapPlaceResolutionError.persistenceFailure
        }
        return resolution
    }

    func ignoreTag(tagID: UUID) throws -> WorldMapPlaceTagResolution {
        try database.pool.write { db in
            guard try Bool.fetchOne(
                db,
                sql: """
                SELECT EXISTS(
                    SELECT 1 FROM tag
                    WHERE id = ? AND state = 'active'
                )
                """,
                arguments: [tagID.uuidString.lowercased()]
            ) ?? false else {
                throw WorldMapPlaceResolutionError.tagUnavailable
            }
            try db.execute(
                sql: """
                INSERT INTO tag_place_binding (
                    tag_id, place_id, status, resolver_version, resolved_at_ms, updated_at_ms
                ) VALUES (?, NULL, 'ignored', ?, NULL, ?)
                ON CONFLICT(tag_id) DO UPDATE SET
                    place_id = NULL,
                    status = 'ignored',
                    resolver_version = excluded.resolver_version,
                    resolved_at_ms = NULL,
                    updated_at_ms = excluded.updated_at_ms
                """,
                arguments: [
                    tagID.uuidString.lowercased(),
                    Self.resolverVersion,
                    clock.nowMs,
                ]
            )
            try db.execute(
                sql: "DELETE FROM tag_place_candidate WHERE tag_id = ?",
                arguments: [tagID.uuidString.lowercased()]
            )
            try Self.refreshCanonicalLocations(
                db,
                assetIDs: Self.acceptedAssetIDs(db, tagID: tagID),
                nowMs: clock.nowMs
            )
        }
        guard let resolution = try fetchResolution(tagID: tagID) else {
            throw WorldMapPlaceResolutionError.persistenceFailure
        }
        return resolution
    }

    private func cachedResolverVersion(tagID: UUID) throws -> Int? {
        try database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT resolver_version FROM tag_place_binding WHERE tag_id = ?",
                arguments: [tagID.uuidString.lowercased()]
            )
        }
    }

    private static func fetchResolution(
        _ db: Database,
        tagID: UUID
    ) throws -> WorldMapPlaceTagResolution? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT
                tag.id AS tag_id,
                tag.name AS tag_name,
                tag_group.name AS group_name,
                binding.status AS binding_status,
                binding.place_id AS confirmed_place_id,
                (
                    SELECT COUNT(*) FROM asset_tag_decision decision
                    WHERE decision.tag_id = tag.id AND decision.decision = 'accepted'
                ) AS accepted_count
            FROM tag
            LEFT JOIN tag_group ON tag_group.id = tag.group_id
            LEFT JOIN tag_place_binding binding ON binding.tag_id = tag.id
            WHERE tag.id = ? AND tag.state = 'active'
            """,
            arguments: [tagID.uuidString.lowercased()]
        ) else {
            return nil
        }
        let candidateRows = try Row.fetchAll(
            db,
            sql: """
            SELECT
                place.id, place.canonical_name, place.subtitle,
                place.latitude, place.longitude, place.kind
            FROM tag_place_candidate candidate
            JOIN place ON place.id = candidate.place_id
            WHERE candidate.tag_id = ?
            ORDER BY candidate.rank
            """,
            arguments: [tagID.uuidString.lowercased()]
        )
        let candidates = try candidateRows.map(Self.candidate)
        guard let rawTagID: String = row["tag_id"],
              let parsedTagID = UUID(uuidString: rawTagID)
        else {
            throw WorldMapPlaceResolutionError.persistenceFailure
        }
        let rawStatus: String? = row["binding_status"]
        return WorldMapPlaceTagResolution(
            tagID: parsedTagID,
            tagName: row["tag_name"],
            groupName: row["group_name"] ?? TagGroupSeed.other.displayName,
            acceptedPhotoCount: row["accepted_count"],
            status: rawStatus.flatMap(WorldMapPlaceBindingStatus.init(rawValue:)) ?? .unresolved,
            confirmedPlaceID: row["confirmed_place_id"],
            candidates: candidates
        )
    }

    private static func candidate(_ row: Row) throws -> WorldMapPlaceCandidate {
        guard let kind = WorldMapPlaceKind(rawValue: row["kind"]) else {
            throw WorldMapPlaceResolutionError.persistenceFailure
        }
        return WorldMapPlaceCandidate(
            placeID: row["id"],
            displayName: row["canonical_name"],
            subtitle: row["subtitle"],
            latitude: row["latitude"],
            longitude: row["longitude"],
            kind: kind
        )
    }

    private static func isValid(_ candidate: WorldMapPlaceCandidate) -> Bool {
        !candidate.placeID.isEmpty
            && !candidate.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && candidate.latitude.isFinite
            && candidate.longitude.isFinite
            && (-90 ... 90).contains(candidate.latitude)
            && (-180 ... 180).contains(candidate.longitude)
    }

    private static func upsertPlace(
        _ db: Database,
        candidate: WorldMapPlaceCandidate,
        nowMs: Int64
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO place (
                id, canonical_name, subtitle, latitude, longitude, kind,
                created_at_ms, updated_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                canonical_name = excluded.canonical_name,
                subtitle = excluded.subtitle,
                latitude = excluded.latitude,
                longitude = excluded.longitude,
                kind = excluded.kind,
                updated_at_ms = excluded.updated_at_ms
            """,
            arguments: [
                candidate.placeID,
                candidate.displayName,
                candidate.subtitle,
                candidate.latitude,
                candidate.longitude,
                candidate.kind.rawValue,
                nowMs,
                nowMs,
            ]
        )
    }

    static func acceptedAssetIDs(_ db: Database, tagID: UUID) throws -> [UUID] {
        try String.fetchAll(
            db,
            sql: """
            SELECT asset_id
            FROM asset_tag_decision
            WHERE tag_id = ? AND decision = 'accepted'
            """,
            arguments: [tagID.uuidString.lowercased()]
        ).compactMap(UUID.init(uuidString:))
    }

    static func refreshCanonicalLocations(
        _ db: Database,
        assetIDs: [UUID],
        nowMs: Int64
    ) throws {
        for assetID in Set(assetIDs) {
            let assetToken = assetID.uuidString.lowercased()
            let existingSource = try String.fetchOne(
                db,
                sql: "SELECT source_kind FROM asset_location WHERE asset_id = ?",
                arguments: [assetToken]
            )
            guard existingSource == nil || existingSource == "none" || existingSource == "placeTag" else {
                continue
            }
            let places = try Row.fetchAll(
                db,
                sql: """
                SELECT DISTINCT place.id, place.latitude, place.longitude
                FROM asset_tag_decision decision
                JOIN tag ON tag.id = decision.tag_id AND tag.state = 'active'
                JOIN tag_place_binding binding
                    ON binding.tag_id = decision.tag_id AND binding.status = 'resolved'
                JOIN place ON place.id = binding.place_id
                WHERE decision.asset_id = ? AND decision.decision = 'accepted'
                """,
                arguments: [assetToken]
            )
            if places.count == 1, let place = places.first {
                try db.execute(
                    sql: """
                    INSERT INTO asset_location (
                        asset_id, latitude, longitude, altitude_m, source_kind,
                        updated_at_ms, place_id
                    ) VALUES (?, ?, ?, NULL, 'placeTag', ?, ?)
                    ON CONFLICT(asset_id) DO UPDATE SET
                        latitude = excluded.latitude,
                        longitude = excluded.longitude,
                        altitude_m = NULL,
                        source_kind = 'placeTag',
                        place_id = excluded.place_id,
                        updated_at_ms = excluded.updated_at_ms
                    """,
                    arguments: [
                        assetToken,
                        place["latitude"],
                        place["longitude"],
                        nowMs,
                        place["id"],
                    ]
                )
            } else if existingSource == "placeTag" {
                try db.execute(
                    sql: """
                    UPDATE asset_location
                    SET latitude = NULL, longitude = NULL, altitude_m = NULL,
                        source_kind = 'none', updated_at_ms = ?, place_id = NULL
                    WHERE asset_id = ?
                    """,
                    arguments: [nowMs, assetToken]
                )
            }
        }
    }
}

struct WorldMapPlaceSearchRegion: Sendable, Equatable {
    let centerLatitude: Double
    let centerLongitude: Double
    let latitudeDelta: Double
    let longitudeDelta: Double

    static let global = WorldMapPlaceSearchRegion(
        centerLatitude: 0,
        centerLongitude: 0,
        latitudeDelta: 180,
        longitudeDelta: 360
    )

    private init(
        centerLatitude: Double,
        centerLongitude: Double,
        latitudeDelta: Double,
        longitudeDelta: Double
    ) {
        self.centerLatitude = centerLatitude
        self.centerLongitude = centerLongitude
        self.latitudeDelta = latitudeDelta
        self.longitudeDelta = longitudeDelta
    }

    init(anchor: WorldMapPlaceCandidate) {
        centerLatitude = anchor.latitude
        centerLongitude = anchor.longitude
        (latitudeDelta, longitudeDelta) = switch anchor.kind {
        case .poi: (2, 2)
        case .city: (8, 8)
        case .region: (30, 60)
        case .country: (80, 160)
        }
    }

    var mapKitRegion: MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: centerLatitude,
                longitude: centerLongitude
            ),
            span: MKCoordinateSpan(
                latitudeDelta: latitudeDelta,
                longitudeDelta: longitudeDelta
            )
        )
    }
}

protocol WorldMapApplePlaceSearching: Sendable {
    func geocode(query: String) async throws -> [WorldMapPlaceCandidate]
    func search(
        query: String,
        region: WorldMapPlaceSearchRegion?
    ) async throws -> [WorldMapPlaceCandidate]
}

private struct WorldMapCountryQueryHint: Sendable {
    private struct CatalogEntry: Sendable {
        let regionCode: String
        let canonicalEnglishName: String
        let aliases: [String]
    }

    let regionCode: String
    let canonicalEnglishName: String
    let aliases: [String]
    let isCountryOnlyQuery: Bool

    static func detect(in query: String) -> Self? {
        let normalizedQuery = normalized(query)
        guard !normalizedQuery.isEmpty else { return nil }

        let matches = catalog.compactMap { entry -> (CatalogEntry, [String], Int)? in
            var matchedAliases = entry.aliases.filter {
                containsAlias($0, in: normalizedQuery)
            }
            let normalizedRegionCode = entry.regionCode.lowercased()
            if normalizedQuery == normalizedRegionCode {
                matchedAliases.append(normalizedRegionCode)
            }
            guard !matchedAliases.isEmpty else { return nil }
            let lastPosition = matchedAliases.compactMap {
                normalizedQuery.range(of: $0, options: .backwards)?.lowerBound
            }.map { normalizedQuery.distance(from: normalizedQuery.startIndex, to: $0) }
                .max() ?? 0
            return (entry, matchedAliases, lastPosition)
        }
        guard let best = matches.max(by: { lhs, rhs in
            if lhs.1.count != rhs.1.count { return lhs.1.count < rhs.1.count }
            if lhs.2 != rhs.2 { return lhs.2 < rhs.2 }
            let lhsLength = lhs.1.map(\.count).max() ?? 0
            let rhsLength = rhs.1.map(\.count).max() ?? 0
            return lhsLength < rhsLength
        }) else {
            return nil
        }

        var residual = normalizedQuery
        for alias in best.1.sorted(by: { $0.count > $1.count })
        where containsAlias(alias, in: residual) {
            residual = residual.replacingOccurrences(of: alias, with: " ")
        }
        let isCountryOnly = residual.unicodeScalars.allSatisfy {
            !CharacterSet.alphanumerics.contains($0)
        }
        return Self(
            regionCode: best.0.regionCode,
            canonicalEnglishName: best.0.canonicalEnglishName,
            aliases: best.0.aliases + [best.0.regionCode.lowercased()],
            isCountryOnlyQuery: isCountryOnly
        )
    }

    func matches(_ candidate: WorldMapPlaceCandidate) -> Bool {
        if candidate.countryCode?.caseInsensitiveCompare(regionCode) == .orderedSame {
            return true
        }
        guard candidate.kind == .country else { return false }
        let candidateName = Self.normalized(candidate.displayName)
        return aliases.contains(candidateName)
    }

    private static let catalog: [CatalogEntry] = {
        let locales = [
            Locale.current,
            Locale(identifier: "zh_Hans"),
            Locale(identifier: "en_US"),
        ]
        let supplementalAliases: [String: [String]] = [
            "AE": ["UAE"],
            "GB": ["UK", "U.K.", "Britain", "Great Britain"],
            "US": ["USA", "U.S.A.", "United States of America"],
        ]
        return Locale.Region.isoRegions.compactMap { region in
            let code = region.identifier.uppercased()
            guard code.count == 2,
                  let englishName = Locale(identifier: "en_US")
                    .localizedString(forRegionCode: code)
            else {
                return nil
            }
            let localizedNames = locales.compactMap {
                $0.localizedString(forRegionCode: code)
            }
            let rawAliases = localizedNames + supplementalAliases[code, default: []]
            var seen = Set<String>()
            let aliases = rawAliases.compactMap { value -> String? in
                let alias = normalized(value)
                guard !alias.isEmpty, seen.insert(alias).inserted else { return nil }
                return alias
            }
            return CatalogEntry(
                regionCode: code,
                canonicalEnglishName: englishName,
                aliases: aliases
            )
        }
    }()

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
    }

    private static func containsAlias(_ alias: String, in query: String) -> Bool {
        var searchRange = query.startIndex ..< query.endIndex
        while let range = query.range(of: alias, range: searchRange) {
            let beforeIsAlphanumeric = range.lowerBound > query.startIndex
                && isAlphanumeric(query[query.index(before: range.lowerBound)])
            let afterIsAlphanumeric = range.upperBound < query.endIndex
                && isAlphanumeric(query[range.upperBound])
            let aliasIsASCII = alias.unicodeScalars.allSatisfy(\.isASCII)
            if !aliasIsASCII || (!beforeIsAlphanumeric && !afterIsAlphanumeric) {
                return true
            }
            searchRange = range.upperBound ..< query.endIndex
        }
        return false
    }

    private static func isAlphanumeric(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}

struct MapKitWorldMapPlaceResolver: WorldMapPlaceResolving {
    private enum SearchError: Error {
        case unavailable
    }

    let searcher: any WorldMapApplePlaceSearching

    init(searcher: any WorldMapApplePlaceSearching = AppleWorldMapPlaceSearcher()) {
        self.searcher = searcher
    }

    func resolve(query: String) async throws -> [WorldMapPlaceCandidate] {
        let countryHint = WorldMapCountryQueryHint.detect(in: query)
        let geocoded: [WorldMapPlaceCandidate]
        var geocodingSucceeded: Bool
        do {
            geocoded = try await searcher.geocode(query: query)
            geocodingSucceeded = true
        } catch {
            geocoded = []
            geocodingSucceeded = false
        }

        let countryGeocoded: [WorldMapPlaceCandidate]
        if let countryHint,
           countryHint.canonicalEnglishName.compare(
               query,
               options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
           ) != .orderedSame
        {
            do {
                countryGeocoded = try await searcher.geocode(
                    query: countryHint.canonicalEnglishName
                )
                geocodingSucceeded = true
            } catch {
                countryGeocoded = []
            }
        } else {
            countryGeocoded = geocoded
        }

        let matchingGeocoded = countryHint.map { hint in
            geocoded.filter(hint.matches)
        } ?? geocoded
        let matchingCountries = countryHint.map { hint in
            countryGeocoded.filter(hint.matches)
        } ?? countryGeocoded
        let anchor: WorldMapPlaceCandidate? = if countryHint?.isCountryOnlyQuery == true {
            matchingCountries.first(where: { $0.kind == .country })
                ?? matchingCountries.first
                ?? matchingGeocoded.first
        } else {
            matchingGeocoded.first
                ?? matchingCountries.first(where: { $0.kind == .country })
                ?? matchingCountries.first
        }
        // A 180 x 360 "required" MKCoordinateRegion is not a useful global
        // fallback: Apple can reject it with GEOError -8. Omitting the region
        // gives MKLocalSearch its actual worldwide/default behavior.
        let region = anchor.map(WorldMapPlaceSearchRegion.init(anchor:))
        let searched: [WorldMapPlaceCandidate]
        let searchFailed: Bool
        do {
            searched = try await searcher.search(query: query, region: region)
            searchFailed = false
        } catch {
            searched = []
            searchFailed = true
        }

        guard geocodingSucceeded || !searchFailed else {
            throw SearchError.unavailable
        }

        var combined = searched + geocoded + countryGeocoded
        if let countryHint {
            let countryScoped = combined.filter(countryHint.matches)
            // Never surface a foreign restaurant merely because every genuine
            // result for the requested country was unavailable. An empty result
            // lets the explicit user-search path invoke its international fallback.
            combined = countryScoped
            if countryHint.isCountryOnlyQuery {
                let countryCandidates = combined.filter { $0.kind == .country }
                if !countryCandidates.isEmpty {
                    combined = countryCandidates
                }
            }
        }
        var seen = Set<String>()
        return combined.compactMap { candidate in
            guard seen.insert(candidate.placeID).inserted else { return nil }
            return candidate
        }.prefix(WorldMapPlaceResolutionService.maximumCandidateCount).map(\.self)
    }
}

struct CascadingWorldMapPlaceResolver: WorldMapPlaceResolving {
    let primary: any WorldMapPlaceResolving
    let fallback: any WorldMapPlaceResolving

    func resolve(query: String) async throws -> [WorldMapPlaceCandidate] {
        do {
            let candidates = try await primary.resolve(query: query)
            if !candidates.isEmpty {
                return candidates
            }
        } catch {
            // User-triggered searches still get one bounded international
            // fallback when Apple's regional catalog is unavailable.
        }
        return try await fallback.resolve(query: query)
    }
}

protocol NominatimWorldMapDataLoading: Sendable {
    func data(for request: URLRequest, cacheKey: String) async throws -> Data
}

actor NominatimWorldMapHTTPClient: NominatimWorldMapDataLoading {
    static let shared = NominatimWorldMapHTTPClient()

    private enum ClientError: Error {
        case invalidResponse
    }

    private static let minimumRequestInterval = Duration.seconds(1)
    private static let maximumMemoryEntryCount = 128

    private let clock = ContinuousClock()
    private var lastRequestAt: ContinuousClock.Instant?
    private var requestIsInFlight = false
    private var cachedData: [String: Data] = [:]
    private var cacheRecency: [String] = []

    func data(for request: URLRequest, cacheKey: String) async throws -> Data {
        if let cached = cachedData[cacheKey] {
            touch(cacheKey)
            return cached
        }

        while requestIsInFlight {
            try await clock.sleep(for: .milliseconds(50))
        }
        if let cached = cachedData[cacheKey] {
            touch(cacheKey)
            return cached
        }
        requestIsInFlight = true
        defer { requestIsInFlight = false }

        if let lastRequestAt {
            let nextAllowedRequest = lastRequestAt.advanced(by: Self.minimumRequestInterval)
            if clock.now < nextAllowedRequest {
                try await clock.sleep(until: nextAllowedRequest)
            }
        }
        lastRequestAt = clock.now

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode)
        else {
            throw ClientError.invalidResponse
        }
        cachedData[cacheKey] = data
        touch(cacheKey)
        while cacheRecency.count > Self.maximumMemoryEntryCount {
            let evicted = cacheRecency.removeFirst()
            cachedData.removeValue(forKey: evicted)
        }
        return data
    }

    private func touch(_ cacheKey: String) {
        cacheRecency.removeAll(where: { $0 == cacheKey })
        cacheRecency.append(cacheKey)
    }
}

struct NominatimWorldMapPlaceResolver: WorldMapPlaceResolving {
    private struct Response: Decodable {
        struct Address: Decodable {
            let city: String?
            let town: String?
            let village: String?
            let municipality: String?
            let county: String?
            let state: String?
            let country: String?
            let countryCode: String?

            enum CodingKeys: String, CodingKey {
                case city, town, village, municipality, county, state, country
                case countryCode = "country_code"
            }
        }

        let placeID: Int64?
        let osmType: String?
        let osmID: Int64?
        let latitude: String
        let longitude: String
        let name: String?
        let displayName: String
        let type: String?
        let addressType: String?
        let address: Address?

        enum CodingKeys: String, CodingKey {
            case placeID = "place_id"
            case osmType = "osm_type"
            case osmID = "osm_id"
            case latitude = "lat"
            case longitude = "lon"
            case name, type, address
            case displayName = "display_name"
            case addressType = "addresstype"
        }
    }

    private enum ResolverError: Error {
        case invalidRequest
    }

    let client: any NominatimWorldMapDataLoading

    init(client: any NominatimWorldMapDataLoading = NominatimWorldMapHTTPClient.shared) {
        self.client = client
    }

    func resolve(query: String) async throws -> [WorldMapPlaceCandidate] {
        let countryHint = WorldMapCountryQueryHint.detect(in: query)
        let remoteQuery = if countryHint?.isCountryOnlyQuery == true {
            countryHint?.canonicalEnglishName ?? query
        } else {
            query
        }
        let languages = Locale.preferredLanguages.prefix(3).joined(separator: ",")
        var components = URLComponents(string: "https://nominatim.openstreetmap.org/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: remoteQuery),
            URLQueryItem(name: "format", value: "jsonv2"),
            URLQueryItem(name: "addressdetails", value: "1"),
            URLQueryItem(name: "namedetails", value: "1"),
            URLQueryItem(name: "limit", value: String(WorldMapPlaceResolutionService.maximumCandidateCount)),
            URLQueryItem(name: "accept-language", value: languages),
        ]
        guard let url = components?.url else {
            throw ResolverError.invalidRequest
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .returnCacheDataElseLoad
        request.setValue(
            "ImageAll/1.0 (https://github.com/lgw2023/ImageAll)",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let cacheKey = "\(remoteQuery)|\(languages)"
        let data = try await client.data(for: request, cacheKey: cacheKey)
        let responses = try JSONDecoder().decode([Response].self, from: data)
        var candidates = responses.compactMap(Self.candidate)
        if let countryHint {
            candidates = candidates.filter(countryHint.matches)
            if countryHint.isCountryOnlyQuery {
                let countries = candidates.filter { $0.kind == .country }
                if !countries.isEmpty {
                    candidates = countries
                }
            }
        }
        var seen = Set<String>()
        return candidates.compactMap { candidate in
            guard seen.insert(candidate.placeID).inserted else { return nil }
            return candidate
        }.prefix(WorldMapPlaceResolutionService.maximumCandidateCount).map(\.self)
    }

    private static func candidate(_ response: Response) -> WorldMapPlaceCandidate? {
        guard let latitude = Double(response.latitude),
              let longitude = Double(response.longitude),
              (-90 ... 90).contains(latitude),
              (-180 ... 180).contains(longitude)
        else {
            return nil
        }
        let kind: WorldMapPlaceKind = switch response.addressType ?? response.type {
        case "country": .country
        case "city", "town", "village", "municipality": .city
        case "state", "region", "province", "county": .region
        default: .poi
        }
        let countryCode = response.address?.countryCode?.uppercased()
        let localizedCountryName = countryCode.flatMap {
            Locale.current.localizedString(forRegionCode: $0)
        }
        let fallbackName = response.displayName
            .split(separator: ",", maxSplits: 1)
            .first
            .map(String.init)
        let displayName = if kind == .country {
            localizedCountryName ?? response.name ?? fallbackName
        } else {
            response.name ?? fallbackName
        }
        guard let displayName,
              !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        let subtitleValues = [
            response.address?.city,
            response.address?.town,
            response.address?.municipality,
            response.address?.state,
            localizedCountryName ?? response.address?.country,
        ].compactMap { value -> String? in
            guard let value,
                  value.compare(displayName, options: [.caseInsensitive, .diacriticInsensitive])
                    != .orderedSame
            else {
                return nil
            }
            return value
        }
        let subtitle = Array(NSOrderedSet(array: subtitleValues))
            .compactMap { $0 as? String }
            .joined(separator: "，")
        let placeID: String
        if let osmType = response.osmType, let osmID = response.osmID {
            placeID = "nominatim-v1-\(osmType)-\(osmID)"
        } else if let rawPlaceID = response.placeID {
            placeID = "nominatim-v1-place-\(rawPlaceID)"
        } else {
            placeID = "nominatim-v1-\(latitude)-\(longitude)"
        }
        return WorldMapPlaceCandidate(
            placeID: placeID,
            displayName: displayName,
            subtitle: subtitle.isEmpty ? nil : subtitle,
            latitude: latitude,
            longitude: longitude,
            kind: kind,
            countryCode: countryCode
        )
    }
}

struct AppleWorldMapPlaceSearcher: WorldMapApplePlaceSearching {
    func geocode(query: String) async throws -> [WorldMapPlaceCandidate] {
        if #available(macOS 26.0, *) {
            guard let request = MKGeocodingRequest(addressString: query) else {
                return []
            }
            request.preferredLocale = .current
            return try await Self.candidates(from: request.mapItems)
        }

        let placemarks = try await CLGeocoder().geocodeAddressString(
            query,
            in: nil,
            preferredLocale: .current
        )
        return placemarks.compactMap(Self.candidate(from:))
    }

    func search(
        query: String,
        region: WorldMapPlaceSearchRegion?
    ) async throws -> [WorldMapPlaceCandidate] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.address, .pointOfInterest, .physicalFeature]
        if let region {
            request.region = region.mapKitRegion
            request.regionPriority = .required
        }
        let response = try await MKLocalSearch(request: request).start()
        return Self.candidates(from: response.mapItems)
    }

    private static func candidates(from mapItems: [MKMapItem]) -> [WorldMapPlaceCandidate] {
        var seen = Set<String>()
        var candidates: [WorldMapPlaceCandidate] = []
        for item in mapItems {
            let coordinate = item.placemark.coordinate
            guard CLLocationCoordinate2DIsValid(coordinate) else { continue }
            let placemark = item.placemark
            let displayName = item.name
                ?? placemark.locality
                ?? placemark.administrativeArea
                ?? placemark.country
            guard let displayName,
                  !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                continue
            }
            let kind: WorldMapPlaceKind
            if item.pointOfInterestCategory != nil || Self.isNamedFeature(
                displayName,
                locality: placemark.locality,
                administrativeArea: placemark.administrativeArea,
                country: placemark.country
            ) {
                kind = .poi
            } else if placemark.locality != nil {
                kind = .city
            } else if placemark.administrativeArea != nil {
                kind = .region
            } else {
                kind = .country
            }
            let subtitleParts = [
                placemark.locality,
                placemark.administrativeArea,
                placemark.country,
            ].compactMap { value -> String? in
                guard let value, value != displayName else { return nil }
                return value
            }
            let subtitle = subtitleParts.isEmpty
                ? nil
                : Array(NSOrderedSet(array: subtitleParts))
                    .compactMap { $0 as? String }
                    .joined(separator: "，")
            let placeID = Self.stablePlaceID(
                displayName: displayName,
                subtitle: subtitle,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                kind: kind
            )
            guard seen.insert(placeID).inserted else { continue }
            candidates.append(
                WorldMapPlaceCandidate(
                    placeID: placeID,
                    displayName: displayName,
                    subtitle: subtitle,
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    kind: kind,
                    countryCode: placemark.isoCountryCode
                )
            )
            if candidates.count == WorldMapPlaceResolutionService.maximumCandidateCount {
                break
            }
        }
        return candidates
    }

    private static func candidate(from placemark: CLPlacemark) -> WorldMapPlaceCandidate? {
        guard let coordinate = placemark.location?.coordinate,
              CLLocationCoordinate2DIsValid(coordinate)
        else {
            return nil
        }
        let displayName = placemark.areasOfInterest?.first
            ?? placemark.name
            ?? placemark.locality
            ?? placemark.administrativeArea
            ?? placemark.country
        guard let displayName,
              !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        let kind: WorldMapPlaceKind
        if placemark.areasOfInterest?.isEmpty == false || Self.isNamedFeature(
            displayName,
            locality: placemark.locality,
            administrativeArea: placemark.administrativeArea,
            country: placemark.country
        ) {
            kind = .poi
        } else if placemark.locality != nil {
            kind = .city
        } else if placemark.administrativeArea != nil {
            kind = .region
        } else {
            kind = .country
        }
        let subtitle = Self.subtitle(
            displayName: displayName,
            locality: placemark.locality,
            administrativeArea: placemark.administrativeArea,
            country: placemark.country
        )
        return WorldMapPlaceCandidate(
            placeID: stablePlaceID(
                displayName: displayName,
                subtitle: subtitle,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                kind: kind
            ),
            displayName: displayName,
            subtitle: subtitle,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            kind: kind,
            countryCode: placemark.isoCountryCode
        )
    }

    private static func isNamedFeature(
        _ displayName: String,
        locality: String?,
        administrativeArea: String?,
        country: String?
    ) -> Bool {
        ![locality, administrativeArea, country]
            .compactMap { $0 }
            .contains {
                $0.compare(
                    displayName,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) == .orderedSame
            }
    }

    private static func subtitle(
        displayName: String,
        locality: String?,
        administrativeArea: String?,
        country: String?
    ) -> String? {
        let parts = [locality, administrativeArea, country].compactMap { value -> String? in
            guard let value, value != displayName else { return nil }
            return value
        }
        return parts.isEmpty
            ? nil
            : Array(NSOrderedSet(array: parts))
                .compactMap { $0 as? String }
                .joined(separator: "，")
    }

    private static func stablePlaceID(
        displayName: String,
        subtitle: String?,
        latitude: Double,
        longitude: Double,
        kind: WorldMapPlaceKind
    ) -> String {
        let identity = [
            displayName.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            ),
            subtitle ?? "",
            String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), latitude),
            String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), longitude),
            kind.rawValue,
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "mapkit-v1-\(digest)"
    }
}

private struct NormalizedWorldMapCatalogQuery {
    struct Bounds {
        let west: Double
        let south: Double
        let east: Double
        let north: Double
        let crossesAntimeridian: Bool
        let coversEveryLongitude: Bool
    }

    let bounds: Bounds?
    let maximumClusters: Int
    let cellDegrees: Double

    var selectionBounds: WorldMapCatalogBounds? {
        guard let bounds else { return nil }
        return WorldMapCatalogBounds(
            west: bounds.coversEveryLongitude ? -180 : bounds.west,
            south: bounds.south,
            east: bounds.coversEveryLongitude ? 180 : bounds.east,
            north: bounds.north
        )
    }

    init(_ query: WorldMapCatalogQuery) throws {
        guard (1 ... WorldMapCatalogQuery.maximumClusterLimit)
            .contains(query.maximumClusters)
        else {
            throw WorldMapCatalogError.invalidQuery
        }
        maximumClusters = query.maximumClusters

        guard let raw = query.bounds else {
            bounds = nil
            cellDegrees = 7.5
            return
        }
        guard raw.west.isFinite,
              raw.south.isFinite,
              raw.east.isFinite,
              raw.north.isFinite
        else {
            throw WorldMapCatalogError.invalidQuery
        }
        let south = max(-90, min(90, raw.south))
        let north = max(-90, min(90, raw.north))
        guard south < north else {
            throw WorldMapCatalogError.invalidQuery
        }
        let coversEveryLongitude = abs(raw.east - raw.west) >= 359.999
        let west = Self.normalizeLongitude(raw.west)
        let east = Self.normalizeLongitude(raw.east)
        let crossesAntimeridian = !coversEveryLongitude && west > east
        let longitudeSpan: Double
        if coversEveryLongitude {
            longitudeSpan = 360
        } else if crossesAntimeridian {
            longitudeSpan = (180 - west) + (east + 180)
        } else {
            longitudeSpan = max(0.002, east - west)
        }
        cellDegrees = max(0.002, longitudeSpan / 48, (north - south) / 32)
        bounds = Bounds(
            west: west,
            south: south,
            east: east,
            north: north,
            crossesAntimeridian: crossesAntimeridian,
            coversEveryLongitude: coversEveryLongitude
        )
    }

    private static func normalizeLongitude(_ value: Double) -> Double {
        let shifted = (value + 180).truncatingRemainder(dividingBy: 360)
        return (shifted < 0 ? shifted + 360 : shifted) - 180
    }
}

struct LibrarySourceDeletionPreparation: Sendable, Equatable {
    let sourceID: UUID
    let kind: SourceKind
    let assetIDs: [UUID]
}

struct LibrarySourceDeletionService: Sendable {
    let database: CatalogDatabase
    let cachePurger: any AppOwnedAssetCachePurging

    private func recycleBlockers(
        in db: Database,
        sourceToken: String
    ) throws -> LibrarySourceDeletionBlockers {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            WITH latest_attempt AS (
                SELECT
                    recycle.*,
                    ROW_NUMBER() OVER (
                        PARTITION BY recycle.asset_id
                        ORDER BY recycle.created_at_ms DESC, recycle.rowid DESC
                    ) AS lifecycle_rank
                FROM recycle_entry AS recycle
                WHERE recycle.asset_id IS NOT NULL
            )
            SELECT
                COALESCE(SUM(CASE WHEN recycle.state = 'recycled' THEN 1 ELSE 0 END), 0)
                    AS recycled_count,
                COALESCE(SUM(CASE
                    WHEN recycle.state = 'failed'
                     AND recycle.source_kind = 'file'
                     AND recycle.error_code = ?
                     AND recycle.original_relative_path IS NOT NULL
                     AND recycle.photos_local_identifier IS NULL
                    THEN 1 ELSE 0 END), 0) AS discardable_authorization_count,
                COUNT(*) AS total_count
            FROM latest_attempt AS recycle
            JOIN asset ON asset.id = recycle.asset_id
            WHERE asset.source_id = ?
              AND recycle.lifecycle_rank = 1
              AND recycle.state NOT IN ('restored', 'purged')
              AND (
                  recycle.source_kind <> 'file'
                  OR recycle.error_code IS NULL
                  OR recycle.error_code NOT IN (?, ?)
              )
            """,
            arguments: [
                RecycleFailureCode.mutationAuthorizationRequired,
                sourceToken,
                RecycleFailureCode.spaceFirstSourceDeletionPending,
                RecycleFailureCode.spaceFirstAppCacheCleanupPending,
            ]
        ) else {
            throw DeleteLibrarySourceError.persistenceFailure
        }
        let recycledItemCount: Int = row["recycled_count"]
        let discardableAuthorizationFailureCount: Int =
            row["discardable_authorization_count"]
        let totalCount: Int = row["total_count"]
        return LibrarySourceDeletionBlockers(
            recycledItemCount: recycledItemCount,
            discardableAuthorizationFailureCount:
                discardableAuthorizationFailureCount,
            inspectionRequiredCount: max(
                0,
                totalCount
                    - recycledItemCount
                    - discardableAuthorizationFailureCount
            )
        )
    }

    func prepare(sourceID: UUID) throws -> LibrarySourceDeletionPreparation {
        try database.pool.read { db in
            let sourceToken = sourceID.uuidString.lowercased()
            guard let kindToken = try String.fetchOne(
                db,
                sql: "SELECT kind FROM source WHERE id = ?",
                arguments: [sourceToken]
            ), let kind = SourceKind(rawValue: kindToken) else {
                throw DeleteLibrarySourceError.sourceNotFound
            }

            let blockers = try recycleBlockers(in: db, sourceToken: sourceToken)
            guard blockers.totalCount == 0 else {
                throw DeleteLibrarySourceError.unresolvedRecycleEntries(
                    blockers: blockers
                )
            }

            let assetIDs = try String.fetchAll(
                db,
                sql: "SELECT id FROM asset WHERE source_id = ? ORDER BY id",
                arguments: [sourceToken]
            ).compactMap(UUID.init(uuidString:))
            return LibrarySourceDeletionPreparation(
                sourceID: sourceID,
                kind: kind,
                assetIDs: assetIDs
            )
        }
    }

    func delete(
        preparation: LibrarySourceDeletionPreparation
    ) throws -> DeleteLibrarySourceOutcome {
        do {
            for assetID in preparation.assetIDs {
                try cachePurger.purge(assetID: assetID)
            }
        } catch {
            throw DeleteLibrarySourceError.cacheCleanupFailed
        }

        do {
            return try database.pool.write { db in
                let sourceToken = preparation.sourceID.uuidString.lowercased()
                guard let kindToken = try String.fetchOne(
                    db,
                    sql: "SELECT kind FROM source WHERE id = ? AND state = 'disabled'",
                    arguments: [sourceToken]
                ), kindToken == preparation.kind.rawValue else {
                    throw DeleteLibrarySourceError.persistenceFailure
                }

                let blockers = try recycleBlockers(in: db, sourceToken: sourceToken)
                guard blockers.totalCount == 0 else {
                    throw DeleteLibrarySourceError.unresolvedRecycleEntries(
                        blockers: blockers
                    )
                }

                let currentAssetIDs = try String.fetchAll(
                    db,
                    sql: "SELECT id FROM asset WHERE source_id = ? ORDER BY id",
                    arguments: [sourceToken]
                ).compactMap(UUID.init(uuidString:))
                guard currentAssetIDs == preparation.assetIDs else {
                    throw DeleteLibrarySourceError.persistenceFailure
                }

                try db.execute(
                    sql: """
                    DELETE FROM recycle_entry
                    WHERE asset_id IN (SELECT id FROM asset WHERE source_id = ?)
                    """,
                    arguments: [sourceToken]
                )
                try db.execute(
                    sql: """
                    DELETE FROM asset_tag_decision
                    WHERE asset_id IN (SELECT id FROM asset WHERE source_id = ?)
                    """,
                    arguments: [sourceToken]
                )
                try db.execute(
                    sql: "DELETE FROM job WHERE source_id = ?",
                    arguments: [sourceToken]
                )
                try db.execute(
                    sql: "DELETE FROM asset WHERE source_id = ?",
                    arguments: [sourceToken]
                )
                guard db.changesCount == preparation.assetIDs.count else {
                    throw DeleteLibrarySourceError.persistenceFailure
                }
                try db.execute(
                    sql: "DELETE FROM source WHERE id = ?",
                    arguments: [sourceToken]
                )
                guard db.changesCount == 1 else {
                    throw DeleteLibrarySourceError.persistenceFailure
                }
                return DeleteLibrarySourceOutcome(
                    sourceID: preparation.sourceID,
                    deletedAssetCount: preparation.assetIDs.count
                )
            }
        } catch let error as DeleteLibrarySourceError {
            throw error
        } catch {
            throw DeleteLibrarySourceError.persistenceFailure
        }
    }
}

struct ProductionLibraryWorkspaceService:
    LibraryWorkspacePort,
    RemoteCatalogServing,
    RemoteSourceManagementWorkspacePort,
    Sendable
{
    let sourceRepository: GRDBFolderSourceAuthorizationRepository
    let folderSourceMonitor: FolderSourceMonitoringCoordinator
    let photosSourceMonitor: PhotosLibraryChangeObserverCoordinator
    let authorization: any FolderAuthorizationCommandPort
    let photosConnection: PhotosLibraryConnectionService
    let photosMutation: any PhotosLibraryMutationPort
    let queue: GRDBJobQueue
    let executionCoordinator: JobExecutionCoordinator
    let query: GRDBAssetCatalogQueryRepository
    let tags: GRDBTagCatalogRepository
    let assetImages: LibraryAssetImageLoader
    let personalizationReview: PersonalizationReviewService
    let derivedImageCache: DerivedImageCacheService
    let quarantineRootURL: URL
    let photosOriginalCache: PhotosOriginalCacheService
    let sourceDeletion: LibrarySourceDeletionService
    let interactiveIOGate: InteractiveIOPriorityGate?
    let appStorageLocationController: AppStorageLocationController
    let portableExportDestinationPicker: any PortableExportDestinationPicking
    let portableExportSourceIsolation: PortableExportSourceIsolationValidator
    let portableExporter: PortableCatalogExporter
    let worldMapSnapshotCache: WorldMapSnapshotCache
    let appVersion: String
    let clock: any JobClock

    @MainActor
    func openPhotosPrivacySettings() -> Bool {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos"
        ) else { return false }
        return NSWorkspace.shared.open(url)
    }

    func startCatalogSourceMonitoring(onChange: @escaping @Sendable () -> Void) throws {
        // Startup restores event streams only. A full reconcile for every active
        // external source would monopolize mechanical disks before the user asks
        // to refresh a source; persisted jobs and later FSEvents still reconcile.
        try folderSourceMonitor.start(
            onChange: onChange,
            enqueueInitialReconciles: false
        )
        photosSourceMonitor.start(onChange: onChange)
    }

    func stopCatalogSourceMonitoring() {
        folderSourceMonitor.stop()
        photosSourceMonitor.stop()
    }

    @MainActor
    func choosePortableExportDirectory() -> URL? {
        portableExportDestinationPicker.chooseParentDirectory()
    }

    func exportPortableUserData(to parentDirectoryURL: URL) throws -> PortableCatalogExportResult {
        try portableExportSourceIsolation.validate(parentDirectoryURL: parentDirectoryURL)
        let createdAtMs = clock.nowMs
        return try portableExporter.export(
            PortableCatalogExportRequest(
                parentDirectoryURL: parentDirectoryURL,
                bundleName: PortableExportBundleNamer.bundleName(createdAtMs: createdAtMs),
                createdAtMs: createdAtMs,
                appVersion: appVersion
            )
        )
    }

    func fetchPreviewCacheUsage() throws -> DerivedImageCacheUsage {
        try derivedImageCache.cacheUsage()
    }

    func clearPreviewCache() async throws -> DerivedImageCacheClearResult {
        try await derivedImageCache.clearCache()
    }

    func fetchPhotosOriginalStorageUsage() throws -> PhotosOriginalStorageUsage {
        try photosOriginalCache.storageUsage()
    }

    func clearPhotosOriginalStorage() throws -> PhotosOriginalStorageClearResult {
        let hasActiveAnalysis = try queue.database.pool.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                SELECT EXISTS(
                    SELECT 1
                    FROM job
                    WHERE kind = ?
                      AND state IN ('pending', 'running')
                )
                """,
                arguments: [LibrarySlimmingAnalysisJobFactory.kind]
            ) ?? false
        }
        guard !hasActiveAnalysis else {
            throw ProductionLibraryWorkspaceError.librarySlimmingAnalysisInProgress
        }
        return try photosOriginalCache.clearAll()
    }

    func fetchAppStorageLocation() -> AppStorageLocationStatus {
        appStorageLocationController.activeStatus
    }

    @MainActor
    func chooseExternalAppStorageLocation() async throws -> AppStorageLocationSelectionResult {
        try await appStorageLocationController.chooseExternalLocation()
    }

    func fetchJobActivity() throws -> [JobActivityItem] {
        try queue.fetchActivityItems()
    }

    func applyJobActivityAction(_ action: JobActivityAction, jobID: UUID) throws {
        let operation: JobStateCommand.Operation
        switch action {
        case .pause:
            operation = .pause
        case .resume:
            operation = .resume(notBeforeMs: clock.nowMs)
        case .cancel:
            operation = .cancel
        }
        _ = try queue.applyStateCommand(JobStateCommand(jobID: jobID, operation: operation))
    }

    func fetchSources() throws -> [LibrarySourceSummary] {
        try photosConnection.fetchSources()
    }

    func fetchGalleryOverview() throws -> GalleryOverviewSnapshot {
        try query.fetchGalleryOverview()
    }

    func cachedWorldMapSnapshot(
        query request: WorldMapCatalogQuery
    ) -> WorldMapCatalogSnapshot? {
        worldMapSnapshotCache.snapshot(for: request)
    }

    func fetchWorldMapSnapshot(
        query request: WorldMapCatalogQuery
    ) throws -> WorldMapCatalogSnapshot {
        let snapshot = try GRDBWorldMapCatalogRepository(database: query.database)
            .fetchSnapshot(query: request)
        worldMapSnapshotCache.store(snapshot, for: request)
        return snapshot
    }

    func fetchWorldMapSelection(
        query request: WorldMapCatalogSelectionQuery
    ) throws -> WorldMapCatalogSelection {
        try GRDBWorldMapCatalogRepository(database: query.database)
            .fetchSelection(query: request)
    }

    func fetchWorldMapLocationBackfillSnapshots() throws
        -> [WorldMapLocationBackfillSnapshot]
    {
        try GRDBWorldMapLocationBackfillRepository(database: query.database)
            .fetchSnapshots()
    }

    func startWorldMapLocationBackfill(sourceID: UUID) throws {
        try worldMapLocationBackfillControl.start(sourceID: sourceID)
    }

    func cancelWorldMapLocationBackfill(sourceID: UUID) throws {
        try worldMapLocationBackfillControl.cancel(sourceID: sourceID)
    }

    func runPendingWorldMapLocationBackfill(
        sourceID: UUID,
        sourceKind: SourceKind
    ) throws {
        if sourceKind == .photos {
            try runPendingPhotosReconcileJobs(sourceIDs: [sourceID])
        } else {
            try runPendingReconcileJobs(sourceIDs: [sourceID])
        }
    }

    private var worldMapLocationBackfillControl: WorldMapLocationBackfillControl {
        WorldMapLocationBackfillControl(
            repository: GRDBWorldMapLocationBackfillRepository(database: query.database),
            queue: queue,
            clock: clock,
            enqueueFolder: { sourceID in
                try enqueueReconcile(sourceIDs: [sourceID])
            },
            requestPhotosFullRepair: { sourceID in
                // A location backfill must enumerate the existing Photos catalog;
                // a quiet incremental sync may otherwise have no change-token work.
                try photosConnection.requestFullRepair(sourceID: sourceID)
            }
        )
    }

    func fetchWorldMapPlaceTagResolutions() throws -> [WorldMapPlaceTagResolution] {
        try worldMapPlaceResolutionService.listTagResolutions()
    }

    func resolveWorldMapPlaceTag(
        tagID: UUID
    ) async throws -> WorldMapPlaceTagResolution {
        try await worldMapPlaceResolutionService.resolveTag(tagID: tagID)
    }

    func searchWorldMapPlaceTag(
        tagID: UUID,
        query: String
    ) async throws -> WorldMapPlaceTagResolution {
        try await worldMapManualPlaceResolutionService.resolveTag(tagID: tagID, query: query)
    }

    func confirmWorldMapPlaceCandidate(
        tagID: UUID,
        placeID: String
    ) throws -> WorldMapPlaceTagResolution {
        try worldMapPlaceResolutionService.confirmCandidate(tagID: tagID, placeID: placeID)
    }

    func ignoreWorldMapPlaceTag(tagID: UUID) throws -> WorldMapPlaceTagResolution {
        try worldMapPlaceResolutionService.ignoreTag(tagID: tagID)
    }

    private var worldMapPlaceResolutionService: WorldMapPlaceResolutionService {
        WorldMapPlaceResolutionService(
            database: query.database,
            resolver: MapKitWorldMapPlaceResolver(),
            clock: clock
        )
    }

    private var worldMapManualPlaceResolutionService: WorldMapPlaceResolutionService {
        WorldMapPlaceResolutionService(
            database: query.database,
            resolver: CascadingWorldMapPlaceResolver(
                primary: MapKitWorldMapPlaceResolver(),
                fallback: NominatimWorldMapPlaceResolver()
            ),
            clock: clock
        )
    }

    func connectFolder() async throws -> ConnectFolderOutcome {
        let outcome = try await authorization.connectFolder()
        try folderSourceMonitor.synchronize()
        return outcome
    }

    func connectPhotos() async throws -> ConnectPhotosOutcome {
        try await photosConnection.connect()
    }

    func syncPhotosLibrary(sourceID: UUID) async throws {
        try photosConnection.syncNow(sourceID: sourceID)
    }

    func requestPhotosFullRepair(sourceID: UUID) async throws {
        try photosConnection.requestFullRepair(sourceID: sourceID)
    }

    func photosLibrarySupportedImageCount() throws -> Int {
        try photosConnection.supportedStaticImageCount()
    }

    func photosCatalogAssetCount(sourceID: UUID) throws -> Int {
        try query.fetchPhotosCatalogAssetCount(sourceID: sourceID)
    }

    func reactivatePhotosLibrary(sourceID: UUID) async throws {
        try photosConnection.reactivate(sourceID: sourceID)
    }

    func restoreDefaultSourceAuthorizations() async throws {
        // Only soft-reactivate existing authorizationRequired sources.
        // Do not call photos connect() here — that can kick off heavy library
        // work during startup and freeze sidebar navigation.
        for source in try photosConnection.fetchSources()
            where source.kind == .photos && source.state == .authorizationRequired
        {
            try? photosConnection.reactivate(sourceID: source.id)
        }

        let folderSources = try sourceRepository.fetchAllFolderSources()
        for source in folderSources where source.state == .authorizationRequired {
            _ = try? authorization.attemptRestoreFolderAuthorization(sourceID: source.id)
        }
        // Restore security-scoped sessions for reads without enqueueing a
        // full-library reconcile for every newly activated folder source.
        try folderSourceMonitor.synchronize(enqueueInitialReconciles: false)
    }

    func rebindPhotos(unavailableSourceID: UUID) async throws -> RebindPhotosOutcome {
        try await photosConnection.rebind(unavailableSourceID: unavailableSourceID)
    }

    func reauthorizeFolder(sourceID: UUID) async throws -> ReauthorizeFolderOutcome {
        let outcome = try await authorization.reauthorizeFolder(sourceID: sourceID)
        try folderSourceMonitor.synchronize()
        return outcome
    }

    func disableFolderSource(sourceID: UUID) async throws -> DisableFolderOutcome {
        if try photosConnection.fetchSources().first(where: { $0.id == sourceID })?.kind == .photos {
            return try photosConnection.disable(sourceID: sourceID)
        }
        let outcome = try await authorization.disableFolderSource(sourceID: sourceID)
        try folderSourceMonitor.synchronize()
        return outcome
    }

    func deleteLibrarySource(sourceID: UUID) async throws -> DeleteLibrarySourceOutcome {
        if let interactiveIOGate {
            return try await interactiveIOGate.withInteractiveWork {
                try await deleteLibrarySourceWithExclusiveMutationWindow(
                    sourceID: sourceID
                )
            }
        }
        return try await deleteLibrarySourceWithExclusiveMutationWindow(
            sourceID: sourceID
        )
    }

    private func deleteLibrarySourceWithExclusiveMutationWindow(
        sourceID: UUID
    ) async throws -> DeleteLibrarySourceOutcome {
        let initialPreparation = try sourceDeletion.prepare(sourceID: sourceID)
        switch initialPreparation.kind {
        case .folder:
            _ = try await authorization.disableFolderSource(sourceID: sourceID)
            try folderSourceMonitor.synchronize(enqueueInitialReconciles: false)
        case .photos:
            _ = try photosConnection.disable(sourceID: sourceID)
        }
        // Disabling prevents new recycle intents. Re-read blockers and asset IDs
        // before deleting any App-owned cache so an operation that raced with the
        // initial preflight cannot cause a half-completed rejected deletion.
        let preparation = try sourceDeletion.prepare(sourceID: sourceID)
        guard preparation.kind == initialPreparation.kind else {
            throw DeleteLibrarySourceError.persistenceFailure
        }
        let outcome = try sourceDeletion.delete(preparation: preparation)
        if preparation.kind == .folder {
            try folderSourceMonitor.synchronize(enqueueInitialReconciles: false)
        }
        return outcome
    }

    func enqueueReconcile(sourceIDs: [UUID]) throws {
        let requested = Set(sourceIDs)
        for source in try sourceRepository.fetchAllFolderSources()
            where source.state == .active && requested.contains(source.id)
        {
            let command = try FolderReconcileJobFactory.makeEnqueueCommand(
                jobID: UUID(),
                sourceID: source.id,
                notBeforeMs: clock.nowMs
            )
            _ = try queue.enqueueOrReuseActive(command)
        }
        for source in try photosConnection.fetchSources()
            where source.kind == .photos && source.state == .active && requested.contains(source.id)
        {
            try photosConnection.enqueueReconcile(sourceID: source.id)
        }
    }

    func hasPendingCatalogReconcileJobs() throws -> Bool {
        try queue.hasBlockingReconcileWork(nowMs: clock.nowMs)
    }

    func sourceIsReconcileClean(sourceID: UUID) throws -> Bool {
        try queue.isSourceReconcileClean(sourceID: sourceID)
    }

    func fetchCatalogReconcileProgress() throws -> CatalogReconcileProgress? {
        try queue.database.pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT job.kind, job.source_id, job.progress_completed, job.progress_total,
                       source.display_name
                FROM job
                LEFT JOIN source ON source.id = job.source_id
                WHERE job.kind IN (?, ?)
                    AND job.state IN ('pending', 'running')
                ORDER BY
                    CASE job.state WHEN 'running' THEN 0 ELSE 1 END,
                    CASE job.kind WHEN ? THEN 0 ELSE 1 END,
                    job.priority DESC,
                    job.created_at_ms ASC
                LIMIT 1
                """,
                arguments: [
                    FolderReconcileJobFactory.kind,
                    PhotosReconcileJobFactory.kind,
                    FolderReconcileJobFactory.kind,
                ]
            ) else {
                return nil
            }
            let kind: String = row["kind"]
            let sourceIDString: String? = row["source_id"]
            return CatalogReconcileProgress(
                sourceKind: kind == PhotosReconcileJobFactory.kind ? .photos : .folder,
                sourceID: sourceIDString.flatMap(UUID.init(uuidString:)),
                sourceDisplayName: row["display_name"],
                completed: row["progress_completed"],
                total: row["progress_total"]
            )
        }
    }

    func runPendingReconcileJobs(sourceIDs: Set<UUID>?) throws {
        defer { try? folderSourceMonitor.synchronize() }
        let claim = ClaimNextInput(
            owner: "imageall-reconcile-\(UUID().uuidString.lowercased())",
            leaseDurationMs: FolderReconcileJobFactory.leaseDurationMs,
            allowedKinds: [FolderReconcileJobFactory.kind],
            allowedSourceIDs: sourceIDs
        )
        while let result = try executionCoordinator.claimAndExecuteOnce(claim) {
            guard result.snapshot.state == .completed
                    || result.snapshot.state == .cancelled
            else {
                throw ProductionLibraryWorkspaceError.reconcileFailed
            }
        }
    }

    func runPendingPhotosReconcileJobs(sourceIDs: Set<UUID>?) throws {
        let claim = ClaimNextInput(
            owner: "imageall-photos-reconcile-\(UUID().uuidString.lowercased())",
            leaseDurationMs: 60_000,
            allowedKinds: [PhotosReconcileJobFactory.kind],
            allowedSourceIDs: sourceIDs
        )
        while let result = try executionCoordinator.claimAndExecuteOnce(claim) {
            guard result.snapshot.state == .completed
                    || result.snapshot.state == .cancelled
            else {
                throw ProductionLibraryWorkspaceError.reconcileFailed
            }
        }
    }

    func runPendingLibrarySlimmingJobs() throws {
        let claim = ClaimNextInput(
            owner: "imageall-library-slimming-\(UUID().uuidString.lowercased())",
            leaseDurationMs: 60_000,
            allowedKinds: [LibrarySlimmingPurgeJobFactory.kind]
        )
        while let result = try executionCoordinator.claimAndExecuteOnce(claim) {
            guard result.snapshot.state == .completed else {
                throw ProductionLibraryWorkspaceError.librarySlimmingMaintenanceFailed
            }
        }
    }

    func runPendingPersonalizationJobs() throws {
        _ = try personalizationReview.runPendingSuggestionJobs(maxSteps: nil)
    }

    func fetchAssetPage(
        filter: AssetPageFilter,
        sort: AssetPageSort,
        cursor: AssetPageCursor?
    ) throws -> AssetPageResult {
        try query.fetchAssetPage(
            AssetPageRequest(
                filter: filter,
                sort: sort,
                cursor: cursor,
                limit: 100
            )
        )
    }

    func fetchFavoriteStates(assetIDs: [UUID]) throws -> [UUID: MediaFavoriteState] {
        let uniqueIDs = Array(Set(assetIDs))
        guard !uniqueIDs.isEmpty else { return [:] }
        var states = Dictionary(
            uniqueKeysWithValues: uniqueIDs.map { ($0, MediaFavoriteState.none(assetID: $0)) }
        )
        try query.database.pool.read { db in
            for chunk in uniqueIDs.favoriteChunks(size: 400) {
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT asset_id, desired_value, photos_observed_value,
                           sync_status, intent_revision, requested_at_ms,
                           photos_observed_modified_at_ms, last_error_code
                    FROM asset_favorite_state
                    WHERE asset_id IN (\(placeholders))
                    """,
                    arguments: StatementArguments(
                        chunk.map { $0.uuidString.lowercased() }
                    )
                )
                for row in rows {
                    guard let assetID = UUID(uuidString: row["asset_id"]),
                          let syncStatus = FavoriteSyncStatus(rawValue: row["sync_status"])
                    else { continue }
                    let observed: Int? = row["photos_observed_value"]
                    states[assetID] = MediaFavoriteState(
                        assetID: assetID,
                        isFavorite: (row["desired_value"] as Int) == 1,
                        photosObservedValue: observed.map { $0 == 1 },
                        syncStatus: syncStatus,
                        intentRevision: row["intent_revision"],
                        requestedAtMs: row["requested_at_ms"],
                        photosObservedModifiedAtMs: row["photos_observed_modified_at_ms"],
                        lastErrorCode: row["last_error_code"]
                    )
                }
            }
        }
        return states
    }

    func setFavorite(
        assetIDs: [UUID],
        isFavorite: Bool
    ) throws -> FavoriteMutationSummary {
        let uniqueIDs = Array(Set(assetIDs))
        guard !uniqueIDs.isEmpty else { return .zero }
        let nowMs = clock.nowMs
        var changedCount = 0
        var photosSourceIDs = Set<UUID>()
        try query.database.pool.write { db in
            for chunk in uniqueIDs.favoriteChunks(size: 400) {
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT asset.id, asset.source_id, asset.locator_kind,
                           favorite.desired_value, favorite.photos_observed_value,
                           favorite.sync_status, favorite.intent_revision
                    FROM asset
                    LEFT JOIN asset_favorite_state AS favorite
                      ON favorite.asset_id = asset.id
                    WHERE asset.id IN (\(placeholders))
                    """,
                    arguments: StatementArguments(
                        chunk.map { $0.uuidString.lowercased() }
                    )
                )
                for row in rows {
                    let assetID: String = row["id"]
                    let sourceIDRaw: String = row["source_id"]
                    let locatorKind: String = row["locator_kind"]
                    let existingDesired: Int? = row["desired_value"]
                    let observed: Int? = row["photos_observed_value"]
                    let oldProtected = existingDesired == 1 || observed == 1
                    let newDesired = isFavorite ? 1 : 0
                    let isPhotos = locatorKind == "photos"
                    let existingStatus: String? = row["sync_status"]
                    let needsNewIntent = existingDesired != newDesired
                        || (isPhotos && existingStatus == nil)
                    guard needsNewIntent else {
                        if isPhotos,
                           existingStatus == FavoriteSyncStatus.pending.rawValue
                                || existingStatus == FavoriteSyncStatus.failed.rawValue,
                           let sourceID = UUID(uuidString: sourceIDRaw)
                        {
                            photosSourceIDs.insert(sourceID)
                        }
                        continue
                    }
                    let oldRevision: Int = row["intent_revision"] ?? 0
                    let syncStatus: FavoriteSyncStatus = isPhotos ? .pending : .localOnly
                    try db.execute(
                        sql: """
                        INSERT INTO asset_favorite_state (
                            asset_id, desired_value, photos_observed_value,
                            sync_status, intent_revision, requested_at_ms,
                            photos_observed_modified_at_ms,
                            photos_write_modified_at_ms, last_error_code, updated_at_ms
                        ) VALUES (?, ?, ?, ?, ?, ?, NULL, NULL, NULL, ?)
                        ON CONFLICT(asset_id) DO UPDATE SET
                            desired_value = excluded.desired_value,
                            sync_status = excluded.sync_status,
                            intent_revision = excluded.intent_revision,
                            requested_at_ms = excluded.requested_at_ms,
                            photos_write_modified_at_ms = NULL,
                            last_error_code = NULL,
                            updated_at_ms = excluded.updated_at_ms
                        """,
                        arguments: [
                            assetID, newDesired, observed, syncStatus.rawValue,
                            oldRevision + 1, nowMs, nowMs,
                        ]
                    )
                    changedCount += 1
                    if isPhotos, let sourceID = UUID(uuidString: sourceIDRaw) {
                        photosSourceIDs.insert(sourceID)
                    } else if oldProtected, !isFavorite {
                        let resetPurgeAfterMs = nowMs + 30 * 24 * 60 * 60 * 1_000
                        try db.execute(
                            sql: """
                            UPDATE recycle_entry
                            SET trashed_at_ms = ?, purge_after_ms = ?, updated_at_ms = ?
                            WHERE asset_id = ? AND source_kind = 'file' AND state = 'recycled'
                            """,
                            arguments: [nowMs, resetPurgeAfterMs, nowMs, assetID]
                        )
                    }
                }
            }
        }
        if !photosSourceIDs.isEmpty {
            _ = try synchronizePendingFavorites(sourceIDs: photosSourceIDs)
        }
        let summary = try favoriteMutationSummary(assetIDs: uniqueIDs)
        return FavoriteMutationSummary(
            changedCount: changedCount,
            localOnlyCount: summary.localOnlyCount,
            syncedCount: summary.syncedCount,
            pendingCount: summary.pendingCount,
            failedCount: summary.failedCount
        )
    }

    func retryPendingFavoriteSync(
        sourceIDs: Set<UUID>?
    ) throws -> FavoriteMutationSummary {
        try synchronizePendingFavorites(sourceIDs: sourceIDs)
    }

    private func synchronizePendingFavorites(
        sourceIDs: Set<UUID>?
    ) throws -> FavoriteMutationSummary {
        struct PendingFavoriteIntent {
            let assetID: UUID
            let localIdentifier: String
            let desiredValue: Bool
            let intentRevision: Int
        }

        let intents: [PendingFavoriteIntent] = try query.database.pool.read { db in
            var arguments = StatementArguments()
            var sourceClause = ""
            if let sourceIDs, !sourceIDs.isEmpty {
                sourceClause = "AND asset.source_id IN (\(Array(repeating: "?", count: sourceIDs.count).joined(separator: ", ")))"
                for sourceID in sourceIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                    arguments += [sourceID.uuidString.lowercased()]
                }
            }
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT favorite.asset_id, asset.photos_local_identifier,
                       favorite.desired_value, favorite.intent_revision
                FROM asset_favorite_state AS favorite
                JOIN asset ON asset.id = favorite.asset_id
                WHERE asset.locator_kind = 'photos'
                  AND asset.locator_state = 'current'
                  AND favorite.sync_status IN ('pending', 'failed')
                  \(sourceClause)
                ORDER BY favorite.requested_at_ms, favorite.asset_id
                """,
                arguments: arguments
            )
            return rows.compactMap { row in
                guard let assetID = UUID(uuidString: row["asset_id"]),
                      let localIdentifier: String = row["photos_local_identifier"]
                else { return nil }
                return PendingFavoriteIntent(
                    assetID: assetID,
                    localIdentifier: localIdentifier,
                    desiredValue: (row["desired_value"] as Int) == 1,
                    intentRevision: row["intent_revision"]
                )
            }
        }
        guard !intents.isEmpty else { return .zero }

        for desiredValue in [false, true] {
            let matching = intents.filter { $0.desiredValue == desiredValue }
            for batch in matching.favoriteChunks(size: 50) {
                do {
                    let observations = try photosMutation.setFavorite(
                        localIdentifiers: batch.map(\.localIdentifier),
                        isFavorite: desiredValue
                    )
                    try query.database.pool.write { db in
                        for intent in batch {
                            guard let observation = observations[intent.localIdentifier] else {
                                continue
                            }
                            try db.execute(
                                sql: """
                                UPDATE asset_favorite_state
                                SET photos_observed_value = ?, sync_status = 'synced',
                                    photos_observed_modified_at_ms = ?,
                                    photos_write_modified_at_ms = ?,
                                    last_error_code = NULL, updated_at_ms = ?
                                WHERE asset_id = ? AND intent_revision = ?
                                  AND desired_value = ?
                                """,
                                arguments: [
                                    observation.isFavorite ? 1 : 0,
                                    observation.modifiedAtMs,
                                    observation.modifiedAtMs,
                                    clock.nowMs,
                                    intent.assetID.uuidString.lowercased(),
                                    intent.intentRevision,
                                    desiredValue ? 1 : 0,
                                ]
                            )
                        }
                    }
                } catch {
                    let failure = favoriteSyncFailure(error)
                    try query.database.pool.write { db in
                        for intent in batch {
                            try db.execute(
                                sql: """
                                UPDATE asset_favorite_state
                                SET sync_status = ?, last_error_code = ?, updated_at_ms = ?
                                WHERE asset_id = ? AND intent_revision = ?
                                  AND desired_value = ?
                                """,
                                arguments: [
                                    failure.keepPending ? FavoriteSyncStatus.pending.rawValue
                                        : FavoriteSyncStatus.failed.rawValue,
                                    failure.code,
                                    clock.nowMs,
                                    intent.assetID.uuidString.lowercased(),
                                    intent.intentRevision,
                                    desiredValue ? 1 : 0,
                                ]
                            )
                        }
                    }
                }
            }
        }
        return try favoriteMutationSummary(assetIDs: intents.map(\.assetID))
    }

    private func favoriteMutationSummary(
        assetIDs: [UUID]
    ) throws -> FavoriteMutationSummary {
        let states = try fetchFavoriteStates(assetIDs: assetIDs).values
        return FavoriteMutationSummary(
            changedCount: assetIDs.count,
            localOnlyCount: states.filter { $0.syncStatus == .localOnly }.count,
            syncedCount: states.filter { $0.syncStatus == .synced }.count,
            pendingCount: states.filter { $0.syncStatus == .pending }.count,
            failedCount: states.filter { $0.syncStatus == .failed }.count
        )
    }

    private func favoriteSyncFailure(
        _ error: Error
    ) -> (code: String, keepPending: Bool) {
        guard let mutationError = error as? PhotosLibraryMutationError else {
            return ("photosFavorite.persistenceFailure", true)
        }
        switch mutationError {
        case .authorizationDenied:
            return ("photosFavorite.authorizationDenied", false)
        case .authorizationRestricted:
            return ("photosFavorite.authorizationRestricted", false)
        case .notDetermined:
            return ("photosFavorite.authorizationNotDetermined", false)
        case .assetNotFound:
            return ("photosFavorite.assetNotFound", false)
        case .changeFailed:
            return ("photosFavorite.changeFailed", true)
        case let .systemChangeFailed(diagnostic):
            return (
                diagnostic.persistenceCode,
                diagnostic.category == .libraryUnavailable
            )
        }
    }

    func fetchAssetPage(
        filter: AssetPageFilter,
        sort: AssetPageSort,
        cursor: AssetPageCursor?,
        limit: Int
    ) throws -> AssetPageResult {
        try query.fetchAssetPage(
            AssetPageRequest(
                filter: filter,
                sort: sort,
                cursor: cursor,
                limit: limit
            )
        )
    }

    func loadThumbnail(assetID: UUID) async throws -> Data {
        try await assetImages.load(assetID: assetID, variant: .grid)
    }

    func loadThumbnailIfCached(assetID: UUID) async throws -> Data? {
        try await assetImages.loadThumbnailIfCached(assetID: assetID)
    }

    func loadOriginalAspectThumbnailIfCached(assetID: UUID) async throws -> Data? {
        try await assetImages.loadOriginalAspectThumbnailIfCached(assetID: assetID)
    }

    func cachedSquareThumbnailAssetIDs(sourceID: UUID) async throws -> Set<UUID> {
        try await cachedThumbnailAssetIDs(sourceID: sourceID, variant: .gridRegular)
    }

    func cachedOriginalAspectThumbnailAssetIDs(sourceID: UUID) async throws -> Set<UUID> {
        try await cachedThumbnailAssetIDs(sourceID: sourceID, variant: .gridOriginal)
    }

    private func cachedThumbnailAssetIDs(
        sourceID: UUID,
        variant: DerivedImageVariant
    ) async throws -> Set<UUID> {
        let database = queue.database
        return try await Task.detached(priority: .utility) {
            try database.pool.read { db in
                let rows = try String.fetchAll(
                    db,
                    sql: """
                    SELECT a.id
                    FROM asset a
                    JOIN derived_image_cache_entry e
                      ON e.asset_id = a.id
                     AND e.content_revision = a.content_revision
                    WHERE a.source_id = ?
                      AND a.locator_state = 'current'
                      AND e.representation_version = ?
                      AND e.variant = ?
                    ORDER BY a.id
                    """,
                    arguments: [
                        sourceID.uuidString.lowercased(),
                        DerivedImageRepresentationVersion.production,
                        variant.rawValue,
                    ]
                )
                return Set(rows.compactMap(UUID.init(uuidString:)))
            }
        }.value
    }

    func prewarmOriginalAspectThumbnail(assetID: UUID) async throws -> Data {
        try await assetImages.prewarmOriginalAspectThumbnail(assetID: assetID)
    }

    func prewarmRecycledFileThumbnail(assetID: UUID) async throws -> Data {
        try await derivedImageCache.loadOrGenerateRecycledFileThumbnail(
            assetID: assetID,
            quarantineRootURL: quarantineRootURL
        )
    }

    func loadPreview(assetID: UUID) async throws -> Data {
        try await assetImages.load(assetID: assetID, variant: .preview)
    }

    func downloadCloudPreview(
        assetID: UUID,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Data {
        try await assetImages.downloadCloudPreview(assetID: assetID, onProgress: onProgress)
    }

    func listTags() throws -> [TagListItem] {
        try tags.listTags(includeArchived: false)
    }

    func listTagsIncludingArchived() throws -> [TagListItem] {
        try tags.listTags(includeArchived: true)
    }

    func listTagGroups() throws -> [TagGroupListItem] {
        try tags.listTagGroups()
    }

    func installPresetTags() throws -> TagPresetInstallResult {
        let created = try tags.createMissingTags(
            rawNames: TagPresetCatalog.starterDisplayNames,
            timestampMs: clock.nowMs
        )
        return TagPresetInstallResult(
            createdTags: created.map {
                TagListItem(
                    id: $0.id,
                    displayName: $0.displayName,
                    state: $0.state,
                    groupID: TagGroupSeed.classify(displayName: $0.displayName).id
                )
            }
        )
    }

    func installStandardOntologyPackage(
        _ package: StandardOntologyPackageInput
    ) throws -> StandardOntologyInstallResult {
        try tags.installStandardOntologyPackage(package, timestampMs: clock.nowMs)
    }

    func fetchInspectorDetail(assetID: UUID) throws -> AssetInspectorDetail {
        try query.fetchInspectorDetail(assetID: assetID)
    }

    func selectionAggregate(tagIDs: [UUID], assetIDs: [UUID]) throws -> [TagSelectionAggregate] {
        try tags.selectionAggregate(tagIDs: tagIDs, assetIDs: assetIDs)
    }

    func mutateTag(
        tagID: UUID,
        assetIDs: [UUID],
        action: LibraryTagDecisionAction
    ) throws -> TagMutationPriorStateSnapshot {
        let result: TagMutationResult
        switch action {
        case .accept:
            result = try tags.batchAccept(tagID: tagID, assetIDs: assetIDs, timestampMs: clock.nowMs)
        case .reject:
            result = try tags.batchReject(tagID: tagID, assetIDs: assetIDs, timestampMs: clock.nowMs)
        case .clear:
            result = try tags.batchClear(tagID: tagID, assetIDs: assetIDs, timestampMs: clock.nowMs)
        }
        return TagMutationPriorStateSnapshot(tagID: tagID, priorStates: result.priorStates)
    }

    func restoreTagMutation(_ snapshot: TagMutationPriorStateSnapshot) throws {
        try tags.restorePriorStates(snapshot, timestampMs: clock.nowMs)
    }

    func createTagAndAccept(
        rawName: String,
        assetIDs: [UUID]
    ) throws -> TagCreateAndApplyResult {
        try tags.createTagAndApply(
            rawName: rawName,
            assetIDs: assetIDs,
            decision: .accepted,
            timestampMs: clock.nowMs
        )
    }

    func renameTag(tagID: UUID, rawName: String) throws -> TagListItem {
        _ = try tags.renameTag(tagID: tagID, rawName: rawName, timestampMs: clock.nowMs)
        let listed = try tags.listTags(includeArchived: true)
        guard let item = listed.first(where: { $0.id == tagID }) else {
            throw CatalogQueryError.notFound
        }
        return item
    }

    func archiveTag(tagID: UUID) throws {
        _ = try tags.archiveTag(tagID: tagID, timestampMs: clock.nowMs)
    }

    func moveTag(tagID: UUID, toGroupID: UUID) throws -> TagListItem {
        try tags.moveTag(tagID: tagID, toGroupID: toGroupID, timestampMs: clock.nowMs)
    }

    func createTagGroup(rawName: String) throws -> TagGroupListItem {
        try tags.createTagGroup(rawName: rawName, timestampMs: clock.nowMs)
    }

    func renameTagGroup(groupID: UUID, rawName: String) throws -> TagGroupListItem {
        try tags.renameTagGroup(groupID: groupID, rawName: rawName, timestampMs: clock.nowMs)
    }

    func deleteTagGroup(groupID: UUID) throws {
        try tags.deleteTagGroup(groupID: groupID, timestampMs: clock.nowMs)
    }
}

private struct LibraryOriginalAssetLocator: Sendable {
    let sourceID: UUID
    let sourceKind: SourceKind
    let locatorKind: AssetLocatorKind
    let mediaKind: MediaKind
    let relativePath: String?
    let photosLocalIdentifier: String?
    let availability: AssetAvailability
}

@MainActor
struct AppKitLibraryOriginalAssetOpener: LibraryOriginalAssetOpening {
    let database: CatalogDatabase
    let folderAuthorization: FolderAuthorizationCoordinator
    let photosLibrary: PhotoKitPhotosLibraryAdapter

    func openOriginalAsset(assetID: UUID) async throws {
        let locator = try fetchLibraryOriginalAssetLocator(
            database: database,
            assetID: assetID
        )
        guard locator.availability == .available else {
            throw LibraryOriginalAssetOpenError.unavailable
        }

        switch (locator.sourceKind, locator.locatorKind) {
        case (.folder, .file):
            guard let relativePath = locator.relativePath,
                  case let .success(validatedPath) = RelativePathRules.validate(relativePath)
            else {
                throw LibraryOriginalAssetOpenError.unsafeLocator
            }
            try folderAuthorization.accessFolderSource(sourceID: locator.sourceID) { rootURL in
                let url = rootURL.appendingPathComponent(validatedPath, isDirectory: false)
                if locator.mediaKind == .video {
                    try openWithSystemDefault(url)
                } else {
                    try openWithPreview(url)
                }
            }
        case (.photos, .photos):
            guard let localIdentifier = locator.photosLocalIdentifier else {
                throw LibraryOriginalAssetOpenError.unsafeLocator
            }
            if locator.mediaKind == .video {
                let originalURL = try await photosLibrary.requestOriginalVideoURL(
                    localIdentifier: localIdentifier
                )
                try openWithSystemDefault(originalURL)
            } else {
                let originalURL = try await photosLibrary.requestOriginalImageURL(
                    localIdentifier: localIdentifier
                )
                try openWithPreview(originalURL)
            }
        default:
            throw LibraryOriginalAssetOpenError.unsafeLocator
        }
    }

    private func openWithPreview(_ url: URL) throws {
        guard let previewURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Preview"
        ) else {
            throw LibraryOriginalAssetOpenError.previewUnavailable
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.promptsUserIfNeeded = true
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: previewURL,
            configuration: configuration,
            completionHandler: nil
        )
    }

    private func openWithSystemDefault(_ url: URL) throws {
        guard NSWorkspace.shared.open(url) else {
            throw LibraryOriginalAssetOpenError.previewUnavailable
        }
    }
}

@MainActor
struct AppKitLibraryVideoPlaybackProvider: LibraryVideoPlaybackProviding {
    let database: CatalogDatabase
    let folderAuthorization: FolderAuthorizationCoordinator
    let photosLibrary: PhotoKitPhotosLibraryAdapter

    func prepareVideoPlayback(assetID: UUID) async throws -> LibraryVideoPlaybackResource {
        let locator = try fetchLibraryOriginalAssetLocator(
            database: database,
            assetID: assetID
        )
        guard locator.availability == .available, locator.mediaKind == .video else {
            throw LibraryOriginalAssetOpenError.unavailable
        }

        switch (locator.sourceKind, locator.locatorKind) {
        case (.folder, .file):
            guard let relativePath = locator.relativePath,
                  case let .success(validatedPath) = RelativePathRules.validate(relativePath)
            else {
                throw LibraryOriginalAssetOpenError.unsafeLocator
            }
            let accessLease = try folderAuthorization.acquireFolderSourceAccess(
                sourceID: locator.sourceID
            )
            let url = accessLease.rootURL.appendingPathComponent(
                validatedPath,
                isDirectory: false
            )
            return LibraryVideoPlaybackResource(url: url) {
                accessLease.release()
            }
        case (.photos, .photos):
            guard let localIdentifier = locator.photosLocalIdentifier else {
                throw LibraryOriginalAssetOpenError.unsafeLocator
            }
            let url = try await photosLibrary.requestOriginalVideoURL(
                localIdentifier: localIdentifier
            )
            return LibraryVideoPlaybackResource(url: url)
        default:
            throw LibraryOriginalAssetOpenError.unsafeLocator
        }
    }
}

private func fetchLibraryOriginalAssetLocator(
    database: CatalogDatabase,
    assetID: UUID
) throws -> LibraryOriginalAssetLocator {
    try database.pool.read { db in
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT
                asset.source_id,
                source.kind AS source_kind,
                asset.locator_kind,
                asset.media_kind,
                asset.relative_path,
                asset.photos_local_identifier,
                asset.availability
            FROM asset
            INNER JOIN source ON source.id = asset.source_id
            WHERE asset.id = ? AND asset.locator_state = 'current'
            """,
            arguments: [assetID.uuidString.lowercased()]
        ),
            let sourceID = UUID(uuidString: row["source_id"]),
            let sourceKind = SourceKind(rawValue: row["source_kind"]),
            let locatorKind = AssetLocatorKind(rawValue: row["locator_kind"]),
            let mediaKind = MediaKind(rawValue: row["media_kind"]),
            let availability = AssetAvailability(rawValue: row["availability"])
        else {
            throw LibraryOriginalAssetOpenError.unavailable
        }
        return LibraryOriginalAssetLocator(
            sourceID: sourceID,
            sourceKind: sourceKind,
            locatorKind: locatorKind,
            mediaKind: mediaKind,
            relativePath: row["relative_path"],
            photosLocalIdentifier: row["photos_local_identifier"],
            availability: availability
        )
    }
}

private extension Array {
    func favoriteChunks(size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        var result: [[Element]] = []
        var index = startIndex
        while index < endIndex {
            let end = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(Array(self[index ..< end]))
            index = end
        }
        return result
    }
}
