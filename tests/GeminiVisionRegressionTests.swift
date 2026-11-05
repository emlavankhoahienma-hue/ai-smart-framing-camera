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

    func testGoogleGeminiInteractionsFallbackChainUses2026Models() {
        let chain = AIVisionModel.fallbackChain(
            selected: .autoStrongest, customModelName: "", provider: .googleGemini
        )
        XCTAssertEqual(chain.first, "gemini-3.8-flash")
        XCTAssertEqual(chain, ["gemini-3.8-flash", "gemini-3.5-flash-lite", "gemini-3.1-flash-lite"])
    }

    func testGeminiStructuredFramingOutputDecoding() {
        let jsonStr = """
        {
            "target_x": 0.33,
            "target_y": 0.45,
            "suggested_zoom": 1.5,
            "composition_rule": "Rule of Thirds",
            "scene_type": "portrait",
            "explanation": "Chủ thể tại điểm vàng",
            "recommended_preset": "Kodak Portra 400",
            "preset_explanation": "Tone màu ấm",
            "color_recipe": {
                "exposure_ev": 0.2,
                "contrast": 1.1,
                "highlights": -0.1,
                "shadows": 0.1,
                "warmth": 5600,
                "tint": 0,
                "saturation": 1.05
            }
        }
        """
        guard let data = jsonStr.data(using: .utf8),
              let output = try? JSONDecoder().decode(GeminiStructuredFramingOutput.self, from: data) else {
            XCTFail("Failed to decode GeminiStructuredFramingOutput")
            return
        }
        let response = output.toFramingResponse(modelUsed: "gemini-3.8-flash", latencyMs: 120)
        XCTAssertEqual(response.targetX, 0.33)
        XCTAssertEqual(response.targetY, 0.45)
        XCTAssertEqual(response.suggestedZoom, 1.5)
        XCTAssertEqual(response.modelUsed, "gemini-3.8-flash")
        XCTAssertEqual(response.colorRecipe.temperatureK, 5600)
    }
}
