import Foundation
import GRDB
@testable import ImageAll

enum CatalogQueryTestFaultSupport {
    enum FaultMode: Int {
        case none = 0
        case failDecisionWrites = 1
        case failAfter500DecisionWrites = 2
        case failRestoreAfterFirstWrite = 3
    }

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

        try db.execute(sql: "DROP TRIGGER IF EXISTS test_fail_restore_after_first")
        try db.execute(sql: """
            CREATE TRIGGER test_fail_restore_after_first
            BEFORE INSERT ON asset_tag_decision
            WHEN (SELECT mode FROM test_fault_control) = 3
              AND (SELECT count FROM test_restore_write_count) >= 1
            BEGIN
                SELECT RAISE(ABORT, 'test_fail_restore_after_first');
            END
            """)

        try db.execute(sql: "DROP TRIGGER IF EXISTS test_fail_restore_delete_after_first")
        try db.execute(sql: """
            CREATE TRIGGER test_fail_restore_delete_after_first
            BEFORE DELETE ON asset_tag_decision
            WHEN (SELECT mode FROM test_fault_control) = 3
              AND (SELECT count FROM test_restore_write_count) >= 1
            BEGIN
                SELECT RAISE(ABORT, 'test_fail_restore_delete_after_first');
            END
            """)
    }

    static func setFaultMode(_ mode: FaultMode, on db: Database) throws {
        try db.execute(sql: "UPDATE test_fault_control SET mode = ?", arguments: [mode.rawValue])
        if mode == .failAfter500DecisionWrites {
            try db.execute(sql: "UPDATE test_decision_write_count SET count = 0")
        }
        if mode == .failRestoreAfterFirstWrite {
            try db.execute(sql: "UPDATE test_restore_write_count SET count = 0")
        }
    }
}
