import XCTest
@testable import Shrunk

final class NetContentParserTests: XCTestCase {

    // MARK: - Shared fixtures (must agree with the Python and TypeScript ports)

    private struct FixtureCase: Decodable {
        let input: String
        let quantity: Double?
        let unit_kind: String?
        let note: String
    }

    func test_sharedFixtures() throws {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "package_weights", withExtension: "json"),
            "package_weights.json is missing from the test bundle — check the resources entry in project.yml"
        )
        let cases = try JSONDecoder().decode([FixtureCase].self, from: Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(cases.count, 28)

        for fixture in cases {
            let result = NetContentParser.parse(fixture.input)
            if let expected = fixture.quantity {
                let parsed = try XCTUnwrap(result, "expected a parse for \(fixture.input) — \(fixture.note)")
                XCTAssertEqual(parsed.unitKind.rawValue, fixture.unit_kind, fixture.note)
                XCTAssertEqual(parsed.quantity, expected, accuracy: 0.01, fixture.note)
                XCTAssertEqual(parsed.raw, fixture.input, fixture.note)
            } else {
                XCTAssertNil(result, "expected a reject for \(fixture.input) — \(fixture.note)")
            }
        }
    }

    // MARK: - Real label strings (spec §10)

    func test_realLabelStrings() {
        let cases: [(String, Double, UnitKind)] = [
            ("NET WT 12 OZ (340g)",                  340.194,  .mass),
            ("NET WT 8 OZ (227g)",                   226.796,  .mass),
            ("NET WT. 1 LB 4 OZ (567g)",             566.990,  .mass),
            ("e 500 g",                              500,      .mass),
            ("500 g e",                              500,      .mass),
            ("NET CONTENTS 28 FL OZ (828 mL)",       828.058,  .volume),
            ("12 – 12 FL OZ CANS",                   4258.584, .volume),
            ("NET WT 16 OZ (1 LB) 453g",             453.592,  .mass),
            ("NET WT 5.3 OZ (150g)",                 150.252,  .mass),
            ("NET WT 1.5 LB (680g)",                 680.388,  .mass),
            ("NET 2 LB (907 g)",                     907.184,  .mass),
            ("1 GAL (3.78 L)",                       3785.410, .volume),
            ("64 FL OZ (1.89 L)",                    1892.704, .volume),
            ("NET WT 10 OZ",                         283.495,  .mass),
            ("NET WEIGHT 750 g",                     750,      .mass),
            ("NET WT 2.6 OZ (74g)",                  73.709,   .mass),
            ("18 CT",                                18,       .count),
            ("NET WT 19.5 OZ (1 LB 3.5 OZ) 553g",    552.815,  .mass),
            ("NET WT 1 LB 8 OZ (680 g)",             680.388,  .mass),
            ("6 x 12 FL OZ",                         2129.292, .volume),
            ("NET WT 32 OZ (2 LB) 907g",             907.184,  .mass),
            ("NET WT 4.4 OZ (125g)",                 124.738,  .mass),
            ("CONTENIDO NETO 400 g",                 400,      .mass),
            ("NET WT 3.5 OZ (99g)",                  99.223,   .mass),
            ("1 QT (946 mL)",                        946.353,  .volume),
            ("NET WT 24 OZ (1 LB 8 OZ) 680g",        680.388,  .mass),
            ("NET WT 7 OZ (198g)",                   198.447,  .mass),
            ("e 250 ml",                             250,      .volume),
            ("NET WT 12.5 OZ (354g)",                354.369,  .mass),
            ("NET WT 16.9 FL OZ (500 mL)",           499.792,  .volume),
            ("NET WT 1.36 kg (3 LB)",                1360,     .mass)
        ]

        for (input, quantity, kind) in cases {
            guard let parsed = NetContentParser.parse(input) else {
                XCTFail("expected a parse for \(input)")
                continue
            }
            XCTAssertEqual(parsed.quantity, quantity, accuracy: 0.01, input)
            XCTAssertEqual(parsed.unitKind, kind, input)
        }
    }

    func test_labelStringsThatMustNotParse() {
        let rejects = [
            "SERVING SIZE 1 CUP",
            "NET WT",
            "INGREDIENTS: WATER, SUGAR, SALT",
            "NET WT 0 OZ",
            "NET WT 12 OZ (500g)",     // segments disagree by 47%
            "BEST BY 12/25/2027"
        ]
        for input in rejects {
            XCTAssertNil(NetContentParser.parse(input), "expected a reject for \(input)")
        }
    }

    // MARK: - Line selection

    func test_isNetContentLine_matchesTheSpecRegex() {
        XCTAssertTrue(NetContentParser.isNetContentLine("NET WT 12 OZ"))
        XCTAssertTrue(NetContentParser.isNetContentLine("net weight 750 g"))
        XCTAssertTrue(NetContentParser.isNetContentLine("NET CONTENTS 28 FL OZ"))
        XCTAssertTrue(NetContentParser.isNetContentLine("e 500 g"))
        XCTAssertFalse(NetContentParser.isNetContentLine("INGREDIENTS: WATER"))
        XCTAssertFalse(NetContentParser.isNetContentLine("12 – 12 FL OZ CANS"))
    }

    // MARK: - I3 regression: serving-size lines and word-internal e-signs (spec §6.3)

    func test_isNetContentLine_rejectsServingSizeLines() {
        // "SERVING SIZE 1 OZ (28g)" case-insensitively matched the old `e\s*\d`
        // branch via the trailing "e" in "SIZE" — the serving size (28g), not the
        // net weight, would win. A SERVING guard must reject it outright.
        XCTAssertFalse(NetContentParser.isNetContentLine("SERVING SIZE 1 OZ (28g)"))
        XCTAssertFalse(NetContentParser.isNetContentLine("SERVING SIZE 2/3 CUP (55g)"))
        XCTAssertFalse(NetContentParser.isNetContentLine("Serving Size 12 fl oz"))
    }

    func test_isNetContentLine_ignoresWordInternalESign() {
        // The estimated-sign "e" must be a standalone token, not any letter "e"
        // that happens to precede a digit inside a word like "Maine".
        XCTAssertFalse(NetContentParser.isNetContentLine("Made in Maine 5 miles from the coast"))
    }

    func test_firstNetContent_prefersNetWtOverServingSizeLine() {
        let lines = ["NUTRITION FACTS", "SERVING SIZE 1 OZ (28g)", "NET WT 12 OZ (340g)"]
        let match = NetContentParser.firstNetContent(in: lines)
        XCTAssertEqual(match?.lineIndex, 2)
        XCTAssertEqual(match?.line, "NET WT 12 OZ (340g)")
        XCTAssertEqual(match?.parsed.unitKind, .mass)
        XCTAssertEqual(match?.parsed.quantity ?? 0, 340.194, accuracy: 0.01)
    }

    func test_firstNetContent_prefersTheNetContentLine() {
        let lines = ["DORITOS", "12 CT", "NET WT 9.75 OZ (276g)", "INGREDIENTS: CORN"]
        let match = NetContentParser.firstNetContent(in: lines)
        XCTAssertEqual(match?.lineIndex, 2)
        XCTAssertEqual(match?.line, "NET WT 9.75 OZ (276g)")
        XCTAssertEqual(match?.parsed.unitKind, .mass)
        XCTAssertEqual(match?.parsed.quantity ?? 0, 276.408, accuracy: 0.01)
    }

    func test_firstNetContent_fallsBackToAMassOrVolumeLine() {
        // Many US labels print the size with no "NET WT" prefix at all.
        let lines = ["COCA-COLA", "12 – 12 FL OZ CANS", "CAFFEINE FREE"]
        let match = NetContentParser.firstNetContent(in: lines)
        XCTAssertEqual(match?.lineIndex, 1)
        XCTAssertEqual(match?.parsed.unitKind, .volume)
        XCTAssertEqual(match?.parsed.quantity ?? 0, 4258.584, accuracy: 0.01)
    }

    func test_firstNetContent_neverGuessesFromABareCount() {
        // "12 CT" alone is as likely to be servings as packages, so the fallback
        // tier ignores count-only lines and the sheet falls back to manual entry.
        XCTAssertNil(NetContentParser.firstNetContent(in: ["DORITOS", "12 CT", "PARTY SIZE"]))
    }

    func test_firstNetContent_returnsNilWhenNothingParses() {
        XCTAssertNil(NetContentParser.firstNetContent(in: ["DORITOS", "INGREDIENTS: CORN", ""]))
    }

    // MARK: - R45 multipack rule (final fix wave, C2)
    //
    // A leading bare integer or "N ct"/"N pk"/"N pack" segment is a pack
    // multiplier for the segment right after it — the "/"-spelling of a
    // multipack must yield the same whole-pack total as its "-"/"x" spelling
    // ("12 - 12 FL OZ CANS" == 4258.584 mL, one 12-pack of 12 fl oz cans), not
    // the per-unit size of a single item. Mirrors `backend/src/normalize.ts` /
    // `scripts/fdc/normalize.py`.

    func test_multipack_slashSpelling_bareLeadingInteger() {
        // 12-pack of 12 fl oz cans: 144 fl oz total, same whole-pack figure as
        // the "12 - 12 FL OZ CANS" hyphen spelling.
        let parsed = NetContentParser.parse("12/12 fl oz")
        XCTAssertEqual(parsed?.quantity ?? 0, 4258.584, accuracy: 0.01)
        XCTAssertEqual(parsed?.unitKind, .volume)
    }

    func test_multipack_slashSpelling_decimalPerUnitSize() {
        // 6-pack of 16.9 fl oz bottles: 101.4 fl oz total.
        let parsed = NetContentParser.parse("6/16.9 fl oz")
        XCTAssertEqual(parsed?.quantity ?? 0, 2998.753, accuracy: 0.01)
        XCTAssertEqual(parsed?.unitKind, .volume)
    }

    func test_multipack_slashSpelling_massUnit() {
        let parsed = NetContentParser.parse("2/1 lb")
        XCTAssertEqual(parsed?.quantity ?? 0, 907.184, accuracy: 0.01)
        XCTAssertEqual(parsed?.unitKind, .mass)
    }

    func test_multipack_leadingCtSegment() {
        // Same 12-pack of 12 fl oz cans, spelled with an explicit count unit.
        let parsed = NetContentParser.parse("12 ct / 12 fl oz")
        XCTAssertEqual(parsed?.quantity ?? 0, 4258.584, accuracy: 0.01)
        XCTAssertEqual(parsed?.unitKind, .volume)
    }

    func test_multipack_leadingBareCountWithNoPerUnitSize_rejects() {
        // The leading segment is a pack multiplier, but what follows is
        // itself just a count, not a physical per-unit size — reject rather
        // than silently falling back to some other reading of the string.
        XCTAssertNil(NetContentParser.parse("6 pk / 6 ct"))
    }

    func test_multipack_plainSingleSegmentCount_stillParsesAsACount() {
        // Regression guard: the R45 branch only fires with ≥2 "/"-split
        // segments — a bare "12 ct" with no "/" must still parse as a plain
        // count of 12, exactly as before this fix.
        let parsed = NetContentParser.parse("12 ct")
        XCTAssertEqual(parsed?.quantity ?? 0, 12, accuracy: 0.01)
        XCTAssertEqual(parsed?.unitKind, .count)
    }
}
