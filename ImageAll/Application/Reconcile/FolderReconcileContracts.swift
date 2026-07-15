import Foundation

enum FolderReconcileSafeErrorCode {
    static let payloadInvalid = JobSafeErrorCode.folderPayloadInvalid
    static let checkpointInvalid = JobSafeErrorCode.folderCheckpointInvalid
    static let authorizationRequired = JobSafeErrorCode.folderAuthorizationRequired
    static let sourceUnavailable = JobSafeErrorCode.folderSourceUnavailable
    static let enumerationIncomplete = JobSafeErrorCode.folderEnumerationIncomplete
    static let unsafeRelativePath = JobSafeErrorCode.folderUnsafeRelativePath
}

enum FolderReconcilePayloadValidation {
    struct ValidPayload: Equatable, Sendable {
        let sourceID: UUID
        let contractVersion: Int
    }

    enum ValidationFailure: Equatable, Error {
        case invalid(JobSafeErrorCode)
    }

    static func validate(
        payloadVersion: Int,
        payload: Data,
        jobSourceID: UUID?
    ) -> Result<ValidPayload, ValidationFailure> {
        guard payloadVersion == FolderReconcileJobFactory.payloadVersion else {
            return .failure(.invalid(JobSafeErrorCode.folderPayloadInvalid))
        }

        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return .failure(.invalid(FolderReconcileSafeErrorCode.payloadInvalid))
        }

        let allowedKeys: Set<String> = ["contract_version", "source_id"]
        guard Set(object.keys) == allowedKeys else {
            return .failure(.invalid(FolderReconcileSafeErrorCode.payloadInvalid))
        }

        guard let contractVersion = object["contract_version"] as? Int,
              contractVersion == FolderReconcileJobFactory.contractVersion
        else {
            return .failure(.invalid(FolderReconcileSafeErrorCode.payloadInvalid))
        }

        guard let sourceIDString = object["source_id"] as? String,
              let sourceID = UUID(uuidString: sourceIDString),
              sourceID.uuidString.lowercased() == sourceIDString.lowercased()
        else {
            return .failure(.invalid(FolderReconcileSafeErrorCode.payloadInvalid))
        }

        guard let jobSourceID, jobSourceID == sourceID else {
            return .failure(.invalid(FolderReconcileSafeErrorCode.payloadInvalid))
        }

        return .success(ValidPayload(sourceID: sourceID, contractVersion: contractVersion))
    }
}

enum FolderReconcileCheckpointCodec {
    static func encode(_ checkpoint: FolderReconcileCheckpointV1) throws -> Data {
        let encoder = JSONEncoder()
        return try encoder.encode(checkpoint)
    }

    static func decode(_ data: Data) throws -> FolderReconcileCheckpointV1 {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FolderReconcileCheckpointError.invalidShape
        }

        let allowedKeys: Set<String> = [
            "contract_version",
            "generation",
            "started_dirty_epoch",
            "attempt",
            "enumerated_entries",
            "candidate_files",
            "committed_assets",
            "ignored_entries",
            "unsupported_assets",
            "unreadable_assets",
            "identity_conflicts",
        ]
        guard Set(object.keys) == allowedKeys else {
            throw FolderReconcileCheckpointError.invalidShape
        }

        guard let contractVersion = object["contract_version"] as? Int,
              contractVersion == FolderReconcileCheckpointV1.contractVersionValue,
              let generation = object["generation"] as? Int, generation > 0,
              let startedDirtyEpoch = object["started_dirty_epoch"] as? Int, startedDirtyEpoch >= 0,
              let attempt = object["attempt"] as? Int, attempt > 0,
              let enumeratedEntries = object["enumerated_entries"] as? Int, enumeratedEntries >= 0,
              let candidateFiles = object["candidate_files"] as? Int, candidateFiles >= 0,
              let committedAssets = object["committed_assets"] as? Int, committedAssets >= 0,
              let ignoredEntries = object["ignored_entries"] as? Int, ignoredEntries >= 0,
              let unsupportedAssets = object["unsupported_assets"] as? Int, unsupportedAssets >= 0,
              let unreadableAssets = object["unreadable_assets"] as? Int, unreadableAssets >= 0,
              let identityConflicts = object["identity_conflicts"] as? Int, identityConflicts >= 0
        else {
            throw FolderReconcileCheckpointError.invalidShape
        }

        return FolderReconcileCheckpointV1(
            generation: generation,
            startedDirtyEpoch: startedDirtyEpoch,
            attempt: attempt,
            enumeratedEntries: enumeratedEntries,
            candidateFiles: candidateFiles,
            committedAssets: committedAssets,
            ignoredEntries: ignoredEntries,
            unsupportedAssets: unsupportedAssets,
            unreadableAssets: unreadableAssets,
            identityConflicts: identityConflicts
        )
    }

    static func validateAgainstJob(
        _ checkpoint: FolderReconcileCheckpointV1,
        scanGeneration: Int?,
        startedDirtyEpoch: Int?
    ) -> Bool {
        guard let scanGeneration, let startedDirtyEpoch else {
            return false
        }
        return checkpoint.generation == scanGeneration
            && checkpoint.startedDirtyEpoch == startedDirtyEpoch
    }
}

enum FolderReconcileCheckpointError: Error, Equatable {
    case invalidShape
}
