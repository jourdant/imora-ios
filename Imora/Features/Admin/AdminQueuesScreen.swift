import SwiftUI

/// polls the queue counters every few seconds while a queues screen is on
/// screen and keeps the last thirty readings for the detail graph, the
/// web's queue manager.
@Observable
final class QueueMonitor {
    struct Snapshot: Identifiable {
        let id = UUID()
        let timestamp: Date
        /// nil when that poll failed, which the graph leaves as a gap.
        let queues: [Queue]?
    }

    private(set) var snapshots: [Snapshot] = []
    /// the last successful reading, so a failed poll never blanks the cards.
    private(set) var queues: [Queue] = []
    private(set) var hasLoaded = false
    private(set) var loadError: Error?

    private let client: ImmichClient
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var lastRefresh = Date.distantPast

    init(client: ImmichClient) {
        self.client = client
    }

    /// runs until the task is cancelled. the list and the detail screen each
    /// poll from their own task, so a tick that lands right after another
    /// screen's refresh is skipped.
    func poll() async {
        while !Task.isCancelled {
            await refresh(tick: true)
            try? await Task.sleep(for: .seconds(3))
        }
    }

    func refresh(tick: Bool = false) async {
        if tick, Date().timeIntervalSince(lastRefresh) < 2.5 { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        lastRefresh = Date()
        do {
            let fetched = try await client.queues()
            queues = fetched
            loadError = nil
            snapshots.append(Snapshot(timestamp: Date(), queues: fetched))
        } catch {
            if queues.isEmpty { loadError = error }
            snapshots.append(Snapshot(timestamp: Date(), queues: nil))
        }
        hasLoaded = true
        if snapshots.count > 30 {
            snapshots.removeFirst(snapshots.count - 30)
        }
    }

    func queue(named name: String) -> Queue? {
        queues.first { $0.name == name }
    }

    /// runs one legacy queue command and re-reads the counters.
    func run(_ command: QueueCommand, on queue: Queue, force: Bool?) async throws {
        try await client.runQueueCommand(name: queue.name, command: command, force: force)
        await refresh()
    }
}

/// the web's queues page: one card per known queue with its counters and
/// the start, pause, resume and clear buttons.
struct AdminQueuesScreen: View {
    @Environment(SessionStore.self) private var session

    @State private var monitor: QueueMonitor?
    @State private var showsCreateJob = false
    @State private var isResuming = false
    @State private var feedback = TransientFeedback()

    private var pausedQueues: [Queue] {
        monitor?.queues.filter(\.isPaused) ?? []
    }

