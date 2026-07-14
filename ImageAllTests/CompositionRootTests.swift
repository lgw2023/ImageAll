import XCTest
@testable import ImageAll

final class CompositionRootTests: XCTestCase {
    func testCompositionRootProducesFoundationReadyPresentation() {
        let presentation = CompositionRoot().makeStartupPresentation()

        XCTAssertEqual(presentation.productName, "ImageAll")
        XCTAssertTrue(
            presentation.foundationReady,
            "foundationReady must indicate the app shell and dependency assembly have started"
        )
    }
}
