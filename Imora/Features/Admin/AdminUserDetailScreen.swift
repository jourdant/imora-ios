import SwiftUI

/// the web's user details page: counts, profile, feature switches, quota,
/// sessions and the upload heatmap, with the same toolbar actions.
struct AdminUserDetailScreen: View {
    @Environment(SessionStore.self) private var session

    @State private var user: AdminUser
    let onUpdated: (AdminUser) -> Void

    @State private var preferences: AdminUserPreferences?
    @State private var statistics: AssetStatistics?
    @State private var sessions: [UserSession]?
    @State private var heatmap: CalendarHeatmap?
    @State private var heatmapFailed = false
    @State private var action: AdminUserAction?
    @State private var showsEdit = false
    @State private var feedback = TransientFeedback()

    init(user: AdminUser, onUpdated: @escaping (AdminUser) -> Void) {
        _user = State(initialValue: user)
        self.onUpdated = onUpdated
    }

    var body: some View {
        List {
            if user.isDeleted {
                Section {
                    Label("This user has been deleted.", systemImage: "trash")
                        .foregroundStyle(.red)
                }
            }
            headerSection
            statisticsSection
            profileSection
            featuresSection
            quotaSection
            devicesSection
            uploadsSection
        }
        .navigationTitle(user.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    AdminUserMenuItems(
                        user: user,
                        onEdit: { showsEdit = true },
                        action: $action
                    )
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityIdentifier("admin-user-menu")
                // ios 26 morphs a dialog out of the control that raised it,
                // and a menu item cannot host one, so they sit on the menu.
                .adminUserActions(
                    for: user,
                    action: $action,
                    onUpdated: apply,
                    onFeedback: feedback.show
                )
            }
        }
        .sheet(isPresented: $showsEdit) {
            AdminUserFormSheet(mode: .edit(user)) { apply($0) }
        }
        .feedbackPill(feedback)
        .task(id: user.id) { await load() }
    }

    // MARK: - sections

    private var headerSection: some View {
        Section {
            HStack(spacing: 16) {
                UserAvatar(user: user.asUser, size: 64)
                VStack(alignment: .leading, spacing: 6) {
                    Text(user.name)
                        .font(.title2.weight(.bold))
                    if user.isAdmin {
                        AdminBadge("Admin User", color: .indigo)
                    }
                }
                Spacer()
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
        }
    }

    private var statisticsSection: some View {
        Section {
            HStack(spacing: 12) {
                StatisticCard(
                    title: "Photos",
                    icon: "camera.aperture",
                    value: statistics.map { $0.images.formatted() }
                )
                StatisticCard(
                    title: "Videos",
                    icon: "play.circle",
                    value: statistics.map { $0.videos.formatted() }
                )
                StatisticCard(
                    title: "Storage",
                    icon: "chart.pie",
                    value: storageComponents?.value,
                    unit: storageComponents?.unit
                )
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    private var profileSection: some View {
        Section {
            LabeledContent("Name", value: user.name)
            LabeledContent("Email", value: user.email)
            LabeledContent("Created", value: dateText(user.createdDate))
            LabeledContent("Updated", value: dateText(user.updatedDate))
            LabeledContent("ID") {
                Text(user.id)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            Label("Profile", systemImage: "person")
        }
    }

    private var featuresSection: some View {
        Section {
            if let preferences {
                ForEach(preferences.features, id: \.title) { feature in
                    LabeledContent(feature.title) {
                        Image(systemName: feature.enabled ? "checkmark" : "xmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(feature.enabled ? Color.accentColor : .red)
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        } header: {
            Label("Features", systemImage: "slider.horizontal.3")
        }
    }

    private var quotaSection: some View {
        Section {
            if let quota = user.quotaSizeInBytes, quota >= 0 {
                let used = user.quotaUsageInBytes ?? 0
                let fraction = quota > 0 ? Double(used) / Double(quota) : 0
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: min(1, fraction))
                        .tint(quotaTint(fraction))
                    Text("\(BinaryByteFormat.string(used, maxFractionDigits: 2)) of \(BinaryByteFormat.string(quota, maxFractionDigits: 2)) used")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                Label("Unlimited", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }
        } header: {
            Label("Storage Quota", systemImage: "chart.pie")
        }
    }

    private var devicesSection: some View {
        Section {
            if let sessions {
                if sessions.isEmpty {
                    Text("No devices")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sessions) { device in
                        DeviceRow(device: device)
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        } header: {
            Label("Authorized Devices", systemImage: "laptopcomputer.and.iphone")
        }
    }

    private var uploadsSection: some View {
        Section {
            if let heatmap {
                UploadHeatmapView(data: heatmap)
                    .padding(.vertical, 4)
            } else if heatmapFailed {
                Text("Upload activity is not available on this server.")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        } header: {
            Label("Uploads", systemImage: "icloud.and.arrow.up")
        }
    }

    // MARK: - helpers

    /// the web switches to two decimals past a tebibyte.
    private var storageComponents: (value: String, unit: String)? {
        let used = user.quotaUsageInBytes ?? 0
        let tebibyte: Int64 = 1 << 40
        return BinaryByteFormat.components(used, maxFractionDigits: used > tebibyte ? 2 : 0)
    }

    private func quotaTint(_ fraction: Double) -> Color {
        if fraction >= 0.95 { return .red }
        if fraction >= 0.8 { return .orange }
        return .accentColor
    }

    private func dateText(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown"
    }

    private func apply(_ updated: AdminUser) {
        user = updated
        onUpdated(updated)
    }

    private func load() async {
        guard let client = session.client else { return }
        let id = user.id
        let range = HeatmapRange.current()
        async let freshUser = try? client.adminUsers(id: id).first
        async let preferencesTask = try? client.adminUserPreferences(id: id)
        async let statisticsTask = try? client.adminUserStatistics(id: id)
        async let sessionsTask = try? client.adminUserSessions(id: id)
        async let heatmapTask = try? client.adminUserUploadHeatmap(id: id, from: range.from, to: range.to)
        if let fresh = await freshUser, fresh != user {
            apply(fresh)
        }
        preferences = await preferencesTask
        statistics = await statisticsTask
        sessions = await sessionsTask ?? []
        heatmap = await heatmapTask
        heatmapFailed = heatmap == nil
    }
}

// MARK: - pieces

/// one of the three headline counters.
private struct StatisticCard: View {
    let title: String
    let icon: String
    let value: String?
    var unit: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.tint)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value ?? "0000")
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .redacted(reason: value == nil ? .placeholder : [])
                if let unit {
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

/// the web's device card: platform icon, device line, last seen.
private struct DeviceRow: View {
    let device: UserSession

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.title)
                    .font(.subheadline)
                if let seen = device.lastSeen {
                    HStack(spacing: 4) {
                        Text("Last seen \(relativeDay(seen))")
                            .font(.caption)
                        Text("· \(seen.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if device.current {
                Spacer()
                AdminBadge("Current", color: .green)
            }
        }
        .padding(.vertical, 2)
    }

    private func relativeDay(_ date: Date) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: Date())
        ).day ?? 0
        switch days {
        case ...0: return "today"
        case 1: return "yesterday"
        default: return "\(days) days ago"
        }
    }
}

/// a year of daily upload counts as a week-column grid, the web's calendar
/// heatmap with its four intensity steps and legend.
struct UploadHeatmapView: View {
    let data: CalendarHeatmap

    private let cell: CGFloat = 11
    private let gap: CGFloat = 2

    private var maxCount: Int { data.series.map(\.count).max() ?? 0 }

    /// rows before the first day so the columns line up on the locale week.
    private var leadingPadding: Int {
        guard let from = HeatmapRange.parse(data.from) else { return 0 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let weekday = calendar.component(.weekday, from: from)
        return (weekday - Calendar.current.firstWeekday + 7) % 7
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                weekdayLabels
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: Array(repeating: GridItem(.fixed(cell), spacing: gap), count: 7), spacing: gap) {
                        ForEach(0..<leadingPadding, id: \.self) { _ in
                            Color.clear
                                .frame(width: cell, height: cell)
                        }
                        ForEach(data.series) { day in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(color(for: day.count))
                                .frame(width: cell, height: cell)
                                .accessibilityLabel("\(day.count) uploads on \(day.date)")
                        }
                    }
                }
                .defaultScrollAnchor(.trailing)
            }
            HStack(spacing: 4) {
                Text("Less")
                ForEach(0..<5, id: \.self) { step in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(legendColor(step))
                        .frame(width: cell, height: cell)
                }
                Text("More")
                Spacer()
                Text("\(data.totalCount.formatted()) upload\(data.totalCount == 1 ? "" : "s")")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// monday, wednesday and friday, plus sunday when the week starts on
    /// monday, like the web.
    private var weekdayLabels: some View {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        let first = Calendar.current.firstWeekday - 1
        return VStack(spacing: gap) {
            ForEach(0..<7, id: \.self) { row in
                let weekday = (first + row) % 7
                let labelled = weekday == 1 || weekday == 3 || weekday == 5 || (weekday == 0 && row == 6)
                Text(labelled ? symbols[weekday] : "")
                    .font(.system(size: 8).monospaced())
                    .foregroundStyle(.secondary)
                    .frame(width: 10, height: cell)
            }
        }
    }

    private func color(for count: Int) -> Color {
        guard count > 0, maxCount > 0 else { return Color(.systemFill) }
        let quarter = Int((Double(maxCount) * 0.25).rounded(.up))
        let half = Int((Double(maxCount) * 0.5).rounded(.up))
        let threeQuarters = Int((Double(maxCount) * 0.75).rounded(.up))
        if count <= quarter { return Color.accentColor.opacity(0.3) }
        if count <= half { return Color.accentColor.opacity(0.5) }
        if count <= threeQuarters { return Color.accentColor.opacity(0.7) }
        return Color.accentColor
    }

    private func legendColor(_ step: Int) -> Color {
        switch step {
        case 0: Color(.systemFill)
        case 1: Color.accentColor.opacity(0.3)
        case 2: Color.accentColor.opacity(0.5)
        case 3: Color.accentColor.opacity(0.7)
        default: Color.accentColor
        }
    }
}
