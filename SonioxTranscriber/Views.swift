import SwiftUI
import SwiftData
import UIKit

struct RootView: View {
    @State private var apiKey = KeychainStore.loadAPIKey()
    @State private var showingSetup = KeychainStore.loadAPIKey() == nil

    var body: some View {
        MainView(apiKey: $apiKey, showingSetup: $showingSetup)
            .fullScreenCover(isPresented: $showingSetup) {
                APIKeyView(apiKey: $apiKey, canDismiss: apiKey != nil)
            }
    }
}

struct APIKeyView: View {
    @Binding var apiKey: String?
    let canDismiss: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var revealKey = false
    @State private var isChecking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "waveform.and.mic")
                            .font(.system(size: 44)).foregroundStyle(Color.accentColor)
                        Text("Sonioxをはじめる").font(.title2.bold())
                        Text("あなた自身のSoniox APIキーを入力してください。キーはこのiPhoneのKeychainだけに保存されます。")
                            .foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                }
                Section("APIキー") {
                    HStack {
                        Group {
                            if revealKey { TextField("APIキー", text: $input) }
                            else { SecureField("APIキー", text: $input) }
                        }
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button { revealKey.toggle() } label: {
                            Image(systemName: revealKey ? "eye.slash" : "eye")
                        }.buttonStyle(.plain)
                    }
                    Link("Soniox ConsoleでAPIキーを発行", destination: URL(string: "https://console.soniox.com/")!)
                }
                Section {
                    Button {
                        Task { await validateAndSave() }
                    } label: {
                        HStack {
                            Spacer()
                            if isChecking { ProgressView().padding(.trailing, 6) }
                            Text(isChecking ? "接続を確認中…" : "接続を確認して保存")
                            Spacer()
                        }
                    }
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isChecking)
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
                if apiKey != nil {
                    Section {
                        Button("保存済みAPIキーを削除", role: .destructive) {
                            KeychainStore.deleteAPIKey(); apiKey = nil; input = ""
                        }
                    }
                }
            }
            .navigationTitle("設定")
            .toolbar {
                if canDismiss { ToolbarItem(placement: .topBarTrailing) { Button("完了") { dismiss() } } }
            }
            .interactiveDismissDisabled(!canDismiss)
            .onAppear { input = apiKey ?? "" }
        }
    }

    private func validateAndSave() async {
        isChecking = true; errorMessage = nil
        let candidate = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let socket = SonioxWebSocket()
        do {
            try await socket.connect(apiKey: candidate)
            try await socket.finish()
            let response = try await withThrowingTaskGroup(of: SonioxResponse.self) { group in
                group.addTask { try await socket.receive() }
                group.addTask { try await Task.sleep(for: .seconds(8)); throw SonioxServiceError.connection }
                let value = try await group.next()!
                group.cancelAll()
                return value
            }
            _ = response
            await socket.close()
            try KeychainStore.saveAPIKey(candidate)
            apiKey = candidate
            dismiss()
        } catch {
            await socket.close()
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "APIキーを確認できませんでした。"
        }
        isChecking = false
    }
}

