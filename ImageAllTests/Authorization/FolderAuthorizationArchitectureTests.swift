import Foundation
import XCTest
@testable import ImageAll

final class FolderAuthorizationArchitectureTests: XCTestCase {
    func testApplicationAuthorizationErrorsDoNotLeakSensitiveFields() {
        let errors: [FolderAuthorizationError] = [
            .sourceNotFound,
            .sourceKindMismatch,
            .invalidSourceState,
            .invalidRoot,
            .sourceOverlap,
            .overlapIndeterminate,
            .identityMismatch,
            .identityIndeterminate,
            .bookmarkCreationFailed,
            .authorizationUnavailable,
            .persistenceFailure,
        ]

        for error in errors {
            let description = String(describing: error)
            XCTAssertFalse(description.contains("/Volumes/"))
            XCTAssertFalse(description.contains("/Users/"))
            XCTAssertFalse(description.localizedCaseInsensitiveContains("sqlite"))
        }
    }

    func testDomainAndApplicationSourcesDoNotImportAppKitOrGRDB() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let targets = [
            repoRoot.appendingPathComponent("ImageAll/Application"),
            repoRoot.appendingPathComponent("ImageAll/Domain"),
        ]

        for target in targets {
            guard let files = try FileManager.default.subpaths(atPath: target.path)?.filter({ $0.hasSuffix(".swift") }) else {
                XCTFail("Missing sources at \(target.path)")
                continue
            }
            for file in files {
                let path = target.appendingPathComponent(file).path
                let contents = try String(contentsOfFile: path, encoding: .utf8)
                XCTAssertFalse(contents.contains("import AppKit"), path)
                XCTAssertFalse(contents.contains("import GRDB"), path)
            }
        }
    }

    func testOnlyAppKitAdapterImportsAppKitAmongAuthorizationInfrastructure() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let authDir = repoRoot.appendingPathComponent("ImageAll/Infrastructure/Authorization")
        guard let files = try FileManager.default.subpaths(atPath: authDir.path)?.filter({ $0.hasSuffix(".swift") }) else {
            XCTFail("Missing authorization infrastructure sources")
            return
        }

        var appKitFiles: [String] = []
        for file in files {
            let path = authDir.appendingPathComponent(file).path
            let contents = try String(contentsOfFile: path, encoding: .utf8)
            if contents.contains("import AppKit") {
                appKitFiles.append(file)
            }
        }
        XCTAssertEqual(appKitFiles.sorted(), ["AppKitFolderDirectoryPicker.swift", "FolderDirectoryPickerPort.swift"].sorted())
    }

    func testRootViewDoesNotReferenceOpenPanel() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let rootView = try String(
            contentsOf: repoRoot.appendingPathComponent("ImageAll/App/RootView.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(rootView.contains("NSOpenPanel"))
        XCTAssertFalse(rootView.contains("connectFolder"))
    }
}
