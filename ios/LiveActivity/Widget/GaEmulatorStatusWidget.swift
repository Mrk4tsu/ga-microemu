import ActivityKit
import Foundation
import SwiftUI
import WidgetKit

struct GaEmulatorStatusWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GaEmulatorActivityAttributes.self) { context in
            SessionCard(state: context.state, stale: activityIsStale(context))
                .activityBackgroundTint(Color(red: 0.07, green: 0.10, blue: 0.14))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("GaEmulator", systemImage: "gamecontroller.fill").font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(statusTitle(context.state, stale: activityIsStale(context))).font(.caption)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        SessionMetrics(state: context.state)
                        UpdateTimestamp(date: context.state.updatedAt)
                    }
                }
            } compactLeading: {
                Image(systemName: "gamecontroller.fill").foregroundColor(.green)
            } compactTrailing: {
                Text("\(context.state.tabs)").monospacedDigit().accessibilityLabel("\(context.state.tabs) tab")
            } minimal: {
                Image(systemName: "gamecontroller.fill")
            }
            .keylineTint(.green)
        }
    }
}

private func activityIsStale(_ context: ActivityViewContext<GaEmulatorActivityAttributes>) -> Bool {
    if #available(iOS 16.2, *) { return context.isStale }
    return false
}

private func statusTitle(_ state: GaEmulatorActivityAttributes.ContentState, stale: Bool) -> String {
    if stale { return "Chưa có số liệu mới" }
    return state.status == 1 ? "Đang chạy nền" : "Chạy nền bị gián đoạn"
}

private struct SessionCard: View {
    let state: GaEmulatorActivityAttributes.ContentState
    let stale: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("GaEmulator", systemImage: "gamecontroller.fill").font(.headline)
                Spacer()
                Text(statusTitle(state, stale: stale)).font(.caption).foregroundColor(stale || state.status != 1 ? .orange : .green)
            }
            SessionMetrics(state: state)
            UpdateTimestamp(date: state.updatedAt)
        }.padding(14).foregroundColor(.white)
    }
}

private struct SessionMetrics: View {
    let state: GaEmulatorActivityAttributes.ContentState
    var body: some View {
        HStack {
            metric("RAM", state.memoryMB.map { String(format: "%.0f MB", $0) } ?? "--")
            Spacer()
            metric("CPU", state.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "--")
            Spacer()
            metric("Tab", "\(state.tabs)")
        }
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Text(value).font(.headline).monospacedDigit()
        }.accessibilityElement(children: .combine)
    }
}

private struct UpdateTimestamp: View {
    let date: Date
    var body: some View {
        HStack(spacing: 4) {
            Text("Cập nhật")
            Text(date, format: .dateTime.hour().minute().second())
        }.font(.caption2).foregroundColor(.secondary)
    }
}

@main
struct GaEmulatorStatusBundle: WidgetBundle {
    var body: some Widget { GaEmulatorStatusWidget() }
}
