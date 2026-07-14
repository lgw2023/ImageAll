import Foundation

protocol JobClock: Sendable {
    var nowMs: Int64 { get }
}
