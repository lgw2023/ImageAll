import Foundation

protocol JobClock: Sendable {
    var nowMs: Int64 { get }
}

struct FixedJobClock: JobClock {
    let nowMs: Int64

    init(nowMs: Int64) {
        self.nowMs = nowMs
    }
}
