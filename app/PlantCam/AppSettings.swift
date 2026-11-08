import Foundation
import Security
import SwiftUI

enum PhotoSize: String, CaseIterable, Identifiable {
    case small, medium, large

    var id: String { rawValue }

    var label: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    /// Longest side, in pixels, of the copy sent to Claude.
    var longEdge: CGFloat {
        switch self {
        case .small: return 512
        case .medium: return 1024
        case .large: return 1600
        }
    }
}

enum PlantView: String, CaseIterable, Identifiable {
    case side, overhead, nodes

    var id: String { rawValue }

    var label: String {
        switch self {
        case .side: return "Side"
        case .overhead: return "Overhead"
        case .nodes: return "Nodes"
        }
    }

    var albumName: String {
        switch self {
        case .side: return "Plant Side"
        case .overhead: return "Plant Overhead"
        case .nodes: return "Plant Nodes"
        }
    }
}

final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var relayAddress: String {
        didSet { defaults.set(relayAddress, forKey: "relayAddress") }
    }
    @Published var relayPassword: String {
        didSet { Keychain.set(relayPassword, for: "relayPassword") }
    }
    @Published var sproutDate: Date {
        didSet { defaults.set(sproutDate, forKey: "sproutDate") }
    }
    @Published var photoSize: PhotoSize {
        didSet { defaults.set(photoSize.rawValue, forKey: "photoSize") }
    }
    @Published var keepScreenOn: Bool {
        didSet { defaults.set(keepScreenOn, forKey: "keepScreenOn") }
    }
    /// Keep the connection to Claude alive when Plant Cam isn't on screen.
    @Published var keepInBackground: Bool {
        didSet { defaults.set(keepInBackground, forKey: "keepInBackground") }
    }
    @Published var hasSeenWelcome: Bool {
        didSet { defaults.set(hasSeenWelcome, forKey: "hasSeenWelcome") }
    }
    /// Line timelapse photos up on what holds still, so the view stays steady.
    @Published var stabilize: Bool {
        didSet { defaults.set(stabilize, forKey: "stabilize") }
    }
    /// One photo per day, steady pace. Off shows every photo.
    @Published var smartPacing: Bool {
        didSet { defaults.set(smartPacing, forKey: "smartPacing") }
    }

    init() {
        relayAddress = defaults.string(forKey: "relayAddress") ?? ""
        relayPassword = Keychain.get("relayPassword") ?? ""
        if let saved = defaults.object(forKey: "sproutDate") as? Date {
            sproutDate = saved
        } else {
            var parts = DateComponents()
            parts.year = 2026
            parts.month = 9
            parts.day = 8
            sproutDate = Calendar.current.date(from: parts) ?? Date()
        }
        photoSize = PhotoSize(rawValue: defaults.string(forKey: "photoSize") ?? "") ?? .large
        keepScreenOn = (defaults.object(forKey: "keepScreenOn") as? Bool) ?? true
        keepInBackground = (defaults.object(forKey: "keepInBackground") as? Bool) ?? true
        hasSeenWelcome = defaults.bool(forKey: "hasSeenWelcome")
        stabilize = (defaults.object(forKey: "stabilize") as? Bool) ?? true
        smartPacing = (defaults.object(forKey: "smartPacing") as? Bool) ?? true
    }

    /// The relay's phone address, for example wss://plant-cam-relay.you.workers.dev/phone
    var phoneURL: URL? {
        var address = relayAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.isEmpty { return nil }
        while address.hasSuffix("/") { address.removeLast() }
        if address.hasSuffix("/mcp") { address.removeLast(4) }
        if address.hasPrefix("https://") {
            address = "wss://" + String(address.dropFirst(8))
        } else if address.hasPrefix("http://") {
            address = "ws://" + String(address.dropFirst(7))
        } else if !address.hasPrefix("wss://") && !address.hasPrefix("ws://") {
            address = "wss://" + address
        }
        return URL(string: address + "/phone")
    }
}

enum Keychain {
    static func set(_ value: String, for key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        if value.isEmpty { return }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Dated notes for the timelapse timeline, keyed by YYYY-MM-DD.
final class NotesStore {
    static let shared = NotesStore()
    private let key = "timelineNotes"

    func all() -> [String: String] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
    }

    func add(date: String, text: String) {
        var notes = all()
        notes[date] = text
        UserDefaults.standard.set(notes, forKey: key)
    }
}

enum DayFormat {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func parse(_ text: String) -> Date? { formatter.date(from: text) }
    static func string(_ date: Date) -> String { formatter.string(from: date) }
}
