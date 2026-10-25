import Foundation

// Claude Code writes a recap ("※ recap: …") when you come back to an idle session, and herdr
// reports it as done. In the transcript it is a `system` / `away_summary` entry; a recap is
// the newest conversation entry, while a finished turn ends in assistant and turn lines.

enum RecapDetector {
    /// Entry types that belong to the conversation; the rest (titles, modes, costs) is bookkeeping.
    private static let conversation: Set<String> = ["user", "assistant", "system"]
    private static let hint = try! NSRegularExpression(pattern: #"\s*\(disable recaps in /config\)\s*$"#)

    /// The recap text when the transcript ends in one, else nil.
    static func summary(inTranscriptTail tail: String) -> String? {
        for line in tail.split(separator: "\n").reversed() {
            guard let data = line.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = object["type"] as? String, conversation.contains(type) else { continue }
            guard type == "system", object["subtype"] as? String == "away_summary" else { return nil }
            return cleaned(object["content"] as? String ?? "")
        }
        return nil
    }

    /// Reads only the end of the transcript; a cut-off first line is skipped as undecodable.
    static func summary(atEndOf url: URL, bytes: UInt64 = 32_768) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size > bytes ? size - bytes : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return summary(inTranscriptTail: String(decoding: data, as: UTF8.self))
    }

    private static func cleaned(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return hint.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
