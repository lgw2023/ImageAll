import Foundation

enum FolderReconcileSafeErrorCode {
    static let payloadInvalid = JobSafeErrorCode.folderPayloadInvalid
    static let checkpointInvalid = JobSafeErrorCode.folderCheckpointInvalid
    static let authorizationRequired = JobSafeErrorCode.folderAuthorizationRequired
    static let sourceUnavailable = JobSafeErrorCode.folderSourceUnavailable
    static let enumerationIncomplete = JobSafeErrorCode.folderEnumerationIncomplete
    static let unsafeRelativePath = JobSafeErrorCode.folderUnsafeRelativePath
}

enum FolderReconcileSafeErrorSettlement {
    static func outcome(for code: JobSafeErrorCode) -> JobHandlerOutcome {
        switch code {
        case .folderSourceUnavailable, .folderEnumerationIncomplete:
            return .retryableFailure(code: code)
        case .folderPayloadInvalid, .folderCheckpointInvalid, .folderAuthorizationRequired, .folderUnsafeRelativePath:
            return .nonRetryableFailure(code: code)
        default:
            return .nonRetryableFailure(code: code)
        }
    }
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
        guard StrictJSONValidation.exactObjectKeys(object, allowed: allowedKeys) else {
            return .failure(.invalid(FolderReconcileSafeErrorCode.payloadInvalid))
        }

        guard StrictJSONValidation.exactContractVersion(object["contract_version"]) != nil else {
            return .failure(.invalid(FolderReconcileSafeErrorCode.payloadInvalid))
        }

        guard let sourceIDString = StrictJSONValidation.lowercaseCanonicalUUIDString(object["source_id"]),
              let sourceID = UUID(uuidString: sourceIDString)
        else {
            return .failure(.invalid(FolderReconcileSafeErrorCode.payloadInvalid))
        }

        guard let jobSourceID, jobSourceID == sourceID else {
            return .failure(.invalid(FolderReconcileSafeErrorCode.payloadInvalid))
        }

        return .success(
            ValidPayload(
                sourceID: sourceID,
                contractVersion: FolderReconcileJobFactory.contractVersion
            )
        )
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
        guard StrictJSONValidation.exactObjectKeys(object, allowed: allowedKeys) else {
            throw FolderReconcileCheckpointError.invalidShape
        }

        guard StrictJSONValidation.exactCheckpointContractVersion(object["contract_version"]) != nil,
              let generation = StrictJSONValidation.positiveInteger(object["generation"]),
              let startedDirtyEpoch = StrictJSONValidation.nonNegativeInteger(object["started_dirty_epoch"]),
              let attempt = StrictJSONValidation.positiveInteger(object["attempt"]),
              let enumeratedEntries = StrictJSONValidation.nonNegativeInteger(object["enumerated_entries"]),
              let candidateFiles = StrictJSONValidation.nonNegativeInteger(object["candidate_files"]),
              let committedAssets = StrictJSONValidation.nonNegativeInteger(object["committed_assets"]),
              let ignoredEntries = StrictJSONValidation.nonNegativeInteger(object["ignored_entries"]),
              let unsupportedAssets = StrictJSONValidation.nonNegativeInteger(object["unsupported_assets"]),
              let unreadableAssets = StrictJSONValidation.nonNegativeInteger(object["unreadable_assets"]),
              let identityConflicts = StrictJSONValidation.nonNegativeInteger(object["identity_conflicts"])
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

    static func validateResumable(
        _ checkpoint: FolderReconcileCheckpointV1,
        scanGeneration: Int?,
        startedDirtyEpoch: Int?,
        currentAttempt: Int
    ) -> Bool {
        guard let scanGeneration, let startedDirtyEpoch else {
            return false
        }
        guard checkpoint.generation == scanGeneration,
              checkpoint.startedDirtyEpoch == startedDirtyEpoch
        else {
            return false
        }
        return checkpoint.attempt <= currentAttempt
    }

    static func validateAgainstJob(
        _ checkpoint: FolderReconcileCheckpointV1,
        scanGeneration: Int?,
        startedDirtyEpoch: Int?,
        attempt: Int
    ) -> Bool {
        guard let scanGeneration, let startedDirtyEpoch else {
            return false
        }
        return checkpoint.generation == scanGeneration
            && checkpoint.startedDirtyEpoch == startedDirtyEpoch
            && checkpoint.attempt == attempt
    }
}

enum FolderReconcileCheckpointError: Error, Equatable {
    case invalidShape
}
