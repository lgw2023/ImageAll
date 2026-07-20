import CoreGraphics
import CoreML
import CryptoKit
import Foundation

struct AppCoreMLModelIdentity: Equatable, Sendable {
    let provider: String
    let modelID: String
    let modelRevision: String
    let preprocessingRevision: String
    let elementCount: Int
    let artifactSHA256: String
    let manifestSHA256: String
    let licenseID: String
    let licenseSHA256: String
}

struct AppCoreMLEmbedding: Equatable, Sendable {
    let identity: AppCoreMLModelIdentity
    let values: [Float]
}

enum AppCoreMLModelFailure: Equatable, Sendable {
    case artifactMissing
    case manifestInvalid
    case checksumMismatch
    case artifactInvalid
}

enum AppCoreMLModelAvailability: Equatable, Sendable {
    case disabled
    case unavailable(AppCoreMLModelFailure)
    case ready(AppCoreMLModelIdentity)
}

enum AppCoreMLEmbeddingError: Error, Equatable {
    case unavailable
    case inferenceFailed
}

final class AppCoreMLEmbeddingService: @unchecked Sendable {
    let availability: AppCoreMLModelAvailability

    private let model: MLModel?
    private let identity: AppCoreMLModelIdentity?

    init(isEnabled: Bool, artifactDirectory: URL) {
        guard isEnabled else {
            availability = .disabled
            model = nil
            identity = nil
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: artifactDirectory.path,
            isDirectory: &isDirectory
        ) else {
            availability = .unavailable(.artifactMissing)
            model = nil
            identity = nil
            return
        }
        guard isDirectory.boolValue else {
            availability = .unavailable(.artifactInvalid)
            model = nil
            identity = nil
            return
        }
        do {
            let loaded = try Self.loadArtifact(at: artifactDirectory)
            availability = .ready(loaded.identity)
            model = loaded.model
            identity = loaded.identity
        } catch ArtifactError.manifestInvalid {
            availability = .unavailable(.manifestInvalid)
            model = nil
            identity = nil
        } catch ArtifactError.checksumMismatch {
            availability = .unavailable(.checksumMismatch)
            model = nil
            identity = nil
        } catch {
            availability = .unavailable(.artifactInvalid)
            model = nil
            identity = nil
        }
    }

    func embedding(for image: CGImage) throws -> AppCoreMLEmbedding {
        guard let model, let identity else {
            throw AppCoreMLEmbeddingError.unavailable
        }
        let input = try Self.pixelValues(for: image)
        let provider = try MLDictionaryFeatureProvider(
            dictionary: ["pixel_values": MLFeatureValue(multiArray: input)]
        )
        let prediction: MLFeatureProvider
        do {
            prediction = try model.prediction(from: provider)
        } catch {
            throw AppCoreMLEmbeddingError.inferenceFailed
        }
        guard
            let array = prediction.featureValue(for: "embedding")?.multiArrayValue,
            array.count == identity.elementCount
        else {
            throw AppCoreMLEmbeddingError.inferenceFailed
        }
        let values = (0..<array.count).map { array[$0].floatValue }
        guard values.allSatisfy({ $0.isFinite }) else {
            throw AppCoreMLEmbeddingError.inferenceFailed
        }
        return AppCoreMLEmbedding(identity: identity, values: values)
    }

    private static func loadArtifact(at directory: URL) throws -> (
        model: MLModel,
        identity: AppCoreMLModelIdentity
    ) {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let manifestData: Data
        let manifest: Manifest
        do {
            manifestData = try Data(contentsOf: manifestURL)
            manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
            try manifest.validate()
        } catch {
            throw ArtifactError.manifestInvalid
        }

        let licenseURL = directory.appendingPathComponent(manifest.license.file)
        guard try sha256(of: licenseURL) == manifest.license.sha256 else {
            throw ArtifactError.checksumMismatch
        }
        let modelURL = directory.appendingPathComponent(manifest.artifact.path)
        guard try directorySHA256(modelURL) == manifest.artifact.sha256 else {
            throw ArtifactError.checksumMismatch
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        let identity = AppCoreMLModelIdentity(
            provider: manifest.encoder.provider,
            modelID: manifest.encoder.modelID,
            modelRevision: manifest.encoder.modelRevision,
            preprocessingRevision: manifest.encoder.preprocessingRevision,
            elementCount: manifest.encoder.elementCount,
            artifactSHA256: manifest.artifact.sha256,
            manifestSHA256: SHA256.hash(data: manifestData).hexString,
            licenseID: manifest.license.id,
            licenseSHA256: manifest.license.sha256
        )
        return (model, identity)
    }

    private static func pixelValues(for image: CGImage) throws -> MLMultiArray {
        let side = 224
        let resizedShortEdge = 256.0
        let scale = resizedShortEdge / Double(min(image.width, image.height))
        let drawWidth = Double(image.width) * scale
        let drawHeight = Double(image.height) * scale
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress else { return false }
            guard let context = CGContext(
                data: baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .high
            context.draw(
                image,
                in: CGRect(
                    x: (Double(side) - drawWidth) / 2,
                    y: (Double(side) - drawHeight) / 2,
                    width: drawWidth,
                    height: drawHeight
                )
            )
            return true
        }
        guard rendered else {
            throw AppCoreMLEmbeddingError.inferenceFailed
        }

        let result = try MLMultiArray(
            shape: [1, 3, NSNumber(value: side), NSNumber(value: side)],
            dataType: .float32
        )
        let means: [Float] = [0.485, 0.456, 0.406]
        let standardDeviations: [Float] = [0.229, 0.224, 0.225]
        let planeSize = side * side
        let output = result.dataPointer.bindMemory(
            to: Float32.self,
            capacity: 3 * planeSize
        )
        for pixelIndex in 0..<planeSize {
            let sourceOffset = pixelIndex * 4
            for channel in 0..<3 {
                let scaled = Float(pixels[sourceOffset + channel]) / 255
                output[channel * planeSize + pixelIndex] =
                    (scaled - means[channel]) / standardDeviations[channel]
            }
        }
        return result
    }

    private static func sha256(of file: URL) throws -> String {
        guard
            let values = try? file.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            ),
            values.isRegularFile == true,
            values.isSymbolicLink != true
        else {
            throw ArtifactError.checksumMismatch
        }
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().hexString
    }

