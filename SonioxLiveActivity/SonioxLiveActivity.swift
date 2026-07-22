import ActivityKit
import SwiftUI
import WidgetKit

@main
struct SonioxLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
    }
}

struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(context.state.tint.opacity(0.18))
                    Image(systemName: context.state.symbol)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(context.state.tint)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text(context.attributes.title)
                        .font(.headline)
                    Text(context.state.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Text(context.state.startedAt, style: .timer)
                    .font(.headline.monospacedDigit())
                    .multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, 4)
            .activityBackgroundTint(.black.opacity(0.82))
            .activitySystemActionForegroundColor(.white)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(context.attributes.title)、\(context.state.status)")
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("録音", systemImage: context.state.symbol)
                        .foregroundStyle(context.state.tint)
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.startedAt, style: .timer)
                        .font(.headline.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.state.status)
                            .font(.subheadline)
                        Spacer()
                        Image(systemName: "waveform")
                            .foregroundStyle(context.state.tint)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.symbol)
                    .foregroundStyle(context.state.tint)
                    .accessibilityLabel("録音状態")
            } compactTrailing: {
                Text(context.state.startedAt, style: .timer)
                    .font(.caption2.monospacedDigit())
                    .frame(width: 48)
                    .accessibilityLabel("録音時間")
            } minimal: {
                Image(systemName: context.state.symbol)
                    .foregroundStyle(context.state.tint)
                    .accessibilityLabel(context.state.status)
            }
            .keylineTint(context.state.tint)
        }
    }
}

private extension RecordingActivityAttributes.ContentState {
    var tint: Color {
        switch phase {
        case .recording: .red
        case .interrupted, .reconnecting, .finishing: .orange
        }
    }

    var symbol: String {
        switch phase {
        case .recording: "waveform"
        case .interrupted: "mic.slash.fill"
        case .reconnecting: "arrow.triangle.2.circlepath"
        case .finishing: "ellipsis.circle.fill"
        }
    }
}
