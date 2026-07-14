import XCTest
@testable import ImageAll

final class JobConcurrentClaimTests: XCTestCase {
    func testTwoConcurrentClaimantsOnlyOneClaimsSameJob() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)
        let jobID = UUID()
        _ = try JobTestSupport.enqueueDefault(queue: queue, id: jobID)

        let ready = DispatchGroup()
        ready.enter()
        ready.enter()

        let start = DispatchGroup()
        start.enter()
        start.enter()

        let resultsLock = NSLock()
        var results: [JobLeaseToken?] = []

        let done = DispatchGroup()
        done.enter()
        done.enter()

        DispatchQueue.global(qos: .userInitiated).async {
            ready.leave()
            start.wait()
            let lease = try? JobTestSupport.claimDefault(queue: queue, owner: "worker-a")
            resultsLock.lock()
            results.append(lease)
            resultsLock.unlock()
            done.leave()
        }

        DispatchQueue.global(qos: .userInitiated).async {
            ready.leave()
            start.wait()
            let lease = try? JobTestSupport.claimDefault(queue: queue, owner: "worker-b")
            resultsLock.lock()
            results.append(lease)
            resultsLock.unlock()
            done.leave()
        }

        ready.wait()
        start.leave()
        start.leave()
        done.wait()

        let claimed = results.compactMap { $0 }
        XCTAssertEqual(claimed.count, 1)
        XCTAssertEqual(claimed[0].jobID, jobID)
        XCTAssertEqual(try queue.fetchJob(id: jobID).attempts, 1)
    }

    func testConcurrentClaimsAssignDistinctJobs() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)
        let firstID = UUID()
        let secondID = UUID()
        _ = try JobTestSupport.enqueueDefault(queue: queue, id: firstID)
        _ = try JobTestSupport.enqueueDefault(queue: queue, id: secondID)

        let ready = DispatchGroup()
        ready.enter()
        ready.enter()

        let start = DispatchGroup()
        start.enter()
        start.enter()

        let resultsLock = NSLock()
        var results: [JobLeaseToken?] = []
        let done = DispatchGroup()
        done.enter()
        done.enter()

        for owner in ["worker-a", "worker-b"] {
            DispatchQueue.global(qos: .userInitiated).async {
                ready.leave()
                start.wait()
                let lease = try? JobTestSupport.claimDefault(queue: queue, owner: owner)
                resultsLock.lock()
                results.append(lease)
                resultsLock.unlock()
                done.leave()
            }
        }

        ready.wait()
        start.leave()
        start.leave()
        done.wait()

        let claimedIDs = Set(results.compactMap(\.?.jobID))
        XCTAssertEqual(claimedIDs.count, 2)
        XCTAssertTrue(claimedIDs.contains(firstID))
        XCTAssertTrue(claimedIDs.contains(secondID))
    }
}