    private static func directorySHA256(_ directory: URL) throws -> String {
        let rootValues = try directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw ArtifactError.checksumMismatch
        }
        guard let enumerator = FileManager.default.enumerator(
            atPath: directory.path
        ) else {
            throw ArtifactError.checksumMismatch
        }
        var files: [(url: URL, relativePath: String, size: UInt64)] = []
        for case let relativePath as String in enumerator {
            let url = directory.appendingPathComponent(relativePath)
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            guard values.isSymbolicLink != true else {
                throw ArtifactError.checksumMismatch
            }
            guard values.isRegularFile == true else { continue }
            files.append((
                url,
                relativePath,
                UInt64(values.fileSize ?? 0)
            ))
        }
        files.sort { $0.relativePath < $1.relativePath }

        var hasher = SHA256()
        for file in files {
            let pathData = Data(file.relativePath.utf8)
            hasher.update(data: bigEndianData(UInt64(pathData.count)))
            hasher.update(data: pathData)
            hasher.update(data: bigEndianData(file.size))
            let handle = try FileHandle(forReadingFrom: file.url)
            defer { try? handle.close() }
            while true {
                let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
                if data.isEmpty { break }
                hasher.update(data: data)
            }
        }
        return hasher.finalize().hexString
    }

    private static func bigEndianData(_ value: UInt64) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }

    private struct Manifest: Decodable {
        let schemaRevision: Int
        let license: License
        let encoder: Encoder
        let artifact: Artifact
        let input: Tensor
        let output: Tensor

        enum CodingKeys: String, CodingKey {
            case schemaRevision = "schema_revision"
            case license, encoder, artifact, input, output
        }

        func validate() throws {
            guard
                schemaRevision == 1,
                license.id == "Apache-2.0",
                license.file == "LICENSE.txt",
                license.source == "https://raw.githubusercontent.com/facebookresearch/dinov2/7764ea0f912e53c92e82eb78a2a1631e92725fc8/LICENSE",
                license.sha256.isLowercaseSHA256,
                encoder == .approved,
                artifact.path == "encoder.mlmodelc",
                artifact.sha256.isLowercaseSHA256,
                artifact.format == "mlprogram-compiled",
                artifact.minimumDeploymentTarget == "macOS15",
                artifact.computePrecision == "float16",
                input == .approvedInput,
                output == .approvedOutput
            else {
                throw ArtifactError.manifestInvalid
            }
        }
    }

    private struct License: Decodable {
        let id: String
        let file: String
        let sha256: String
        let source: String
    }

    private struct Encoder: Decodable, Equatable {
        let provider: String
        let modelID: String
        let modelRevision: String
        let preprocessingRevision: String
        let elementCount: Int

        enum CodingKeys: String, CodingKey {
            case provider
            case modelID = "model_id"
            case modelRevision = "model_revision"
            case preprocessingRevision = "preprocessing_revision"
            case elementCount = "element_count"
        }

        static let approved = Encoder(
            provider: "dinov2",
            modelID: "facebook/dinov2-small",
            modelRevision: "ed25f3a31f01632728cabb09d1542f84ab7b0056",
            preprocessingRevision: "dinov2-hf-autoimageprocessor-v1",
            elementCount: 384
        )
    }

    private struct Artifact: Decodable {
        let path: String
        let sha256: String
        let format: String
        let minimumDeploymentTarget: String
        let computePrecision: String

        enum CodingKeys: String, CodingKey {
            case path, sha256, format
            case minimumDeploymentTarget = "minimum_deployment_target"
            case computePrecision = "compute_precision"
        }
    }

    private struct Tensor: Decodable, Equatable {
        let name: String
        let shape: [Int]
        let elementType: String

        enum CodingKeys: String, CodingKey {
            case name, shape
            case elementType = "element_type"
        }

        static let approvedInput = Tensor(
            name: "pixel_values",
            shape: [1, 3, 224, 224],
            elementType: "float32"
        )
        static let approvedOutput = Tensor(
            name: "embedding",
            shape: [1, 384],
            elementType: "float32"
        )
    }

    private enum ArtifactError: Error {
        case manifestInvalid
        case checksumMismatch
    }
}

private extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private extension String {
    var isLowercaseSHA256: Bool {
        count == 64 && allSatisfy { $0.isNumber || ("a"..."f").contains(String($0)) }
    }
}
