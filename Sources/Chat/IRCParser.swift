import Foundation

struct IRCParser {

    // MARK: – Parse a raw IRC line
    static func parse(_ raw: String) -> IRCMessage? {
        var rest = raw
        var tags: [String: String] = [:]
        var prefix: String? = nil

        // 1 – Tags  @key=value;key2=value2 ...
        if rest.hasPrefix("@") {
            guard let spaceIdx = rest.firstIndex(of: " ") else { return nil }
            let tagStr = String(rest[rest.index(after: rest.startIndex)..<spaceIdx])
            rest = String(rest[rest.index(after: spaceIdx)...]).trimmingCharacters(in: .whitespaces)
            for pair in tagStr.components(separatedBy: ";") {
                let kv = pair.components(separatedBy: "=")
                tags[kv[0]] = kv.count > 1 ? kv[1...].joined(separator: "=") : ""
            }
        }

        // 2 – Prefix  :nick!user@host ...
        if rest.hasPrefix(":") {
            let parts = rest.dropFirst().components(separatedBy: " ")
            prefix = String(parts[0])
            rest = parts.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
        }

        // 3 – Command + params
        var components = rest.components(separatedBy: " ")
        guard !components.isEmpty else { return nil }
        let command = components.removeFirst()

        var params: [String] = []
        var i = 0
        while i < components.count {
            if components[i].hasPrefix(":") {
                // Trailing param — rest of the line
                let trailing = components[i...].joined(separator: " ")
                params.append(String(trailing.dropFirst()))
                break
            } else {
                params.append(components[i])
            }
            i += 1
        }

        return IRCMessage(raw: raw, tags: tags, command: command, params: params, prefix: prefix)
    }

    // MARK: – Parse emote positions from tags
    // Format: emoteid:start-end,start-end/emoteid2:start-end
    static func parseEmoteRanges(raw: String, text: String) -> [(String, Range<String.Index>)] {
        guard !raw.isEmpty else { return [] }
        var result: [(String, Range<String.Index>)] = []
        // Twitch compte en points de code (unicodeScalars), pas en UTF-16 :
        // après un emoji, les emotes étaient décalées.
        let scalars = text.unicodeScalars
        let count = scalars.count

        for part in raw.components(separatedBy: "/") {
            let kv = part.components(separatedBy: ":")
            guard kv.count == 2 else { continue }
            let emoteId = kv[0]
            for rangeStr in kv[1].components(separatedBy: ",") {
                let bounds = rangeStr.components(separatedBy: "-").compactMap { Int($0) }
                // début ≤ fin vérifié : sinon `s..<e` faisait planter l'app.
                guard bounds.count == 2, bounds[0] >= 0, bounds[0] <= bounds[1], bounds[1] < count else { continue }
                let startIdx = scalars.index(scalars.startIndex, offsetBy: bounds[0])
                let endIdx   = scalars.index(startIdx, offsetBy: bounds[1] - bounds[0] + 1)
                if let s = startIdx.samePosition(in: text),
                   let e = endIdx.samePosition(in: text), s < e {
                    result.append((emoteId, s..<e))
                }
            }
        }
        return result.sorted { $0.1.lowerBound < $1.1.lowerBound }
    }

    /// Tag `gifs` (clavier GIF de Twitch) : « début-fin|id|adresse » séparés
    /// par des virgules, positions en points de code comme les emotes.
    /// L'adresse est gardée telle quelle (règle de Twitch), GIPHY seulement.
    static func parseGifRanges(raw: String, text: String) -> [(url: String, range: Range<String.Index>)] {
        let value = ircUnescape(raw)
        guard !value.isEmpty,
              let re = try? NSRegularExpression(pattern: #"(\d+)-(\d+)\|[^|]*\|(https://[^,]+?)(?=,\d+-\d+\||$)"#)
        else { return [] }
        let scalars = text.unicodeScalars
        let count = scalars.count
        var out: [(url: String, range: Range<String.Index>)] = []
        for m in re.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
            guard let r1 = Range(m.range(at: 1), in: value), let r2 = Range(m.range(at: 2), in: value),
                  let r3 = Range(m.range(at: 3), in: value),
                  let a = Int(value[r1]), let b = Int(value[r2]), a <= b, b < count else { continue }
            let url = String(value[r3])
            guard let host = URL(string: url)?.host?.lowercased(),
                  host == "giphy.com" || host.hasSuffix(".giphy.com") else { continue }
            let s = scalars.index(scalars.startIndex, offsetBy: a)
            let e = scalars.index(s, offsetBy: b - a + 1)
            if let si = s.samePosition(in: text), let ei = e.samePosition(in: text), si < ei {
                out.append((url: url, range: si..<ei))
            }
        }
        return out
    }
}
