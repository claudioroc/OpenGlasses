import Foundation
import UserNotifications

/// Local notification edge for job completion and approval gates. It never
/// requests critical-alert privileges and never embeds job detail in userInfo.
enum FleetNotificationCoordinator {
    static let categoryIdentifier = "FLEET_JOB"

    static func configure() {
        let center = UNUserNotificationCenter.current()
        let open = UNNotificationAction(
            identifier: "OPEN_FLEET_JOB",
            title: "Open Fleet",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [open],
            intentIdentifiers: [],
            options: []
        )
        center.getNotificationCategories { categories in
            center.setNotificationCategories(categories.union([category]))
        }
    }

    static func prepareAuthorization() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func notifyTransition(job: FleetJobSnapshot, previousPhase: FleetJobPhase?) async {
        guard previousPhase != job.phase else { return }
        guard job.phase.isTerminal || job.phase == .awaitingApproval else { return }

        let defaultsKey = "fleetSiri.lastNotifiedPhase.\(job.id)"
        let defaults = SharedAppState.defaults
        guard defaults.string(forKey: defaultsKey) != job.phase.rawValue else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = job.phase == .awaitingApproval ? "Fleet needs approval" : "Fleet task \(job.phase.displayName)"
        content.body = String(job.spokenSummary.prefix(180))
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier
        content.userInfo = ["job_id": job.id]

        let request = UNNotificationRequest(
            identifier: "fleet-job-\(job.id)-\(job.phase.rawValue)",
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            defaults.set(job.phase.rawValue, forKey: defaultsKey)
        } catch {
            NSLog("[FleetNotification] delivery failed: %@", error.localizedDescription)
        }
    }
}
