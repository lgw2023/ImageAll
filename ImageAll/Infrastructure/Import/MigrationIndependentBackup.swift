import Foundation
import DiskArbitration
import IOKit
import GRDB

struct MigrationBackupStorageIdentity: Codable, Equatable, Sendable {
    let volumeUUID: String
    /// Current registry IDs are observations, not persistent device identities.
    let domains: Set<String>

    func isIndependent(of other: Self) -> Bool {
        !volumeUUID.isEmpty && !other.volumeUUID.isEmpty && volumeUUID != other.volumeUUID
            && !domains.isEmpty && !other.domains.isEmpty && domains.isDisjoint(with: other.domains)
    }
}

enum MigrationBackupError: LocalizedError {
    case storageUnknown, notIndependent, changed, missingRecord
    var errorDescription: String? {
        switch self {
        case .storageUnknown: "无法确认底层存储独立性；请选择可识别的本机磁盘或 USB 外置磁盘。"
        case .notIndependent: "备份与归档位于相同卷或共享底层存储，请选择另一台存储设备。"
        case .changed: "备份、归档、卷身份或完成回执已变化，请重新核对。"
        case .missingRecord: "找不到匹配的备份记录。"
        }
    }
}

enum MigrationBackupStorage {
    static func resolve(_ url: URL) throws -> MigrationBackupStorageIdentity {
        let values = try url.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeIsLocalKey, .volumeURLKey])
        guard values.volumeIsLocal == true, let uuid = values.volumeUUIDString, !uuid.isEmpty,
              let volumeURL = values.volume,
              let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volumeURL as CFURL) else {
            throw MigrationBackupError.storageUnknown
        }
        let media = DADiskCopyIOMedia(disk)
        guard media != 0 else { throw MigrationBackupError.storageUnknown }
        defer { IOObjectRelease(media) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(media, kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents), &iterator) == KERN_SUCCESS else {
            throw MigrationBackupError.storageUnknown
        }
        defer { IOObjectRelease(iterator) }
        var domains = Set<String>()
        var count = 0
        while case let node = IOIteratorNext(iterator), node != 0 {
            defer { IOObjectRelease(node) }
            count += 1
            guard count <= 512 else { throw MigrationBackupError.storageUnknown }
            guard IOObjectConformsTo(node, "IOBlockStorageDevice") != 0 else { continue }
            guard let properties = IORegistryEntryCreateCFProperty(node,
                "Protocol Characteristics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
                  let transport = properties["Physical Interconnect"] as? String,
                  let location = properties["Physical Interconnect Location"] as? String else {
                throw MigrationBackupError.storageUnknown
            }
            if location == "Internal", ["PCI-Express", "Apple Fabric", "SATA", "ATA", "NVMe"].contains(transport) {
                // Conservatively group every internal drive; never infer
                // separate fault domains from partitions or namespaces.
                domains.insert("internal-storage")
            } else if location == "External", transport == "USB" {
                domains.insert("usb-device-\(try nearestUSBDevice(node))")
            } else {
                // Virtual disks, remote storage and unknown stacks do not
                // silently degrade to a path or volume-name comparison.
                throw MigrationBackupError.storageUnknown
            }
        }
        guard IOIteratorIsValid(iterator) != 0, !domains.isEmpty else {
            throw MigrationBackupError.storageUnknown
        }
        return .init(volumeUUID: uuid, domains: domains)
    }

    private static func nearestUSBDevice(_ entry: io_registry_entry_t) throws -> UInt64 {
        IOObjectRetain(entry)
        var queue: [(io_registry_entry_t, Int)] = [(entry, 0)]
        defer { for (node, _) in queue { IOObjectRelease(node) } }
        var index = 0
        var visited = Set<UInt64>()
        var matchDepth: Int?
        var matches = Set<UInt64>()
        while index < queue.count {
            let (node, depth) = queue[index]
            index += 1
            if let matchDepth, depth > matchDepth { break }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(node, &id) == KERN_SUCCESS else {
                throw MigrationBackupError.storageUnknown
            }
            guard visited.insert(id).inserted else { continue }
            if IOObjectConformsTo(node, "IOUSBHostDevice") != 0 {
                matchDepth = depth
                matches.insert(id)
                continue
            }
            var parents: io_iterator_t = 0
            guard IORegistryEntryGetParentIterator(node, kIOServicePlane, &parents) == KERN_SUCCESS else {
                throw MigrationBackupError.storageUnknown
            }
            defer { IOObjectRelease(parents) }
            while case let parent = IOIteratorNext(parents), parent != 0 {
                queue.append((parent, depth + 1))
                guard queue.count <= 512 else { throw MigrationBackupError.storageUnknown }
            }
            guard IOIteratorIsValid(parents) != 0 else { throw MigrationBackupError.storageUnknown }
        }
        guard matches.count == 1, let result = matches.first else { throw MigrationBackupError.storageUnknown }
        return result
    }
}

