import XCTest
@testable import SonioxTranscriber

final class TranscriptAccumulatorTests: XCTestCase {
    func testFinalTokensAppendAndProvisionalTokensReplace() {
        var sut = TranscriptAccumulator()
        sut.consume([SonioxToken(text: "こん", isFinal: false, speaker: "1")])
        sut.consume([SonioxToken(text: "こんにちは", isFinal: true, speaker: "1"), SonioxToken(text: "世", isFinal: false, speaker: "1")])
        XCTAssertEqual(sut.finalText, "こんにちは")
        XCTAssertEqual(sut.provisionalText, "世")
        sut.consume([SonioxToken(text: "世界", isFinal: false, speaker: "1")])
        XCTAssertEqual(sut.finalText, "こんにちは")
        XCTAssertEqual(sut.provisionalText, "世界")
    }

    func testSegmentsGroupAdjacentSpeakersAndIgnoreMarkers() {
        var sut = TranscriptAccumulator()
        sut.consume([
            SonioxToken(text: "こんにちは", isFinal: true, speaker: "1"),
            SonioxToken(text: "。", isFinal: true, speaker: "1"),
            SonioxToken(text: "どうも", isFinal: true, speaker: "2"),
            SonioxToken(text: "<end>", isFinal: true, speaker: nil)
        ])
        XCTAssertEqual(sut.segments.map(\.text), ["こんにちは。", "どうも"])
        XCTAssertEqual(sut.segments.map(\.speaker), ["1", "2"])
    }

    func testFinalizingProvisionalTokensRetainsVisibleText() {
        var sut = TranscriptAccumulator()
        sut.consume([
            SonioxToken(text: "途中まで", isFinal: true, speaker: "1"),
            SonioxToken(text: "話した内容", isFinal: false, speaker: "1")
        ])

        sut.finalizeProvisionalTokens()

        XCTAssertEqual(sut.finalText, "途中まで話した内容")
        XCTAssertEqual(sut.provisionalText, "")
        XCTAssertEqual(sut.segments.map(\.text), ["途中まで話した内容"])
    }
}
