import XCTest
@testable import ImageAll

final class JobConcurrentClaimTests: XCTestCase {
    private enum ClaimAttemptResult {
        case success(JobLeaseToken?)
        case failure(Error)
    }

    private func runConcurrentClaims(
        queue: GRDBJobQueue,
        owners: [String]
    ) throws -> [ClaimAttemptResult] {
        let ready = DispatchGroup()
        for _ in owners {
            ready.enter()
        }

        let start = DispatchGroup()
        for _ in owners {
            start.enter()
        }

        let done = DispatchGroup()
        for _ in owners {
            done.enter()
        }

        let resultsLock = NSLock()
        var results: [ClaimAttemptResult] = []

        for owner in owners {
            DispatchQueue.global(qos: .userInitiated).async {
                ready.leave()
                start.wait()
                let result: ClaimAttemptResult
                do {
                    let lease = try JobTestSupport.claimDefault(queue: queue, owner: owner)
                    result = .success(lease)
                } catch {
                    result = .failure(error)
                }
                resultsLock.lock()
                results.append(result)
                resultsLock.unlock()
                done.leave()
            }
        }

        ready.wait()
        for _ in owners {
            start.leave()
        }
        done.wait()
        return results
    }

    func testTwoConcurrentClaimantsOnlyOneClaimsSameJob() throws {
        let url = try makeTempDatabaseURL()
        let database = try CatalogDatabase.open(at: url)
        let queue = JobTestSupport.makeQueue(database: database)
        let jobID = UUID()
        _ = try JobTestSupport.enqueueDefault(queue: queue, id: jobID)

        let results = try runConcurrentClaims(queue: queue, owners: ["worker-a", "worker-b"])

        XCTAssertEqual(results.count, 2)
        var failureCount = 0
        var nilSuccessCount = 0
        var tokenSuccessCount = 0
        var claimedToken: JobLeaseToken?
        for result in results {
            switch result {
            case let .success(token):
                if let token {
                    tokenSuccessCount += 1
                    claimedToken = token
                } else {
                    nilSuccessCount += 1
                }
            case .failure:
                failureCount += 1
            }
        }
        XCTAssertEqual(failureCount, 0)
        XCTAssertEqual(nilSuccessCount, 1)
        XCTAssertEqual(tokenSuccessCount, 1)
        XCTAssertEqual(claimedToken?.jobID, jobID)
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

        let results = try runConcurrentClaims(queue: queue, owners: ["worker-a", "worker-b"])

        XCTAssertEqual(results.count, 2)
        var failureCount = 0
        var tokens: [JobLeaseToken] = []
        for result in results {
            switch result {
            case let .success(token):
                if let token {
                    tokens.append(token)
                } else {
                    XCTFail("Expected non-nil claim when two jobs are available")
                }
            case .failure:
                failureCount += 1
            }
        }
        XCTAssertEqual(failureCount, 0)
        XCTAssertEqual(tokens.count, 2)
        let claimedIDs = Set(tokens.map(\.jobID))
        XCTAssertEqual(claimedIDs.count, 2)
        XCTAssertTrue(claimedIDs.contains(firstID))
        XCTAssertTrue(claimedIDs.contains(secondID))
    }
}