struct PhoneArchiveIndependentBackup: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let migrationID: UUID
    let completionReceiptID: UUID
    let sourceStorage: MigrationBackupStorageIdentity
    let backupStorage: MigrationBackupStorageIdentity
    let backupArchivePath: String
    let backupCatalogPath: String
    let parentBookmark: Data?
    let createdAtMs: Int64
}

extension VerifiedPhoneArchiveImporter {
    typealias BackupStorageResolver = @Sendable (URL) throws -> MigrationBackupStorageIdentity

    func createIndependentBackup(completion: PhoneArchiveCompletionReceipt, into directory: URL,
        parentBookmark: Data?, storage: BackupStorageResolver = MigrationBackupStorage.resolve
    ) throws -> PhoneArchiveIndependentBackup {
        guard try latestCompletionReceipt(migrationID: completion.migrationID) == completion else {
            throw MigrationBackupError.changed
        }
        let original = try auditCompletionReceipt(completion)
        let source = URL(fileURLWithPath: completion.archivePath, isDirectory: true)
        let sourceStorage = try storage(source), backupStorage = try storage(directory)
        guard sourceStorage.isIndependent(of: backupStorage) else { throw MigrationBackupError.notIndependent }
        let copied = try verifyIndependentRecovery(migrationID: completion.migrationID,
            archiveRoot: source, into: directory)
        guard copied.integrity == original, try auditCompletionReceipt(completion) == original,
              try storage(source) == sourceStorage, try storage(directory) == backupStorage else {
            throw MigrationBackupError.changed
        }
        let record = PhoneArchiveIndependentBackup(id: UUID(), migrationID: completion.migrationID,
            completionReceiptID: completion.id, sourceStorage: sourceStorage, backupStorage: backupStorage,
            backupArchivePath: copied.restoredArchiveURL.path, backupCatalogPath: copied.recoveredCatalogURL.path,
            parentBookmark: parentBookmark, createdAtMs: Int64(Date().timeIntervalSince1970 * 1_000))
        let payload = try JSONEncoder().encode(record)
        try database.pool.write { db in
            try db.execute(sql: "INSERT INTO migration_independent_backup (id, migration_id, record_json, created_at_ms) VALUES (?, ?, ?, ?)",
                arguments: [record.id.uuidString.lowercased(), record.migrationID.uuidString.lowercased(), payload, record.createdAtMs])
        }
        return record
    }

    func latestIndependentBackup(migrationID: UUID) throws -> PhoneArchiveIndependentBackup? {
        try database.pool.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT record_json FROM migration_independent_backup WHERE migration_id = ? ORDER BY created_at_ms DESC, rowid DESC LIMIT 1",
                arguments: [migrationID.uuidString.lowercased()]) else { return nil }
            return try JSONDecoder().decode(PhoneArchiveIndependentBackup.self, from: data)
        }
    }

    /// Re-resolve topology on every audit. Registry IDs recorded before a reboot
    /// are historical only; current volume identity and byte proofs must match.
    func auditIndependentBackup(_ record: PhoneArchiveIndependentBackup,
        storage: BackupStorageResolver = MigrationBackupStorage.resolve
    ) throws -> PhoneArchiveIntegrityReport {
        let saved = try database.pool.read { db in
            try Data.fetchOne(db, sql: "SELECT record_json FROM migration_independent_backup WHERE id = ?",
                arguments: [record.id.uuidString.lowercased()])
        }
        guard let saved, try JSONDecoder().decode(PhoneArchiveIndependentBackup.self, from: saved) == record,
              let completion = try latestCompletionReceipt(migrationID: record.migrationID),
              completion.id == record.completionReceiptID else { throw MigrationBackupError.missingRecord }
        let source = URL(fileURLWithPath: completion.archivePath, isDirectory: true)
        let backup = URL(fileURLWithPath: record.backupArchivePath, isDirectory: true)
        let originalStorage = try storage(source), currentBackupStorage = try storage(backup)
        guard originalStorage.volumeUUID == record.sourceStorage.volumeUUID,
              currentBackupStorage.volumeUUID == record.backupStorage.volumeUUID,
              originalStorage.isIndependent(of: currentBackupStorage) else { throw MigrationBackupError.notIndependent }
        guard try storage(URL(fileURLWithPath: record.backupCatalogPath)) == currentBackupStorage else {
            throw MigrationBackupError.changed
        }
        let original = try auditCompletionReceipt(completion)
        var configuration = Configuration()
        configuration.readonly = true
        let restored = VerifiedPhoneArchiveImporter(database: CatalogDatabase(pool:
            try DatabasePool(path: record.backupCatalogPath, configuration: configuration)))
        let copied = try restored.auditImportedArchive(migrationID: record.migrationID, archiveRoot: backup)
        guard copied == original, try storage(source) == originalStorage,
              try storage(backup) == currentBackupStorage else { throw MigrationBackupError.changed }
        return original
    }
}
