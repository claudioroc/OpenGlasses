import SwiftUI
import WidgetKit

struct FleetStatusWidget: Widget {
    let kind = "FleetStatusWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FleetStatusProvider()) { entry in
            FleetStatusView(entry: entry)
                .containerBackground(for: .widget) {
                    LinearGradient(
                        colors: [Color.black, Color(red: 0.17, green: 0.08, blue: 0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
                .widgetURL(URL(string: "openglasses://fleet"))
        }
        .configurationDisplayName("Fleet Cortex")
        .description("Fleet health, active jobs and approvals from Home Overseer.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct FleetStatusEntry: TimelineEntry {
    let date: Date
    let state: FleetWidgetState
}

private struct FleetStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> FleetStatusEntry {
        FleetStatusEntry(
            date: Date(),
            state: FleetWidgetState(
                health: "healthy",
                spokenSummary: "Fleet stable; no consecutive failures.",
                activeJobs: 1,
                pendingApprovals: 0,
                lastJobTitle: "Review acquisition pipeline",
                lastJobPhase: "running",
                updatedAt: Date()
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (FleetStatusEntry) -> Void) {
        completion(FleetStatusEntry(date: Date(), state: SharedAppState.fleetWidgetState))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FleetStatusEntry>) -> Void) {
        let entry = FleetStatusEntry(date: Date(), state: SharedAppState.fleetWidgetState)
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

private struct FleetStatusView: View {
    let entry: FleetStatusEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(healthColor)
                Text("Fleet Cortex")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Circle()
                    .fill(healthColor)
                    .frame(width: 8, height: 8)
            }

            Text(entry.state.spokenSummary)
                .font(family == .systemSmall ? .caption : .subheadline)
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(family == .systemSmall ? 3 : 2)

            Spacer(minLength: 2)

            if family == .systemMedium, let title = entry.state.lastJobTitle {
                Label {
                    Text("\(title) · \(entry.state.lastJobPhase ?? "updated")")
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "bolt.horizontal.circle")
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.72))
            }

            HStack(spacing: 12) {
                metric(icon: "gearshape.2", value: entry.state.activeJobs, label: "active")
                metric(icon: "checkmark.shield", value: entry.state.pendingApprovals, label: "approvals")
                Spacer()
                if let updated = entry.state.updatedAt {
                    Text(updated, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
    }

    private func metric(icon: String, value: Int, label: String) -> some View {
        Label("\(value) \(label)", systemImage: icon)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.white.opacity(0.82))
    }

    private var healthColor: Color {
        switch entry.state.health {
        case "healthy": return .green
        case "degraded": return .orange
        case "down": return .red
        default: return .gray
        }
    }
}
