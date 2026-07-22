import Accelerate
import CryptoKit
import Foundation

struct AppPersonalLinearHeadArtifact: Equatable, Sendable {
    let encodedData: Data
}

struct AppPersonalLinearHeadIdentity: Equatable, Sendable {
    let catalogScopeID: String
    let decisionSnapshotRevision: String
    let labelVocabularyRevision: String
    let encoderIdentity: AppCoreMLModelIdentity
    let personalTagIDs: [UUID]
    let weightsSHA256: String
}

struct AppPersonalLinearHeadSuggestion: Equatable, Sendable {
    let tagID: UUID
    let score: Float
}

enum AppPersonalLinearHeadError: Error, Equatable {
    case invalidSnapshot
    case insufficientDecisions
    case invalidArtifact
    case identityMismatch
    case invalidEmbedding
}

enum AppPersonalLinearHeadTrainer {
    private static let schemaRevision = 1
    private static let algorithmRevision = "positive-centroid-float32-v1"

    static func train(
        snapshot: PersonalModelRebuildSnapshot,
        encoderIdentity: AppCoreMLModelIdentity
    ) throws -> AppPersonalLinearHeadArtifact {
        guard encoderMatches(snapshot.encoder, encoderIdentity),
              encoderIdentity.elementType == "float32",
              !snapshot.catalogScopeID.isEmpty,
              isLowercaseSHA256(snapshot.decisionSnapshotRevision),
              isLowercaseSHA256(snapshot.labelVocabularyRevision),
              !snapshot.personalTagIDs.isEmpty,
              Set(snapshot.personalTagIDs).count == snapshot.personalTagIDs.count
        else {
            throw AppPersonalLinearHeadError.invalidSnapshot
        }
        let rows = try embeddingRows(snapshot, elementCount: encoderIdentity.elementCount)
        try validateDecisions(snapshot, rows: rows)
        var parameters = Data()
        for tagID in snapshot.personalTagIDs {
            let accepted = try embeddings(
                for: tagID,
                state: .manualAccepted,
                snapshot: snapshot,
                rows: rows
            )
            guard accepted.count >= 2 else {
                throw AppPersonalLinearHeadError.insufficientDecisions
            }
            // Pure positive prototype: score = μ⁺·x − ½‖μ⁺‖².
            // Untagged photos are not treated as negatives.
            let positiveMean = mean(accepted, elementCount: encoderIdentity.elementCount)
            let weights = positiveMean
            let bias = -0.5 * dot(positiveMean, positiveMean)
            append(weights, to: &parameters)
            append([bias], to: &parameters)
        }
        let weightsSHA256 = sha256(parameters)
        let record = AppPersonalLinearHeadRecord(
            schemaRevision: schemaRevision,
            algorithmRevision: algorithmRevision,
            catalogScopeID: snapshot.catalogScopeID,
            decisionSnapshotRevision: snapshot.decisionSnapshotRevision,
            labelVocabularyRevision: snapshot.labelVocabularyRevision,
            encoder: AppPersonalLinearHeadEncoderRecord(encoderIdentity),
            personalTagIDs: snapshot.personalTagIDs.map { $0.uuidString.lowercased() },
            parameters: parameters,
            weightsSHA256: weightsSHA256
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return AppPersonalLinearHeadArtifact(encodedData: try encoder.encode(record))
    }

    private static func embeddingRows(
        _ snapshot: PersonalModelRebuildSnapshot,
        elementCount: Int
    ) throws -> [EmbeddingKey: [Float]] {
        var result: [EmbeddingKey: [Float]] = [:]
        for row in snapshot.embeddings {
            guard row.contentRevision >= 0,
                  row.values.count == elementCount,
                  row.values.allSatisfy(\.isFinite),
                  result.updateValue(
                      row.values,
                      forKey: EmbeddingKey(
                          assetID: row.assetID,
                          contentRevision: row.contentRevision
                      )
                  ) == nil
            else {
                throw AppPersonalLinearHeadError.invalidSnapshot
            }
        }
        return result
    }

    private static func embeddings(
        for tagID: UUID,
        state: PersonalTrainingDecisionState,
        snapshot: PersonalModelRebuildSnapshot,
        rows: [EmbeddingKey: [Float]]
    ) throws -> [[Float]] {
        try snapshot.decisions.compactMap { decision in
            guard snapshot.personalTagIDs.contains(decision.tagID) else {
                throw AppPersonalLinearHeadError.invalidSnapshot
            }
            guard decision.tagID == tagID, decision.state == state else { return nil }
            guard let values = rows[
                EmbeddingKey(
                    assetID: decision.assetID,
                    contentRevision: decision.contentRevision
                )
            ] else {
                throw AppPersonalLinearHeadError.invalidSnapshot
            }
            return values
        }
    }

    private static func validateDecisions(
        _ snapshot: PersonalModelRebuildSnapshot,
        rows: [EmbeddingKey: [Float]]
    ) throws {
        let knownTags = Set(snapshot.personalTagIDs)
        var seen: Set<DecisionKey> = []
        for decision in snapshot.decisions {
            let embeddingKey = EmbeddingKey(
                assetID: decision.assetID,
                contentRevision: decision.contentRevision
            )
            let decisionKey = DecisionKey(
                assetID: decision.assetID,
                contentRevision: decision.contentRevision,
                tagID: decision.tagID
            )
            guard decision.contentRevision >= 0,
                  knownTags.contains(decision.tagID),
                  rows[embeddingKey] != nil,
                  seen.insert(decisionKey).inserted
            else {
                throw AppPersonalLinearHeadError.invalidSnapshot
            }
        }
    }

    private static func mean(_ rows: [[Float]], elementCount: Int) -> [Float] {
        var result = [Float](repeating: 0, count: elementCount)
        for row in rows {
            for index in 0..<elementCount {
                result[index] += row[index]
            }
        }
        let divisor = Float(rows.count)
        for index in 0..<elementCount {
            result[index] /= divisor
        }
        return result
    }

    private static func encoderMatches(
        _ snapshot: PersonalTrainingEncoderIdentity,
        _ identity: AppCoreMLModelIdentity
    ) -> Bool {
        snapshot.provider == identity.provider
            && snapshot.modelID == identity.modelID
            && snapshot.modelRevision == identity.modelRevision
            && snapshot.preprocessingRevision == identity.preprocessingRevision
            && snapshot.elementCount == identity.elementCount
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64
            && value.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "0123456789abcdef").contains($0)
            }
    }
}

