import CryptoKit
import Foundation
import GRDB

/// ADR-045 policy identity for the per-source similarity index. Bumping `identityVersion`
/// (algorithm change) or the current `NearDuplicateSceneThresholds.featurePrintMaxL2Distance`
/// (threshold change) makes previously built indexes incompatible; callers must rebuild.
enum SourceSimilarityIndexPolicy {
    static let identityVersion = "source-similarity-index-v1"
    static let lshBitCount = 24
    static let neighborMaxHamming = 1
}

struct SourceSimilarityIndexService: SourceSimilarityIndexPort {
    let database: CatalogDatabase
    let queue: GRDBJobQueue
    let featureLoader: any SlimmingFeatureVectorLoading
    let thresholdReader: any NearDuplicateSceneThresholdReading
    let clock: any JobClock
    private let coordinator: JobExecutionCoordinator

    init(
        database: CatalogDatabase,
        queue: GRDBJobQueue,
        featureLoader: any SlimmingFeatureVectorLoading,
        thresholdReader: any NearDuplicateSceneThresholdReading = StaticNearDuplicateSceneThresholds(
            value: .factory
        ),
        clock: any JobClock
    ) {
        self.database = database
        self.queue = queue
        self.featureLoader = featureLoader
        self.thresholdReader = thresholdReader
        self.clock = clock
        let handler = SourceSimilarityIndexHandler(
            database: database,
            queue: queue,
            featureLoader: featureLoader,
            clock: clock
        )
        coordinator = JobExecutionCoordinator(
            queue: queue,
            registry: MultiJobHandlerRegistry(handlers: [handler]),
            leaseContextProvider: GRDBJobLeaseContextProvider(queue: queue)
        )
    }

    func status(sourceID: UUID) throws -> SourceSimilarityIndexStatus? {
        try status(sourceID: sourceID, mediaKind: .image)
    }

    func enqueueBuild(sourceID: UUID) throws -> UUID {
        try enqueueBuild(sourceID: sourceID, mediaKind: .image)
    }

    func candidateAssetIDs(
        seedAssetIDs: [UUID],
        universeAssetIDs: [UUID]
    ) throws -> SourceSimilarityCandidatePlan {
        try candidateAssetIDs(
            seedAssetIDs: seedAssetIDs,
            universeAssetIDs: universeAssetIDs,
            mediaKind: .image
        )
    }

    func status(sourceID: UUID, mediaKind: MediaKind) throws -> SourceSimilarityIndexStatus? {
        try database.pool.read { db in
            guard let row = try Self.fetchRow(
                db,
                sourceID: sourceID,
                mediaKind: mediaKind
            ) else { return nil }
            return row.status
        }
    }

    func enqueueBuild(sourceID: UUID, mediaKind: MediaKind) throws -> UUID {
        let jobID = UUID()
        let nowMs = clock.nowMs
        let command = try SourceSimilarityIndexJobFactory.makeCommand(
            jobID: jobID,
            sourceID: sourceID,
            mediaKind: mediaKind,
            notBeforeMs: nowMs
        )
        let assetCount = try database.pool.read { db in
            try Self.countAvailableAssets(db, sourceID: sourceID, mediaKind: mediaKind)
        }
        let maxL2 = thresholdReader.thresholds().clamped().featurePrintMaxL2Distance
        do {
            try database.pool.write { db in
                try JobInsertInTransaction.insertPendingJob(db, command: command, nowMs: nowMs)
                try Self.upsertBuildingRow(
                    db,
                    sourceID: sourceID,
                    mediaKind: mediaKind,
                    jobID: jobID,
                    assetCount: assetCount,
                    featurePrintMaxL2: maxL2,
                    nowMs: nowMs
                )
            }
        } catch JobQueueError.activeCoalescingConflict(let existingJobID) {
            return existingJobID
        }
        return jobID
    }

    func runPending() throws {
        try queue.settleRetryableJobs()
        let claim = ClaimNextInput(
            owner: "imageall-source-similarity-index-\(UUID().uuidString.lowercased())",
            leaseDurationMs: SourceSimilarityIndexJobFactory.leaseDurationMs,
            allowedKinds: [SourceSimilarityIndexJobFactory.kind]
        )
        while let execution = try coordinator.claimAndExecuteOnce(claim) {
            if execution.snapshot.state == .paused
                || execution.snapshot.state == .terminalFailed
                || execution.snapshot.state == .cancelled
            {
                break
            }
        }
    }

