import Foundation
import GRDB

struct JobRowSnapshot: Equatable, Sendable {
    let columns: [String: String?]

    init(row: Row) {
        var values: [String: String?] = [:]
        for column in row.columnNames {
            if row[column] == nil {
                values[column] = nil
            } else if let data = row[column] as? Data {
                values[column] = data.base64EncodedString()
            } else {
                values[column] = String(describing: row[column]!)
            }
        }
        self.columns = values
    }
}
