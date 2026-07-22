import Foundation
import SwiftData

struct TranscriptSegment: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var speaker: String
    var text: String
}

@Model
final class Transcription {
    @Attribute(.unique) var id: UUID
    var title: String
    var text: String
    var segmentsData: Data
    var createdAt: Date
    var updatedAt: Date
    var duration: TimeInterval

    init(id: UUID = UUID(), title: String, text: String, segments: [TranscriptSegment], createdAt: Date = .now, duration: TimeInterval) {
        self.id = id
        self.title = title
        self.text = text
        self.segmentsData = (try? JSONEncoder().encode(segments)) ?? Data()
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.duration = duration
    }

    var segments: [TranscriptSegment] {
        (try? JSONDecoder().decode([TranscriptSegment].self, from: segmentsData)) ?? []
    }
}

struct SonioxToken: Decodable, Equatable {
    let text: String
    let isFinal: Bool
    let speaker: String?

    enum CodingKeys: String, CodingKey {
        case text
        case isFinal = "is_final"
        case speaker
    }
}

struct SonioxResponse: Decodable {
    let tokens: [SonioxToken]?
    let finished: Bool?
    let errorCode: String?
    let errorType: String?
    let errorMessage: String?
    let requestID: String?

    enum CodingKeys: String, CodingKey {
        case tokens, finished
        case errorCode = "error_code"
        case errorType = "error_type"
        case errorMessage = "error_message"
        case requestID = "request_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tokens = try container.decodeIfPresent([SonioxToken].self, forKey: .tokens)
        finished = try container.decodeIfPresent(Bool.self, forKey: .finished)
        errorType = try container.decodeIfPresent(String.self, forKey: .errorType)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        requestID = try container.decodeIfPresent(String.self, forKey: .requestID)
        if let string = try? container.decodeIfPresent(String.self, forKey: .errorCode) {
            errorCode = string
        } else if let number = try? container.decodeIfPresent(Int.self, forKey: .errorCode) {
            errorCode = String(number)
        } else {
            errorCode = nil
        }
    }
}

struct TranscriptAccumulator {
    private(set) var finalTokens: [SonioxToken] = []
    private(set) var provisionalTokens: [SonioxToken] = []
    private var sessionBreaks: Set<Int> = []

    mutating func consume(_ tokens: [SonioxToken]) {
        provisionalTokens = tokens.filter { !$0.isFinal }
        finalTokens.append(contentsOf: tokens.filter(\.isFinal))
    }

    /// Soniox が終了時の確定応答を返せなかった場合でも、最後に表示していた
    /// 仮トークンを失わず履歴へ残すために使用する。
    mutating func finalizeProvisionalTokens() {
        finalTokens.append(contentsOf: provisionalTokens)
        provisionalTokens = []
    }

    /// Ends the current Soniox stream without ending the user-visible recording.
    /// Speaker identifiers are scoped to a stream, so the next stream must not
    /// merge its first speaker with the previous stream's last speaker.
    mutating func beginNewSession() {
        finalizeProvisionalTokens()
        sessionBreaks.insert(finalTokens.count)
    }

    var finalText: String { finalTokens.map(\.text).joined() }
    var provisionalText: String { provisionalTokens.map(\.text).joined() }

    var segments: [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        for (index, token) in finalTokens.enumerated() where token.text != "<end>" && token.text != "<fin>" {
            let speaker = token.speaker ?? "1"
            if !sessionBreaks.contains(index), result.last?.speaker == speaker {
                result[result.count - 1].text += token.text
            } else {
                result.append(TranscriptSegment(speaker: speaker, text: token.text))
            }
        }
        return result.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
