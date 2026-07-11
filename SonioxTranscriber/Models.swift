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
    let errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case tokens, finished
        case errorCode = "error_code"
        case errorMessage = "error_message"
    }
}

struct TranscriptAccumulator {
    private(set) var finalTokens: [SonioxToken] = []
    private(set) var provisionalTokens: [SonioxToken] = []

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

    var finalText: String { finalTokens.map(\.text).joined() }
    var provisionalText: String { provisionalTokens.map(\.text).joined() }

    var segments: [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        for token in finalTokens where token.text != "<end>" && token.text != "<fin>" {
            let speaker = token.speaker ?? "1"
            if result.last?.speaker == speaker {
                result[result.count - 1].text += token.text
            } else {
                result.append(TranscriptSegment(speaker: speaker, text: token.text))
            }
        }
        return result.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
