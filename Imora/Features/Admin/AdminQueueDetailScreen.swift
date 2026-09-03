import Charts
import SwiftUI

/// the web's queue details page: counters, the jobs-over-time graph fed by
/// the monitor's polling, and the pause, clear and failed-jobs actions.
struct AdminQueueDetailScreen: View {
    let name: String
    let monitor: QueueMonitor

    @State private var feedback = TransientFeedback()

    private var queue: Queue? { monitor.queue(named: name) }
    private var kind: QueueKind? { QueueKind(rawValue: name) }
    private var title: String { kind?.title ?? name }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Label(title, systemImage: kind?.icon ?? "gearshape")
                            .font(.title3.weight(.bold))
                        if queue?.isPaused == true {
                            AdminBadge("Paused", color: .orange)
                        }
                    }
                    if let subtitle = kind?.subtitle {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let statistics = queue?.statistics {
                        HStack(spacing: 6) {
                            AdminBadge("Active \(statistics.active.formatted())", color: .secondary)
                            AdminBadge("Waiting \((statistics.waiting + statistics.paused).formatted())", color: .secondary)
                            if statistics.failed > 0 {
                                AdminBadge("Failed \(statistics.failed.formatted())", color: .red)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                QueueGraph(name: name, snapshots: monitor.snapshots)
                    .frame(height: 240)
                    .padding(.vertical, 8)
            } header: {
                Label("Jobs Over Time", systemImage: "clock")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if let queue {
                        if queue.isPaused {
                            Button("Resume", systemImage: "play") {
                                run(.resume, on: queue)
                            }
                        } else {
                            Button("Pause", systemImage: "pause") {
                                run(.pause, on: queue)
                            }
                        }
                        Button("Clear", systemImage: "xmark") {
                            run(.empty, on: queue)
                        }
                        Divider()
                        Button("Remove Failed Jobs", systemImage: "trash", role: .destructive) {
                            run(.clearFailed, on: queue)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityIdentifier("admin-queue-menu")
            }
        }
        .feedbackPill(feedback)
        .task { await monitor.poll() }
    }

    private func run(_ command: QueueCommand, on queue: Queue) {
        Task {
            do {
                try await monitor.run(command, on: queue, force: false)
                switch command {
                case .empty: feedback.show("Cleared jobs for \(title)")
                case .clearFailed: feedback.show("Removed failed jobs")
                default: break
                }
            } catch {
                ErrorToastCenter.shared.show("Command \(command.rawValue) failed for \(title)", error: error)
            }
        }
    }
}

/// failed, active and waiting counts of one queue across the monitor's
/// snapshots. a failed poll breaks the lines instead of drawing zero.
private struct QueueGraph: View {
    let name: String
    let snapshots: [QueueMonitor.Snapshot]

    private struct Point: Identifiable {
        let id: String
        let time: Date
        let series: String
        let value: Int
        let segment: Int
    }

    private var points: [Point] {
        var result: [Point] = []
        var segment = 0
        for snapshot in snapshots {
            guard let statistics = snapshot.queues?.first(where: { $0.name == name })?.statistics else {
                segment += 1
                continue
            }
            let time = snapshot.timestamp
            let base = snapshot.id.uuidString
            result.append(Point(id: base + "f", time: time, series: "Failed", value: statistics.failed, segment: segment))
            result.append(Point(id: base + "a", time: time, series: "Active", value: statistics.active, segment: segment))
            result.append(Point(
                id: base + "w",
                time: time,
                series: "Waiting",
                value: statistics.waiting + statistics.paused,
                segment: segment
            ))
        }
        return result
    }

    var body: some View {
        let points = points
        if points.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart(points) { point in
                LineMark(
                    x: .value("Time", point.time),
                    y: .value("Jobs", point.value),
                    series: .value("Segment", "\(point.series)-\(point.segment)")
                )
                .foregroundStyle(by: .value("Series", point.series))
                .lineStyle(StrokeStyle(lineWidth: 2))
            }
            .chartForegroundStyleScale([
                "Failed": Color.red,
                "Active": Color.indigo,
                "Waiting": Color.blue,
            ])
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour().minute().second())
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
            .chartLegend(position: .bottom, alignment: .leading)
        }
    }
}
