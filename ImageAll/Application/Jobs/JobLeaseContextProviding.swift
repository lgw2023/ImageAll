import Foundation

protocol JobLeaseContextProviding: Sendable {
    func makeLeaseContext(leaseDurationMs: Int64) -> JobLeaseExecutionContext
}
