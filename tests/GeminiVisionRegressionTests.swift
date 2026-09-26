import XCTest
@testable import AISmartFramingCamera

/// Run in an iOS XCTest target on macOS. The Windows source check cannot execute these tests.
final class GeminiVisionRegressionTests: XCTestCase {
    func testAutoUsesFastVisionModelAndDeepModeUsesProFirst() {
        XCTAssertEqual(
            AIVisionModel.fallbackChain(selected: .autoStrongest, customModelName: ""),
            ["google/gemini-3.7-flash", "google/gemini-2.5-flash"]
        )
        XCTAssertEqual(
            AIVisionModel.fallbackChain(selected: .gemini31Pro, customModelName: "").first,
            "google/gemini-3.1-pro-preview"
        )
        XCTAssertEqual(
            AIVisionModel.fallbackChain(selected: .gemini37Flash,
                                        customModelName: "google/gemini-3.1-pro-preview")
                .filter { $0 == "google/gemini-3.1-pro-preview" }.count,
            1
        )
    }

    func testFreeVisionNeverFallsBackToPaidModels() {
        let chain = AIVisionModel.fallbackChain(
            selected: .freeVision, customModelName: "google/gemini-3.1-pro-preview"
        )
        XCTAssertEqual(chain.first, "google/gemma-4-31b-it:free")
        XCTAssertTrue(chain.allSatisfy { $0.hasSuffix(":free") || $0 == "openrouter/free" })
    }

    func testCloudFramingRequiresRealSubjectCoordinatesAndZoom() {
        XCTAssertTrue(GeminiService.hasUsableFraming([
            "target_x": 0.28, "target_y": 0.39, "suggested_zoom": 1.2
        ]))
        XCTAssertFalse(GeminiService.hasUsableFraming([
            "explanation": "Ảnh đẹp", "suggested_zoom": 1.2
        ]))
        XCTAssertFalse(GeminiService.hasUsableFraming([
            "target_x": 1.3, "target_y": 0.39, "suggested_zoom": 1.2
        ]))
    }

    func testPartialTextDoesNotFabricateCenteredFraming() {
        XCTAssertNil(GeminiService.regexExtractFallbackFraming(
            from: "{\"explanation\":\"Đã phân tích\"}", modelUsed: "test", latencyMs: 10
        ))
    }
}
