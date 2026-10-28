import Foundation
import UserNotifications

/// Polls the Claude status page (Atlassian Statuspage JSON API) and notifies
/// when the overall status indicator changes.
@MainActor
class StatusMonitor: ObservableObject {
    /// "none", "minor", "major", "critical" (Statuspage indicators)
    @Published var indicator: String?
    @Published var statusDescription: String = ""
    @Published var incidentName: String = ""

    static let statusPageURL = "https://status.claude.com"
    private static let summaryURL = URL(string: "https://status.claude.com/api/v2/summary.json")!
    private static let lastIndicatorKey = "lastStatusIndicator"

    /// User preference: notify when the status changes (default on)
    var alertsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "statusAlertsEnabled") as? Bool ?? true }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: "statusAlertsEnabled")
        }
    }

    private var timer: Timer?

    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    func start() {
        guard timer == nil else { return }
        Task { await check() }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
    }

    func check() async {
        guard let (data, response) = try? await urlSession.data(from: Self.summaryURL),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let status = json["status"] as? [String: Any],
              let newIndicator = status["indicator"] as? String else {
            return // network/API failure — keep last known state, try again next tick
        }

        let description = status["description"] as? String ?? ""
        let incidents = json["incidents"] as? [[String: Any]] ?? []
        let firstIncident = incidents.first?["name"] as? String ?? ""

        indicator = newIndicator
        statusDescription = description
        incidentName = firstIncident

        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: Self.lastIndicatorKey)
        defaults.set(newIndicator, forKey: Self.lastIndicatorKey)

        // Notify only on a real change (not on first-ever check)
        guard let previous, previous != newIndicator, alertsEnabled else { return }

        let content = UNMutableNotificationContent()
        if newIndicator == "none" {
            content.title = "Claude status: recovered"
            content.body = description // "All Systems Operational"
        } else {
            content.title = "Claude status: \(description)"
            content.body = firstIncident.isEmpty ? "See status.claude.com for details" : firstIncident
        }
        content.sound = .default
        content.userInfo = ["status_url": Self.statusPageURL]

        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "status-\(Date().timeIntervalSince1970)", content: content, trigger: nil)
        )
    }
}
