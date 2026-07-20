import CryptoKit
import Darwin
import Foundation

enum AppPersonalLinearHeadCapabilityFailure: Equatable, Sendable {
    case artifactMissing
    case artifactInvalid
    case identityMismatch
}

enum AppPersonalLinearHeadCapability: Equatable, Sendable {
    case unavailable(AppPersonalLinearHeadCapabilityFailure)
    case ready(AppPersonalLinearHeadIdentity)
}

enum AppPersonalLinearHeadStoreError: Error, Equatable {
    case invalidCandidate
    case identityMismatch
    case persistenceFailed
    case unavailable
}

actor AppPersonalLinearHeadStore {
    private static let pointerSchemaRevision = 1

    private let applicationSupportDirectory: URL
    private let expectedCatalogScopeID: String
    private let expectedEncoderIdentity: AppCoreMLModelIdentity
    private var activeModel: AppPersonalLinearHeadModel?
    private var state: AppPersonalLinearHeadCapability = .unavailable(.artifactMissing)

    init(
        applicationSupportDirectory: URL,
        expectedCatalogScopeID: String,
        expectedEncoderIdentity: AppCoreMLModelIdentity
    ) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.expectedCatalogScopeID = expectedCatalogScopeID
        self.expectedEncoderIdentity = expectedEncoderIdentity
    }

    func start() -> AppPersonalLinearHeadCapability {
        let loaded = loadActive()
        activeModel = loaded.model
        state = loaded.capability
        return state
    }

    func capability() -> AppPersonalLinearHeadCapability {
        state
    }

    func suggestions(
        for embedding: AppCoreMLEmbedding,
        maximumCount: Int
    ) throws -> [AppPersonalLinearHeadSuggestion] {
        guard let activeModel,
              state == .ready(activeModel.identity)
        else {
            throw AppPersonalLinearHeadStoreError.unavailable
        }
        return try activeModel.suggestions(for: embedding, maximumCount: maximumCount)
    }

    func publish(
        _ artifact: AppPersonalLinearHeadArtifact
    ) throws -> AppPersonalLinearHeadCapability {
        let model: AppPersonalLinearHeadModel
        do {
            model = try AppPersonalLinearHeadModel(artifact: artifact)
        } catch {
            throw AppPersonalLinearHeadStoreError.invalidCandidate
        }
        guard matchesExpectedIdentity(model.identity) else {
            throw AppPersonalLinearHeadStoreError.identityMismatch
        }

        do {
            try ensureStoreDirectories()
            let artifactSHA256 = Self.sha256(artifact.encodedData)
            let candidateURL = objectURL(artifactSHA256: artifactSHA256)
            try publishCandidateObject(
                artifact,
                artifactSHA256: artifactSHA256,
                at: candidateURL
            )
            let reloadedData = try readRegularFile(at: candidateURL)
            guard Self.sha256(reloadedData) == artifactSHA256,
                  reloadedData == artifact.encodedData,
                  let reloadedModel = try? AppPersonalLinearHeadModel(
                      artifact: AppPersonalLinearHeadArtifact(encodedData: reloadedData)
                  ),
                  reloadedModel.identity == model.identity,
                  matchesExpectedIdentity(reloadedModel.identity)
            else {
                throw AppPersonalLinearHeadStoreError.persistenceFailed
            }
            let pointer = ActivePointer(
                schemaRevision: Self.pointerSchemaRevision,
                artifactSHA256: artifactSHA256
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try requireRegularFileOrMissing(at: activePointerURL)
            try encoder.encode(pointer).write(to: activePointerURL, options: .atomic)
            guard DerivedImageSecureIO.isRegularFile(at: activePointerURL) else {
                throw AppPersonalLinearHeadStoreError.persistenceFailed
            }
        } catch {
            throw AppPersonalLinearHeadStoreError.persistenceFailed
        }

        let loaded = loadActive()
        guard loaded.capability == .ready(model.identity) else {
            throw AppPersonalLinearHeadStoreError.persistenceFailed
        }
        activeModel = loaded.model
        state = loaded.capability
        return state
    }

    private func loadActive() -> (
        model: AppPersonalLinearHeadModel?,
        capability: AppPersonalLinearHeadCapability
    ) {
        switch storeDirectoryReadState() {
        case .missing:
            return (nil, .unavailable(.artifactMissing))
        case .invalid:
            return (nil, .unavailable(.artifactInvalid))
        case .ready:
            break
        }
        guard FileManager.default.fileExists(atPath: activePointerURL.path) else {
            return (nil, .unavailable(.artifactMissing))
        }
        do {
            let pointerData = try readRegularFile(at: activePointerURL)
            let pointer = try JSONDecoder().decode(ActivePointer.self, from: pointerData)
            guard pointer.schemaRevision == Self.pointerSchemaRevision,
                  Self.isLowercaseSHA256(pointer.artifactSHA256)
            else {
                return (nil, .unavailable(.artifactInvalid))
            }
            let artifactData = try readRegularFile(
                at: objectURL(artifactSHA256: pointer.artifactSHA256)
            )
            guard Self.sha256(artifactData) == pointer.artifactSHA256 else {
                return (nil, .unavailable(.artifactInvalid))
            }
            let model = try AppPersonalLinearHeadModel(
                artifact: AppPersonalLinearHeadArtifact(encodedData: artifactData)
            )
            guard matchesExpectedIdentity(model.identity) else {
                return (nil, .unavailable(.identityMismatch))
            }
            return (model, .ready(model.identity))
        } catch {
            return (nil, .unavailable(.artifactInvalid))
        }
    }

    private func matchesExpectedIdentity(_ identity: AppPersonalLinearHeadIdentity) -> Bool {
        identity.catalogScopeID == expectedCatalogScopeID
            && identity.encoderIdentity == expectedEncoderIdentity
    }

    private func ensureStoreDirectories() throws {
        for directory in storeDirectoryChain {
            try DerivedImageSecureIO.ensureDirectory(at: directory)
            guard !DerivedImageSecureIO.isSymlink(at: directory) else {
                throw DerivedImageSecureIOError.unsafePath
            }
        }
    }

    private func storeDirectoryReadState() -> StoreDirectoryReadState {
        for directory in storeDirectoryChain {
            var status = stat()
            if lstat(directory.path, &status) == 0 {
                guard status.st_mode & S_IFMT == S_IFDIR else {
                    return .invalid
                }
                continue
            }
            return errno == ENOENT ? .missing : .invalid
        }
        return .ready
    }

    private func publishCandidateObject(
        _ artifact: AppPersonalLinearHeadArtifact,
        artifactSHA256: String,
        at url: URL
    ) throws {
        let entryExists = try requireRegularFileOrMissing(at: url)
        if entryExists {
            let existing = try readRegularFile(at: url)
            guard existing == artifact.encodedData,
                  Self.sha256(existing) == artifactSHA256
            else {
                throw AppPersonalLinearHeadStoreError.persistenceFailed
            }
            return
        }
        try artifact.encodedData.write(to: url, options: .atomic)
        guard DerivedImageSecureIO.isRegularFile(at: url) else {
            throw AppPersonalLinearHeadStoreError.persistenceFailed
        }
    }

    @discardableResult
    private func requireRegularFileOrMissing(at url: URL) throws -> Bool {
        var status = stat()
        if lstat(url.path, &status) == 0 {
            guard status.st_mode & S_IFMT == S_IFREG else {
                throw DerivedImageSecureIOError.unsafePath
            }
            return true
        }
        guard errno == ENOENT else {
            throw DerivedImageSecureIOError.ioFailure
        }
        return false
    }

    private func readRegularFile(at url: URL) throws -> Data {
        let descriptor = try DerivedImageSecureIO.openReadOnlyNoFollow(at: url)
        defer { Darwin.close(descriptor) }
        try DerivedImageSecureIO.verifyRegularFileFD(descriptor)
        return try DerivedImageSecureIO.readAllBytes(from: descriptor)
    }

    private var storeRoot: URL {
        applicationSupportDirectory.appendingPathComponent(
            "PersonalModels/LinearHead/v1",
            isDirectory: true
        )
    }

    private var objectsDirectory: URL {
        storeRoot.appendingPathComponent("objects", isDirectory: true)
    }

    private var storeDirectoryChain: [URL] {
        [
            applicationSupportDirectory,
            applicationSupportDirectory.appendingPathComponent("PersonalModels", isDirectory: true),
            applicationSupportDirectory.appendingPathComponent(
                "PersonalModels/LinearHead",
                isDirectory: true
            ),
            storeRoot,
            objectsDirectory,
        ]
    }

    private var activePointerURL: URL {
        storeRoot.appendingPathComponent("active.json")
    }

    private func objectURL(artifactSHA256: String) -> URL {
        objectsDirectory.appendingPathComponent("\(artifactSHA256).personal-head")
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64
            && value.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "0123456789abcdef").contains($0)
            }
    }

    private struct ActivePointer: Codable {
        let schemaRevision: Int
        let artifactSHA256: String
    }

    private enum StoreDirectoryReadState {
        case missing
        case invalid
        case ready
    }
}
