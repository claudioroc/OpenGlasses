import ActivityKit
import SwiftUI
import WidgetKit

struct FleetJobActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FleetJobActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: phaseIcon(context.state.phase))
                    .font(.title2)
                    .foregroundStyle(phaseColor(context.state.phase))
                VStack(alignment: .leading, spacing: 3) {
                    Text(context.attributes.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(context.state.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Text(phaseLabel(context.state.phase))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(phaseColor(context.state.phase))
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.88))
            .activitySystemActionForegroundColor(.white)
            .widgetURL(jobURL(context.attributes.jobId))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.domain, systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.caption)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(phaseLabel(context.state.phase))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(phaseColor(context.state.phase))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.attributes.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(context.state.summary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(AccentColors.aiCoral)
            } compactTrailing: {
                Image(systemName: phaseIcon(context.state.phase))
                    .foregroundStyle(phaseColor(context.state.phase))
            } minimal: {
                Image(systemName: phaseIcon(context.state.phase))
                    .foregroundStyle(phaseColor(context.state.phase))
            }
            .widgetURL(jobURL(context.attributes.jobId))
        }
    }

    private func jobURL(_ id: String) -> URL {
        var components = URLComponents()
        components.scheme = "openglasses"
        components.host = "fleet"
        components.path = "/job/\(id)"
        return components.url ?? URL(string: "openglasses://fleet")!
    }

    private func phaseIcon(_ phase: String) -> String {
        switch phase {
        case "queued": return "clock"
        case "running": return "gearshape.2"
        case "awaitingApproval": return "checkmark.shield"
        case "succeeded": return "checkmark.circle.fill"
        case "failed": return "exclamationmark.triangle.fill"
        case "cancelled": return "xmark.circle"
        default: return "questionmark.circle"
        }
    }

    private func phaseLabel(_ phase: String) -> String {
        switch phase {
        case "awaitingApproval": return "approval"
        case "succeeded": return "done"
        default: return phase
        }
    }

    private func phaseColor(_ phase: String) -> Color {
        switch phase {
        case "succeeded": return .green
        case "failed": return .red
        case "cancelled": return .gray
        case "awaitingApproval": return .orange
        default: return AccentColors.aiCoral
        }
    }
}