struct AppPersonalLinearHeadModel: Sendable {
    static let acceptedAlgorithmRevisions: Set<String> = [
        "positive-centroid-float32-v1",
        "positive-adamw-float32-v1",
    ]

    let identity: AppPersonalLinearHeadIdentity
    let algorithmRevision: String

    private let parameters: [Parameters]

    init(artifact: AppPersonalLinearHeadArtifact) throws {
        guard let record = try? JSONDecoder().decode(
            AppPersonalLinearHeadRecord.self,
            from: artifact.encodedData
        ) else {
            throw AppPersonalLinearHeadError.invalidArtifact
        }
        let personalTagIDs = record.personalTagIDs.compactMap(UUID.init(uuidString:))
        guard record.schemaRevision == 1,
              Self.acceptedAlgorithmRevisions.contains(record.algorithmRevision),
              let encoderIdentity = record.encoder.identity,
              personalTagIDs.count == record.personalTagIDs.count,
              record.weightsSHA256 == sha256(record.parameters)
        else {
            throw AppPersonalLinearHeadError.invalidArtifact
        }
        let values = Self.values(record.parameters)
        let width = encoderIdentity.elementCount + 1
        guard personalTagIDs.count > 0,
              Set(personalTagIDs).count == personalTagIDs.count,
              values.count == personalTagIDs.count * width,
              values.allSatisfy(\.isFinite)
        else {
            throw AppPersonalLinearHeadError.invalidArtifact
        }
        var parsed: [Parameters] = []
        for index in personalTagIDs.indices {
            let start = index * width
            parsed.append(
                Parameters(
                    weights: Array(values[start..<(start + encoderIdentity.elementCount)]),
                    bias: values[start + encoderIdentity.elementCount]
                )
            )
        }
        identity = AppPersonalLinearHeadIdentity(
            catalogScopeID: record.catalogScopeID,
            decisionSnapshotRevision: record.decisionSnapshotRevision,
            labelVocabularyRevision: record.labelVocabularyRevision,
            encoderIdentity: encoderIdentity,
            personalTagIDs: personalTagIDs,
            weightsSHA256: record.weightsSHA256
        )
        algorithmRevision = record.algorithmRevision
        parameters = parsed
    }

