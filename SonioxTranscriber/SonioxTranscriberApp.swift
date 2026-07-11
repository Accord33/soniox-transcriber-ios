import SwiftUI
import SwiftData

@main
struct SonioxTranscriberApp: App {
    private let container: ModelContainer = {
        let schema = Schema([Transcription.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        return try! ModelContainer(for: schema, configurations: [configuration])
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }
}
