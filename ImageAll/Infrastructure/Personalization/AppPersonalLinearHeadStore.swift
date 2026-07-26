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

struct AppPersonalLinearHeadStagedArtifact: Equatable, Sendable {
    let identity: AppPersonalLinearHeadIdentity
    let artifactSHA256: String
}

enum AppPersonalLinearHeadFamily: String, Sendable {
    case centroid
    case adamW

    var directoryName: String {
        switch self {
        case .centroid: "LinearHead"
        case .adamW: "AdamWHead"
        }
    }

    var acceptedAlgorithmRevisions: Set<String> {
        switch self {
        case .centroid: ["positive-centroid-float32-v1"]
        case .adamW: ["positive-adamw-float32-v1"]
        }
    }

    var objectExtension: String {
        switch self {
        case .centroid: "personal-head"
        case .adamW: "personal-adamw-head"
        }
    }
}

actor AppPersonalLinearHeadStore {
    private static let pointerSchemaRevision = 1

    private let family: AppPersonalLinearHeadFamily
    private let applicationSupportDirectory: URL
    private let expectedCatalogScopeID: String
    private let expectedEncoderIdentity: AppCoreMLModelIdentity
    private var activeModels: [UUID: AppPersonalLinearHeadModel] = [:]
    private var state: AppPersonalLinearHeadCapability = .unavailable(.artifactMissing)

    init(
        applicationSupportDirectory: URL,
        expectedCatalogScopeID: String,
        expectedEncoderIdentity: AppCoreMLModelIdentity,
        family: AppPersonalLinearHeadFamily = .centroid
    ) {
        self.family = family
        self.applicationSupportDirectory = applicationSupportDirectory
        self.expectedCatalogScopeID = expectedCatalogScopeID
        self.expectedEncoderIdentity = expectedEncoderIdentity
    }

    func start() -> AppPersonalLinearHeadCapability {
        migrateLegacyActivePointerIfNeeded()
        let loaded = loadAllActive()
        activeModels = loaded.models
        state = loaded.capability
        return state
    }

    func start(publishedArtifactSHA256: String?) -> AppPersonalLinearHeadCapability {
        do {
            guard let publishedArtifactSHA256 else {
                return start()
            }
            _ = start()
            return try activate(artifactSHA256: publishedArtifactSHA256)
        } catch let error as AppPersonalLinearHeadStoreError {
            state = switch error {
            case .identityMismatch: .unavailable(.identityMismatch)
            case .invalidCandidate, .persistenceFailed, .unavailable:
                .unavailable(.artifactInvalid)
            }
            return state
        } catch {
            state = .unavailable(.artifactInvalid)
            return state
        }
    }

    func start(publishedArtifacts: [UUID: String]) -> AppPersonalLinearHeadCapability {
        migrateLegacyActivePointerIfNeeded()
        guard !publishedArtifacts.isEmpty else {
            do {
                try clearAllActivePointers()
            } catch {
                // Best-effort clear; fall through to unavailable.
            }
            activeModels = [:]
            state = .unavailable(.artifactMissing)
            return state
        }
        var models: [UUID: AppPersonalLinearHeadModel] = [:]
        for (_, sha) in publishedArtifacts.sorted(by: {
            $0.key.uuidString.lowercased() < $1.key.uuidString.lowercased()
        }) {
            do {
                _ = try activate(artifactSHA256: sha)
                if case let .ready(identity) = state,
                   let tagID = identity.personalTagIDs.first,
                   let model = activeModels[tagID]
                {
                    models[tagID] = model
                }
            } catch {
                // Skip a single bad published artifact; keep other tags usable.
                continue
            }
        }
        do {
            try removeActivePointers(except: Set(models.keys))
        } catch {
            // Pointer cleanup is best-effort; in-memory models remain authoritative.
        }
        activeModels = models
        if models.isEmpty {
            state = .unavailable(.artifactMissing)
        } else {
            let sorted = models.values.map(\.identity).sorted {
                $0.personalTagIDs[0].uuidString.lowercased()
                    < $1.personalTagIDs[0].uuidString.lowercased()
            }
            state = .ready(sorted[0])
        }
        return state
    }

    func capability() -> AppPersonalLinearHeadCapability {
        state
    }

    func identities() -> [AppPersonalLinearHeadIdentity] {
        activeModels.values.map(\.identity).sorted {
            $0.personalTagIDs[0].uuidString.lowercased()
                < $1.personalTagIDs[0].uuidString.lowercased()
        }
    }

    func suggestions(
        for embedding: AppCoreMLEmbedding,
        maximumCount: Int
    ) throws -> [AppPersonalLinearHeadSuggestion] {
        guard !activeModels.isEmpty else {
            throw AppPersonalLinearHeadStoreError.unavailable
        }
        var combined: [AppPersonalLinearHeadSuggestion] = []
        for model in activeModels.values {
            combined.append(
                contentsOf: try model.suggestions(for: embedding, maximumCount: maximumCount)
            )
        }
        return Array(
            combined
                .sorted {
                    if $0.score == $1.score {
                        return $0.tagID.uuidString.lowercased()
                            < $1.tagID.uuidString.lowercased()
                    }
                    return $0.score > $1.score
                }
                .prefix(maximumCount)
        )
    }

    func score(
        tagID: UUID,
        embedding: AppCoreMLEmbedding
    ) throws -> Float? {
        guard let model = activeModels[tagID] else {
            throw AppPersonalLinearHeadStoreError.unavailable
        }
        return try model.score(tagID: tagID, embedding: embedding)
    }

    func publish(
        _ artifact: AppPersonalLinearHeadArtifact
    ) throws -> AppPersonalLinearHeadCapability {
        let staged = try stage(artifact)
        return try activate(artifactSHA256: staged.artifactSHA256)
    }

    func stage(
        _ artifact: AppPersonalLinearHeadArtifact
    ) throws -> AppPersonalLinearHeadStagedArtifact {
        let model: AppPersonalLinearHeadModel
        do {
            model = try AppPersonalLinearHeadModel(artifact: artifact)
        } catch {
            throw AppPersonalLinearHeadStoreError.invalidCandidate
        }
        guard matchesFamily(model),
              model.identity.personalTagIDs.count == 1
        else {
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
                  matchesFamily(reloadedModel)
            else {
                throw AppPersonalLinearHeadStoreError.persistenceFailed
            }
            return AppPersonalLinearHeadStagedArtifact(
                identity: reloadedModel.identity,
                artifactSHA256: artifactSHA256
            )
        } catch {
            throw AppPersonalLinearHeadStoreError.persistenceFailed
        }
    }

    func activate(artifactSHA256: String) throws -> AppPersonalLinearHeadCapability {
        guard Self.isLowercaseSHA256(artifactSHA256) else {
            throw AppPersonalLinearHeadStoreError.invalidCandidate
        }
        do {
            try ensureStoreDirectories()
            let artifactData = try readRegularFile(at: objectURL(artifactSHA256: artifactSHA256))
            guard Self.sha256(artifactData) == artifactSHA256,
                  let model = try? AppPersonalLinearHeadModel(
                      artifact: AppPersonalLinearHeadArtifact(encodedData: artifactData)
                  ),
                  matchesFamily(model),
                  model.identity.personalTagIDs.count == 1,
                  let tagID = model.identity.personalTagIDs.first
            else {
                throw AppPersonalLinearHeadStoreError.identityMismatch
            }
            let pointer = ActivePointer(
                schemaRevision: Self.pointerSchemaRevision,
                artifactSHA256: artifactSHA256
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let pointerURL = activePointerURL(for: tagID)
            try FileManager.default.createDirectory(
                at: pointerURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try requireRegularFileOrMissing(at: pointerURL)
            try encoder.encode(pointer).write(to: pointerURL, options: .atomic)
            guard DerivedImageSecureIO.isRegularFile(at: pointerURL) else {
                throw AppPersonalLinearHeadStoreError.persistenceFailed
            }
            activeModels[tagID] = model
            state = .ready(model.identity)
            return state
        } catch let error as AppPersonalLinearHeadStoreError {
            throw error
        } catch {
            throw AppPersonalLinearHeadStoreError.persistenceFailed
        }
    }

    private func clearAllActivePointers() throws {
        try removeActivePointers(except: [])
    }

    private func removeActivePointers(except keepTagIDs: Set<UUID>) throws {
        migrateLegacyActivePointerIfNeeded()
        let tagsRoot = tagsDirectory
        guard FileManager.default.fileExists(atPath: tagsRoot.path) else {
            try clearLegacyRootPointer()
            return
        }
        let keep = Set(keepTagIDs.map { $0.uuidString.lowercased() })
        let contents = try FileManager.default.contentsOfDirectory(
            at: tagsRoot,
            includingPropertiesForKeys: nil
        )
        for directory in contents where directory.hasDirectoryPath {
            let tagKey = directory.lastPathComponent.lowercased()
            guard !keep.contains(tagKey) else { continue }
            let pointer = directory.appendingPathComponent("active.json")
            if FileManager.default.fileExists(atPath: pointer.path) {
                try FileManager.default.removeItem(at: pointer)
            }
        }
        try clearLegacyRootPointer()
    }

    private func clearLegacyRootPointer() throws {
        guard FileManager.default.fileExists(atPath: legacyActivePointerURL.path) else { return }
        guard try requireRegularFileOrMissing(at: legacyActivePointerURL) else { return }
        try FileManager.default.removeItem(at: legacyActivePointerURL)
    }

    private func migrateLegacyActivePointerIfNeeded() {
        guard FileManager.default.fileExists(atPath: legacyActivePointerURL.path) else { return }
        do {
            let pointerData = try readRegularFile(at: legacyActivePointerURL)
            let pointer = try JSONDecoder().decode(ActivePointer.self, from: pointerData)
            guard pointer.schemaRevision == Self.pointerSchemaRevision,
                  Self.isLowercaseSHA256(pointer.artifactSHA256)
            else { return }
            let artifactData = try readRegularFile(
                at: objectURL(artifactSHA256: pointer.artifactSHA256)
            )
            guard Self.sha256(artifactData) == pointer.artifactSHA256 else { return }
            let model = try AppPersonalLinearHeadModel(
                artifact: AppPersonalLinearHeadArtifact(encodedData: artifactData)
            )
            guard model.identity.personalTagIDs.count == 1,
                  let tagID = model.identity.personalTagIDs.first
            else { return }
            let destination = activePointerURL(for: tagID)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: destination.path) {
                try pointerData.write(to: destination, options: .atomic)
            }
            try FileManager.default.removeItem(at: legacyActivePointerURL)
        } catch {
            return
        }
    }

    private func loadAllActive() -> (
        models: [UUID: AppPersonalLinearHeadModel],
        capability: AppPersonalLinearHeadCapability
    ) {
        switch storeDirectoryReadState() {
        case .missing:
            return ([:], .unavailable(.artifactMissing))
        case .invalid:
            return ([:], .unavailable(.artifactInvalid))
        case .ready:
            break
        }
        var models: [UUID: AppPersonalLinearHeadModel] = [:]
        var emptyFailure: AppPersonalLinearHeadCapabilityFailure?
        let tagsRoot = tagsDirectory
        if FileManager.default.fileExists(atPath: tagsRoot.path),
           let contents = try? FileManager.default.contentsOfDirectory(
               at: tagsRoot,
               includingPropertiesForKeys: nil
           )
        {
            for directory in contents where directory.hasDirectoryPath {
                let pointerURL = directory.appendingPathComponent("active.json")
                guard FileManager.default.fileExists(atPath: pointerURL.path) else { continue }
                do {
                    let pointerData = try readRegularFile(at: pointerURL)
                    let pointer = try JSONDecoder().decode(ActivePointer.self, from: pointerData)
                    guard pointer.schemaRevision == Self.pointerSchemaRevision,
                          Self.isLowercaseSHA256(pointer.artifactSHA256)
                    else {
                        emptyFailure = .artifactInvalid
                        continue
                    }
                    let artifactData = try readRegularFile(
                        at: objectURL(artifactSHA256: pointer.artifactSHA256)
                    )
                    guard Self.sha256(artifactData) == pointer.artifactSHA256 else {
                        emptyFailure = .artifactInvalid
                        continue
                    }
                    let model = try AppPersonalLinearHeadModel(
                        artifact: AppPersonalLinearHeadArtifact(encodedData: artifactData)
                    )
                    guard family.acceptedAlgorithmRevisions.contains(model.algorithmRevision),
                          model.identity.personalTagIDs.count == 1,
                          let tagID = model.identity.personalTagIDs.first,
                          tagID.uuidString.lowercased() == directory.lastPathComponent.lowercased()
                    else {
                        emptyFailure = .artifactInvalid
                        continue
                    }
                    guard matchesExpectedIdentity(model.identity) else {
                        emptyFailure = .identityMismatch
                        continue
                    }
                    models[tagID] = model
                } catch {
                    // One corrupt tag pointer must not disable other healthy tags.
                    emptyFailure = .artifactInvalid
                    continue
                }
            }
        }
        if models.isEmpty {
            return ([:], .unavailable(emptyFailure ?? .artifactMissing))
        }
        let sorted = models.values.map(\.identity).sorted {
            $0.personalTagIDs[0].uuidString.lowercased()
                < $1.personalTagIDs[0].uuidString.lowercased()
        }
        return (models, .ready(sorted[0]))
    }

    private func matchesExpectedIdentity(_ identity: AppPersonalLinearHeadIdentity) -> Bool {
        identity.catalogScopeID == expectedCatalogScopeID
            && identity.encoderIdentity == expectedEncoderIdentity
    }

    private func matchesFamily(_ model: AppPersonalLinearHeadModel) -> Bool {
        family.acceptedAlgorithmRevisions.contains(model.algorithmRevision)
            && matchesExpectedIdentity(model.identity)
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
            "PersonalModels/\(family.directoryName)/v1",
            isDirectory: true
        )
    }

    private var objectsDirectory: URL {
        storeRoot.appendingPathComponent("objects", isDirectory: true)
    }

    private var tagsDirectory: URL {
        storeRoot.appendingPathComponent("tags", isDirectory: true)
    }

    private var storeDirectoryChain: [URL] {
        [
            applicationSupportDirectory,
            applicationSupportDirectory.appendingPathComponent("PersonalModels", isDirectory: true),
            applicationSupportDirectory.appendingPathComponent(
                "PersonalModels/\(family.directoryName)",
                isDirectory: true
            ),
            storeRoot,
            objectsDirectory,
            tagsDirectory,
        ]
    }

    private var legacyActivePointerURL: URL {
        storeRoot.appendingPathComponent("active.json")
    }

    private func activePointerURL(for tagID: UUID) -> URL {
        tagsDirectory
            .appendingPathComponent(tagID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("active.json")
    }

    private func objectURL(artifactSHA256: String) -> URL {
        objectsDirectory.appendingPathComponent("\(artifactSHA256).\(family.objectExtension)")
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
