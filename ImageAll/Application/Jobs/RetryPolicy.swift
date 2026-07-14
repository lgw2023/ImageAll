import Foundation

protocol RetryPolicy: Sendable {
    func nextNotBeforeMs(
        nowMs: Int64,
        attempts: Int,
        maxAttempts: Int,
        errorCode: JobSafeErrorCode
    ) -> Int64
}

struct FixedDelayRetryPolicy: RetryPolicy {
    let delayMs: Int64

    func nextNotBeforeMs(
        nowMs: Int64,
        attempts: Int,
        maxAttempts: Int,
        errorCode: JobSafeErrorCode
    ) -> Int64 {
        nowMs + delayMs
    }
}
