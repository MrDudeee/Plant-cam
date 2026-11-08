import AVFoundation
import Foundation

/// Keeps Plant Cam running after you switch to another app, by playing silence.
/// iOS lets apps that play audio keep running, and the open connection to the relay depends on that.
/// Nothing audible plays, and other apps' sound isn't interrupted.
@MainActor
final class BackgroundKeeper {
    private(set) var running = false
    var onProblem: ((String) -> Void)?

    private var player: AVAudioPlayer?
    private var interruption: NSObjectProtocol?

    func start() {
        guard !running else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let silent = try AVAudioPlayer(data: Self.silence(), fileTypeHint: AVFileType.wav.rawValue)
            silent.numberOfLoops = -1
            silent.volume = 1
            guard silent.prepareToPlay(), silent.play() else {
                onProblem?("Couldn't start staying connected in the background")
                return
            }
            player = silent
            running = true
        } catch {
            onProblem?("Couldn't stay connected in the background: \(error.localizedDescription)")
            return
        }
        interruption = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in self?.interrupted(raw) }
        }
    }

    func stop() {
        guard running || player != nil else { return }
        player?.stop()
        player = nil
        running = false
        if let observer = interruption {
            NotificationCenter.default.removeObserver(observer)
            interruption = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// After a phone call or alarm ends, start the silence again.
    private func interrupted(_ raw: UInt?) {
        guard running, let raw = raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .ended {
            try? AVAudioSession.sharedInstance().setActive(true)
            player?.play()
        }
    }

    /// One second of silence as a WAV file, built in memory.
    private static func silence() -> Data {
        let sampleRate = 8000
        let dataSize = sampleRate * 2
        var data = Data()
        func put32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func put16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        put32(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        put32(16)
        put16(1)
        put16(1)
        put32(UInt32(sampleRate))
        put32(UInt32(sampleRate * 2))
        put16(2)
        put16(16)
        data.append(contentsOf: Array("data".utf8))
        put32(UInt32(dataSize))
        data.append(Data(count: dataSize))
        return data
    }
}
