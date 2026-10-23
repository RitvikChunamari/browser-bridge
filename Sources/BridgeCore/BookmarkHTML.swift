import Foundation

/// Reads the Netscape bookmark HTML interchange format without executing HTML or loading resources.
public enum BookmarkHTML {
    public static func read(_ data: Data) throws -> Snapshot {
        guard data.count <= 64 * 1024 * 1024, let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            throw BridgeError.message("Bookmark HTML is unreadable or exceeds 64 MB. Export it as UTF-8 and retry.")
        }
        let tokenizer = try NSRegularExpression(pattern: "<[^>]*>|[^<]+", options: [.dotMatchesLineSeparators])
        let href = try NSRegularExpression(pattern: #"\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#, options: [.caseInsensitive])
        var snapshot = Snapshot(), stack: [Int64] = [0], pending: Int64?, title = "", url: String?, reading = ""
        for match in tokenizer.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            let token = String(html[Range(match.range, in: html)!])
            if token.hasPrefix("<") {
                let tag = token.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if tag.hasPrefix("h3>") || tag.hasPrefix("h3 ") { reading = "folder"; title = "" }
                else if tag.hasPrefix("/h3") {
                    let id = Int64(snapshot.bookmarks.count + 1)
                    snapshot.bookmarks.append(.init(id: id, parent: stack.last ?? 0, title: decode(title), url: nil, type: 2))
                    pending = id; reading = ""
                } else if tag.hasPrefix("a ") {
                    reading = "link"; title = ""; url = nil
                    if let found = href.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)) {
                        for index in 1...3 where found.range(at: index).location != NSNotFound { url = decode(String(token[Range(found.range(at: index), in: token)!])); break }
                    }
                } else if tag.hasPrefix("/a>") {
                    if let url { snapshot.bookmarks.append(.init(id: Int64(snapshot.bookmarks.count + 1), parent: stack.last ?? 0, title: decode(title), url: url, type: 1)) }
                    reading = ""; url = nil
                } else if tag.hasPrefix("dl>") || tag.hasPrefix("dl ") { stack.append(pending ?? stack.last ?? 0); pending = nil }
                else if tag.hasPrefix("/dl") { if stack.count > 1 { stack.removeLast() }; pending = nil }
            } else if !reading.isEmpty { title += token }
        }
        guard !snapshot.bookmarks.isEmpty else { throw BridgeError.message("No bookmarks found in this HTML file. Choose a browser-exported bookmarks file.") }
        snapshot.sourceFile = "Bookmarks HTML"
        snapshot.warnings = ["Portable bookmark file only: no original browser profile, passwords, history, tabs or native spaces were included in this input."]
        return snapshot
    }

    private static func decode(_ text: String) -> String {
        var value = text
        let named = ["&lt;":"<", "&gt;":">", "&quot;":"\"", "&apos;":"'", "&#39;":"'", "&nbsp;":" "]
        for (entity, plain) in named { value = value.replacingOccurrences(of: entity, with: plain) }
        if let pattern = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);") {
            for match in pattern.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
                guard let numberRange = Range(match.range(at: 1), in: value), let range = Range(match.range, in: value) else { continue }
                let number = String(value[numberRange]); let code = number.hasPrefix("x") ? UInt32(number.dropFirst(), radix: 16) : UInt32(number)
                if let code, let scalar = UnicodeScalar(code) { value.replaceSubrange(range, with: String(scalar)) }
            }
        }
        return value.replacingOccurrences(of: "&amp;", with: "&")
    }
}
