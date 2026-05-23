import SwiftUI
import WidgetKit

private let appGroupIdentifier = "group.com.helpfully.ClaudeUsage"
private let usageSnapshotKey = "latestUsageSnapshot"

struct UsageSnapshot: Codable {
    let sessionPercentage: Int
    let weeklyPercentage: Int
    let sonnetPercentage: Int?
    let extraUsagePercentage: Int?
    let lastUpdated: Date

    static let placeholder = UsageSnapshot(
        sessionPercentage: 42,
        weeklyPercentage: 18,
        sonnetPercentage: 31,
        extraUsagePercentage: nil,
        lastUpdated: Date()
    )
}

struct ClaudeUsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot?
}

struct ClaudeUsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> ClaudeUsageEntry {
        ClaudeUsageEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (ClaudeUsageEntry) -> Void) {
        completion(ClaudeUsageEntry(date: Date(), snapshot: loadSnapshot() ?? .placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ClaudeUsageEntry>) -> Void) {
        let entry = ClaudeUsageEntry(date: Date(), snapshot: loadSnapshot())
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }

    private func loadSnapshot() -> UsageSnapshot? {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier),
              let data = defaults.data(forKey: usageSnapshotKey) else {
            return nil
        }
        return try? JSONDecoder().decode(UsageSnapshot.self, from: data)
    }
}

struct ClaudeUsageWidgetExtensionEntryView: View {
    let entry: ClaudeUsageEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "chart.bar.fill")
                        .foregroundStyle(statusColor(snapshot.sessionPercentage))
                    Text("Claude Usage")
                        .font(.headline)
                        .lineLimit(1)
                }

                VStack(spacing: 8) {
                    usageRow(title: "Session", percentage: snapshot.sessionPercentage)
                    usageRow(title: "Weekly", percentage: snapshot.weeklyPercentage)

                    if let sonnetPercentage = snapshot.sonnetPercentage {
                        usageRow(title: "Sonnet", percentage: sonnetPercentage)
                    }

                    if let extraUsagePercentage = snapshot.extraUsagePercentage {
                        usageRow(title: "Overage", percentage: extraUsagePercentage)
                    }
                }

                Spacer(minLength: 0)

                Text("Updated \(snapshot.lastUpdated.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "chart.bar.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Claude Usage")
                    .font(.headline)
                Text("Open the menu bar app once to load usage data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }

    private func usageRow(title: String, percentage: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(percentage)%")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(statusColor(percentage))
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                    Capsule()
                        .fill(statusColor(percentage))
                        .frame(width: geometry.size.width * CGFloat(min(max(percentage, 0), 100)) / 100)
                }
            }
            .frame(height: 5)
        }
    }

    private func statusColor(_ percentage: Int) -> Color {
        if percentage >= 90 { return .red }
        if percentage >= 70 { return .orange }
        return .green
    }
}

struct ClaudeUsageWidgetExtension: Widget {
    let kind = "ClaudeUsageWidgetExtension"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ClaudeUsageProvider()) { entry in
            ClaudeUsageWidgetExtensionEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Claude Usage")
        .description("Shows your latest Claude usage from the menu bar app.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
