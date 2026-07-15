import Foundation

protocol JobLeaseContextProviding: Sendable {
    func makeLeaseContext(queue: JobQueue, leaseDurationMs: Int64) -> JobLeaseExecutionContext
}