struct MainView: View {
    @Binding var apiKey: String?
    @Binding var showingSetup: Bool
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Transcription.createdAt, order: .reverse) private var history: [Transcription]
    @StateObject private var manager = TranscriptionManager()
    @State private var showingHistory = false
    @State private var selected: Transcription?
    @State private var shareItem: ShareItem?
    @State private var showMicSettings = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                transcriptContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                recordButton.padding(.bottom, 28)
            }
            .navigationTitle(selected?.title ?? "文字起こし")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingHistory = true } label: { Image(systemName: "line.3.horizontal") }
                    .accessibilityLabel("履歴")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showingSetup = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("設定")
                    Button { createShareFile() } label: { Image(systemName: "square.and.arrow.up") }
                        .disabled(currentText.isEmpty || manager.isActive)
                        .accessibilityLabel("共有")
                }
            }
        }
        .sheet(isPresented: $showingHistory) {
            HistoryView(history: history, selected: $selected, isPresented: $showingHistory) {
                selected = nil
                if !manager.isActive { manager.resetTranscript() }
            }
        }
        .sheet(item: $shareItem) { ShareSheet(items: [$0.url]) }
        .alert("マイクへのアクセスが必要です", isPresented: $showMicSettings) {
            Button("設定を開く") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
            Button("キャンセル", role: .cancel) {}
        } message: { Text("設定アプリでマイクへのアクセスを許可してください。") }
        .onAppear {
            manager.onCompleted = { text, segments, duration in save(text: text, segments: segments, duration: duration) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active && manager.isActive { Task { await manager.handleInterruption() } }
        }
        .onChange(of: manager.state) { _, state in
            if case .failed(let message) = state, message.contains("マイク") { showMicSettings = true }
            if case .failed(let message) = state, message.contains("APIキー") { showingSetup = true }
        }
    }

    @ViewBuilder private var transcriptContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if manager.isActive {
                        statusHeader
                        ForEach(manager.segments) { segment in
                            speakerBlock(segment)
                        }
                        if !manager.provisionalText.isEmpty {
                            Text(manager.provisionalText).foregroundStyle(.secondary)
                        }
                    } else if let selected {
                        Text(selected.createdAt.formatted(date: .long, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        ForEach(selected.segments) { speakerBlock($0) }
                        if selected.segments.isEmpty { Text(selected.text).font(.body) }
                    } else if !manager.finalText.isEmpty {
                        ForEach(manager.segments) { segment in
                            speakerBlock(segment)
                        }
                        if manager.segments.isEmpty { Text(manager.finalText).textSelection(.enabled) }
                    } else {
                        ContentUnavailableView("話して、文字に。", systemImage: "mic.fill", description: Text("下のマイクボタンを押すと\nリアルタイム文字起こしが始まります。"))
                            .padding(.top, 120)
                    }
                    Spacer(minLength: 130)
                    Color.clear.frame(height: 1).id("transcript-bottom")
                }.padding()
            }
            .onChange(of: manager.finalText) { _, _ in scrollToLatest(using: proxy) }
            .onChange(of: manager.provisionalText) { _, _ in scrollToLatest(using: proxy) }
        }
    }

    private func scrollToLatest(using proxy: ScrollViewProxy) {
        guard manager.isActive else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo("transcript-bottom", anchor: .bottom)
        }
    }

    private var statusHeader: some View {
        HStack {
            Circle().fill(manager.state == .recording ? .red : .orange).frame(width: 8, height: 8)
            Text(manager.state.label).font(.caption.weight(.medium))
            Spacer()
            Text(formatDuration(manager.elapsed)).monospacedDigit().font(.caption)
        }.foregroundStyle(.secondary)
    }

    private func speakerBlock(_ segment: TranscriptSegment) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("話者 \(segment.speaker)").font(.caption.bold()).foregroundStyle(Color.accentColor)
            Text(segment.text).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recordButton: some View {
        Button {
            Task {
                if manager.isActive { await manager.stop() }
                else if let apiKey { selected = nil; await manager.start(apiKey: apiKey) }
                else { showingSetup = true }
            }
        } label: {
            ZStack {
                Circle().fill(manager.isActive ? Color.red : Color.cyan.opacity(0.85))
                    .frame(width: 76, height: 76).shadow(color: .black.opacity(0.16), radius: 10, y: 4)
                if manager.state == .connecting || manager.state == .finishing { ProgressView().tint(.white) }
                else { Image(systemName: manager.isActive ? "stop.fill" : "mic.fill").font(.system(size: 30)).foregroundStyle(.white) }
            }
        }.disabled(manager.state == .finishing).accessibilityLabel(manager.isActive ? "停止" : "録音開始")
    }

    private var currentText: String { selected?.text ?? manager.finalText }

    private func save(text: String, segments: [TranscriptSegment], duration: TimeInterval) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let title = String(clean.prefix(28)) + (clean.count > 28 ? "…" : "")
        let item = Transcription(title: title, text: clean, segments: segments, duration: duration)
        modelContext.insert(item); try? modelContext.save(); selected = item
    }

    private func createShareFile() {
        let title = selected?.title ?? String(currentText.prefix(28))
        let date = selected?.createdAt ?? .now
        let duration = selected?.duration ?? manager.elapsed
        let segments = selected?.segments ?? manager.segments
        let body = segments.isEmpty ? currentText : segments.map { "話者 \($0.speaker)\n\($0.text)" }.joined(separator: "\n\n")
        let content = "\(title)\n\(date.formatted(date: .long, time: .shortened))\n録音時間: \(formatDuration(duration))\n\n\(body)\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeFilename(title)).txt")
        do { try content.write(to: url, atomically: true, encoding: .utf8); shareItem = ShareItem(url: url) } catch {}
    }
}

struct HistoryView: View {
    let history: [Transcription]
    @Binding var selected: Transcription?
    @Binding var isPresented: Bool
    let onNewTranscription: () -> Void
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationStack {
            List {
                Button {
                    onNewTranscription()
                    isPresented = false
                } label: { Label("新しい文字起こし", systemImage: "square.and.pencil") }
                Section("履歴") {
                    if history.isEmpty { Text("履歴はまだありません").foregroundStyle(.secondary) }
                    ForEach(history) { item in
                        Button { selected = item; isPresented = false } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).lineLimit(1).foregroundStyle(.primary)
                                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.onDelete { offsets in offsets.forEach { modelContext.delete(history[$0]) }; try? modelContext.save() }
                }
            }.navigationTitle("文字起こし履歴").toolbar { Button("閉じる") { isPresented = false } }
        }
    }
}

struct ShareItem: Identifiable { let id = UUID(); let url: URL }
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private func formatDuration(_ value: TimeInterval) -> String {
    let total = max(0, Int(value)); return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
}
private func safeFilename(_ value: String) -> String {
    let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
    let clean = value.components(separatedBy: invalid).joined(separator: "_")
    return clean.isEmpty ? "文字起こし" : String(clean.prefix(60))
}
