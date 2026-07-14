import Foundation
import GRDB
@testable import ImageAll

enum CatalogQueryTestFaultSupport {
    enum FaultMode: Int {
        case none = 0
        case failDecisionWrites = 1
        case failAfter500DecisionWrites = 2
        case failRestoreAfterThreeWrites = 3
    }

    private static let restoreFailAfterWriteCount = 3

    static func installFaultInfrastructure(on db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS test_fault_control (
                mode INTEGER NOT NULL DEFAULT 0
            ) STRICT
            """)
        try db.execute(sql: "DELETE FROM test_fault_control")
        try db.execute(sql: "INSERT INTO test_fault_control (mode) VALUES (0)")

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS test_decision_write_count (
                count INTEGER NOT NULL DEFAULT 0
            ) STRICT
            """)
        try db.execute(sql: "DELETE FROM test_decision_write_count")
        try db.execute(sql: "INSERT INTO test_decision_write_count (count) VALUES (0)")

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS test_restore_write_count (
                count INTEGER NOT NULL DEFAULT 0
            ) STRICT
            """)
        try db.execute(sql: "DELETE FROM test_restore_write_count")
        try db.execute(sql: "INSERT INTO test_restore_write_count (count) VALUES (0)")

        try db.execute(sql: "DROP TRIGGER IF EXISTS test_fail_decision_insert")
        try db.execute(sql: """
            CREATE TRIGGER test_fail_decision_insert
            BEFORE INSERT ON asset_tag_decision
            WHEN (SELECT mode FROM test_fault_control) = 1
            BEGIN
                SELECT RAISE(ABORT, 'test_fail_decision_insert');
            END
            """)

        try db.execute(sql: "DROP TRIGGER IF EXISTS test_fail_decision_after_500")
        try db.execute(sql: """
            CREATE TRIGGER test_fail_decision_after_500
            BEFORE INSERT ON asset_tag_decision
            WHEN (SELECT mode FROM test_fault_control) = 2
              AND (SELECT count FROM test_decision_write_count) >= 500
            BEGIN
                SELECT RAISE(ABORT, 'test_fail_decision_after_500');
            END
            """)

        try db.execute(sql: "DROP TRIGGER IF EXISTS test_count_decision_insert")
        try db.execute(sql: """
            CREATE TRIGGER test_count_decision_insert
            AFTER INSERT ON asset_tag_decision
            WHEN (SELECT mode FROM test_fault_control) = 2
            BEGIN
                UPDATE test_decision_write_count SET count = count + 1;
            END
            """)

        try db.execute(sql: "DROP TRIGGER IF EXISTS test_count_restore_delete")
        try db.execute(sql: """
            CREATE TRIGGER test_count_restore_delete
            AFTER DELETE ON asset_tag_decision
            WHEN (SELECT mode FROM test_fault_control) = 3
            BEGIN
                UPDATE test_restore_write_count SET count = count + 1;
            END
            """)

        try db.execute(sql: "DROP TRIGGER IF EXISTS test_count_restore_insert")
        try db.execute(sql: """
            CREATE TRIGGER test_count_restore_insert
            AFTER INSERT ON asset_tag_decision
            WHEN (SELECT mode FROM test_fault_control) = 3
            BEGIN
                UPDATE test_restore_write_count SET count = count + 1;
            END
            """)

        try db.execute(sql: "DROP TRIGGER IF EXISTS test_count_restore_update")
        try db.execute(sql: """
            CREATE TRIGGER test_count_restore_update
            AFTER UPDATE ON asset_tag_decision
            WHEN (SELECT mode FROM test_fault_control) = 3
            BEGIN
                UPDATE test_restore_write_count SET count = count + 1;
            END
            """)

        try db.execute(sql: "DROP TRIGGER IF EXISTS test_fail_restore_delete_after_threshold")
        try db.execute(sql: """
            CREATE TRIGGER test_fail_restore_delete_after_threshold
            BEFORE DELETE ON asset_tag_decision
            WHEN (SELECT mode FROM test_fault_control) = 3
              AND (SELECT count FROM test_restore_write_count) >= \(restoreFailAfterWriteCount)
            BEGIN
                SELECT RAISE(ABORT, 'test_fail_restore_delete_after_threshold');
            END
            """)

        try db.execute(sql: "DROP TRIGGER IF EXISTS test_fail_restore_insert_after_threshold")
        try db.execute(sql: """
            CREATE TRIGGER test_fail_restore_insert_after_threshold
            BEFORE INSERT ON asset_tag_decision
            WHEN (SELECT mode FROM test_fault_control) = 3
              AND (SELECT count FROM test_restore_write_count) >= \(restoreFailAfterWriteCount)
            BEGIN
                SELECT RAISE(ABORT, 'test_fail_restore_insert_after_threshold');
            END
            """)

        try db.execute(sql: "DROP TRIGGER IF EXISTS test_fail_restore_update_after_threshold")
        try db.execute(sql: """
            CREATE TRIGGER test_fail_restore_update_after_threshold
            BEFORE UPDATE ON asset_tag_decision
            WHEN (SELECT mode FROM test_fault_control) = 3
              AND (SELECT count FROM test_restore_write_count) >= \(restoreFailAfterWriteCount)
            BEGIN
                SELECT RAISE(ABORT, 'test_fail_restore_update_after_threshold');
            END
            """)
    }

    static func setFaultMode(_ mode: FaultMode, on db: Database) throws {
        try db.execute(sql: "UPDATE test_fault_control SET mode = ?", arguments: [mode.rawValue])
        if mode == .failAfter500DecisionWrites {
            try db.execute(sql: "UPDATE test_decision_write_count SET count = 0")
        }
        if mode == .failRestoreAfterThreeWrites {
            try db.execute(sql: "UPDATE test_restore_write_count SET count = 0")
        }
    }

    static func installUnrelatedTagUniqueIndex(on db: Database) throws {
        try db.execute(sql: """
            CREATE UNIQUE INDEX IF NOT EXISTS test_tag_created_at_ms_uq ON tag(created_at_ms)
            """)
    }
}

/// Records `asset_tag_decision` writes during a restore attempt. Counters live in Swift memory
/// and remain available after the production transaction rolls back.
final class RestoreDecisionWriteRecorder: TransactionObserver {
    private(set) var deletes = 0
    private(set) var inserts = 0
    private(set) var updates = 0

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        switch eventKind {
        case .insert(let tableName), .delete(let tableName):
            return tableName == "asset_tag_decision"
        case .update(let tableName, _):
            return tableName == "asset_tag_decision"
        }
    }

    func databaseDidChange(with event: DatabaseEvent) {
        switch event.kind {
        case .insert:
            inserts += 1
        case .update:
            updates += 1
        case .delete:
            deletes += 1
        }
    }

    func databaseDidCommit(_ db: Database) {}

    func databaseDidRollback(_ db: Database) {}
}