    func candidateAssetIDs(
        seedAssetIDs: [UUID],
        universeAssetIDs: [UUID],
        mediaKind: MediaKind
    ) throws -> SourceSimilarityCandidatePlan {
        let seeds = Array(Set(seedAssetIDs))
        let universe = Array(Set(universeAssetIDs).union(seeds))
        guard !seeds.isEmpty, !universe.isEmpty else { return .fullUniverse }

        let thresholds = thresholdReader.thresholds().clamped()

        let lookup: (assetSourceMap: [UUID: UUID], sourceRows: [UUID: SourceSimilarityIndexRow])? =
            try database.pool.read { db in
                guard let map = try Self.assetSourceMap(db, assetIDs: universe),
                      map.count == universe.count
                else {
                    return nil
                }
                var rows: [UUID: SourceSimilarityIndexRow] = [:]
                for sourceID in Set(map.values) {
                    guard let row = try Self.fetchRow(
                        db,
                        sourceID: sourceID,
                        mediaKind: mediaKind
                    ) else { return nil }
                    rows[sourceID] = row
                }
                return (map, rows)
            }
        guard let lookup else { return .fullUniverse }

        for row in lookup.sourceRows.values {
            guard row.state == SourceSimilarityIndexState.ready.rawValue,
                  Self.isCompatible(row: row, thresholds: thresholds)
            else {
                return .fullUniverse
            }
        }

        var neighborLookups: [(sourceID: UUID, neighborKeys: [Int64])] = []
        for seed in seeds {
            guard let sourceID = lookup.assetSourceMap[seed],
                  let row = lookup.sourceRows[sourceID],
                  let firstPlane = row.lshPlanes.first
            else {
                return .fullUniverse
            }
            guard let vector = try? featureLoader.featureVector(assetID: seed),
                  vector.count == firstPlane.count
            else {
                return .fullUniverse
            }
            let key = FeaturePrintLSH.bucketKey(vector: vector, planes: row.lshPlanes)
            let neighbors = FeaturePrintLSH.neighborKeys(
                key: key,
                bitCount: row.lshBitCount,
                maxHamming: SourceSimilarityIndexPolicy.neighborMaxHamming
            ).map { Int64(bitPattern: $0) }
            neighborLookups.append((sourceID, neighbors))
        }

        let universeSet = Set(universe)
        var candidates = Set(seeds)
        try database.pool.read { db in
            for (sourceID, neighborKeys) in neighborLookups {
                guard !neighborKeys.isEmpty else { continue }
                let placeholders = Array(repeating: "?", count: neighborKeys.count).joined(separator: ", ")
                var arguments: [DatabaseValueConvertible?] = [
                    sourceID.uuidString.lowercased(),
                    mediaKind.rawValue,
                ]
                arguments.append(contentsOf: neighborKeys as [DatabaseValueConvertible?])
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT bm.asset_id AS asset_id
                    FROM source_similarity_bucket_member bm
                    JOIN asset a ON a.id = bm.asset_id
                    WHERE bm.source_id = ?
                        AND bm.media_kind = ?
                        AND bm.bucket_key IN (\(placeholders))
                        AND bm.content_revision = a.content_revision
                    """,
                    arguments: StatementArguments(arguments)
                )
                for row in rows {
                    let raw: String = row["asset_id"]
                    guard let assetID = UUID(uuidString: raw), universeSet.contains(assetID) else { continue }
                    candidates.insert(assetID)
                }
            }
        }
        return .restricted(
            candidates: Array(candidates).sorted {
                $0.uuidString.lowercased() < $1.uuidString.lowercased()
            }
        )
    }

    private static func isCompatible(
        row: SourceSimilarityIndexRow,
        thresholds: NearDuplicateSceneThresholds
    ) -> Bool {
        row.policyVersion == SourceSimilarityIndexPolicy.identityVersion
            && row.lshBitCount == SourceSimilarityIndexPolicy.lshBitCount
            && row.featurePrintProvider == PersonalizationConstants.provider
            && row.featurePrintRequestRevision == PersonalizationConstants.requestRevision
            && row.featurePrintPreprocessingRevision == PersonalizationConstants.preprocessingRevision
            && abs(row.featurePrintMaxL2 - thresholds.featurePrintMaxL2Distance) < 0.0001
    }

    fileprivate static func assetSourceMap(_ db: Database, assetIDs: [UUID]) throws -> [UUID: UUID]? {
        guard !assetIDs.isEmpty else { return [:] }
        let idStrings = assetIDs.map { $0.uuidString.lowercased() }
        let placeholders = Array(repeating: "?", count: idStrings.count).joined(separator: ", ")
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT id, source_id FROM asset WHERE id IN (\(placeholders))",
            arguments: StatementArguments(idStrings)
        )
        var result: [UUID: UUID] = [:]
        for row in rows {
            let rawID: String = row["id"]
            let rawSourceID: String = row["source_id"]
            guard let assetID = UUID(uuidString: rawID), let sourceID = UUID(uuidString: rawSourceID) else {
                return nil
            }
            result[assetID] = sourceID
        }
        return result
    }

    fileprivate static func countAvailableAssets(
        _ db: Database,
        sourceID: UUID,
        mediaKind: MediaKind
    ) throws -> Int {
        try Int.fetchOne(
            db,
            sql: """
            SELECT COUNT(*) FROM asset
            WHERE source_id = ? AND media_kind = ?
              AND locator_state = 'current' AND availability = 'available'
            """,
            arguments: [sourceID.uuidString.lowercased(), mediaKind.rawValue]
        ) ?? 0
    }

    fileprivate static func upsertBuildingRow(
        _ db: Database,
        sourceID: UUID,
        mediaKind: MediaKind,
        jobID: UUID,
        assetCount: Int,
        featurePrintMaxL2: Double,
        nowMs: Int64
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO source_similarity_index (
                source_id, media_kind, state, policy_version, feature_print_provider,
                feature_print_request_revision, feature_print_preprocessing_revision,
                feature_print_max_l2, lsh_bit_count, lsh_planes_json,
                asset_count, indexed_count, cluster_count, pending_count,
                job_id, built_at_ms, updated_at_ms, last_error
            ) VALUES (?, ?, 'building', ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, ?, ?, NULL, ?, NULL)
            ON CONFLICT(source_id, media_kind) DO UPDATE SET
                state = 'building',
                policy_version = excluded.policy_version,
                feature_print_provider = excluded.feature_print_provider,
                feature_print_request_revision = excluded.feature_print_request_revision,
                feature_print_preprocessing_revision = excluded.feature_print_preprocessing_revision,
                feature_print_max_l2 = excluded.feature_print_max_l2,
                lsh_bit_count = excluded.lsh_bit_count,
                lsh_planes_json = excluded.lsh_planes_json,
                asset_count = excluded.asset_count,
                indexed_count = 0,
                cluster_count = 0,
                pending_count = excluded.pending_count,
                job_id = excluded.job_id,
                built_at_ms = NULL,
                updated_at_ms = excluded.updated_at_ms,
                last_error = NULL
            """,
            arguments: [
                sourceID.uuidString.lowercased(),
                mediaKind.rawValue,
                SourceSimilarityIndexPolicy.identityVersion,
                PersonalizationConstants.provider,
                PersonalizationConstants.requestRevision,
                PersonalizationConstants.preprocessingRevision,
                featurePrintMaxL2,
                SourceSimilarityIndexPolicy.lshBitCount,
                Data("[]".utf8),
                assetCount,
                assetCount,
                jobID.uuidString.lowercased(),
                nowMs,
            ]
        )
    }

    fileprivate static func fetchRow(
        _ db: Database,
        sourceID: UUID,
        mediaKind: MediaKind
    ) throws -> SourceSimilarityIndexRow? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT * FROM source_similarity_index
            WHERE source_id = ? AND media_kind = ?
            """,
            arguments: [sourceID.uuidString.lowercased(), mediaKind.rawValue]
        ) else {
            return nil
        }
        return try SourceSimilarityIndexRow(row: row)
    }
}

struct SourceSimilarityIndexRow {
    let sourceID: UUID
    let mediaKind: MediaKind
    let state: String
    let policyVersion: String
    let featurePrintProvider: String
    let featurePrintRequestRevision: Int
    let featurePrintPreprocessingRevision: Int
    let featurePrintMaxL2: Double
    let lshBitCount: Int
    let lshPlanes: [[Float]]
    let assetCount: Int
    let indexedCount: Int
    let clusterCount: Int
    let pendingCount: Int
    let updatedAtMs: Int64
    let lastError: String?

    init(row: Row) throws {
        let rawSourceID: String = row["source_id"]
        guard let sourceID = UUID(uuidString: rawSourceID) else {
            throw JobQueueError.unknownPersistedRawValue(field: "source_id", value: rawSourceID)
        }
        self.sourceID = sourceID
        let rawMediaKind: String = row["media_kind"]
        guard let mediaKind = MediaKind(rawValue: rawMediaKind) else {
            throw JobQueueError.unknownPersistedRawValue(
                field: "media_kind",
                value: rawMediaKind
            )
        }
        self.mediaKind = mediaKind
        state = row["state"]
        policyVersion = row["policy_version"]
        featurePrintProvider = row["feature_print_provider"]
        featurePrintRequestRevision = row["feature_print_request_revision"]
        featurePrintPreprocessingRevision = row["feature_print_preprocessing_revision"]
        featurePrintMaxL2 = row["feature_print_max_l2"]
        lshBitCount = row["lsh_bit_count"]
        let planesData: Data = row["lsh_planes_json"]
        lshPlanes = (try? JSONDecoder().decode([[Float]].self, from: planesData)) ?? []
        assetCount = row["asset_count"]
        indexedCount = row["indexed_count"]
        clusterCount = row["cluster_count"]
        pendingCount = row["pending_count"]
        updatedAtMs = row["updated_at_ms"]
        lastError = row["last_error"]
    }

    var status: SourceSimilarityIndexStatus {
        SourceSimilarityIndexStatus(
            sourceID: sourceID,
            mediaKind: mediaKind,
            state: SourceSimilarityIndexState(rawValue: state) ?? .failed,
            assetCount: assetCount,
            indexedCount: indexedCount,
            clusterCount: clusterCount,
            pendingCount: pendingCount,
            updatedAtMs: updatedAtMs,
            lastError: lastError
        )
    }
}

enum SourceSimilarityIndexJobFactory {
    static let kind = "librarySlimming.sourceIndex.v1"
    static let payloadVersion = 1
    static let checkpointVersion = 1
    static let priority = 10
    static let maxAttempts = 3
    static let vectorBatchSize = 32
    static let leaseDurationMs: Int64 = 10 * 60 * 1_000

    struct Payload: Codable, Sendable, Equatable {
        let sourceID: UUID
        let mediaKind: MediaKind

        init(sourceID: UUID, mediaKind: MediaKind = .image) {
            self.sourceID = sourceID
            self.mediaKind = mediaKind
        }

        private enum CodingKeys: String, CodingKey {
            case sourceID
            case mediaKind
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            sourceID = try values.decode(UUID.self, forKey: .sourceID)
            mediaKind = try values.decodeIfPresent(MediaKind.self, forKey: .mediaKind) ?? .image
        }
    }

    enum Phase: String, Codable, Sendable {
        case vectors
        case clustering
    }

    struct Checkpoint: Codable, Sendable, Equatable {
        var phase: Phase
        var nextOffset: Int
        var totalAssetCount: Int
        var dimension: Int?
    }

    static func coalescingKey(sourceID: UUID, mediaKind: MediaKind = .image) -> String {
        let base = "sourceSimilarityIndex:\(sourceID.uuidString.lowercased())"
        return mediaKind == .image ? base : "\(base):\(mediaKind.rawValue)"
    }

    static func makeCommand(
        jobID: UUID,
        sourceID: UUID,
        mediaKind: MediaKind = .image,
        notBeforeMs: Int64
    ) throws -> EnqueueJobCommand {
        EnqueueJobCommand(
            id: jobID,
            kind: kind,
            payloadVersion: payloadVersion,
            payload: try JSONEncoder().encode(Payload(sourceID: sourceID, mediaKind: mediaKind)),
            sourceID: sourceID,
            coalescingKey: coalescingKey(sourceID: sourceID, mediaKind: mediaKind),
            priority: priority,
            maxAttempts: maxAttempts,
            notBeforeMs: notBeforeMs
        )
    }

    static func decodePayload(_ data: Data) throws -> Payload {
        try JSONDecoder().decode(Payload.self, from: data)
    }

    static func decodeCheckpoint(_ checkpoint: JobCheckpoint?) throws -> Checkpoint? {
        guard let checkpoint else { return nil }
        guard checkpoint.version == checkpointVersion else {
            throw JobQueueError.unsupportedCheckpointVersion(kind: kind, version: checkpoint.version)
        }
        return try JSONDecoder().decode(Checkpoint.self, from: checkpoint.data)
    }

    static func encodeCheckpoint(_ value: Checkpoint) throws -> JobCheckpoint {
        JobCheckpoint(version: checkpointVersion, data: try JSONEncoder().encode(value))
    }
}

private struct SourceSimilarityIndexHandler: LeaseBoundJobHandler {
    let database: CatalogDatabase
    let queue: GRDBJobQueue
    let featureLoader: any SlimmingFeatureVectorLoading
    let clock: any JobClock

    var kind: String { SourceSimilarityIndexJobFactory.kind }
    var supportedPayloadVersions: Set<Int> { [SourceSimilarityIndexJobFactory.payloadVersion] }
    var supportedCheckpointVersions: Set<Int> { [SourceSimilarityIndexJobFactory.checkpointVersion] }

    func execute(
        payloadVersion: Int,
        payload: Data,
        checkpoint: JobCheckpoint?
    ) -> JobHandlerExecutionResult {
        failure(checkpoint: checkpoint)
    }

    func execute(
        lease: JobLeaseToken,
        payloadVersion: Int,
        payload: Data,
        checkpoint: JobCheckpoint?,
        context: JobLeaseExecutionContext
    ) throws -> JobHandlerExecutionResult {
        _ = context
        guard payloadVersion == SourceSimilarityIndexJobFactory.payloadVersion else {
            return failure(checkpoint: checkpoint)
        }
        let decoded: SourceSimilarityIndexJobFactory.Payload
        do {
            decoded = try SourceSimilarityIndexJobFactory.decodePayload(payload)
        } catch {
            return failure(checkpoint: checkpoint)
        }
        let sourceID = decoded.sourceID
        let mediaKind = decoded.mediaKind

        do {
            var state = try SourceSimilarityIndexJobFactory.decodeCheckpoint(checkpoint)
            if state == nil {
                let total = try database.pool.read { db in
                    try SourceSimilarityIndexService.countAvailableAssets(
                        db,
                        sourceID: sourceID,
                        mediaKind: mediaKind
                    )
                }
                try database.pool.write { db in
                    try db.execute(
                        sql: """
                        DELETE FROM source_similarity_bucket_member
                        WHERE source_id = ? AND media_kind = ?
                        """,
                        arguments: [sourceID.uuidString.lowercased(), mediaKind.rawValue]
                    )
                }
                state = SourceSimilarityIndexJobFactory.Checkpoint(
                    phase: .vectors,
                    nextOffset: 0,
                    totalAssetCount: total,
                    dimension: nil
                )
            }
            var current = state!
            let progressTotal = current.totalAssetCount + 1

            while true {
                if try hasControlRequest(jobID: lease.jobID) {
                    return JobHandlerExecutionResult(
                        outcome: .continue,
                        checkpoint: try SourceSimilarityIndexJobFactory.encodeCheckpoint(current),
                        progress: progress(state: current, progressTotal: progressTotal)
                    )
                }
                switch current.phase {
                case .vectors:
                    let batch = try listAssets(
                        sourceID: sourceID,
                        mediaKind: mediaKind,
                        offset: current.nextOffset,
                        limit: SourceSimilarityIndexJobFactory.vectorBatchSize
                    )
                    if batch.isEmpty {
                        current.phase = .clustering
                        current.nextOffset = 0
                        continue
                    }
                    var cachedPlanes: [[Float]]?
                    for member in batch {
                        guard let vector = try? featureLoader.featureVector(assetID: member.assetID) else {
                            continue
                        }
                        if current.dimension == nil {
                            current.dimension = vector.count
                            try persistPlanes(
                                sourceID: sourceID,
                                mediaKind: mediaKind,
                                dimension: vector.count
                            )
                            cachedPlanes = nil
                        }
                        guard vector.count == current.dimension else { continue }
                        if cachedPlanes == nil {
                            cachedPlanes = try loadPlanes(
                                sourceID: sourceID,
                                mediaKind: mediaKind
                            )
                        }
                        guard let planes = cachedPlanes, !planes.isEmpty else { continue }
                        let key = FeaturePrintLSH.bucketKey(vector: vector, planes: planes)
                        try insertMember(
                            sourceID: sourceID,
                            mediaKind: mediaKind,
                            assetID: member.assetID,
                            contentRevision: member.contentRevision,
                            bucketKey: key
                        )
                    }
                    current.nextOffset += batch.count
                    if let settled = try commitProgress(
                        lease: lease,
                        state: current,
                        progressTotal: progressTotal
                    ) {
                        return settled
                    }
                case .clustering:
                    let (clusterCount, indexedCount) = try clusterAndFinalize(
                        sourceID: sourceID,
                        mediaKind: mediaKind
                    )
                    let finalCheckpoint = try SourceSimilarityIndexJobFactory.encodeCheckpoint(current)
                    let finalProgress = JobProgress(completed: progressTotal, total: progressTotal)
                    _ = try queue.commitLeaseProtectedBatch(
                        input: SafeBatchCommitInput(
                            lease: lease,
                            outcome: .completed,
                            checkpoint: finalCheckpoint,
                            progress: finalProgress,
                            leaseDurationMs: SourceSimilarityIndexJobFactory.leaseDurationMs
                        )
                    ) { db in
                        try markReady(
                            db,
                            sourceID: sourceID,
                            mediaKind: mediaKind,
                            assetCount: current.totalAssetCount,
                            indexedCount: indexedCount,
                            clusterCount: clusterCount,
                            nowMs: clock.nowMs
                        )
                    }
                    return JobHandlerExecutionResult(
                        outcome: .completed,
                        checkpoint: finalCheckpoint,
                        progress: finalProgress,
                        settledByHandler: true
                    )
                }
            }
        } catch {
            let message = String(describing: error)
            try? database.pool.write { db in
                try markFailed(
                    db,
                    sourceID: sourceID,
                    mediaKind: mediaKind,
                    message: message,
                    nowMs: clock.nowMs
                )
            }
            let persisted = try? queue.fetchJob(id: lease.jobID)
            return JobHandlerExecutionResult(
                outcome: .nonRetryableFailure(code: .librarySlimmingSourceIndexFailed),
                checkpoint: persisted?.checkpoint ?? checkpoint,
                progress: persisted?.progress ?? JobProgress(completed: 0, total: nil)
            )
        }
    }

    private struct Member {
        let assetID: UUID
        let contentRevision: Int
    }

    private func listAssets(
        sourceID: UUID,
        mediaKind: MediaKind,
        offset: Int,
        limit: Int
    ) throws -> [Member] {
        try database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, content_revision FROM asset
                WHERE source_id = ? AND media_kind = ?
                  AND locator_state = 'current' AND availability = 'available'
                ORDER BY id ASC
                LIMIT ? OFFSET ?
                """,
                arguments: [
                    sourceID.uuidString.lowercased(),
                    mediaKind.rawValue,
                    limit,
                    offset,
                ]
            )
            return rows.compactMap { row -> Member? in
                let rawID: String = row["id"]
                guard let assetID = UUID(uuidString: rawID) else { return nil }
                return Member(assetID: assetID, contentRevision: row["content_revision"])
            }
        }
    }

    private func persistPlanes(sourceID: UUID, mediaKind: MediaKind, dimension: Int) throws {
        guard let row = try database.pool.read({ db in
            try SourceSimilarityIndexService.fetchRow(
                db,
                sourceID: sourceID,
                mediaKind: mediaKind
            )
        }) else {
            return
        }
        let seed = "\(row.policyVersion)|bits=\(row.lshBitCount)|dim=\(dimension)"
        let planes = FeaturePrintLSH.generatePlanes(seed: seed, bitCount: row.lshBitCount, dimension: dimension)
        let json = try JSONEncoder().encode(planes)
        try database.pool.write { db in
            try db.execute(
                sql: """
                UPDATE source_similarity_index SET lsh_planes_json = ?, updated_at_ms = ?
                WHERE source_id = ? AND media_kind = ?
                """,
                arguments: [
                    json,
                    clock.nowMs,
                    sourceID.uuidString.lowercased(),
                    mediaKind.rawValue,
                ]
            )
        }
    }

    private func loadPlanes(sourceID: UUID, mediaKind: MediaKind) throws -> [[Float]] {
        guard let row = try database.pool.read({ db in
            try SourceSimilarityIndexService.fetchRow(
                db,
                sourceID: sourceID,
                mediaKind: mediaKind
            )
        }) else {
            return []
        }
        return row.lshPlanes
    }

    private func loadMaxL2(sourceID: UUID, mediaKind: MediaKind) throws -> Double {
        guard let row = try database.pool.read({ db in
            try SourceSimilarityIndexService.fetchRow(
                db,
                sourceID: sourceID,
                mediaKind: mediaKind
            )
        }) else {
            return NearDuplicateScenePolicy.featurePrintMaxL2Distance
        }
        return row.featurePrintMaxL2
    }

    private func insertMember(
        sourceID: UUID,
        mediaKind: MediaKind,
        assetID: UUID,
        contentRevision: Int,
        bucketKey: UInt64
    ) throws {
        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO source_similarity_bucket_member (
                    source_id, media_kind, asset_id, content_revision, bucket_key, cluster_id
                ) VALUES (?, ?, ?, ?, ?, NULL)
                ON CONFLICT(source_id, media_kind, asset_id) DO UPDATE SET
                    content_revision = excluded.content_revision,
                    bucket_key = excluded.bucket_key,
                    cluster_id = NULL
                """,
                arguments: [
                    sourceID.uuidString.lowercased(),
                    mediaKind.rawValue,
                    assetID.uuidString.lowercased(),
                    contentRevision,
                    Int64(bitPattern: bucketKey),
                ]
            )
        }
    }

    private func clusterAndFinalize(
        sourceID: UUID,
        mediaKind: MediaKind
    ) throws -> (clusterCount: Int, indexedCount: Int) {
        let maxL2 = try loadMaxL2(sourceID: sourceID, mediaKind: mediaKind)
        let members = try database.pool.read { db -> [(assetID: UUID, bucketKey: Int64)] in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT asset_id, bucket_key
                FROM source_similarity_bucket_member
                WHERE source_id = ? AND media_kind = ?
                """,
                arguments: [sourceID.uuidString.lowercased(), mediaKind.rawValue]
            )
            return rows.compactMap { row -> (assetID: UUID, bucketKey: Int64)? in
                let rawID: String = row["asset_id"]
                guard let assetID = UUID(uuidString: rawID) else { return nil }
                let bucketKey: Int64 = row["bucket_key"]
                return (assetID, bucketKey)
            }
        }

        var byBucket: [Int64: [UUID]] = [:]
        for member in members {
            byBucket[member.bucketKey, default: []].append(member.assetID)
        }

        var clusterAssignments: [UUID: String] = [:]
        for assetIDs in byBucket.values {
            guard assetIDs.count >= 2 else { continue }
            let sorted = assetIDs.sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
            var vectors: [UUID: [Float]] = [:]
            for assetID in sorted {
                if let vector = try? featureLoader.featureVector(assetID: assetID) {
                    vectors[assetID] = vector
                }
            }
            var adjacency: [UUID: Set<UUID>] = Dictionary(uniqueKeysWithValues: sorted.map { ($0, []) })
            for i in 0..<sorted.count {
                guard let leftVector = vectors[sorted[i]] else { continue }
                for j in (i + 1)..<sorted.count {
                    guard let rightVector = vectors[sorted[j]],
                          let distance = SimilarityVectorMath.l2Distance(leftVector, rightVector),
                          distance <= maxL2
                    else { continue }
                    adjacency[sorted[i], default: []].insert(sorted[j])
                    adjacency[sorted[j], default: []].insert(sorted[i])
                }
            }

            var visited: Set<UUID> = []
            for assetID in sorted {
                if visited.contains(assetID) { continue }
                var component: [UUID] = []
                var stack = [assetID]
                while let node = stack.popLast() {
                    if visited.contains(node) { continue }
                    visited.insert(node)
                    component.append(node)
                    for neighbor in adjacency[node] ?? [] where !visited.contains(neighbor) {
                        stack.append(neighbor)
                    }
                }
                guard component.count >= 2 else { continue }
                let sortedComponent = component.sorted {
                    $0.uuidString.lowercased() < $1.uuidString.lowercased()
                }
                let clusterID = Self.stableClusterID(members: sortedComponent).uuidString.lowercased()
                for member in sortedComponent {
                    clusterAssignments[member] = clusterID
                }
            }
        }

        try database.pool.write { db in
            for (assetID, clusterID) in clusterAssignments {
                try db.execute(
                    sql: """
                    UPDATE source_similarity_bucket_member SET cluster_id = ?
                    WHERE source_id = ? AND media_kind = ? AND asset_id = ?
                    """,
                    arguments: [
                        clusterID,
                        sourceID.uuidString.lowercased(),
                        mediaKind.rawValue,
                        assetID.uuidString.lowercased(),
                    ]
                )
            }
        }

        return (Set(clusterAssignments.values).count, members.count)
    }

    private static func stableClusterID(members: [UUID]) -> UUID {
        let material = (["sourceSimilarityCluster"] + members.map { $0.uuidString.lowercased() })
            .joined(separator: "|")
        let digest = SHA256.hash(data: Data(material.utf8))
        let bytes = Array(digest)
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            )
        )
    }

    private func markReady(
        _ db: Database,
        sourceID: UUID,
        mediaKind: MediaKind,
        assetCount: Int,
        indexedCount: Int,
        clusterCount: Int,
        nowMs: Int64
    ) throws {
        try db.execute(
            sql: """
            UPDATE source_similarity_index SET
                state = 'ready',
                asset_count = ?,
                indexed_count = ?,
                cluster_count = ?,
                pending_count = ?,
                built_at_ms = ?,
                updated_at_ms = ?,
                last_error = NULL
            WHERE source_id = ? AND media_kind = ?
            """,
            arguments: [
                assetCount,
                indexedCount,
                clusterCount,
                max(0, assetCount - indexedCount),
                nowMs,
                nowMs,
                sourceID.uuidString.lowercased(),
                mediaKind.rawValue,
            ]
        )
    }

    private func markFailed(
        _ db: Database,
        sourceID: UUID,
        mediaKind: MediaKind,
        message: String,
        nowMs: Int64
    ) throws {
        try db.execute(
            sql: """
            UPDATE source_similarity_index SET state = 'failed', last_error = ?, updated_at_ms = ?
            WHERE source_id = ? AND media_kind = ?
            """,
            arguments: [
                String(message.prefix(500)),
                nowMs,
                sourceID.uuidString.lowercased(),
                mediaKind.rawValue,
            ]
        )
    }

    private func hasControlRequest(jobID: UUID) throws -> Bool {
        try queue.fetchJob(id: jobID).controlRequest != .none
    }

    private func progress(
        state: SourceSimilarityIndexJobFactory.Checkpoint,
        progressTotal: Int
    ) -> JobProgress {
        let completed: Int = switch state.phase {
        case .vectors:
            min(state.nextOffset, state.totalAssetCount)
        case .clustering:
            state.totalAssetCount
        }
        return JobProgress(completed: completed, total: progressTotal)
    }

    private func commitProgress(
        lease: JobLeaseToken,
        state: SourceSimilarityIndexJobFactory.Checkpoint,
        progressTotal: Int
    ) throws -> JobHandlerExecutionResult? {
        let checkpoint = try SourceSimilarityIndexJobFactory.encodeCheckpoint(state)
        let progressValue = progress(state: state, progressTotal: progressTotal)
        let snapshot = try queue.submitSafeBatch(
            SafeBatchCommitInput(
                lease: lease,
                outcome: .continue,
                checkpoint: checkpoint,
                progress: progressValue,
                leaseDurationMs: SourceSimilarityIndexJobFactory.leaseDurationMs
            )
        )
        guard snapshot.state != .running else { return nil }
        return JobHandlerExecutionResult(
            outcome: .continue,
            checkpoint: checkpoint,
            progress: progressValue,
            settledByHandler: true
        )
    }

    private func failure(checkpoint: JobCheckpoint?) -> JobHandlerExecutionResult {
        JobHandlerExecutionResult(
            outcome: .nonRetryableFailure(code: .librarySlimmingSourceIndexFailed),
            checkpoint: checkpoint,
            progress: JobProgress(completed: 0, total: nil)
        )
    }
}
