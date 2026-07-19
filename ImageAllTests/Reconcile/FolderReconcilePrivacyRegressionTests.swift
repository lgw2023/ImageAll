import XCTest
@testable import ImageAll

final class FolderReconcilePrivacyRegressionTests: XCTestCase {
    func testBuiltAppPrivacyManifestOnlyDeclaresApprovedCategories() throws {
        guard let manifestURL = Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy") else {
            XCTFail("built ImageAll.app must embed PrivacyInfo.xcprivacy in its resource bundle")
            return
        }
        let data = try Data(contentsOf: manifestURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let types = plist?["NSPrivacyAccessedAPITypes"] as? [[String: Any]]
        XCTAssertEqual(types?.count, 2)
        let mapped = Dictionary(uniqueKeysWithValues: (types ?? []).compactMap { entry -> (String, [String])? in
            guard let type = entry["NSPrivacyAccessedAPIType"] as? String,
                  let reasons = entry["NSPrivacyAccessedAPITypeReasons"] as? [String]
            else { return nil }
            return (type, reasons)
        })
        XCTAssertEqual(mapped["NSPrivacyAccessedAPICategoryFileTimestamp"], ["3B52.1"])
        XCTAssertEqual(mapped["NSPrivacyAccessedAPICategoryDiskSpace"], ["E174.1"])
    }

    func testCatalogMigrationIDOrderingIncludesCurrentSchema() {
        XCTAssertEqual(CatalogMigrationID.knownOrdered, [
            CatalogMigrationID.v001CreateCatalogCore,
            CatalogMigrationID.v002AddStage1CatalogQuerySupport,
            CatalogMigrationID.v003AddDerivedImageCache,
            CatalogMigrationID.v004AddPersonalization,
            CatalogMigrationID.v005AddCatalogScaleIndexes,
            CatalogMigrationID.v006AddAssetTextSearch,
            CatalogMigrationID.v007AddCatalogScopeIdentity,
            CatalogMigrationID.v008AddPersonalModelSuggestions,
            CatalogMigrationID.v009AddStandardOntology,
            CatalogMigrationID.v010AddStandardPredictions,
            CatalogMigrationID.v011AddStandardPredictionProvenance,
        ])
    }
}
