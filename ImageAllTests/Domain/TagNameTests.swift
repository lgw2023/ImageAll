import XCTest
@testable import ImageAll

final class TagNameTests: XCTestCase {
    func testCreateTagRejectsWhitespaceOnlyDisplayName() {
        let result = TagCatalogRules.createTag(rawName: "   \u{3000}\t  ", existingTags: [])

        guard case .failure(.invalidName) = result else {
            return XCTFail("Expected invalidName for whitespace-only input, got \(result)")
        }
    }

    func testNormalizedNameVectorFamily() {
        assertNormalizedName("  家人  ", expected: "家人")
    }

    func testNormalizedNameVectorWorkReference() {
        assertNormalizedName("Work\t  Reference", expected: "work reference")
    }

    func testNormalizedNameVectorComposedCafe() {
        assertNormalizedName("Café", expected: "café")
    }

    func testNormalizedNameVectorDecomposedCafe() {
        let decomposed = "Cafe\u{0301}"
        assertNormalizedName(decomposed, expected: "café")
    }

    func testNormalizedNameVectorGermanSharpSUsesDefaultCaseFold() {
        assertNormalizedName("Straße", expected: "strasse")
    }

    func testNonASCIIUnicodeWhitespaceParticipatesInTrimAndFold() {
        let ideographicSpace = "\u{3000}"
        assertNormalizedName("\(ideographicSpace)Family\(ideographicSpace)Album\(ideographicSpace)", expected: "family album")
    }

    func testNFCDoesNotPerformWidthFolding() {
        let fullwidthA = "\u{FF21}"
        let result = TagNameNormalizer.validateAndNormalize(fullwidthA)
        guard case let .success(parts) = result else {
            return XCTFail("Expected success for fullwidth input")
        }
        XCTAssertEqual(parts.normalizedName, "\u{FF41}")
        XCTAssertNotEqual(parts.normalizedName, "a")
    }

    func testNormalizedNamePreservesDiacritics() {
        assertNormalizedName("Café", expected: "café")
        assertNormalizedName("Straße", expected: "strasse")
    }

    func testDuplicateNormalizedNameRejected() {
        let first = TagCatalogRules.createTag(rawName: "Family", existingTags: [])
        guard case let .success(existingTag) = first else {
            return XCTFail("Expected first tag creation to succeed")
        }

        let duplicate = TagCatalogRules.createTag(rawName: "  FAMILY  ", existingTags: [existingTag])
        guard case .failure(.duplicateTag) = duplicate else {
            return XCTFail("Expected duplicateTag for colliding normalized name")
        }
    }

    func testNormalizedNameKeyUsesBinaryUTF8Comparison() {
        let first = TagNameNormalizer.validateAndNormalize("Café")
        let second = TagNameNormalizer.validateAndNormalize("Cafe\u{0301}")

        guard case let .success(firstParts) = first,
              case let .success(secondParts) = second
        else {
            return XCTFail("Expected both inputs to normalize successfully")
        }

        XCTAssertEqual(firstParts.normalizedNameKey, secondParts.normalizedNameKey)
        XCTAssertEqual(
            firstParts.normalizedNameKey,
            Data("café".utf8),
            "Normalized keys must compare as stable NFC UTF-8 bytes"
        )
    }

    func testDisplayNamePreservesInternalWhitespaceAndCase() {
        let result = TagNameNormalizer.validateAndNormalize("  Work\t  Reference  ")
        guard case let .success(parts) = result else {
            return XCTFail("Expected successful normalization")
        }
        XCTAssertEqual(parts.displayName, "Work\t  Reference")
    }

    func testDisplayNameDoesNotApplyNFC() {
        let decomposed = "\u{3000}Cafe\u{0301}\u{3000}"
        let result = TagNameNormalizer.validateAndNormalize(decomposed)
        guard case let .success(parts) = result else {
            return XCTFail("Expected successful normalization for decomposed display name input")
        }

        let expectedScalars = Array("Cafe\u{0301}".unicodeScalars.map(\.value))
        let actualScalars = Array(parts.displayName.unicodeScalars.map(\.value))
        XCTAssertEqual(actualScalars, expectedScalars)
        XCTAssertTrue(parts.displayName.unicodeScalars.contains(where: { $0.value == 0x0301 }))
        XCTAssertFalse(parts.displayName.unicodeScalars.contains(where: { $0.value == 0x00E9 }))
    }

    func testWhitespaceTrimAndFoldOperateOnUnicodeScalars() {
        let internalWhitespace = "\u{0009}\u{00A0}\u{2003}\u{3000}"
        assertNormalizedName("Hello\(internalWhitespace)World", expected: "hello world")

        let edgeWhitespace = "\u{000B}\u{00A0}\u{2000}"
        let result = TagNameNormalizer.validateAndNormalize("\(edgeWhitespace)Scalar\(edgeWhitespace)")
        guard case let .success(parts) = result else {
            return XCTFail("Expected successful normalization for scalar whitespace boundaries")
        }
        XCTAssertEqual(parts.displayName, "Scalar")
        XCTAssertEqual(parts.normalizedName, "scalar")
    }

    func testWhitespaceTrimRemovesOnlyLeadingWhitespaceScalars() {
        let input = "\u{2000}\u{0308}Cafe"
        let trimmed = TagNameNormalizer.trimUnicodeWhiteSpace(input)
        XCTAssertEqual(trimmed, "\u{0308}Cafe")
        XCTAssertFalse(trimmed.unicodeScalars.contains(where: { $0.value == 0x2000 }))
    }

    private func assertNormalizedName(_ input: String, expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let result = TagNameNormalizer.validateAndNormalize(input)
        guard case let .success(parts) = result else {
            XCTFail("Expected successful normalization for \(input)", file: file, line: line)
            return
        }
        XCTAssertEqual(parts.normalizedName, expected, file: file, line: line)
    }
}
