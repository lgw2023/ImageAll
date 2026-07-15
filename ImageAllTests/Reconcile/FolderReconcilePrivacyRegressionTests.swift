import XCTest
@testable import ImageAll

final class FolderReconcilePrivacyRegressionTests: XCTestCase {
    func testBuiltAppPrivacyManifestOnlyDeclaresFileTimestamp() throws {
        guard let manifestURL = Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy") else {
            XCTFail("built ImageAll.app must embed PrivacyInfo.xcprivacy in its resource bundle")
            return
        }
        let data = try Data(contentsOf: manifestURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let types = plist?["NSPrivacyAccessedAPITypes"] as? [[String: Any]]
        XCTAssertEqual(types?.count, 1)
        XCTAssertEqual(types?.first?["NSPrivacyAccessedAPIType"] as? String, "NSPrivacyAccessedAPICategoryFileTimestamp")
        let reasons = types?.first?["NSPrivacyAccessedAPITypeReasons"] as? [String]
        XCTAssertEqual(reasons, ["3B52.1"])
    }

    func testCatalogMigrationIDOrderingUnchanged() {
        XCTAssertEqual(CatalogMigrationID.knownOrdered, [
            CatalogMigrationID.v001CreateCatalogCore,
            CatalogMigrationID.v002AddStage1CatalogQuerySupport,
        ])
    }
}
