import Foundation
import GRDB

enum CatalogQueryErrorMapping {
    static func rethrow(_ error: Error) throws -> Never {
        if let catalogError = error as? CatalogQueryError {
            throw catalogError
        }
        throw CatalogQueryError.persistenceFailure
    }

    static func perform<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as CatalogQueryError {
            throw error
        } catch {
            throw CatalogQueryError.persistenceFailure
        }
    }
}
