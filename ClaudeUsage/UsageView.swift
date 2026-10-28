import SwiftUI
import AppKit
import ServiceManagement

struct UsageView: View {
    @ObservedObject var manager: UsageManager
    @ObservedObject var sessionMonitor: SessionMonitor
    @ObservedObject var statusMonitor: StatusMonitor
    @ObservedObject var updateInstaller: UpdateInstaller
    @Environment(\.openURL) var openURL
    @State private var launchAtLogin: Bool = {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }()
    @State private var showingSettings = false
    @AppStorage(UsageNotificationSettings.enabledKey) private var notificationsEnabled = UsageNotificationSettings.defaultEnabled
    @AppStorage(UpdateCheckSettings.enabledKey) private var updateChecksEnabled = UpdateCheckSettings.defaultEnabled
    @StateObject private var config = ClaudeConfigManager()
    @State private var alertsEnabled = false
    @State private var menuBarStyle = MenuBarAppearance.style
    @State private var menuBarMetric = MenuBarAppearance.metric
    @AppStorage(UsageNotificationSettings.thresholdIntervalKey) private var notificationThresholdInterval = UsageNotificationSettings.defaultThresholdInterval
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundColor(.accentColor)
                Text("Claude Usage")
                    .font(.headline)
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()

                if manager.isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            // Update available banner
            if let newVersion = manager.updateAvailable {
                updateBanner(newVersion)
            }

            Divider()

