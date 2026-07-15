import Foundation

struct GRDBJobLeaseContextProvider: JobLeaseContextProviding {
    let queue: GRDBJobQueue

    init(queue: GRDBJobQueue) {
        self.queue = queue
    }

    func makeLeaseContext(leaseDurationMs: Int64) -> JobLeaseExecutionContext {
        let repository = GRDBFolderReconcileRepository(queue: queue)
        return JobLeaseExecutionContext(
            leaseDurationMs: leaseDurationMs,
            reconcileBatch: repository,
            jobLookup: repository
        )
    }
}
