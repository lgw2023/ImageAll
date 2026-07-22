import Accelerate
import CryptoKit
import Foundation

struct AppPersonalAdamWTrainingConfig: Equatable, Sendable {
    var maxEpochs: Int
    var learningRate: Float
    var weightDecay: Float
    var beta1: Float
    var beta2: Float
    var epsilon: Float
    var patience: Int
    var validationFraction: Float
    var seed: UInt64

    static let `default` = AppPersonalAdamWTrainingConfig(
        maxEpochs: 200,
        learningRate: 1e-2,
        weightDecay: 1e-2,
        beta1: 0.9,
        beta2: 0.999,
        epsilon: 1e-8,
        patience: 20,
        validationFraction: 0.2,
        seed: 0xA11CE_DADA
    )
}

struct AppPersonalAdamWTrainingReport: Equatable, Sendable {
    let epochsRun: Int
    let bestValidationLoss: Float
    let stoppedEarly: Bool
}

enum AppPersonalAdamWLinearHeadTrainer {
    static let algorithmRevision = "positive-adamw-float32-v1"
    private static let schemaRevision = 1

    static func train(
        snapshot: PersonalModelRebuildSnapshot,
        encoderIdentity: AppCoreMLModelIdentity,
        config: AppPersonalAdamWTrainingConfig = .default
    ) throws -> (AppPersonalLinearHeadArtifact, AppPersonalAdamWTrainingReport) {
        guard config.maxEpochs > 0,
              config.learningRate > 0,
              config.weightDecay >= 0,
              config.beta1 > 0,
              config.beta1 < 1,
              config.beta2 > 0,
              config.beta2 < 1,
              config.epsilon > 0,
              config.patience > 0,
              config.validationFraction >= 0,
              config.validationFraction < 1
        else {
            throw AppPersonalLinearHeadError.invalidSnapshot
        }
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
        try validateAcceptedOnly(snapshot, rows: rows)
        let samples = try makeSamples(
            snapshot: snapshot,
            rows: rows,
            elementCount: encoderIdentity.elementCount
        )
        guard !samples.isEmpty else {
            throw AppPersonalLinearHeadError.insufficientDecisions
        }

        let split = splitTrainValidation(samples: samples, config: config)
        var parameters = try warmStartFromCentroid(
            snapshot: snapshot,
            rows: rows,
            elementCount: encoderIdentity.elementCount
        )
        let width = encoderIdentity.elementCount + 1
        var moment1 = [Float](repeating: 0, count: parameters.count)
        var moment2 = [Float](repeating: 0, count: parameters.count)
        var bestParameters = parameters
        var bestValidationLoss = Float.greatestFiniteMagnitude
        var epochsWithoutImprovement = 0
        var epochsRun = 0
        var stoppedEarly = false

        for epoch in 1...config.maxEpochs {
            epochsRun = epoch
            adamWEpoch(
                samples: split.train,
                tagCount: snapshot.personalTagIDs.count,
                width: width,
                parameters: &parameters,
                moment1: &moment1,
                moment2: &moment2,
                step: epoch,
                config: config
            )
            let validationLoss = meanBCE(
                samples: split.validation.isEmpty ? split.train : split.validation,
                tagCount: snapshot.personalTagIDs.count,
                width: width,
                parameters: parameters
            )
            if validationLoss + 1e-7 < bestValidationLoss {
                bestValidationLoss = validationLoss
                bestParameters = parameters
                epochsWithoutImprovement = 0
            } else {
                epochsWithoutImprovement += 1
                if epochsWithoutImprovement >= config.patience {
                    stoppedEarly = true
                    break
                }
            }
        }

        parameters = bestParameters
        var packed = Data()
        append(parameters, to: &packed)
        let weightsSHA256 = sha256(packed)
        let record = AppPersonalLinearHeadRecord(
            schemaRevision: Self.schemaRevision,
            algorithmRevision: Self.algorithmRevision,
            catalogScopeID: snapshot.catalogScopeID,
            decisionSnapshotRevision: snapshot.decisionSnapshotRevision,
            labelVocabularyRevision: snapshot.labelVocabularyRevision,
            encoder: AppPersonalLinearHeadEncoderRecord(encoderIdentity),
            personalTagIDs: snapshot.personalTagIDs.map { $0.uuidString.lowercased() },
            parameters: packed,
            weightsSHA256: weightsSHA256
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let artifact = AppPersonalLinearHeadArtifact(encodedData: try encoder.encode(record))
        let report = AppPersonalAdamWTrainingReport(
            epochsRun: epochsRun,
            bestValidationLoss: bestValidationLoss,
            stoppedEarly: stoppedEarly
        )
        return (artifact, report)
    }

    private static func warmStartFromCentroid(
        snapshot: PersonalModelRebuildSnapshot,
        rows: [EmbeddingKey: [Float]],
        elementCount: Int
    ) throws -> [Float] {
        var parameters: [Float] = []
        for tagID in snapshot.personalTagIDs {
            let accepted = try acceptedEmbeddings(
                for: tagID,
                snapshot: snapshot,
                rows: rows
            )
            guard accepted.count >= 2 else {
                throw AppPersonalLinearHeadError.insufficientDecisions
            }
            let positiveMean = mean(accepted, elementCount: elementCount)
            parameters.append(contentsOf: positiveMean)
            parameters.append(-0.5 * dot(positiveMean, positiveMean))
        }
        return parameters
    }

    private static func makeSamples(
        snapshot: PersonalModelRebuildSnapshot,
        rows: [EmbeddingKey: [Float]],
        elementCount: Int
    ) throws -> [TrainingSample] {
        var labelsByAsset: [EmbeddingKey: [Float]] = [:]
        for decision in snapshot.decisions {
            guard decision.state == .manualAccepted else { continue }
            guard let tagIndex = snapshot.personalTagIDs.firstIndex(of: decision.tagID) else {
                throw AppPersonalLinearHeadError.invalidSnapshot
            }
            let key = EmbeddingKey(
                assetID: decision.assetID,
                contentRevision: decision.contentRevision
            )
            guard rows[key] != nil else {
                throw AppPersonalLinearHeadError.invalidSnapshot
            }
            var labels = labelsByAsset[key] ?? [Float](
                repeating: 0,
                count: snapshot.personalTagIDs.count
            )
            labels[tagIndex] = 1
            labelsByAsset[key] = labels
        }
        return labelsByAsset.keys.sorted(by: EmbeddingKey.isOrderedBefore).map { key in
            TrainingSample(
                values: rows[key]!,
                labels: labelsByAsset[key]!
            )
        }.filter { sample in
            sample.values.count == elementCount
                && sample.labels.contains(where: { $0 > 0 })
        }
    }

    private static func splitTrainValidation(
        samples: [TrainingSample],
        config: AppPersonalAdamWTrainingConfig
    ) -> (train: [TrainingSample], validation: [TrainingSample]) {
        guard samples.count >= 5, config.validationFraction > 0 else {
            return (samples, [])
        }
        var generator = SeededGenerator(seed: config.seed)
        var shuffled = samples
        for index in stride(from: shuffled.count - 1, through: 1, by: -1) {
            let swapIndex = Int(generator.next() % UInt64(index + 1))
            shuffled.swapAt(index, swapIndex)
        }
        let validationCount = max(1, Int((Float(samples.count) * config.validationFraction).rounded(.down)))
        let clamped = min(validationCount, samples.count - 2)
        let validation = Array(shuffled.prefix(clamped))
        let train = Array(shuffled.dropFirst(clamped))
        return (train, validation)
    }

    private static func adamWEpoch(
        samples: [TrainingSample],
        tagCount: Int,
        width: Int,
        parameters: inout [Float],
        moment1: inout [Float],
        moment2: inout [Float],
        step: Int,
        config: AppPersonalAdamWTrainingConfig
    ) {
        var gradients = [Float](repeating: 0, count: parameters.count)
        for sample in samples {
            for tagIndex in 0..<tagCount {
                let start = tagIndex * width
                let weights = Array(parameters[start..<(start + width - 1)])
                let bias = parameters[start + width - 1]
                let logit = dot(weights, sample.values) + bias
                let prediction = sigmoid(logit)
                let error = prediction - sample.labels[tagIndex]
                for dimension in 0..<(width - 1) {
                    gradients[start + dimension] += error * sample.values[dimension]
                }
                gradients[start + width - 1] += error
            }
        }
        let scale = 1 / Float(samples.count)
        let stepFloat = Float(step)
        let biasCorrection1 = 1 - pow(config.beta1, stepFloat)
        let biasCorrection2 = 1 - pow(config.beta2, stepFloat)
        for index in parameters.indices {
            let gradient = gradients[index] * scale
            moment1[index] = config.beta1 * moment1[index] + (1 - config.beta1) * gradient
            moment2[index] = config.beta2 * moment2[index] + (1 - config.beta2) * gradient * gradient
            let mHat = moment1[index] / biasCorrection1
            let vHat = moment2[index] / biasCorrection2
            let adamStep = mHat / (sqrt(vHat) + config.epsilon)
            // Decoupled weight decay applies to weights, not biases.
            let isBias = (index % width) == (width - 1)
            if isBias {
                parameters[index] -= config.learningRate * adamStep
            } else {
                parameters[index] =
                    parameters[index] * (1 - config.learningRate * config.weightDecay)
                    - config.learningRate * adamStep
            }
        }
    }

    private static func meanBCE(
        samples: [TrainingSample],
        tagCount: Int,
        width: Int,
        parameters: [Float]
    ) -> Float {
        guard !samples.isEmpty else { return 0 }
        var total: Float = 0
        var count: Float = 0
        for sample in samples {
            for tagIndex in 0..<tagCount {
                let start = tagIndex * width
                let weights = Array(parameters[start..<(start + width - 1)])
                let bias = parameters[start + width - 1]
                let logit = dot(weights, sample.values) + bias
                let target = sample.labels[tagIndex]
                total += binaryCrossEntropy(logit: logit, target: target)
                count += 1
            }
        }
        return total / count
    }

    private static func binaryCrossEntropy(logit: Float, target: Float) -> Float {
        let maxLogit = max(logit, 0)
        return maxLogit - logit * target + log1p(exp(-abs(logit)))
    }

    private static func sigmoid(_ value: Float) -> Float {
        if value >= 0 {
            let z = exp(-value)
            return 1 / (1 + z)
        }
        let z = exp(value)
        return z / (1 + z)
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

    private static func validateAcceptedOnly(
        _ snapshot: PersonalModelRebuildSnapshot,
        rows: [EmbeddingKey: [Float]]
    ) throws {
        var seen = Set<DecisionKey>()
        for decision in snapshot.decisions {
            guard snapshot.personalTagIDs.contains(decision.tagID) else {
                throw AppPersonalLinearHeadError.invalidSnapshot
            }
            guard decision.state == .manualAccepted else { continue }
            let key = DecisionKey(
                assetID: decision.assetID,
                contentRevision: decision.contentRevision,
                tagID: decision.tagID
            )
            guard seen.insert(key).inserted else {
                throw AppPersonalLinearHeadError.invalidSnapshot
            }
            guard rows[
                EmbeddingKey(assetID: decision.assetID, contentRevision: decision.contentRevision)
            ] != nil else {
                throw AppPersonalLinearHeadError.invalidSnapshot
            }
        }
        for tagID in snapshot.personalTagIDs {
            let accepted = snapshot.decisions.filter {
                $0.tagID == tagID && $0.state == .manualAccepted
            }
            guard accepted.count >= 2 else {
                throw AppPersonalLinearHeadError.insufficientDecisions
            }
        }
    }

    private static func acceptedEmbeddings(
        for tagID: UUID,
        snapshot: PersonalModelRebuildSnapshot,
        rows: [EmbeddingKey: [Float]]
    ) throws -> [[Float]] {
        try snapshot.decisions.compactMap { decision in
            guard decision.tagID == tagID, decision.state == .manualAccepted else { return nil }
            guard let values = rows[
                EmbeddingKey(assetID: decision.assetID, contentRevision: decision.contentRevision)
            ] else {
                throw AppPersonalLinearHeadError.invalidSnapshot
            }
            return values
        }
    }

    private static func encoderMatches(
        _ lhs: PersonalTrainingEncoderIdentity,
        _ rhs: AppCoreMLModelIdentity
    ) -> Bool {
        lhs.provider == rhs.provider
            && lhs.modelID == rhs.modelID
            && lhs.modelRevision == rhs.modelRevision
            && lhs.preprocessingRevision == rhs.preprocessingRevision
            && lhs.elementCount == rhs.elementCount
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64
            && value.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "0123456789abcdef").contains($0)
            }
    }