    var body: some View {
        Group {
            if let monitor {
                content(monitor)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Job Queues")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !pausedQueues.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await resumePaused() }
                    } label: {
                        Label("Resume Paused (\(pausedQueues.count))", systemImage: "play")
                    }
                    .disabled(isResuming)
                    .accessibilityIdentifier("admin-queues-resume-paused")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Create Job", systemImage: "plus") {
                    showsCreateJob = true
                }
                .accessibilityIdentifier("admin-queues-create-job")
            }
        }
        .sheet(isPresented: $showsCreateJob) {
            CreateJobSheet { feedback.show("Job created") }
        }
        .feedbackPill(feedback)
        .task {
            guard let client = session.client else { return }
            let monitor = self.monitor ?? QueueMonitor(client: client)
            self.monitor = monitor
            await monitor.poll()
        }
    }

    @ViewBuilder private func content(_ monitor: QueueMonitor) -> some View {
        if !monitor.hasLoaded {
            ProgressView()
        } else if let error = monitor.loadError, monitor.queues.isEmpty {
            ContentUnavailableView {
                Label("Couldn’t Load Queues", systemImage: "list.bullet.rectangle")
            } description: {
                Text(error.localizedDescription)
            } actions: {
                Button("Try Again") {
                    Task { await monitor.refresh() }
                }
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(QueueKind.panelOrder, id: \.rawValue) { kind in
                        if let queue = monitor.queue(named: kind.rawValue) {
                            QueueCard(queue: queue, kind: kind, monitor: monitor, onFeedback: feedback.show)
                        }
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
        }
    }

    private func resumePaused() async {
        guard let monitor else { return }
        isResuming = true
        defer { isResuming = false }
        do {
            for queue in pausedQueues {
                try await monitor.run(.resume, on: queue, force: false)
            }
        } catch {
            ErrorToastCenter.shared.show("Couldn’t resume the paused queues", error: error)
        }
    }
}

// MARK: - card

private struct QueueCard: View {
    @Environment(SessionStore.self) private var session

    let queue: Queue
    let kind: QueueKind
    let monitor: QueueMonitor
    let onFeedback: (String) -> Void

    @State private var confirmsForcedStart = false

    private var isDisabled: Bool { kind.isDisabled(features: session.features) }
    private var waiting: Int { queue.statistics.waitingTotal }
    private var hasSeveralButtons: Bool { kind.buttons?.all != nil || kind.buttons?.refresh != nil }

    var body: some View {
        VStack(spacing: 0) {
            if queue.isPaused {
                statusStrip("Paused", color: .orange)
            } else if queue.statistics.active > 0 {
                statusStrip("Active", color: .green)
            }
            VStack(alignment: .leading, spacing: 12) {
                NavigationLink {
                    AdminQueueDetailScreen(name: queue.name, monitor: monitor)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: kind.icon)
                        Text(kind.title)
                            .font(.headline)
                        Spacer(minLength: 8)
                        Image(systemName: "chart.xyaxis.line")
                            .font(.subheadline)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.tint)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("admin-queue-\(queue.name)")

                if queue.statistics.failed > 0 || queue.statistics.delayed > 0 {
                    HStack(spacing: 8) {
                        if queue.statistics.failed > 0 {
                            HStack(spacing: 6) {
                                Text("\(queue.statistics.failed.formatted()) failed")
                                Button {
                                    run(.clearFailed, force: false)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.caption2.weight(.bold))
                                }
                                .accessibilityLabel("Clear failed jobs")
                            }
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Color.red.opacity(0.15), in: Capsule())
                            .foregroundStyle(.red)
                        }
                        if queue.statistics.delayed > 0 {
                            AdminBadge("\(queue.statistics.delayed.formatted()) delayed", color: .secondary)
                        }
                    }
                }

                if let subtitle = kind.subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                counters
            }
            .padding(16)

            Divider()
            buttons
                .frame(height: 64)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private func statusStrip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(color.opacity(0.35))
    }

    private var counters: some View {
        HStack(spacing: 0) {
            HStack {
                Text("Active")
                Spacer()
                Text(queue.statistics.active.formatted())
                    .font(.title2.monospacedDigit())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.accentColor)
            .foregroundStyle(.white)

            HStack {
                Text(waiting.formatted())
                    .font(.title2.monospacedDigit())
                Spacer()
                Text("Waiting")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.tertiarySystemFill))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 0) {
            if isDisabled {
                QueueCardButton("Disabled", icon: "exclamationmark.circle", isEnabled: false) {}
            } else if !queue.isIdle {
                if waiting > 0 {
                    QueueCardButton("Clear", icon: "xmark") {
                        run(.empty, force: false)
                    }
                    Divider()
                }
                if queue.isPaused {
                    QueueCardButton("Resume", icon: "forward.fill") {
                        run(.resume, force: false)
                    }
                } else {
                    QueueCardButton("Pause", icon: "pause.fill") {
                        run(.pause, force: false)
                    }
                }
            } else if let labels = kind.buttons {
                if hasSeveralButtons {
                    if let all = labels.all {
                        QueueCardButton(all, icon: "infinity") {
                            if kind.confirmsForcedStart {
                                confirmsForcedStart = true
                            } else {
                                run(.start, force: true)
                            }
                        }
                        // ios 26 morphs the dialog out of its source control.
                        .confirmationDialog(
                            "Reprocess all faces?",
                            isPresented: $confirmsForcedStart,
                            titleVisibility: .visible
                        ) {
                            Button(all, role: .destructive) {
                                run(.start, force: true)
                            }
                        } message: {
                            Text("This will also clear named people.")
                        }
                        Divider()
                    }
                    if let refresh = labels.refresh {
                        // no force flag at all, which the server reads as a
                        // refresh that keeps the existing face data.
                        QueueCardButton(refresh, icon: "arrow.clockwise") {
                            run(.start, force: nil)
                        }
                        Divider()
                    }
                    QueueCardButton(labels.missing, icon: "doc.text.magnifyingglass") {
                        run(.start, force: false)
                    }
                } else {
                    QueueCardButton(labels.missing, icon: "play.fill") {
                        run(.start, force: false)
                    }
                }
            }
        }
    }

    private func run(_ command: QueueCommand, force: Bool?) {
        Task {
            do {
                try await monitor.run(command, on: queue, force: force)
                if command == .empty {
                    onFeedback("Cleared jobs for \(kind.title)")
                }
            } catch {
                ErrorToastCenter.shared.show("Command \(command.rawValue) failed for \(kind.title)", error: error)
            }
        }
    }
}

/// one of the equal-width actions along the bottom of a card.
private struct QueueCardButton: View {
    let title: String
    let icon: String
    var isEnabled = true
    let action: () -> Void

    init(_ title: String, icon: String, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title3)
                Text(title)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
        .disabled(!isEnabled)
    }
}

// MARK: - create job

/// the web's create job dialog: pick one of the manual jobs and queue it.
private struct CreateJobSheet: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    let onCreated: () -> Void

    @State private var selected: ManualJob?
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(ManualJob.groups, id: \.self) { group in
                    Section(group) {
                        ForEach(ManualJob.allCases.filter { $0.group == group }) { job in
                            Button {
                                selected = job
                            } label: {
                                HStack {
                                    Text(job.title)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if selected == job {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Create Job")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await submit() }
                    }
                    .disabled(selected == nil || isSubmitting)
                    .accessibilityIdentifier("admin-create-job-submit")
                }
            }
            .interactiveDismissDisabled(isSubmitting)
        }
    }

    private func submit() async {
        guard let client = session.client, let selected else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await client.createJob(selected)
            onCreated()
            dismiss()
        } catch {
            ErrorToastCenter.shared.show("Couldn’t submit the job", error: error)
        }
    }
}
