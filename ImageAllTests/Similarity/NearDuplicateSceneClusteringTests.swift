import XCTest
@testable import ImageAll

final class NearDuplicateSceneClusteringTests: XCTestCase {
    private let sceneModelIdentity = SlimmingVectorModelIdentity(
        featurePrintProvider: PersonalizationConstants.provider,
        featurePrintRequestRevision: PersonalizationConstants.requestRevision,
        featurePrintPreprocessingRevision: PersonalizationConstants.preprocessingRevision,
        embeddingProvider: "dinov2",
        embeddingModelID: "facebook/dinov2-small",
        embeddingModelRevision: "model-v1",
        embeddingPreprocessingRevision: "preprocessing-v1",
        perceptualAlgoVersion: nil,
        policyVersion: NearDuplicateScenePolicy.policyVersion
    )

    func testFeaturePrintRecallAndDINORefineFormsSceneCluster() throws {
        let a = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let b = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        let c = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!

        let featurePrints: [UUID: [Float]] = [
            a: [1, 0, 0, 0],
            b: [0.98, 0.02, 0, 0],
            c: [0, 0, 1, 0],
        ]
        let embeddings: [UUID: [Float]] = [
            a: [1, 0, 0],
            b: [0.99, 0.01, 0],
            c: [0, 1, 0],
        ]

        let clusters = NearDuplicateSceneClusterService().cluster(
            featurePrints: featurePrints,
            embeddings: embeddings,
            modelIdentity: sceneModelIdentity
        )
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].kind, .nearDuplicateScene)
        XCTAssertEqual(Set(clusters[0].memberAssetIDs), Set([a, b]))
        XCTAssertGreaterThanOrEqual(
            clusters[0].score,
            NearDuplicateScenePolicy.dinoCosineMinSimilarity
        )
        XCTAssertTrue(clusters[0].modelIdentity.revisionCaption.contains("fp:vision-feature-print/r2"))
        XCTAssertTrue(clusters[0].modelIdentity.revisionCaption.contains("dino:dinov2/"))
    }

    func testDINOBelowThresholdDoesNotClusterDespiteCloseFeaturePrint() throws {
        let a = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let b = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!

        let featurePrints: [UUID: [Float]] = [
            a: [1, 0],
            b: [0.99, 0.01],
        ]
        let embeddings: [UUID: [Float]] = [
            a: [1, 0],
            b: [0, 1],
        ]

        let clusters = NearDuplicateSceneClusterService().cluster(
            featurePrints: featurePrints,
            embeddings: embeddings,
            modelIdentity: sceneModelIdentity
        )
        XCTAssertTrue(clusters.isEmpty)
    }

    func testBridgePairDoesNotMergeIntoThreeMemberClusterUnderCompleteLinkage() throws {
        let a = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let b = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        let c = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!

        let featurePrints: [UUID: [Float]] = [
            a: [1, 0, 0],
            b: [0.99, 0.01, 0],
            c: [0.98, 0.02, 0],
        ]
        let angle28 = 28.0 * Double.pi / 180.0
        let angle56 = 56.0 * Double.pi / 180.0
        let embeddings: [UUID: [Float]] = [
            a: [1, 0],
            b: [Float(cos(angle28)), Float(sin(angle28))],
            c: [Float(cos(angle56)), Float(sin(angle56))],
        ]

        let clusters = NearDuplicateSceneClusterService().cluster(
            featurePrints: featurePrints,
            embeddings: embeddings,
            modelIdentity: sceneModelIdentity
        )
        XCTAssertFalse(clusters.contains(where: { $0.memberAssetIDs.count == 3 }))
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].memberAssetIDs.count, 2)
    }

    func testLargeUnknownDateStyleBucketBoundsFeatureDistanceWorkAndKeepsClosePair() {
        let count = 1_024
        let ids = (0..<count).map { index in
            UUID(uuidString: String(format: "00000000-0000-4000-8000-%012x", index + 1))!
        }
        let closeA = ids[0]
        let closeB = ids[1]
        var featurePrints: [UUID: [Float]] = [:]
        var embeddings: [UUID: [Float]] = [:]

        for (index, id) in ids.enumerated() {
            if index < 2 {
                featurePrints[id] = [1, 0, 0, 0, 0, 0, 0, 0]
                embeddings[id] = [1, 0, 0, 0]
                continue
            }
            featurePrints[id] = (0..<8).map { dimension in
                Float(((index * 37 + dimension * 19) % 211) - 105) / 105
            }
            embeddings[id] = (0..<4).map { dimension in
                Float(((index * 17 + dimension * 23) % 97) - 48) / 48
            }
        }

        final class EvaluationCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var storedValue = 0

            func increment() {
                lock.lock()
                storedValue += 1
                lock.unlock()
            }

            var value: Int {
                lock.lock()
                defer { lock.unlock() }
                return storedValue
            }
        }
        let evaluations = EvaluationCounter()

        var thresholds = NearDuplicateSceneThresholds.factory
        thresholds.featurePrintMaxL2Distance = 0.05
        let clusters = NearDuplicateSceneClusterService().cluster(
            featurePrints: featurePrints,
            embeddings: embeddings,
            modelIdentity: sceneModelIdentity,
            thresholds: thresholds,
            onFeatureDistanceEvaluation: {
                evaluations.increment()
            }
        )

        XCTAssertLessThanOrEqual(
            evaluations.value,
            count * NearDuplicateScenePolicy.largeBucketCandidateLimit
        )
        XCTAssertTrue(
            clusters.contains {
                Set($0.memberAssetIDs).isSuperset(of: [closeA, closeB])
            },
            "bounded recall must retain an obvious close pair"
        )
    }

    func testAllCandidateRecallBypassesLargeBucketCandidateLimit() {
        let count = NearDuplicateScenePolicy.largeBucketActivationAssetCount + 1
        let ids = (0..<count).map { index in
            UUID(uuidString: String(format: "10000000-0000-4000-8000-%012x", index + 1))!
        }
        let featurePrints = Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
            (id, [Float(index), Float(index % 7)])
        })
        let embeddings = Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
            let angle = Double(index + 1) * .pi / Double(count + 1)
            return (id, [Float(cos(angle)), Float(sin(angle))])
        })

        final class EvaluationCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var storedValue = 0

            func increment() {
                lock.lock()
                storedValue += 1
                lock.unlock()
            }

            var value: Int {
                lock.lock()
                defer { lock.unlock() }
                return storedValue
            }
        }
        let evaluations = EvaluationCounter()
        var thresholds = NearDuplicateSceneThresholds.factory
        thresholds.featurePrintRecallMode = .allCandidates
        thresholds.dinoCosineMinSimilarity = 1

        _ = NearDuplicateSceneClusterService().cluster(
            featurePrints: featurePrints,
            embeddings: embeddings,
            modelIdentity: sceneModelIdentity,
            thresholds: thresholds,
            onFeatureDistanceEvaluation: {
                evaluations.increment()
            }
        )

        XCTAssertEqual(evaluations.value, count * (count - 1))
    }

    func testUnlimitedL2AndDINOExtremesHaveLiteralSemantics() {
        let a = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let b = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        let featurePrints: [UUID: [Float]] = [
            a: [0, 0],
            b: [1_000, 0],
        ]
        let embeddings: [UUID: [Float]] = [
            a: [1, 0],
            b: [0, 1],
        ]

        var thresholds = NearDuplicateSceneThresholds.factory
        thresholds.featurePrintL2Mode = .unlimited
        thresholds.dinoCosineMode = .unlimited
        let unlimited = NearDuplicateSceneClusterService().cluster(
            featurePrints: featurePrints,
            embeddings: embeddings,
            modelIdentity: sceneModelIdentity,
            thresholds: thresholds
        )
        XCTAssertEqual(unlimited.count, 1)

        thresholds.featurePrintL2Mode = .radius
        thresholds.featurePrintMaxL2Distance = 0
        let exactL2Only = NearDuplicateSceneClusterService().cluster(
            featurePrints: featurePrints,
            embeddings: embeddings,
            modelIdentity: sceneModelIdentity,
            thresholds: thresholds
        )
        XCTAssertTrue(exactL2Only.isEmpty)

        thresholds.featurePrintL2Mode = .unlimited
        thresholds.dinoCosineMode = .minimum
        thresholds.dinoCosineMinSimilarity = 1
        let exactDINOOnly = NearDuplicateSceneClusterService().cluster(
            featurePrints: featurePrints,
            embeddings: embeddings,
            modelIdentity: sceneModelIdentity,
            thresholds: thresholds
        )
        XCTAssertTrue(exactDINOOnly.isEmpty)
    }

    func testIdenticalMembersExcludedFromSceneClusters() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }

        let bytes = try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 7, uti: .jpeg))
        let a = try env.seedAsset(relativePath: "dup-a.jpg", contents: bytes)
        let b = try env.seedAsset(relativePath: "dup-b.jpg", contents: bytes)
        let cID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
        let dID = UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!

        let completion = env.makeCompletionService()
        _ = try completion.completeFolderAsset(assetID: a.assetID)
        _ = try completion.completeFolderAsset(assetID: b.assetID)

        let featureLoader = DictionarySlimmingFeatureLoader(vectors: [
            a.assetID: [1, 0, 0],
            cID: [0.99, 0.01, 0],
            dID: [0.98, 0.02, 0],
        ])
        let embeddingLoader = DictionarySlimmingEmbeddingLoader(
            vectors: [
                a.assetID: [1, 0, 0],
                cID: [0.99, 0.01, 0],
                dID: [0.98, 0.02, 0],
            ],
            modelIdentity: sceneModelIdentity
        )

        let scan = LibrarySlimmingScanService(
            database: env.database,
            identicalScan: IdenticalDuplicateClusterService(database: env.database),
            fingerprintCompletion: nil,
            featureLoader: featureLoader,
            embeddingLoader: embeddingLoader
        )
        let result = try scan.scan(assetIDs: [a.assetID, b.assetID, cID, dID])

        let identical = result.clusters.filter { $0.kind == .byteIdentical }
        let scene = result.clusters.filter { $0.kind == .nearDuplicateScene }
        XCTAssertEqual(identical.count, 1)
        XCTAssertEqual(Set(identical[0].memberAssetIDs), Set([a.assetID, b.assetID]))
        XCTAssertEqual(scene.count, 1)
        XCTAssertEqual(Set(scene[0].memberAssetIDs), Set([cID, dID]))
        XCTAssertFalse(scene[0].memberAssetIDs.contains(a.assetID))
    }

    func testMissingEmbeddingMarkedPendingNotEmptySuccess() throws {
        let a = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let b = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!

        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }

        let scan = LibrarySlimmingScanService(
            database: env.database,
            identicalScan: IdenticalDuplicateClusterService(database: env.database),
            fingerprintCompletion: nil,
            featureLoader: DictionarySlimmingFeatureLoader(vectors: [
                a: [1, 0],
                b: [0.99, 0.01],
            ]),
            embeddingLoader: DictionarySlimmingEmbeddingLoader(vectors: [
                a: [1, 0],
            ])
        )
        let result = try scan.scan(assetIDs: [a, b])
        XCTAssertTrue(result.clusters.isEmpty)
        XCTAssertEqual(result.pendingAnalysisAssetIDs, [b])
    }

    func testScanReportsProgressPhases() throws {
        let a = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let b = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!

        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }

        let scan = LibrarySlimmingScanService(
            database: env.database,
            identicalScan: IdenticalDuplicateClusterService(database: env.database),
            fingerprintCompletion: nil,
            featureLoader: DictionarySlimmingFeatureLoader(vectors: [
                a: [1, 0],
                b: [0.99, 0.01],
            ]),
            embeddingLoader: DictionarySlimmingEmbeddingLoader(vectors: [
                a: [1, 0],
                b: [0.99, 0.01],
            ])
        )

        final class ProgressBox: @unchecked Sendable {
            var samples: [LibrarySlimmingScanProgress] = []
        }
        let box = ProgressBox()
        _ = try scan.scan(assetIDs: [a, b]) { progress in
            box.samples.append(progress)
        }
        let phases = box.samples.map(\.phase)
        XCTAssertTrue(phases.contains(.loadingFeaturePrints))
        XCTAssertTrue(phases.contains(.loadingEmbeddings))
        XCTAssertTrue(phases.contains(.clustering))
    }

    func testHardwareScaledBudgetsNeverExceedAssetCount() {
        let budgets = SlimmingScanBudgetPolicy.budgets(forAssetCount: 12)
        XCTAssertLessThanOrEqual(budgets.featurePrintGenerations, 12)
        XCTAssertLessThanOrEqual(budgets.embeddingGenerations, 12)
    }

    func testJobProgressPresentationMapsFingerprintPhaseBeforeFeaturePrints() {
        let memberCount = 25_320
        let progressTotal = memberCount * 2 + 1
        let mapped = LibrarySlimmingJobProgressPresentation.scanProgress(
            completed: 5_985,
            progressTotal: progressTotal,
            memberCount: memberCount
        )
        XCTAssertEqual(mapped?.phase, .preparingFingerprints)
        XCTAssertEqual(mapped?.completed, 5_985)
        XCTAssertEqual(mapped?.total, memberCount)
        XCTAssertEqual(mapped?.caption, "补全内容指纹 5985/25320")
    }

    func testJobProgressPresentationMapsVectorPhaseAfterFingerprints() {
        let memberCount = 100
        let progressTotal = memberCount * 2 + 1
        let mapped = LibrarySlimmingJobProgressPresentation.scanProgress(
            completed: memberCount + 40,
            progressTotal: progressTotal,
            memberCount: memberCount
        )
        XCTAssertEqual(mapped?.phase, .loadingFeaturePrints)
        XCTAssertEqual(mapped?.completed, 40)
        XCTAssertEqual(mapped?.total, memberCount)
    }

    func testAnalysisJobPresentationShowsCurrentAndMaximumAttemptCount() {
        let presentation = LibrarySlimmingAnalysisJobPresentation(
            LibrarySlimmingAnalysisJobSummary(
                jobID: UUID(),
                mode: .catalog,
                state: .running,
                controlRequest: .none,
                progress: JobProgress(completed: 40, total: 201),
                attempts: 3,
                maxAttempts: 10,
                memberCount: 100,
                seedCount: 0,
                clusterCount: 0,
                hasResult: false,
                createdAtMs: 1,
                updatedAtMs: 1,
                sourceNames: ["Apple Photos", "2024"]
            )
        )

        XCTAssertEqual(presentation.modeTitle, "全部来源")
        XCTAssertEqual(presentation.sourceCaption, "来源（2）：Apple Photos、2024")
        XCTAssertEqual(presentation.attemptCaption, "3 / 10")
        XCTAssertTrue(presentation.detailCaption.contains("尝试 3/10"))
    }

    func testClusterPresentationKeepsTechnicalRevisionOutOfPrimaryCaption() {
        let memberIDs = [UUID(), UUID()]
        let presentation = LibrarySlimmingClusterPresentation(
            SlimmingCluster(
                id: UUID(),
                kind: .nearDuplicateScene,
                memberAssetIDs: memberIDs,
                representativeAssetID: memberIDs[0],
                score: 0.923,
                modelIdentity: sceneModelIdentity
            )
        )

        XCTAssertEqual(presentation.kindTitle, "同场景相似")
        XCTAssertEqual(presentation.scoreCaption, "同场景相似度 92%")
        XCTAssertFalse(presentation.scoreCaption.contains("DINOv2"))
        XCTAssertFalse(presentation.scoreCaption.contains("policy:"))
        XCTAssertTrue(presentation.technicalDetailsCaption.contains("DINOv2 余弦 0.923"))
        XCTAssertTrue(presentation.technicalDetailsCaption.contains("policy:"))
    }

    func testIdenticalClusterPresentationUsesPlainLanguageResult() {
        let memberIDs = [UUID(), UUID()]
        let presentation = LibrarySlimmingClusterPresentation(
            SlimmingCluster(
                id: UUID(),
                kind: .byteIdentical,
                memberAssetIDs: memberIDs,
                representativeAssetID: memberIDs[0],
                score: 1,
                modelIdentity: .featurePrintOnly
            )
        )

        XCTAssertEqual(presentation.kindTitle, "完全相同")
        XCTAssertEqual(presentation.scoreCaption, "内容完全一致")
        XCTAssertTrue(presentation.technicalDetailsCaption.contains("SHA-256 一致"))
    }

    func testSeedQueryRetrievesUniverseNeighborNotJustSeedClosure() throws {
        let seed = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let hit = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        let distractor = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!

        let featurePrints: [UUID: [Float]] = [
            seed: [1, 0, 0],
            hit: [0.99, 0.01, 0],
            distractor: [0, 1, 0],
        ]
        let embeddings: [UUID: [Float]] = [
            seed: [1, 0],
            hit: [0.99, 0.01],
            distractor: [0, 1],
        ]

        let clusters = NearDuplicateSceneClusterService().clusterAroundSeeds(
            seedAssetIDs: [seed],
            featurePrints: featurePrints,
            embeddings: embeddings,
            modelIdentity: sceneModelIdentity
        )
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(Set(clusters[0].memberAssetIDs), Set([seed, hit]))
        XCTAssertFalse(clusters[0].memberAssetIDs.contains(distractor))
    }

    func testScanSeedsUsesUniverseNotSeedOnlyClosure() throws {
        let seed = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let hit = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        let distractor = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!

        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }

        let scan = LibrarySlimmingScanService(
            database: env.database,
            identicalScan: IdenticalDuplicateClusterService(database: env.database),
            fingerprintCompletion: nil,
            featureLoader: DictionarySlimmingFeatureLoader(vectors: [
                seed: [1, 0, 0],
                hit: [0.99, 0.01, 0],
                distractor: [0, 1, 0],
            ]),
            embeddingLoader: DictionarySlimmingEmbeddingLoader(
                vectors: [
                    seed: [1, 0],
                    hit: [0.99, 0.01],
                    distractor: [0, 1],
                ],
                modelIdentity: sceneModelIdentity
            )
        )

        // Seed-only closed world would never see `hit`.
        let seedOnly = try scan.scan(assetIDs: [seed])
        XCTAssertTrue(seedOnly.clusters.isEmpty)

        let seeded = try scan.scanSeeds(
            seedAssetIDs: [seed],
            universeAssetIDs: [seed, hit, distractor]
        )
        XCTAssertEqual(seeded.clusters.count, 1)
        XCTAssertEqual(Set(seeded.clusters[0].memberAssetIDs), Set([seed, hit]))
    }

    func testSeedQueryClaimsSharedNeighborOnlyOnce() {
        let seedA = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let seedB = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        let hit = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!

        let featurePrints: [UUID: [Float]] = [
            seedA: [1, 0, 0],
            seedB: [0.99, 0.01, 0],
            hit: [0.995, 0.005, 0],
        ]
        let embeddings: [UUID: [Float]] = [
            seedA: [1, 0],
            seedB: [0.99, 0.01],
            hit: [0.995, 0.005],
        ]

        let clusters = NearDuplicateSceneClusterService().clusterAroundSeeds(
            seedAssetIDs: [seedA, seedB],
            featurePrints: featurePrints,
            embeddings: embeddings,
            modelIdentity: sceneModelIdentity
        )
        XCTAssertEqual(clusters.count, 1)
        XCTAssertTrue(clusters[0].memberAssetIDs.contains(hit))
    }

    func testCosineAndL2Helpers() {
        XCTAssertEqual(
            SimilarityVectorMath.cosineSimilarity([1, 0], [1, 0])!,
            1.0,
            accuracy: 1e-6
        )
        XCTAssertEqual(
            SimilarityVectorMath.l2Distance([0, 0], [3, 4])!,
            5.0,
            accuracy: 1e-6
        )
    }

    func testRaisedDINOThresholdSplitsPreviouslyClusteredPair() {
        let a = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let b = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        let featurePrints: [UUID: [Float]] = [
            a: [1, 0],
            b: [0.99, 0.01],
        ]
        // Cosine ≈ 0.905 between [1,0] and [0.9, 0.435]
        let embeddings: [UUID: [Float]] = [
            a: [1, 0],
            b: [0.9, 0.435],
        ]

        let defaultClusters = NearDuplicateSceneClusterService().cluster(
            featurePrints: featurePrints,
            embeddings: embeddings,
            modelIdentity: sceneModelIdentity,
            thresholds: .factory
        )
        XCTAssertEqual(defaultClusters.count, 1)

        var strict = NearDuplicateSceneThresholds.factory
        strict.dinoCosineMinSimilarity = 0.95
        let strictClusters = NearDuplicateSceneClusterService().cluster(
            featurePrints: featurePrints,
            embeddings: embeddings,
            modelIdentity: sceneModelIdentity,
            thresholds: strict
        )
        XCTAssertTrue(strictClusters.isEmpty)
    }

    func testCaptureDayBucketingPreventsCrossDaySceneClusters() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dayA = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1))!
        let dayB = calendar.date(from: DateComponents(year: 2024, month: 1, day: 3))!
        let msA = Int64(dayA.timeIntervalSince1970 * 1_000)
        let msB = Int64(dayB.timeIntervalSince1970 * 1_000)

        let bytesA = try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 11, uti: .jpeg))
        let bytesB = try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 12, uti: .jpeg))
        let a = try env.seedAsset(relativePath: "a.jpg", contents: bytesA, mediaCreatedAtMs: msA)
        let b = try env.seedAsset(relativePath: "b.jpg", contents: bytesB, mediaCreatedAtMs: msB)

        var thresholds = NearDuplicateSceneThresholds.factory
        thresholds.sceneBucketActivationAssetCount = 2

        let scan = LibrarySlimmingScanService(
            database: env.database,
            identicalScan: IdenticalDuplicateClusterService(database: env.database),
            fingerprintCompletion: nil,
            featureLoader: DictionarySlimmingFeatureLoader(vectors: [
                a.assetID: [1, 0, 0],
                b.assetID: [0.99, 0.01, 0],
            ]),
            embeddingLoader: DictionarySlimmingEmbeddingLoader(
                vectors: [
                    a.assetID: [1, 0],
                    b.assetID: [0.99, 0.01],
                ],
                modelIdentity: sceneModelIdentity
            ),
            thresholdReader: StaticNearDuplicateSceneThresholds(value: thresholds),
            bucketCalendar: calendar
        )

        let result = try scan.scan(assetIDs: [a.assetID, b.assetID])
        let keyA = SlimmingCaptureDayBucketing.bucketKey(mediaCreatedAtMs: msA, calendar: calendar)
        let keyB = SlimmingCaptureDayBucketing.bucketKey(mediaCreatedAtMs: msB, calendar: calendar)
        XCTAssertNotEqual(keyA, keyB)
        XCTAssertTrue(
            result.clusters.filter { $0.kind == .nearDuplicateScene }.isEmpty,
            "cross-day assets should not form a scene cluster under bucketing"
        )
        XCTAssertTrue(result.policyVersion.contains("bucket=auto:2"))
    }

    func testNeverBucketingAllowsCrossDaySceneCluster() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dayA = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1))!
        let dayB = calendar.date(from: DateComponents(year: 2024, month: 1, day: 3))!
        let a = try env.seedAsset(
            relativePath: "a.jpg",
            contents: try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 51, uti: .jpeg)),
            mediaCreatedAtMs: Int64(dayA.timeIntervalSince1970 * 1_000)
        )
        let b = try env.seedAsset(
            relativePath: "b.jpg",
            contents: try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 52, uti: .jpeg)),
            mediaCreatedAtMs: Int64(dayB.timeIntervalSince1970 * 1_000)
        )

        var thresholds = NearDuplicateSceneThresholds.factory
        thresholds.sceneBucketingMode = .never
        thresholds.sceneBucketActivationAssetCount = 2
        let scan = LibrarySlimmingScanService(
            database: env.database,
            identicalScan: IdenticalDuplicateClusterService(database: env.database),
            fingerprintCompletion: nil,
            featureLoader: DictionarySlimmingFeatureLoader(vectors: [
                a.assetID: [1, 0],
                b.assetID: [0.99, 0.01],
            ]),
            embeddingLoader: DictionarySlimmingEmbeddingLoader(
                vectors: [
                    a.assetID: [1, 0],
                    b.assetID: [0.99, 0.01],
                ],
                modelIdentity: sceneModelIdentity
            ),
            thresholdReader: StaticNearDuplicateSceneThresholds(value: thresholds),
            bucketCalendar: calendar
        )

        let result = try scan.scan(assetIDs: [a.assetID, b.assetID])
        let scene = result.clusters.filter { $0.kind == .nearDuplicateScene }
        XCTAssertEqual(scene.count, 1)
        XCTAssertTrue(result.policyVersion.contains("bucket=never"))
    }

    func testSameDayStillClustersUnderBucketing() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.date(from: DateComponents(year: 2024, month: 2, day: 10))!
        let ms = Int64(day.timeIntervalSince1970 * 1_000)

        let bytesA = try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 21, uti: .jpeg))
        let bytesB = try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 22, uti: .jpeg))
        let a = try env.seedAsset(relativePath: "a.jpg", contents: bytesA, mediaCreatedAtMs: ms)
        let b = try env.seedAsset(relativePath: "b.jpg", contents: bytesB, mediaCreatedAtMs: ms)

        var thresholds = NearDuplicateSceneThresholds.factory
        thresholds.sceneBucketActivationAssetCount = 2

        let scan = LibrarySlimmingScanService(
            database: env.database,
            identicalScan: IdenticalDuplicateClusterService(database: env.database),
            fingerprintCompletion: nil,
            featureLoader: DictionarySlimmingFeatureLoader(vectors: [
                a.assetID: [1, 0, 0],
                b.assetID: [0.99, 0.01, 0],
            ]),
            embeddingLoader: DictionarySlimmingEmbeddingLoader(
                vectors: [
                    a.assetID: [1, 0],
                    b.assetID: [0.99, 0.01],
                ],
                modelIdentity: sceneModelIdentity
            ),
            thresholdReader: StaticNearDuplicateSceneThresholds(value: thresholds),
            bucketCalendar: calendar
        )

        let result = try scan.scan(assetIDs: [a.assetID, b.assetID])
        let scene = result.clusters.filter { $0.kind == .nearDuplicateScene }
        XCTAssertEqual(scene.count, 1)
        XCTAssertEqual(Set(scene[0].memberAssetIDs), Set([a.assetID, b.assetID]))
    }

    func testByteIdenticalStillMergesAcrossDaysWhenBucketingActive() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dayA = calendar.date(from: DateComponents(year: 2024, month: 3, day: 1))!
        let dayB = calendar.date(from: DateComponents(year: 2024, month: 3, day: 5))!
        let msA = Int64(dayA.timeIntervalSince1970 * 1_000)
        let msB = Int64(dayB.timeIntervalSince1970 * 1_000)

        let bytes = try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 33, uti: .jpeg))
        let a = try env.seedAsset(relativePath: "a.jpg", contents: bytes, mediaCreatedAtMs: msA)
        let b = try env.seedAsset(relativePath: "b.jpg", contents: bytes, mediaCreatedAtMs: msB)

        let completion = env.makeCompletionService()
        _ = try completion.completeFolderAsset(assetID: a.assetID)
        _ = try completion.completeFolderAsset(assetID: b.assetID)

        var thresholds = NearDuplicateSceneThresholds.factory
        thresholds.sceneBucketActivationAssetCount = 2

        let scan = LibrarySlimmingScanService(
            database: env.database,
            identicalScan: IdenticalDuplicateClusterService(database: env.database),
            fingerprintCompletion: nil,
            featureLoader: DictionarySlimmingFeatureLoader(vectors: [:]),
            embeddingLoader: DictionarySlimmingEmbeddingLoader(vectors: [:]),
            thresholdReader: StaticNearDuplicateSceneThresholds(value: thresholds),
            bucketCalendar: calendar
        )

        let result = try scan.scan(assetIDs: [a.assetID, b.assetID])
        let identical = result.clusters.filter { $0.kind == .byteIdentical }
        XCTAssertEqual(identical.count, 1)
        XCTAssertEqual(Set(identical[0].memberAssetIDs), Set([a.assetID, b.assetID]))
    }

    func testSeedScanStillRecallsCrossDayNeighborDespiteBucketPolicy() throws {
        let env = try SimilarityTestSupport.Environment(label: #function)
        defer { env.cleanup() }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dayA = calendar.date(from: DateComponents(year: 2024, month: 4, day: 1))!
        let dayB = calendar.date(from: DateComponents(year: 2024, month: 4, day: 9))!
        let msA = Int64(dayA.timeIntervalSince1970 * 1_000)
        let msB = Int64(dayB.timeIntervalSince1970 * 1_000)

        let bytesA = try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 41, uti: .jpeg))
        let bytesB = try XCTUnwrap(SimilarityTestSupport.patternedImageData(seed: 42, uti: .jpeg))
        let seed = try env.seedAsset(relativePath: "seed.jpg", contents: bytesA, mediaCreatedAtMs: msA)
        let hit = try env.seedAsset(relativePath: "hit.jpg", contents: bytesB, mediaCreatedAtMs: msB)

        var thresholds = NearDuplicateSceneThresholds.factory
        thresholds.sceneBucketActivationAssetCount = 2
        thresholds.featurePrintRecallMode = .allCandidates

        final class UnexpectedSourceIndex: SourceSimilarityIndexPort, @unchecked Sendable {
            func status(sourceID _: UUID) throws -> SourceSimilarityIndexStatus? { nil }
            func enqueueBuild(sourceID _: UUID) throws -> UUID { UUID() }
            func runPending() throws {}

            func candidateAssetIDs(
                seedAssetIDs _: [UUID],
                universeAssetIDs _: [UUID]
            ) throws -> SourceSimilarityCandidatePlan {
                XCTFail("all-candidate seed search must bypass source-index narrowing")
                return .restricted(candidates: [])
            }
        }

        let scan = LibrarySlimmingScanService(
            database: env.database,
            identicalScan: IdenticalDuplicateClusterService(database: env.database),
            fingerprintCompletion: nil,
            featureLoader: DictionarySlimmingFeatureLoader(vectors: [
                seed.assetID: [1, 0, 0],
                hit.assetID: [0.99, 0.01, 0],
            ]),
            embeddingLoader: DictionarySlimmingEmbeddingLoader(
                vectors: [
                    seed.assetID: [1, 0],
                    hit.assetID: [0.99, 0.01],
                ],
                modelIdentity: sceneModelIdentity
            ),
            thresholdReader: StaticNearDuplicateSceneThresholds(value: thresholds),
            bucketCalendar: calendar,
            sourceIndex: UnexpectedSourceIndex()
        )

        let result = try scan.scanSeeds(
            seedAssetIDs: [seed.assetID],
            universeAssetIDs: [seed.assetID, hit.assetID]
        )
        XCTAssertEqual(result.clusters.count, 1)
        XCTAssertEqual(Set(result.clusters[0].memberAssetIDs), Set([seed.assetID, hit.assetID]))
    }

    func testThresholdStoreRoundTripAndReset() {
        let suiteName = "ImageAll.S6Threshold.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsNearDuplicateSceneThresholdStore(defaults: defaults)

        var custom = NearDuplicateSceneThresholds.factory
        custom.dinoCosineMinSimilarity = 0.93
        custom.featurePrintRecallTopK = 8
        custom.featurePrintRecallMode = .allCandidates
        custom.featurePrintL2Mode = .unlimited
        custom.dinoCosineMode = .unlimited
        custom.sceneBucketingMode = .never
        store.setThresholds(custom)
        XCTAssertEqual(store.thresholds().dinoCosineMinSimilarity, 0.93, accuracy: 1e-9)
        XCTAssertEqual(store.thresholds().featurePrintRecallTopK, 8)
        XCTAssertEqual(store.thresholds().featurePrintRecallMode, .allCandidates)
        XCTAssertEqual(store.thresholds().featurePrintL2Mode, .unlimited)
        XCTAssertEqual(store.thresholds().dinoCosineMode, .unlimited)
        XCTAssertEqual(store.thresholds().sceneBucketingMode, .never)

        store.resetToFactory()
        XCTAssertEqual(store.thresholds(), .factory)
    }

    func testThresholdClampPreservesNumericExtremes() {
        var thresholds = NearDuplicateSceneThresholds.factory
        thresholds.featurePrintRecallTopK = 1
        thresholds.featurePrintMaxL2Distance = 0
        thresholds.dinoCosineMinSimilarity = 1
        thresholds.sceneBucketActivationAssetCount = 2

        XCTAssertEqual(thresholds.clamped(), thresholds)
        XCTAssertTrue(thresholds.policyVersion.contains("topk=1"))
        XCTAssertTrue(thresholds.policyVersion.contains("l2=0.00"))
        XCTAssertTrue(thresholds.policyVersion.contains("dino=1.000"))
        XCTAssertTrue(thresholds.policyVersion.contains("bucket=auto:2"))

        thresholds.sceneBucketingMode = .always
        thresholds.sceneBucketActivationAssetCount = 10_000
        XCTAssertTrue(thresholds.usesCaptureDayBuckets(assetCount: 2))
        XCTAssertTrue(thresholds.policyVersion.contains("bucket=always"))

        thresholds.sceneBucketingMode = .never
        XCTAssertFalse(thresholds.usesCaptureDayBuckets(assetCount: 10_000))
        XCTAssertTrue(thresholds.policyVersion.contains("bucket=never"))
    }
}