    private static func mean(_ rows: [[Float]], elementCount: Int) -> [Float] {
        var result = [Float](repeating: 0, count: elementCount)
        for row in rows {
            vDSP_vadd(result, 1, row, 1, &result, 1, vDSP_Length(elementCount))
        }
        var scale = 1 / Float(rows.count)
        vDSP_vsmul(result, 1, &scale, &result, 1, vDSP_Length(elementCount))
        return result
    }

    private static func append(_ values: [Float], to data: inout Data) {
        for value in values {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
    }

    private static func dot(_ lhs: [Float], _ rhs: [Float]) -> Float {
        var result: Float = 0
        vDSP_dotpr(lhs, 1, rhs, 1, &result, vDSP_Length(lhs.count))
        return result
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct TrainingSample: Sendable {
        let values: [Float]
        let labels: [Float]
    }

    private struct SeededGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }
}

private extension EmbeddingKey {
    static func isOrderedBefore(_ lhs: EmbeddingKey, _ rhs: EmbeddingKey) -> Bool {
        let lhsID = lhs.assetID.uuidString.lowercased()
        let rhsID = rhs.assetID.uuidString.lowercased()
        return lhsID == rhsID
            ? lhs.contentRevision < rhs.contentRevision
            : lhsID < rhsID
    }
}
