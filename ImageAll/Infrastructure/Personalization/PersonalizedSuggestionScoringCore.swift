import Foundation

enum PersonalizedSuggestionScoringCore {
    struct LoadedSample: Sendable {
        let assetID: UUID
        let contentRevision: Int
        let role: ModelSampleRole
        let values: [Float]
    }

    struct CandidateRevision: Sendable {
        let assetID: UUID
        let contentRevision: Int
    }

    static func decode(_ payload: FeatureVectorPayload) throws -> [Float] {
        guard payload.elementCount > 0,
              payload.vectorData.count == payload.elementCount * MemoryLayout<Float>.size
        else {
            throw PersonalizedSuggestionError.invalidFeatureVector
        }
        let values = payload.vectorData.withUnsafeBytes { raw in
            (0 ..< payload.elementCount).map { index in
                raw.loadUnaligned(
                    fromByteOffset: index * MemoryLayout<Float>.size,
                    as: Float.self
                )
            }
        }
        guard values.allSatisfy(\.isFinite) else {
            throw PersonalizedSuggestionError.invalidFeatureVector
        }
        return values
    }

    static func scoreCandidate(
        candidateValues: [Float],
        positiveSamples: [[Float]],
        negativeSamples: [[Float]],
        neighborCount: Int
    ) -> Double {
        let positiveMean = nearestMeanDistance(
            candidate: candidateValues,
            samples: positiveSamples,
            count: neighborCount
        )
        let negativeMean = nearestMeanDistance(
            candidate: candidateValues,
            samples: negativeSamples,
            count: neighborCount
        )
        return negativeMean - positiveMean
    }

    static func registrations(
        positives: [LoadedSample],
        negatives: [LoadedSample]
    ) -> [ModelSampleRegistration] {
        positives.enumerated().map { index, sample in
            ModelSampleRegistration(
                identity: FeatureIdentity(
                    assetID: sample.assetID,
                    contentRevision: sample.contentRevision
                ),
                role: .positive,
                rank: index
            )
        } + negatives.enumerated().map { index, sample in
            ModelSampleRegistration(
                identity: FeatureIdentity(
                    assetID: sample.assetID,
                    contentRevision: sample.contentRevision
                ),
                role: .negative,
                rank: index
            )
        }
    }

    private static func nearestMeanDistance(
        candidate: [Float],
        samples: [[Float]],
        count: Int
    ) -> Double {
        let nearest = samples.map { sample in
            sqrt(zip(candidate, sample).reduce(0.0) { partial, pair in
                let difference = Double(pair.0 - pair.1)
                return partial + difference * difference
            })
        }.sorted().prefix(count)
        guard !nearest.isEmpty else { return 0 }
        return nearest.reduce(0, +) / Double(nearest.count)
    }
}

protocol SyncFeatureVectorLoading: Sendable {
    func loadOrGenerateSync(assetID: UUID) throws -> FeatureVectorPayload
}
