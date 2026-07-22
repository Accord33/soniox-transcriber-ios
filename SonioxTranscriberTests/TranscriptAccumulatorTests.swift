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

    func testNewSessionDoesNotMergeMatchingSpeakerIdentifiers() {
        var sut = TranscriptAccumulator()
        sut.consume([SonioxToken(text: "最初の接続", isFinal: true, speaker: "1")])

        sut.beginNewSession()
        sut.consume([SonioxToken(text: "再接続後", isFinal: true, speaker: "1")])

        XCTAssertEqual(sut.finalText, "最初の接続再接続後")
        XCTAssertEqual(sut.segments.map(\.text), ["最初の接続", "再接続後"])
        XCTAssertEqual(sut.segments.map(\.speaker), ["1", "1"])
    }

    func testNewSessionFinalizesVisibleProvisionalTokens() {
        var sut = TranscriptAccumulator()
        sut.consume([SonioxToken(text: "切断直前", isFinal: false, speaker: "2")])

        sut.beginNewSession()

        XCTAssertEqual(sut.finalText, "切断直前")
        XCTAssertEqual(sut.provisionalText, "")
    }

    func testSonioxResponseDecodesNumericErrorDetails() throws {
        let data = Data(#"{"error_code":503,"error_type":"service_unavailable","error_message":"retry","request_id":"request-1"}"#.utf8)

        let response = try JSONDecoder().decode(SonioxResponse.self, from: data)

        XCTAssertEqual(response.errorCode, "503")
        XCTAssertEqual(response.errorType, "service_unavailable")
        XCTAssertEqual(response.errorMessage, "retry")
        XCTAssertEqual(response.requestID, "request-1")
    }

    func testLiveActivityContentStateRoundTripsThroughCodable() throws {
        let state = RecordingActivityAttributes.ContentState(
            startedAt: Date(timeIntervalSince1970: 1_234),
            status: "再接続中… (1/3)",
            phase: .reconnecting
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(
            RecordingActivityAttributes.ContentState.self,
            from: data
        )

        XCTAssertEqual(decoded, state)
    }
}
