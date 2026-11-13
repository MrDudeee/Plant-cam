import Foundation
import SwiftUI

struct ActivityItem: Identifiable {
    let id = UUID()
    let time: Date
    let text: String
}

/// Keeps the connection to the relay open, including while you chat with Claude in another app,
/// and hands each request from Claude to ToolHandler.
@MainActor
final class RelayClient: ObservableObject {
    enum Status: Equatable {
        case off
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var activity: [ActivityItem] = []

    private let settings: AppSettings
    private let keeper = BackgroundKeeper()
    private let session = URLSession(configuration: .default)
    private var task: URLSessionWebSocketTask?
    private var pingTask: Task<Void, Never>?
    private var wantConnected = false
    private var resumeOnActive = false
    private var retryCount = 0

    init(settings: AppSettings) {
        self.settings = settings
        keeper.onProblem = { [weak self] message in
            self?.log(message)
        }
    }

    var isOn: Bool {
        status == .connected || status == .connecting
    }

    // MARK: Start and stop

    func start() {
        wantConnected = true
        retryCount = 0
        if settings.keepInBackground { keeper.start() }
        connect()
    }

    func stop() {
        wantConnected = false
        teardown()
        keeper.stop()
        status = .off
    }

    /// Called when Plant Cam leaves the screen. With "stay connected" on, nothing changes.
    func pauseForBackground() {
        guard wantConnected else { return }
        if settings.keepInBackground && keeper.running { return }
        resumeOnActive = true
        stop()
        log("Paused while Plant Cam was in the background")
    }

    func resumeIfNeeded() {
        if resumeOnActive {
            resumeOnActive = false
            start()
        }
    }

    /// Called when the "stay connected" switch is flipped while connected.
    func backgroundSettingChanged() {
        guard wantConnected else { return }
        if settings.keepInBackground {
            keeper.start()
        } else {
            keeper.stop()
        }
    }

    private func giveUp(_ message: String) {
        wantConnected = false
        teardown()
        keeper.stop()
        status = .failed(message)
    }

    private func teardown() {
        pingTask?.cancel()
        pingTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func connect() {
        teardown()
        guard let url = settings.phoneURL else {
            giveUp("Add the relay address in Settings.")
            return
        }
        guard !settings.relayPassword.isEmpty else {
            giveUp("Add the relay password in Settings.")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(settings.relayPassword)", forHTTPHeaderField: "Authorization")
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 16 * 1024 * 1024
        task = socket
        status = .connecting
        socket.resume()
        receive(on: socket)
        sendText("{\"type\":\"ping\"}", on: socket)

        pingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self = self, !Task.isCancelled, let current = self.task else { return }
                self.sendText("{\"type\":\"ping\"}", on: current)
            }
        }
    }

    // MARK: Receiving

    private func receive(on socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            Task { @MainActor in
                guard let self = self, self.task === socket else { return }
                switch result {
                case .failure(let error):
                    self.handleFailure(socket, error)
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handle(text, from: socket)
                    case .data(let data):
                        self.handle(String(decoding: data, as: UTF8.self), from: socket)
                    @unknown default:
                        break
                    }
                    self.receive(on: socket)
                }
            }
        }
    }

    private func handle(_ text: String, from socket: URLSessionWebSocketTask) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return }

        if type == "pong" {
            if status != .connected {
                status = .connected
                retryCount = 0
                log("Connected to Claude's relay")
            }
            return
        }

        guard type == "request",
              let id = object["id"] as? String,
              let tool = object["tool"] as? String else { return }

        status = .connected
        let args = object["args"] as? [String: Any] ?? [:]
        log(describe(tool, args))
        let context = ToolContext(sproutDate: settings.sproutDate, photoSize: settings.photoSize)

        Task.detached {
            await ToolHandler.handle(id: id, tool: tool, args: args, context: context) { message in
                await RelayClient.send(message, on: socket)
            }
        }
    }

    private func handleFailure(_ socket: URLSessionWebSocketTask, _ error: Error) {
        let code = (socket.response as? HTTPURLResponse)?.statusCode
        teardown()
        guard wantConnected else {
            status = .off
            return
        }
        if code == 401 {
            giveUp("The relay password doesn't match. Check it in Settings.")
            log("The relay turned down the password")
            return
        }
        retryCount += 1
        if retryCount > 5 {
            giveUp("Couldn't reach the relay. Check the address in Settings.")
            return
        }
        status = .connecting
        let delay = min(30.0, pow(2.0, Double(retryCount)))
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self = self, self.wantConnected, self.task == nil else { return }
            self.connect()
        }
    }

    // MARK: Sending

    private func sendText(_ text: String, on socket: URLSessionWebSocketTask) {
        socket.send(.string(text)) { _ in }
    }

    nonisolated static func send(_ message: [String: Any], on socket: URLSessionWebSocketTask) async {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }
        try? await socket.send(.string(text))
    }

    // MARK: Activity

    private func log(_ text: String) {
        activity.insert(ActivityItem(time: Date(), text: text), at: 0)
        if activity.count > 20 { activity.removeLast(activity.count - 20) }
    }

    private func describe(_ tool: String, _ args: [String: Any]) -> String {
        let count = ToolHandler.stringArray(args["ids"]).count
        switch tool {
        case "list_photos":
            return "Claude listed your photos"
        case "view_photos":
            let shown = min(count, 10)
            return "Claude viewed \(shown) photo\(shown == 1 ? "" : "s")"
        case "list_videos":
            return "Claude listed your videos"
        case "view_video":
            return "Claude looked at a video"
        case "file_photos":
            let view = PlantView(rawValue: (args["view"] as? String) ?? "")?.label ?? "a view"
            let remove = (args["remove"] as? Bool) ?? false
            return remove ? "Claude took \(count) out of \(view)" : "Claude filed \(count) under \(view)"
        case "list_notes":
            return "Claude read the timeline notes"
        case "add_note":
            return "Claude added a timeline note"
        default:
            return "Claude asked for \(tool)"
        }
    }
}
