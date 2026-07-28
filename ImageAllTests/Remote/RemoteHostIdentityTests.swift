import Foundation
import XCTest
@testable import ImageAll

/// Smoke coverage for the one property that matters most about `RemoteHostIdentity`: on a
/// real macOS Keychain (as opposed to a mocked one), asking for an identity should actually
/// succeed with a usable TLS `SecIdentity`, not silently fall back to cleartext. A regression
/// here would make ADR-044's "TRY hard to make TLS work" promise silently false.
final class RemoteHostIdentityTests: XCTestCase {
    func testLoadOrCreateProducesAUsableTLSIdentityAndStableHostID() {
        let suiteName = "RemoteHostIdentityTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("failed to create isolated UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = RemoteHostIdentity.loadOrCreate(defaults: defaults)

        XCTAssertTrue(
            first.usesTLS,
            "expected a real self-signed TLS identity on this Keychain-backed macOS host"
        )
        XCTAssertNotNil(first.secIdentity)
        XCTAssertEqual(first.certificateFingerprintSHA256.count, 64, "expected lowercase hex SHA-256")
        XCTAssertEqual(
            first.certificateFingerprintSHA256,
            first.certificateFingerprintSHA256.lowercased()
        )

        // A second call (same UserDefaults suite, same Keychain) must reuse the persisted
        // hostID and certificate rather than minting a new identity every launch.
        let second = RemoteHostIdentity.loadOrCreate(defaults: defaults)
        XCTAssertEqual(second.hostID, first.hostID)
        XCTAssertEqual(second.certificateFingerprintSHA256, first.certificateFingerprintSHA256)
        XCTAssertTrue(second.usesTLS)
    }
}