    func score(
        tagID: UUID,
        embedding: AppCoreMLEmbedding
    ) throws -> Float? {
        guard embedding.identity == identity.encoderIdentity else {
            throw AppPersonalLinearHeadError.identityMismatch
        }
        guard embedding.values.count == identity.encoderIdentity.elementCount,
              embedding.values.allSatisfy(\.isFinite)
        else {
            throw AppPersonalLinearHeadError.invalidEmbedding
        }
        guard let index = identity.personalTagIDs.firstIndex(of: tagID) else {
            return nil
        }
        let tagParameters = parameters[index]
        let score = dot(tagParameters.weights, embedding.values) + tagParameters.bias
        guard score.isFinite else { return nil }
        return score
    }

    func suggestions(
        for embedding: AppCoreMLEmbedding,
        maximumCount: Int
    ) throws -> [AppPersonalLinearHeadSuggestion] {
        guard embedding.identity == identity.encoderIdentity else {
            throw AppPersonalLinearHeadError.identityMismatch
        }
        guard embedding.values.count == identity.encoderIdentity.elementCount,
              embedding.values.allSatisfy(\.isFinite),
              maximumCount > 0
        else {
            throw AppPersonalLinearHeadError.invalidEmbedding
        }
        return zip(identity.personalTagIDs, parameters)
            .map { tagID, parameters in
                AppPersonalLinearHeadSuggestion(
                    tagID: tagID,
                    score: dot(parameters.weights, embedding.values) + parameters.bias
                )
            }
            .filter { $0.score.isFinite && $0.score > 0 }
            .enumerated()
            .sorted {
                if $0.element.score == $1.element.score {
                    return $0.offset < $1.offset
                }
                return $0.element.score > $1.element.score
            }
            .prefix(maximumCount)
            .map(\.element)
    }

    private static func values(_ data: Data) -> [Float] {
        let bytes = [UInt8](data)
        guard bytes.count.isMultiple(of: 4) else { return [] }
        return stride(from: 0, to: bytes.count, by: 4).map { offset in
            let bits = UInt32(bytes[offset])
                | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
            return Float(bitPattern: bits)
        }
    }

    private struct Parameters: Sendable {
        let weights: [Float]
        let bias: Float
    }
}

struct EmbeddingKey: Hashable {
    let assetID: UUID
    let contentRevision: Int
}

struct DecisionKey: Hashable {
    let assetID: UUID
    let contentRevision: Int
    let tagID: UUID
}

struct AppPersonalLinearHeadRecord: Codable {
    let schemaRevision: Int
    let algorithmRevision: String
    let catalogScopeID: String
    let decisionSnapshotRevision: String
    let labelVocabularyRevision: String
    let encoder: AppPersonalLinearHeadEncoderRecord
    let personalTagIDs: [String]
    let parameters: Data
    let weightsSHA256: String
}

struct AppPersonalLinearHeadEncoderRecord: Codable {
    let provider: String
    let modelID: String
    let modelRevision: String
    let preprocessingRevision: String
    let embeddingSemantics: String
    let postprocessingRevision: String
    let elementType: String
    let elementCount: Int
    let sourceModelSHA256: String
    let artifactSHA256: String
    let manifestSHA256: String
    let licenseID: String
    let licenseSHA256: String

    init(_ identity: AppCoreMLModelIdentity) {
        provider = identity.provider
        modelID = identity.modelID
        modelRevision = identity.modelRevision
        preprocessingRevision = identity.preprocessingRevision
        embeddingSemantics = identity.embeddingSemantics
        postprocessingRevision = identity.postprocessingRevision
        elementType = identity.elementType
        elementCount = identity.elementCount
        sourceModelSHA256 = identity.sourceModelSHA256
        artifactSHA256 = identity.artifactSHA256
        manifestSHA256 = identity.manifestSHA256
        licenseID = identity.licenseID
        licenseSHA256 = identity.licenseSHA256
    }

    var identity: AppCoreMLModelIdentity? {
        guard elementCount > 0 else { return nil }
        return AppCoreMLModelIdentity(
            provider: provider,
            modelID: modelID,
            modelRevision: modelRevision,
            preprocessingRevision: preprocessingRevision,
            embeddingSemantics: embeddingSemantics,
            postprocessingRevision: postprocessingRevision,
            elementType: elementType,
            elementCount: elementCount,
            sourceModelSHA256: sourceModelSHA256,
            artifactSHA256: artifactSHA256,
            manifestSHA256: manifestSHA256,
            licenseID: licenseID,
            licenseSHA256: licenseSHA256
        )
    }
}

private func append(_ values: [Float], to data: inout Data) {
    for value in values {
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }
}

private func dot(_ lhs: [Float], _ rhs: [Float]) -> Float {
    var result: Float = 0
    vDSP_dotpr(lhs, 1, rhs, 1, &result, vDSP_Length(lhs.count))
    return result
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
