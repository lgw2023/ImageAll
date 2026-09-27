@preconcurrency import AVFoundation
import Foundation
import ImageAllRemoteClient
import ImageAllRemoteProtocol
import XCTest

@MainActor
final class RemoteVideoTests: XCTestCase {
    func testAuthenticatedSyntheticVideoDecodesSeeksAndStops() async throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let bytes = try Data(contentsOf: root.appendingPathComponent("docs/evidence/time-story-phase-1-20260918/synthetic-silent.mp4"))
        let audit = RangeAudit()
        let client = RemoteLibraryClient(
            endpoint: try RemoteHostEndpoint(host: "fixture.invalid", port: 8787, accessToken: "test-token"),
            transport: VideoTransport { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
                XCTAssertFalse(request.url!.absoluteString.contains("test-token"))
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.query, "revision=7")
                let raw = request.value(forHTTPHeaderField: "Range")!.dropFirst(6).split(separator: "-")
                let start = Int(raw[0])!, requestedEnd = Int(raw[1])!
                await audit.add(requestedEnd - start + 1)
                XCTAssertLessThanOrEqual(requestedEnd - start + 1, RemoteVideoChunk.maximumBytes)
                let end = min(requestedEnd, bytes.count - 1)
                let data = bytes.subdata(in: start..<(end + 1))
                return (data, HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil, headerFields: [
                    "Content-Type": "video/mp4", "Content-Length": String(data.count),
                    "Content-Range": "bytes \(start)-\(end)/\(bytes.count)", "X-ImageAll-Content-Revision": "7"
                ])!)
            }
        )
        let playback = RemoteVideoPlayback()
        let loading = Task { await playback.load(assetID: UUID(), contentRevision: 7, client: client) }
        defer { playback.stop(); loading.cancel() }
        for _ in 0..<500 where playback.state == .idle || playback.state == .loading {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(playback.state, .ready)
        guard playback.state == .ready else { return }
        await loading.value
        let item = try XCTUnwrap(playback.player.currentItem)
        for _ in 0..<500 where item.status == .unknown { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(item.status, .readyToPlay)
        let sought = await playback.player.seek(to: CMTime(seconds: 0.5, preferredTimescale: 600),
                                               toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(sought)
        XCTAssertEqual(playback.player.currentTime().seconds, 0.5, accuracy: 0.1)
        playback.player.play()
        playback.stop()
        XCTAssertNil(playback.player.currentItem)
        XCTAssertNil(playback.assetID)
        let counts = await audit.counts
        XCTAssertGreaterThan(counts.count, 0)
    }

    func testRangeRejectsChangedRevisionMalformedOffsetsAndIgnoredRange() async throws {
        for scenario in 0..<4 {
            let client = RemoteLibraryClient(
                endpoint: try RemoteHostEndpoint(host: "fixture.invalid", port: 8787, accessToken: "test-token"),
                transport: VideoTransport { request in
                    (Data([1, 2]), HTTPURLResponse(url: request.url!, statusCode: scenario == 0 ? 200 : 206,
                                                 httpVersion: nil, headerFields: [
                        "Content-Type": scenario == 3 ? "image/jpeg" : "video/mp4",
                        "Content-Range": scenario == 2 ? "bytes 1-2/10" : "bytes 0-1/10",
                        "X-ImageAll-Content-Revision": scenario == 1 ? "9" : "7"
                    ])!)
                }
            )
            do {
                _ = try await client.readVideoRange(assetID: UUID(), contentRevision: 7, offset: 0, count: 2)
                XCTFail("Invalid response must not reach AVFoundation")
            } catch is RemoteVideoError { }
        }
    }

    func testCancellationAndSizeBudgetStopReads() async throws {
        let client = RemoteLibraryClient(
            endpoint: try RemoteHostEndpoint(host: "fixture.invalid", port: 8787, accessToken: "test-token"),
            transport: VideoTransport { request in
                try await Task.sleep(for: .seconds(20))
                return (Data([1, 2, 3]), HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil, headerFields: nil)!)
            }
        )
        let task = Task { try await client.readVideoRange(assetID: UUID(), contentRevision: 1, offset: 0, count: 2) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        do {
            _ = try await client.readVideoRange(assetID: UUID(), contentRevision: 1, offset: 0,
                                              count: RemoteVideoChunk.maximumBytes + 1)
            XCTFail("Expected byte budget rejection")
        } catch let error as RemoteVideoError { XCTAssertEqual(error, .invalidRange) }
    }

    func testProductionStreamingTransportRejectsOversizedUnknownLengthBody() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OversizedVideoURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let transport = URLSessionRemoteHTTPTransport(session: session)
        do {
            _ = try await transport.data(for: URLRequest(url: URL(string: "https://fixture.invalid/video")!),
                                         maximumBytes: 2)
            XCTFail("Unannounced body bytes must still respect the bound")
        } catch let error as RemoteVideoError {
            XCTAssertEqual(error, .responseTooLarge)
        }
    }

    func testCapabilityFieldIsOptionalForLegacyHosts() throws {
        let legacy = Data(#"{"protocolVersion":2,"minimumClientProtocolVersion":1,"hostAppVersion":"old","usesTLS":false,"capabilities":["previews"]}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(RemoteCapabilities.self, from: legacy).videoRangeStreamingVersion)
    }
}

private struct VideoTransport: RemoteHTTPTransporting {
    let operation: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    func data(for request: URLRequest) async throws -> (Data, URLResponse) { try await operation(request) }
}

private actor RangeAudit {
    var counts: [Int] = []
    func add(_ count: Int) { counts.append(count) }
}

private final class OversizedVideoURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "video/mp4"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data([1, 2, 3]))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
