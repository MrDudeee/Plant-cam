import Foundation

/// What the app knows at the moment a request arrives.
struct ToolContext {
    let sproutDate: Date
    let photoSize: PhotoSize
}

/// Answers one request from Claude, sending results back through `send`.
enum ToolHandler {
    typealias Send = ([String: Any]) async -> Void

    static func handle(id: String, tool: String, args: [String: Any], context: ToolContext, send: @escaping Send) async {
        let photos = PhotoService.shared
        let sprout = Calendar.current.startOfDay(for: context.sproutDate)

        func done(_ content: [[String: Any]]) async {
            await send(["type": "done", "id": id, "content": content])
        }
        func fail(_ message: String) async {
            await send(["type": "error", "id": id, "message": message])
        }

        guard photos.hasAccess else {
            await fail("Photos access is off. Ask the user to allow it in the iPhone Settings app under Plant Cam, then Photos.")
            return
        }

        do {
            switch tool {
            case "list_photos":
                let range = dateRange(args, sprout: sprout)
                let limit = min(500, max(1, intValue(args["limit"]) ?? 100))
                let offset = max(0, intValue(args["offset"]) ?? 0)
                let view = args["view"] as? String
                let listing = photos.listPhotos(since: range.since, until: range.until, view: view, limit: limit, offset: offset)
                await done([textItem(listing)])

            case "view_photos":
                let ids = stringArray(args["ids"])
                if ids.isEmpty {
                    await fail("Pass one or more photo ids from list_photos.")
                    return
                }
                let size = (args["size"] as? String).flatMap { PhotoSize(rawValue: $0) } ?? context.photoSize
                for photoID in ids.prefix(10) {
                    do {
                        let photo = try await photos.jpeg(for: photoID, longEdge: size.longEdge, notBefore: sprout)
                        let image: [String: Any] = [
                            "type": "image",
                            "data": photo.data.base64EncodedString(),
                            "mimeType": "image/jpeg",
                        ]
                        let content: [[String: Any]] = [textItem("\(photoID) (taken \(photo.taken))"), image]
                        await send(["type": "part", "id": id, "content": content])
                    } catch {
                        let content: [[String: Any]] = [textItem("\(photoID): \(error.localizedDescription)")]
                        await send(["type": "part", "id": id, "content": content])
                    }
                }
                if ids.count > 10 {
                    await done([textItem("Showed the first 10. Ask again for the rest.")])
                } else {
                    await done([])
                }

            case "list_videos":
                let range = dateRange(args, sprout: sprout)
                let limit = min(500, max(1, intValue(args["limit"]) ?? 100))
                let offset = max(0, intValue(args["offset"]) ?? 0)
                let listing = photos.listVideos(since: range.since, until: range.until, limit: limit, offset: offset)
                await done([textItem(listing)])

            case "view_video":
                guard let videoID = args["id"] as? String, !videoID.isEmpty else {
                    await fail("Pass a video id from list_videos.")
                    return
                }
                let count = min(12, max(1, intValue(args["frames"]) ?? 8))
                let size = (args["size"] as? String).flatMap { PhotoSize(rawValue: $0) } ?? .medium
                let summary = try await photos.videoFrames(
                    id: videoID,
                    count: count,
                    start: doubleValue(args["start"]),
                    end: doubleValue(args["end"]),
                    longEdge: size.longEdge,
                    notBefore: sprout
                ) { frame in
                    let image: [String: Any] = [
                        "type": "image",
                        "data": frame.data.base64EncodedString(),
                        "mimeType": "image/jpeg",
                    ]
                    let content: [[String: Any]] = [textItem(frame.label), image]
                    await send(["type": "part", "id": id, "content": content])
                }
                await done([textItem(summary)])

            case "file_photos":
                let ids = stringArray(args["ids"])
                guard let name = args["view"] as? String, let view = PlantView(rawValue: name) else {
                    await fail("view must be side, overhead, or nodes.")
                    return
                }
                let remove = (args["remove"] as? Bool) ?? false
                let count = try photos.file(ids: ids, view: view, remove: remove)
                let summary = remove
                    ? "Removed \(count) photo(s) from \(view.label) (album \(view.albumName))."
                    : "Filed \(count) photo(s) under \(view.label) (album \(view.albumName))."
                await done([textItem(summary)])

            case "list_notes":
                let notes = NotesStore.shared.all().sorted { $0.key < $1.key }
                let listing = notes.isEmpty ? "No notes yet." : notes.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
                await done([textItem(listing)])

            case "add_note":
                guard let date = args["date"] as? String, DayFormat.parse(date) != nil else {
                    await fail("date must be YYYY-MM-DD.")
                    return
                }
                let text = ((args["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    await fail("text can't be empty.")
                    return
                }
                NotesStore.shared.add(date: date, text: String(text.prefix(80)))
                await done([textItem("Added a note on \(date).")])

            default:
                await fail("Unknown tool: \(tool)")
            }
        } catch {
            await fail(error.localizedDescription)
        }
    }

    /// The dates Claude asked for, never earlier than the sprout date.
    private static func dateRange(_ args: [String: Any], sprout: Date) -> (since: Date, until: Date?) {
        var since = sprout
        if let text = args["since"] as? String, let day = DayFormat.parse(text), day > sprout {
            since = day
        }
        var until: Date? = nil
        if let text = args["until"] as? String, let day = DayFormat.parse(text) {
            until = Calendar.current.date(byAdding: .day, value: 1, to: day)
        }
        return (since, until)
    }

    static func textItem(_ text: String) -> [String: Any] {
        ["type": "text", "text": text]
    }

    static func stringArray(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { $0 as? String } ?? []
    }

    static func intValue(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? Double { return Int(number) }
        if let text = value as? String { return Int(text) }
        return nil
    }

    static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let text = value as? String { return Double(text) }
        return nil
    }
}
