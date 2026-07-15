import Foundation

struct GRDBJobLeaseContextProvider: JobLeaseContextProviding {
    func makeLeaseContext(queue: JobQueue, leaseDurationMs: Int64) -> JobLeaseExecutionContext {
        guard let grdbQueue = queue as? GRDBJobQueue else {
            fatalError("GRDBJobLeaseContextProvider requires GRDBJobQueue")
        }
        return JobLeaseExecutionContext(
            leaseDurationMs: leaseDurationMs,
            reconcileBatch: GRDBFolderReconcileRepository(queue: grdbQueue)
        )
    }
}