            if showingSettings {
                settingsPanel()
            } else {
                // Live Claude Code sessions (when alert hooks are installed)
                if sessionMonitor.hooksInstalled && !sessionMonitor.sessions.isEmpty {
                    sessionsSection()
                    Divider()
                }

                // Profile tabs (only when several Claude Code logins exist)
                if manager.profiles.count > 1 {
                    profilePicker()
                }

                if let error = manager.error {
                    errorView(error)
                } else if let usage = manager.usage {
                    usageContent(usage)
                } else {
                    loadingView()
                }

                Divider()

                // Claude service status (from status.claude.com)
                statusRow()

                Divider()

                settingsButton()
            }
        }
        .frame(width: 280)
    }
    
    @ViewBuilder
    func profilePicker() -> some View {
        Picker("", selection: Binding(
            get: { manager.selectedProfileService ?? "" },
            set: { manager.selectProfile($0) }
        )) {
            ForEach(manager.profiles) { profile in
                Text(profile.shortLabel).tag(profile.service)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help(manager.profiles.map(\.label).joined(separator: " · "))
        .padding(.horizontal)
        .padding(.top, 10)
    }

    @ViewBuilder
    func usageContent(_ usage: UsageData) -> some View {
        VStack(spacing: 16) {
            // Session usage
            UsageRow(
                title: "Session",
                subtitle: "5-hour window",
                percentage: usage.sessionPercentage,
                resetsAt: usage.sessionResetsAt,
                color: colorForPercentage(usage.sessionPercentage)
            )
            
            // Weekly usage
            UsageRow(
                title: "Weekly",
                subtitle: "7-day window",
                percentage: usage.weeklyPercentage,
                resetsAt: usage.weeklyResetsAt,
                color: colorForPercentage(usage.weeklyPercentage)
            )
            
            // Model-scoped weekly limits (Fable, Opus, etc.)
            ForEach(usage.modelLimits, id: \.name) { limit in
                UsageRow(
                    title: limit.name,
                    subtitle: "Model weekly limit",
                    percentage: limit.percentage,
                    resetsAt: limit.resetsAt,
                    color: colorForPercentage(limit.percentage)
                )
            }

            // Sonnet usage (if available)
            if let sonnetPct = usage.sonnetPercentage {
                UsageRow(
                    title: "Sonnet",
                    subtitle: "Model-specific",
                    percentage: sonnetPct,
                    resetsAt: usage.sonnetResetsAt,
                    color: colorForPercentage(sonnetPct)
                )
            }

            // Extra usage / overage (if enabled)
            if usage.extraUsageEnabled, let limit = usage.extraUsageMonthlyLimit, let used = usage.extraUsageUsedCredits {
                OverageRow(
                    usedDollars: used / 100,
                    limitDollars: limit / 100,
                    percentage: usage.extraUsagePercentage ?? 0
                )
            }
        }
        .padding()
    }
    
    @ViewBuilder
    func sessionsSection() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CLAUDE SESSIONS")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            ForEach(sessionMonitor.sessions) { session in
                Button(action: {
                    AppDelegate.shared?.popover?.performClose(nil)
                    sessionMonitor.focusSession(session)
                }) {
                    HStack(spacing: 8) {
                        Text(sessionIcon(session))
                            .font(.caption)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(session.projectName)
                                .font(.caption)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            Text(sessionLabel(session))
                                .font(.caption2)
                                .foregroundColor(session.status == .needsAttention && !session.acknowledged ? .orange : .secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Text(session.updatedAt.formatted(.relative(presentation: .named)))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Jump to this session's terminal window")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    func sessionIcon(_ session: ClaudeSession) -> String {
        switch session.status {
        case .needsAttention: return session.acknowledged ? "🔕" : "🔔"
        case .running: return "⚙️"
        case .finished: return "✅"
        }
    }

    func sessionLabel(_ session: ClaudeSession) -> String {
        switch session.status {
        case .needsAttention:
            if session.acknowledged { return "Waiting (seen)" }
            return session.message.isEmpty ? "Needs your input" : session.message
        case .running:
            return "Working…"
        case .finished:
            return "Finished"
        }
    }

    @ViewBuilder
    func errorView(_ error: String) -> some View {
        VStack(spacing: 12) {
            if error.contains("Not logged in") {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.largeTitle)
                    .foregroundColor(.blue)

                Text("Not Signed In")
                    .font(.headline)

                Text("This app uses credentials from Claude Code stored in the macOS Keychain.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Text("Please run `claude` in Terminal and log in first.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Button("Open Terminal & Run Claude") {
                    launchClaudeCLI()
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)

                Button("Install Claude Code") {
                    openURL(URL(string: "https://docs.anthropic.com/en/docs/claude-code/overview")!)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundColor(.orange)

                Text(error)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
    }
    
    @ViewBuilder
    func loadingView() -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading usage data...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }
    
    @ViewBuilder
    func settingsButton() -> some View {
        HStack {
            Button(action: {
                Task { await manager.refresh() }
            }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(manager.isLoading)
            
            if let lastUpdated = manager.lastUpdated {
                Text("Updated \(lastUpdated.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: {
                openURL(URL(string: "https://claude.ai")!)
            }) {
                Image(systemName: "globe")
            }
            .buttonStyle(.borderless)
            
            Button(action: {
                showingSettings = true
            }) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            
            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)

        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }

    @ViewBuilder
    func updateBanner(_ newVersion: String) -> some View {
        VStack(spacing: 4) {
            switch updateInstaller.state {
            case .idle:
                if let downloadURL = manager.updateDownloadURL {
                    Button(action: {
                        Task { await updateInstaller.installUpdate(from: downloadURL) }
                    }) {
                        HStack {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("Update to v\(newVersion) & Relaunch")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                } else {
                    // No zip asset found — fall back to manual download
                    Button(action: {
                        openURL(URL(string: "https://github.com/richhickson/claudecodeusage/releases/latest")!)
                    }) {
                        HStack {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("Update Available: v\(newVersion)")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
            case .downloading:
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.6)
                    Text("Downloading v\(newVersion)…").font(.caption)
                }
            case .installing:
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.6)
                    Text("Verifying & installing…").font(.caption)
                }
            case .relaunching:
                Text("Relaunching…").font(.caption)
            case .failed(let message):
                Text("Update failed: \(message)")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Download manually") {
                    openURL(URL(string: "https://github.com/richhickson/claudecodeusage/releases/latest")!)
                }
                .font(.caption)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    func statusRow() -> some View {
        if let indicator = statusMonitor.indicator {
            Button(action: {
                openURL(URL(string: StatusMonitor.statusPageURL)!)
            }) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor(indicator))
                        .frame(width: 8, height: 8)
                    Text(statusMonitor.statusDescription.isEmpty ? "Claude status" : statusMonitor.statusDescription)
                        .font(.caption)
                        .foregroundColor(indicator == "none" ? .secondary : .primary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(statusMonitor.incidentName.isEmpty ? "Open status.claude.com" : statusMonitor.incidentName)
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    func statusColor(_ indicator: String) -> Color {
        switch indicator {
        case "none": return .green
        case "minor": return .yellow
        case "major": return .orange
        default: return .red // critical
        }
    }

    @ViewBuilder
    func settingsPanel() -> some View {
        VStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Usage Notifications", isOn: $notificationsEnabled)
                    .toggleStyle(.checkbox)
                    .font(.caption)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Notify every")
                        Spacer()
                        Text("\(Int(notificationThresholdInterval))%")
                            .foregroundColor(.secondary)
                    }
                    .font(.caption)

                    Slider(
                        value: $notificationThresholdInterval,
                        in: UsageNotificationSettings.minimumThresholdInterval...UsageNotificationSettings.maximumThresholdInterval,
                        step: UsageNotificationSettings.thresholdStep
                    )
                    .disabled(!notificationsEnabled)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            Toggle("Check for Updates", isOn: $updateChecksEnabled)
                .toggleStyle(.checkbox)
                .font(.caption)
                .padding(.horizontal)
                .onChange(of: updateChecksEnabled) { enabled in
                    Task {
                        if enabled { await manager.checkForUpdates() }
                        else { manager.clearUpdate() }
                    }
                }

            Toggle("Launch at Login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.caption)
                .onChange(of: launchAtLogin) { newValue in
                    do {
                        if newValue {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = !newValue
                    }
                }
                .padding(.horizontal)

            Divider()

            claudeCodeSettings()

            Divider()

            Button(action: {
                openURL(URL(string: "https://x.com/richhickson")!)
            }) {
                Text("Created by @richhickson")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)

            Divider()

            Button(action: {
                showingSettings = false
            }) {
                HStack {
                    Image(systemName: "xmark")
                    Text("Close Settings")
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .padding(.bottom, 8)
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    
    
    @ViewBuilder
    func claudeCodeSettings() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Menu bar", selection: $menuBarStyle) {
                ForEach(MenuBarStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            .font(.caption)
            .onChange(of: menuBarStyle) { newValue in
                MenuBarAppearance.style = newValue
                AppDelegate.shared?.updateStatusItem()
            }

            Picker("Show", selection: $menuBarMetric) {
                ForEach(MenuBarMetric.allCases) { metric in
                    Text(metric.label).tag(metric)
                }
            }
            .font(.caption)
            .onChange(of: menuBarMetric) { newValue in
                MenuBarAppearance.metric = newValue
                AppDelegate.shared?.updateStatusItem()
            }

            Divider()

            Toggle("Alert when a session needs attention", isOn: $alertsEnabled)
                .toggleStyle(.checkbox)
                .font(.caption)
                .onChange(of: alertsEnabled) { newValue in
                    guard newValue != sessionMonitor.hooksInstalled else { return }
                    do {
                        try sessionMonitor.setEnabled(newValue)
                        config.statusMessage = nil
                    } catch {
                        alertsEnabled = !newValue
                        config.statusMessage = "Failed: \(error.localizedDescription)"
                    }
                }

            Toggle("Show session pop-ups", isOn: Binding(
                get: { sessionMonitor.popupNotificationsEnabled },
                set: { sessionMonitor.popupNotificationsEnabled = $0 }
            ))
            .toggleStyle(.checkbox)
            .font(.caption)
            .disabled(!alertsEnabled)

            if alertsEnabled {
                switch sessionMonitor.notificationsAuthorized {
                case false:
                    Button("Notifications off in System Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundColor(.orange)
                case nil:
                    Button("Request notification permission") {
                        sessionMonitor.requestNotificationPermission()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                default:
                    Button("Send test notification") {
                        sessionMonitor.sendTestNotification()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }

            Toggle("Alert when Claude status changes", isOn: Binding(
                get: { statusMonitor.alertsEnabled },
                set: { statusMonitor.alertsEnabled = $0 }
            ))
            .toggleStyle(.checkbox)
            .font(.caption)

            Divider()

            HStack {
                Text("Keep conversations")
                Spacer()
                TextField("30", text: $config.cleanupPeriodDays)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 44)
                    .multilineTextAlignment(.trailing)
                    .onSubmit { config.saveCleanupPeriod() }
                Text("days")
                    .foregroundColor(.secondary)
            }
            .font(.caption)

            Button(action: {
                NSWorkspace.shared.open(config.claudeMdURL)
            }) {
                HStack {
                    Image(systemName: "doc.text")
                    Text("Edit CLAUDE.md")
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)

            if let status = config.statusMessage {
                Text(status)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal)
        .onAppear {
            config.load()
            alertsEnabled = sessionMonitor.hooksInstalled
            sessionMonitor.refreshNotificationAuthStatus()
        }
    }

    func colorForPercentage(_ pct: Int) -> Color {
        if pct >= 90 { return .red }
        if pct >= 70 { return .orange }
        return .green
    }

    func launchClaudeCLI() {
        let script = """
        tell application "Terminal"
            activate
            do script "claude"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }
}

struct UsageRow: View {
    let title: String
    let subtitle: String
    let percentage: Int
    let resetsAt: Date?
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Text("\(percentage)%")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(color)
            }
            
            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(NSColor.separatorColor))
                        .frame(height: 8)
                    
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color)
                        .frame(width: geometry.size.width * CGFloat(percentage) / 100, height: 8)
                }
            }
            .frame(height: 8)
            
            // Reset time
            if let resetsAt = resetsAt {
                HStack {
                    Image(systemName: "clock")
                        .font(.caption2)
                    Text("Resets \(formatTimeRemaining(resetsAt))")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
    
    func formatTimeRemaining(_ date: Date) -> String {
        let now = Date()
        let diff = date.timeIntervalSince(now)
        
        if diff <= 0 { return "soon" }
        
        let hours = Int(diff / 3600)
        let minutes = Int((diff.truncatingRemainder(dividingBy: 3600)) / 60)
        
        if hours > 24 {
            let days = hours / 24
            let remainingHours = hours % 24
            return "in \(days)d \(remainingHours)h"
        }
        
        return "in \(hours)h \(minutes)m"
    }
}

struct OverageRow: View {
    let usedDollars: Double
    let limitDollars: Double
    let percentage: Int

    var color: Color {
        if percentage >= 90 { return .red }
        if percentage >= 70 { return .orange }
        return .blue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Overage")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("Extra usage this month")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("$\(String(format: "%.2f", usedDollars))")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(color)
                    Text("of $\(String(format: "%.0f", limitDollars)) limit")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(NSColor.separatorColor))
                        .frame(height: 8)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(color)
                        .frame(width: geometry.size.width * CGFloat(min(percentage, 100)) / 100, height: 8)
                }
            }
            .frame(height: 8)
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}

#Preview {
    UsageView(manager: UsageManager(), sessionMonitor: SessionMonitor(), statusMonitor: StatusMonitor(), updateInstaller: UpdateInstaller())
}
