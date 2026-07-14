import Foundation

protocol RetryPolicy: Sendable {
    func nextNotBeforeMs(
        nowMs: Int64,
        attempts: Int,
        maxAttempts: Int,
        errorCode: JobSafeErrorCode
    ) -> Int64
}
