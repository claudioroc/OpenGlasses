import Foundation
import WidgetKit

struct FleetWidgetState: Codable, Equatable {
    var health: String
    var spokenSummary: String
    var activeJobs: Int
    var pendingApprovals: Int
    var lastJobTitle: String?
    var lastJobPhase: String?
    var updatedAt: Date?

    static let empty = FleetWidgetState(
        health: "unknown",
        spokenSummary: "Ask Siri for fleet status.",
        activeJobs: 0,
        pendingApprovals: 0,
        lastJobTitle: nil,
        lastJobPhase: nil,
        updatedAt: nil
    )
}

/// Cross-process state shared between the app and its widget/control extension.
///
/// Backed by `UserDefaults(suiteName: "group.com.openglasses.app")` so writes from the
/// widget process are immediately visible to the app. A Darwin notification is posted on
/// every write so an alive (background or foreground) app process can react instantly.
enum SharedAppState {
    static let appGroup = (Bundle.main.object(forInfoDictionaryKey: "OpenGlassesAppGroup") as? String)
        ?? "group.com.openglasses.app"
    static let listeningChangedNotification = "com.openglasses.app.listening-changed"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    static var isListening: Bool {
        get { defaults.bool(forKey: "listeningEnabled") }
        set {
            defaults.set(newValue, forKey: "listeningEnabled")
            postListeningChanged()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    static var fleetWidgetState: FleetWidgetState {
        get {
            guard let data = defaults.data(forKey: "fleetSiri.widgetState.v1") else {
                return .empty
            }
            return (try? JSONDecoder().decode(FleetWidgetState.self, from: data)) ?? .empty
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: "fleetSiri.widgetState.v1")
            WidgetCenter.shared.reloadTimelines(ofKind: "FleetStatusWidget")
        }
    }

    static func postListeningChanged() {
        let name = CFNotificationName(listeningChangedNotification as CFString)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            name,
            nil, nil, true
        )
    }
}
