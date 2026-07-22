import ActivityKit
import Foundation

@MainActor
final class RecordingLiveActivityController: ObservableObject {
    private var activity: Activity<RecordingActivityAttributes>?
    private var operationTask: Task<Void, Never>?

    init() {
        activity = Activity<RecordingActivityAttributes>.activities.first
    }

    deinit {
        operationTask?.cancel()
    }

    func handle(state: TranscriptionManager.State, elapsed: TimeInterval) {
        operationTask?.cancel()

        guard let phase = phase(for: state) else {
            if state == .idle || isFailure(state) {
                endAllActivities()
            }
            return
        }

        let startedAt = activity?.content.state.startedAt
            ?? Date.now.addingTimeInterval(-max(0, elapsed))
        let contentState = RecordingActivityAttributes.ContentState(
            startedAt: startedAt,
            status: state.label,
            phase: phase
        )

        if let activity {
            operationTask = Task {
                await activity.update(ActivityContent(state: contentState, staleDate: nil))
            }
        } else if phase == .recording,
                  ActivityAuthorizationInfo().areActivitiesEnabled {
            do {
                activity = try Activity.request(
                    attributes: RecordingActivityAttributes(title: "Soniox文字起こし"),
                    content: ActivityContent(state: contentState, staleDate: nil),
                    pushType: nil
                )
            } catch {
                // Live Activities may be disabled or the system may have reached
                // its activity limit. Recording itself must continue either way.
            }
        }
    }

    private func phase(for state: TranscriptionManager.State) -> RecordingActivityAttributes.ContentState.Phase? {
        switch state {
        case .recording: .recording
        case .interrupted: .interrupted
        case .reconnecting: .reconnecting
        case .finishing: .finishing
        case .idle, .connecting, .failed: nil
        }
    }

    private func isFailure(_ state: TranscriptionManager.State) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private func endAllActivities() {
        let activities = Activity<RecordingActivityAttributes>.activities
        guard !activities.isEmpty else {
            activity = nil
            return
        }
        let finalState = RecordingActivityAttributes.ContentState(
            startedAt: activity?.content.state.startedAt ?? .now,
            status: "録音終了",
            phase: .finishing
        )
        activity = nil
        operationTask = Task {
            for activity in activities {
                await activity.end(
                    ActivityContent(state: finalState, staleDate: nil),
                    dismissalPolicy: .immediate
                )
            }
        }
    }
}
