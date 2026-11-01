import Foundation

extension SourceMetadata {
    static func youtubeSearch(html: String) throws -> [YouTubeMatch] {
        let pattern = #"(?:var\s+ytInitialData|window\["ytInitialData"\]|ytInitialData)\s*=\s*"#
        guard let assignment = html.range(of: pattern, options: .regularExpression),
              let json = jsonObject(in: html[assignment.upperBound...]),
              let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let contents = root["contents"] as? [String: Any] else { throw SourceError.searchUnavailable }
        let search = contents["twoColumnSearchResultsRenderer"] as? [String: Any]
        let primary = search?["primaryContents"] as? [String: Any] ?? contents
        guard let sectionList = primary["sectionListRenderer"] as? [String: Any],
              let sections = sectionList["contents"] as? [[String: Any]] else { throw SourceError.searchUnavailable }
        var seen = Set<String>()
        return sections.flatMap { section -> [[String: Any]] in
            let items = section["itemSectionRenderer"] as? [String: Any]
            return items?["contents"] as? [[String: Any]] ?? []
        }.compactMap { item in
            guard let video = item["videoRenderer"] as? [String: Any],
                  let id = video["videoId"] as? String,
                  (try? SourceLink("https://youtu.be/\(id)")) == .youtube(id),
                  !seen.contains(id),
                  let duration = duration(text(video["lengthText"])), duration > 0 else { return nil }
            let title = text(video["title"])
            guard !title.isEmpty else { return nil }
            let author = text(video["ownerText"] ?? video["longBylineText"] ?? video["shortBylineText"])
            let badges = video["ownerBadges"] as? [[String: Any]] ?? []
            let verified = badges.contains { badge in
                let badge = badge["metadataBadgeRenderer"] as? [String: Any]
                return (badge?["style"] as? String)?.hasPrefix("BADGE_STYLE_TYPE_VERIFIED") == true
            }
            seen.insert(id)
            return YouTubeMatch(id: id, title: title, author: author, duration: duration, verifiedChannel: verified)
        }
    }

    private static func text(_ value: Any?) -> String {
        guard let value = value as? [String: Any] else { return "" }
        if let text = value["simpleText"] as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let runs = value["runs"] as? [[String: Any]] ?? []
        return runs.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func duration(_ text: String) -> Double? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count, numbers.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
        return numbers.reduce(0.0) { $0 * 60 + Double($1) }
    }

    private static func jsonObject(in source: Substring) -> Substring? {
        guard source.first == "{" else { return nil }
        var depth = 0
        var quoted = false
        var escaped = false
        // Search titles can contain braces and escaped quotes; a closing-script regex would truncate them.
        for index in source.indices {
            let character = source[index]
            if quoted {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
            } else if character == "\"" { quoted = true }
            else if character == "{" { depth += 1 }
            else if character == "}" {
                depth -= 1
                if depth == 0 { return source[...index] }
            }
        }
        return nil
    }
}
