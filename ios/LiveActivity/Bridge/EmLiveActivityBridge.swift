import ActivityKit
import Foundation
import UIKit

// Loaded dynamically only on iOS 16.1+. The iOS 12 host never loads Swift,
// ActivityKit or Swift concurrency through this optional framework.
@available(iOS 16.1, *)
@MainActor
@objc(EmLiveActivityBridge)
public final class EmLiveActivityBridge: NSObject {
    private typealias Session = Activity<GaEmulatorActivityAttributes>
    private typealias State = GaEmulatorActivityAttributes.ContentState
    private var activity: Session?
    private var desired: State?
    private var ending: [Session] = []
    private var worker: Task<Void, Never>?
    private var revision = 0
    private var requestFailed = false
    @objc public private(set) var userDismissed = false

    public override init() {
        super.init()
        // Games do not survive process death. Retire orphan cards, rather than
        // showing the previous process's metrics as a current running session.
        ending = Session.activities
        scheduleWork()
    }

    @objc public func prepareForForeground() { requestFailed = false }

    @objc(renderStatus:memoryBytes:cpuPercent:tabCount:)
    public func render(status: Int, memoryBytes: UInt64, cpuPercent: Double, tabCount: Int) -> Bool {
        revision += 1
        guard status != 0, tabCount > 0 else {
            desired = nil
            requestFailed = false
            userDismissed = false
            retireCurrent()
            scheduleWork()
            return false
        }
        desired = State(status: status, memoryMB: memoryBytes > 0 ? Double(memoryBytes) / 1_048_576 : nil,
                        cpuPercent: cpuPercent.isFinite && cpuPercent >= 0 ? cpuPercent : nil,
                        tabs: tabCount, updatedAt: Date())
        if let current = activity, current.activityState == .dismissed || current.activityState == .ended {
            userDismissed = true
            retireCurrent()
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            retireCurrent()
            scheduleWork()
            return false
        }
        // Respect dismissal/expiry for this session. A 15-second timer must not
        // repeatedly recreate a card that the user or the system ended.
        if activity == nil, !requestFailed, !userDismissed,
           UIApplication.shared.applicationState == .active, let state = desired {
            do {
                let attributes = GaEmulatorActivityAttributes(appName: "GaEmulator")
                if #available(iOS 16.2, *) {
                    activity = try Session.request(attributes: attributes,
                        content: ActivityContent(state: state, staleDate: state.updatedAt.addingTimeInterval(60)), pushType: nil)
                } else {
                    activity = try Session.request(attributes: attributes, contentState: state, pushType: nil)
                }
                NSLog("[LIVE_ACTIVITY] started %@", activity?.id ?? "")
            } catch {
                requestFailed = true
                NSLog("[LIVE_ACTIVITY] start failed: %@", String(describing: error))
            }
        }
        scheduleWork()
        return activity != nil
    }

    private func retireCurrent() {
        if let current = activity { ending.append(current); activity = nil }
    }

    private func scheduleWork() {
        guard worker == nil else { return }
        worker = Task { await drain() }
    }

    private func drain() async {
        while true {
            if !ending.isEmpty {
                let old = ending.removeFirst()
                if #available(iOS 16.2, *) { await old.end(nil, dismissalPolicy: .immediate) }
                else { await old.end(using: nil, dismissalPolicy: .immediate) }
                NSLog("[LIVE_ACTIVITY] ended %@", old.id)
                continue
            }
            guard let current = activity, let state = desired else { break }
            let appliedRevision = revision
            if #available(iOS 16.2, *) {
                await current.update(ActivityContent(state: state, staleDate: state.updatedAt.addingTimeInterval(60)))
            } else { await current.update(using: state) }
            NSLog("[LIVE_ACTIVITY] submitted %@ tabs=%ld state=%ld", current.id, state.tabs, state.status)
            // Stop or a newer sample may arrive while update/end is suspended.
            // Serialize those operations and always drain endings before updates.
            if revision == appliedRevision { break }
        }
        worker = nil
    }
}
