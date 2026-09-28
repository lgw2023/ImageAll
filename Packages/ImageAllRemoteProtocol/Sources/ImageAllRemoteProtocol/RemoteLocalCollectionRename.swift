import Foundation

public extension RemoteHTTPPaths {
    static let localLibraryCollectionRename = "/v1/sync/local-library/collection-rename"
}

/// Command IDs belong to the collection-name command namespace, separate from member edits.
public struct RemoteLocalCollectionRenameRequest: Codable, Sendable, Equatable {
    public let commandID: UUID
    public let hostID: UUID
    public let installID: UUID
    public let sourceEpoch: UUID
    public let scopeRevision: Int64
    public let snapshotSequence: Int64
    public let expectedChangeCursor: Int64
    public let collectionID: UUID
    public let expectedName: String
    public let newName: String

    public init(commandID: UUID, hostID: UUID, installID: UUID, sourceEpoch: UUID,
                scopeRevision: Int64, snapshotSequence: Int64, expectedChangeCursor: Int64,
                collectionID: UUID, expectedName: String, newName: String) {
        self.commandID = commandID
        self.hostID = hostID
        self.installID = installID
        self.sourceEpoch = sourceEpoch
        self.scopeRevision = scopeRevision
        self.snapshotSequence = snapshotSequence
        self.expectedChangeCursor = expectedChangeCursor
        self.collectionID = collectionID
        self.expectedName = expectedName
        self.newName = newName
    }
}

/// Historical acknowledgement; the phone must still pull name changes before applying them locally.
public struct RemoteLocalCollectionRenameReceipt: Codable, Sendable, Equatable {
    public let request: RemoteLocalCollectionRenameRequest
    public let deviceID: UUID
    public let resultingChangeCursor: Int64

    public init(request: RemoteLocalCollectionRenameRequest, deviceID: UUID, resultingChangeCursor: Int64) {
        self.request = request
        self.deviceID = deviceID
        self.resultingChangeCursor = resultingChangeCursor
    }
}
