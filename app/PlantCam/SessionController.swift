import BackgroundTasks
import Foundation
import SwiftUI

/// A timed session. The person starts it, iOS keeps the app connected for the length they pick
/// and shows progress on screen, and it ends when time is up or they stop it.
/// This is the App Store friendly way to stay reachable while someone chats with Claude in another app.
@MainActor
final class SessionController: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case running
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var remaining = 0

    private let relay: RelayClient
    private var endTime: Date?
    private var loopTask: Task<Void, Never>?
    private var stopRequested = false
    private var pendingIdentifier: String?
    private var currentTask: AnyObject?

    init(relay: RelayClient) {
        self.relay = relay
    }

    var isActive: Bool {
        state == .starting || state == .running
    }

    func start(minutes: Int) {
        guard !isActive else { return }
        guard #available(iOS 26.0, *) else {
            state = .failed("Timed sessions need iOS 26 or later.")
            return
        }
        begin(minutes: minutes)
    }

    func stop() {
        guard isActive else { return }
        stopRequested = true
        if state == .starting {
            if let identifier = pendingIdentifier {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            }
            state = .idle
        }
    }

    // MARK: Starting

    @available(iOS 26.0, *)
    private func begin(minutes: Int) {
        let identifier = "com.mrdudeee.plantcam.session." + UUID().uuidString
        pendingIdentifier = identifier
        stopRequested = false
        state = .starting

        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { [weak self] task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                self?.run(task, minutes: minutes)
            }
        }

        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: "Claude session",
            subtitle: "Starting"
        )
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            state = .failed("Couldn't start a session: \(error.localizedDescription)")
        }
    }

    // MARK: Running

    @available(iOS 26.0, *)
    private func run(_ task: BGContinuedProcessingTask, minutes: Int) {
        if stopRequested {
            task.setTaskCompleted(success: true)
            state = .idle
            return
        }
        currentTask = task
        let total = Int64(minutes * 60)
        task.progress.totalUnitCount = total
        task.progress.completedUnitCount = 0
        endTime = Date().addingTimeInterval(TimeInterval(minutes * 60))
        relay.beginSession()
        state = .running

        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                self?.finish(success: false, note: "iOS ended the session early. Start another to keep going.")
            }
        }

        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self, let end = self.endTime else { return }
                let left = max(0, Int(end.timeIntervalSinceNow.rounded(.up)))
                self.remaining = left
                task.progress.completedUnitCount = total - Int64(left)
                task.updateTitle("Claude session", subtitle: self.subtitle(left: left))
                if left == 0 || self.stopRequested { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            self?.finish(success: true, note: nil)
        }
    }

    private func finish(success: Bool, note: String?) {
        guard currentTask != nil else { return }
        loopTask?.cancel()
        loopTask = nil
        relay.endSession()
        remaining = 0
        endTime = nil
        if #available(iOS 26.0, *), let task = currentTask as? BGContinuedProcessingTask {
            task.setTaskCompleted(success: success)
        }
        currentTask = nil
        if let note = note {
            state = .failed(note)
        } else {
            state = .idle
        }
    }

    private func subtitle(left: Int) -> String {
        let time = String(format: "%d:%02d left", left / 60, left % 60)
        if let last = relay.activity.first?.text {
            return time + " \u{00B7} " + last
        }
        return time + " \u{00B7} waiting for Claude"
    }
}
