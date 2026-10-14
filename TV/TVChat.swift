import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Chat sur l'Apple TV, en lecture seule et sans compte, posé sur le côté
//  droit de l'image (calque du lecteur natif, sous ses commandes) ; le bouton
//  « Chat » de la barre de lecture l'affiche ou le masque.
//
//  Direct : l'IRC de Twitch par WebSocket, avec un pseudo anonyme
//  (« justinfanNNNNN »), comme le site. VOD : les commentaires de la VOD
//  (requête GQL publique), rejoués au rythme de la lecture. Emotes Twitch
//  (positions données par Twitch) et BTTV, FFZ, 7TV (globales et de la
//  chaîne) en images.
// ═══════════════════════════════════════════════════════════════════════════

struct TVChatLine: Identifiable, Equatable {
    enum Part: Equatable {
        case text(String)
        case emote(url: String, name: String)
    }

    let id: String
    let login: String
    let name: String
    let color: Color
    let parts: [Part]
    /// « /me » : tout le message de la couleur du pseudo.
    let action: Bool
}

@MainActor
final class TVChatModel: ObservableObject {
    @Published private(set) var lines: [TVChatLine] = []
    /// Rien encore à montrer : connexion au direct, premiers commentaires de la VOD.
    @Published private(set) var waiting = true

    private var channel: String?
    private var socket: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    /// Emotes BTTV, FFZ et 7TV : nom → image.
    private var thirdParty: [String: String] = [:]
    private var emotesFor: String?
    /// Assez pour remplir la hauteur de l'écran.
    private static let keep = 40

    // VOD : commentaires chargés d'avance, en attente de leur instant.
    private var vodId: String?
    private var buffer: [(offset: Double, line: TVChatLine)] = []
    /// Identifiants déjà reçus → instant (les pages se chevauchent).
    private var seen: [String: Double] = [:]
    /// Plus grand instant reçu depuis le dernier saut (−1 : rien encore).
    private var fetchedUntil: Double = -1
    private var hasNext = true
    private var fetching = false
    private var lastOffset: Double = -1
    /// Change à chaque saut : une page arrivée trop tard est ignorée.
    private var generation = 0
    /// Après un échec, pas de nouvel essai avant cette date (3 s, puis jusqu'à 30 s).
    private var retryAt = Date.distantPast
    private var failures = 0

    func start(_ login: String) {
        let channel = login.lowercased()
        guard channel != self.channel else { return }
        stop()
        self.channel = channel
        loop = Task { [weak self] in await self?.run(channel) }
    }

    func startVod(_ id: String) {
        guard id != vodId else { return }
        stop()
        vodId = id
        loop = Task { [weak self] in await self?.loadVodOwner(id) }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        channel = nil
        vodId = nil
        lines = []
        buffer = []
        seen = [:]
        fetchedUntil = -1
        hasNext = true
        fetching = false
        lastOffset = -1
        generation += 1
        retryAt = .distantPast
        failures = 0
        waiting = true
    }

    private func add(_ line: TVChatLine) {
        lines.append(line)
        if lines.count > Self.keep { lines.removeFirst(lines.count - Self.keep) }
        waiting = false
    }

    // MARK: Emotes BTTV, FFZ, 7TV
    private func loadEmotes(channelId: String, login: String) async {
        guard emotesFor != channelId else { return }
        emotesFor = channelId
        thirdParty = await TVThirdPartyEmotes.shared.emotes(channelId: channelId, login: login)
    }

    // MARK: Direct
    /// Connexion, lecture, et reconnexion après une coupure (2 s, puis de
    /// plus en plus espacée, 30 s au plus).
    private func run(_ channel: String) async {
        var delay: UInt64 = 2
        while !Task.isCancelled {
            await session(channel)
            guard !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            delay = min(delay * 2, 30)
        }
    }

    private func session(_ channel: String) async {
        guard let url = URL(string: "wss://irc-ws.chat.twitch.tv:443") else { return }
        let ws = URLSession.shared.webSocketTask(with: url)
        socket = ws
        ws.resume()
        let nick = "justinfan\(Int.random(in: 10_000 ... 99_999))"
        for command in ["CAP REQ :twitch.tv/tags twitch.tv/commands", "PASS SCHMOOPIIE",
                        "NICK \(nick)", "JOIN #\(channel)"] {
            try? await ws.send(.string(command))
        }
        while !Task.isCancelled {
            guard let message = try? await ws.receive() else { return }
            let text: String
            switch message {
            case .string(let s): text = s
            case .data(let d): text = String(decoding: d, as: UTF8.self)
            @unknown default: continue
            }
            for raw in text.components(separatedBy: "\r\n") where !raw.isEmpty {
                await handle(raw, ws)
            }
        }
    }

    private func handle(_ raw: String, _ ws: URLSessionWebSocketTask) async {
        if raw.hasPrefix("PING") {
            try? await ws.send(.string("PONG :tmi.twitch.tv"))
            return
        }
        guard let msg = TVIRCLine(raw) else { return }
        switch msg.command {
        case "ROOMSTATE":
            // Identifiant de la chaîne : de quoi charger ses emotes.
            if let id = msg.tags["room-id"], !id.isEmpty, let login = channel {
                Task { await loadEmotes(channelId: id, login: login) }
            }
        case "PRIVMSG":
            append(msg)
        case "CLEARMSG":
            // Message supprimé par la modération.
            if let id = msg.tags["target-msg-id"] { lines.removeAll { $0.id == id } }
        case "CLEARCHAT":
            // Personne bannie ou exclue : ses messages partent ; sans nom, tout le chat.
            if let user = msg.trailing?.lowercased(), !user.isEmpty { lines.removeAll { $0.login == user } }
            else { lines = [] }
        default:
            break
        }
    }

    private func append(_ msg: TVIRCLine) {
        guard var body = msg.trailing else { return }
        var action = false
        if body.hasPrefix("\u{1}ACTION "), body.hasSuffix("\u{1}") {
            body = String(body.dropFirst(8).dropLast())
            action = true
        }
        let login = msg.nick ?? ""
        let shown = msg.tags["display-name"] ?? ""
        add(TVChatLine(id: msg.tags["id"] ?? UUID().uuidString,
                       login: login,
                       name: shown.isEmpty ? login : shown,
                       color: Self.color(msg.tags["color"], login: login),
                       parts: Self.parts(body, emotes: msg.tags["emotes"] ?? "", thirdParty: thirdParty),
                       action: action))
    }

    // MARK: VOD
    /// Propriétaire de la VOD : ses emotes, comme en direct.
    private func loadVodOwner(_ id: String) async {
        let q = "query { video(id: \"\(gqlStr(id))\") { owner { id login } } }"
        guard let owner = ((await Self.gql(["query": q])?["data"] as? [String: Any])?["video"] as? [String: Any])?["owner"] as? [String: Any],
              let ownerId = owner["id"] as? String, let login = owner["login"] as? String,
              vodId == id else { return }
        await loadEmotes(channelId: ownerId, login: login)
    }

    /// Position de lecture d'une VOD (toutes les secondes) : les commentaires
    /// déjà passés s'affichent, la suite se charge d'avance.
    func update(offset: Double) {
        guard vodId != nil, offset.isFinite, offset >= 0 else { return }
        // Début, retour en arrière ou grand saut : on recharge à cet endroit.
        if lastOffset < 0 || offset < lastOffset - 2 || offset > lastOffset + 30 {
            lastOffset = offset
            Task { await seek(to: offset) }
            return
        }
        lastOffset = offset
        release(upTo: offset)
        // Pagination par position (le curseur est refusé par Twitch) : la
        // suite se charge tant qu'on a moins de 30 s d'avance. Rien encore
        // reçu depuis le saut : on repart de la position de lecture.
        if hasNext, !fetching, fetchedUntil < offset + 30, Date() >= retryAt {
            let from = Int(max(0, fetchedUntil < 0 ? offset : fetchedUntil))
            let gen = generation
            fetching = true
            Task { await fetch(offset: from, gen: gen) }
        }
    }

    private func seek(to offset: Double) async {
        generation += 1
        let gen = generation
        lines = []
        buffer = []
        seen = [:]
        fetchedUntil = -1
        hasNext = true
        retryAt = .distantPast
        failures = 0
        waiting = true
        fetching = true
        await fetch(offset: Int(offset), gen: gen)
        guard gen == generation else { return }
        release(upTo: lastOffset)
        waiting = false
    }

    /// Une page à partir de `offset`. Elle chevauche la précédente : on ne
    /// garde que les nouveaux, et une page sans nouveauté avance de 5 s.
    private func fetch(offset: Int, gen: Int) async {
        // Après un saut, c'est la page du saut qui tient le drapeau.
        defer { if gen == generation { fetching = false } }
        guard let id = vodId else { return }
        let page = await Self.commentsPage(videoId: id, offset: offset)
        guard gen == generation, vodId == id else { return }
        guard let page else {
            // Nouvel essai plus tard (3 s, 6 s, 12 s… jusqu'à 30 s) au lieu
            // d'une requête refusée à chaque seconde.
            failures += 1
            retryAt = Date().addingTimeInterval(min(30, 3 * Double(1 << min(failures - 1, 4))))
            return
        }
        failures = 0
        retryAt = .distantPast
        var fresh = 0
        var newest = fetchedUntil
        for node in page.nodes {
            guard let cid = node["id"] as? String, let at = node["contentOffsetSeconds"] as? Double,
                  seen[cid] == nil else { continue }
            seen[cid] = at
            fresh += 1
            newest = max(newest, at)
            if let line = vodLine(node) { buffer.append((at, line)) }
        }
        buffer.sort { $0.offset < $1.offset }
        fetchedUntil = fresh > 0 ? newest : max(fetchedUntil, Double(offset)) + 5
        hasNext = page.hasNext || fresh > 0
        // Longue VOD : les identifiants loin derrière ne servent plus.
        if seen.count > 20_000 { seen = seen.filter { $0.value >= fetchedUntil - 600 } }
    }

    private func release(upTo offset: Double) {
        while let first = buffer.first, first.offset <= offset {
            buffer.removeFirst()
            add(first.line)
        }
    }

    private func vodLine(_ node: [String: Any]) -> TVChatLine? {
        guard let id = node["id"] as? String, let message = node["message"] as? [String: Any],
              let fragments = message["fragments"] as? [[String: Any]] else { return nil }
        let commenter = node["commenter"] as? [String: Any]
        let login = commenter?["login"] as? String ?? ""
        let shown = commenter?["displayName"] as? String ?? ""
        var parts: [TVChatLine.Part] = []
        for f in fragments {
            let text = f["text"] as? String ?? ""
            if let emoteId = (f["emote"] as? [String: Any])?["emoteID"] as? String {
                parts.append(.emote(url: Self.twitchEmoteURL(emoteId), name: text))
            } else if !text.isEmpty {
                parts += Self.parts(text, emotes: "", thirdParty: thirdParty)
            }
        }
        return TVChatLine(id: id, login: login, name: shown.isEmpty ? login : shown,
                          color: Self.color(message["userColor"] as? String, login: login),
                          parts: parts, action: false)
    }

    /// Une page de commentaires à partir d'une position (le curseur est
    /// refusé par Twitch). La requête nommée du site d'abord ; si Twitch ne
    /// la connaît plus (PersistedQueryNotFound), la même en clair.
    private static func commentsPage(videoId: String, offset: Int) async -> (nodes: [[String: Any]], hasNext: Bool)? {
        let vars: [String: Any] = ["videoID": videoId, "contentOffsetSeconds": offset]
        var res = await gql(["operationName": "VideoCommentsByOffsetOrCursor", "variables": vars,
                             "extensions": ["persistedQuery": ["version": 1,
                                                               "sha256Hash": "b70a3591ff0f4e0313d126c6a1502d79a1c02baebb288227c582044aa76adf6a"]]])
        let errors = res?["errors"] as? [[String: Any]] ?? []
        if errors.contains(where: { ($0["message"] as? String)?.contains("PersistedQueryNotFound") == true }) {
            res = await gql(["query": """
                query { video(id: "\(gqlStr(videoId))") { comments(contentOffsetSeconds: \(offset)) { edges { node {
                  id contentOffsetSeconds commenter { login displayName }
                  message { userColor fragments { text emote { emoteID } } } } } pageInfo { hasNextPage } } } }
                """])
        }
        guard let data = res?["data"] as? [String: Any] else { return nil }
        guard let comments = (data["video"] as? [String: Any])?["comments"] as? [String: Any],
              let edges = comments["edges"] as? [[String: Any]] else {
            // Sans erreur mais sans commentaires (VOD supprimée, chat
            // indisponible) : page vide et sans suite, le chat s'arrête comme
            // sur le site. Avec une erreur : nouvel essai plus tard.
            if ((res?["errors"] as? [[String: Any]]) ?? []).isEmpty { return ([], false) }
            return nil
        }
        let hasNext = (comments["pageInfo"] as? [String: Any])?["hasNextPage"] as? Bool ?? false
        return (edges.compactMap { $0["node"] as? [String: Any] }, hasNext)
    }

    private static func gql(_ body: [String: Any]) async -> [String: Any]? {
        guard let url = URL(string: "https://gql.twitch.tv/gql"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue(kGQLClientID, forHTTPHeaderField: "Client-ID")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        guard let (out, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return try? JSONSerialization.jsonObject(with: out) as? [String: Any]
    }

    // MARK: Découpage d'un message
    static func twitchEmoteURL(_ id: String) -> String {
        "https://static-cdn.jtvnw.net/emoticons/v2/\(id)/default/dark/2.0"
    }

    /// Texte, emotes Twitch et emotes BTTV/FFZ/7TV. Les positions du tag
    /// « emotes » (« 25:0-4,12-16/1902:6-10 ») comptent en points de code.
    static func parts(_ body: String, emotes: String, thirdParty: [String: String]) -> [TVChatLine.Part] {
        let scalars = Array(body.unicodeScalars)
        var ranges: [(start: Int, end: Int, id: String)] = []
        for entry in emotes.split(separator: "/") {
            let pieces = entry.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2 else { continue }
            for span in pieces[1].split(separator: ",") {
                let ends = span.split(separator: "-")
                guard ends.count == 2, let a = Int(ends[0]), let b = Int(ends[1]),
                      a <= b, b < scalars.count else { continue }
                ranges.append((a, b, String(pieces[0])))
            }
        }
        ranges.sort { $0.start < $1.start }

        func string(_ from: Int, _ to: Int) -> String {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[from ..< to])
            return String(view)
        }
        var out: [TVChatLine.Part] = []
        /// Texte libre : mot par mot, une emote BTTV/FFZ/7TV devient une image.
        func text(_ s: String) {
            guard !thirdParty.isEmpty else { out.append(.text(s)); return }
            var pending = ""
            for word in s.split(separator: " ", omittingEmptySubsequences: false) {
                if let url = thirdParty[String(word)] {
                    if !pending.isEmpty { out.append(.text(pending)); pending = "" }
                    out.append(.emote(url: url, name: String(word)))
                } else {
                    if !pending.isEmpty { pending += " " }
                    pending += word
                }
            }
            if !pending.isEmpty { out.append(.text(pending)) }
        }
        var i = 0
        for r in ranges where r.start >= i {
            if r.start > i { text(string(i, r.start)) }
            out.append(.emote(url: twitchEmoteURL(r.id), name: string(r.start, r.end + 1)))
            i = r.end + 1
        }
        if i < scalars.count { text(string(i, scalars.count)) }
        return out
    }

    /// Couleurs que Twitch donne à qui n'en a pas choisi.
    private static let palette: [(Double, Double, Double)] = [
        (1, 0, 0), (0, 0, 1), (0, 0.5, 0), (0.7, 0.13, 0.13), (1, 0.5, 0.31), (0.6, 0.8, 0.2), (1, 0.27, 0),
        (0.18, 0.55, 0.34), (0.85, 0.65, 0.13), (0.82, 0.41, 0.12), (0.37, 0.62, 0.63), (0.12, 0.56, 1),
        (1, 0.41, 0.71), (0.54, 0.17, 0.89), (0, 1, 0.5),
    ]

    /// Couleur du pseudo, éclaircie si elle se lit mal sur l'image sombre.
    static func color(_ hex: String?, login: String) -> Color {
        var rgb: (Double, Double, Double)
        if let hex, hex.count == 7, hex.hasPrefix("#"), let v = UInt32(hex.dropFirst(), radix: 16) {
            rgb = (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
        } else {
            let sum = login.unicodeScalars.reduce(0) { $0 + Int($1.value) }
            rgb = palette[sum % palette.count]
        }
        let luminance = 0.299 * rgb.0 + 0.587 * rgb.1 + 0.114 * rgb.2
        if luminance < 0.45 {
            let k = 0.45
            rgb = (rgb.0 + (1 - rgb.0) * k, rgb.1 + (1 - rgb.1) * k, rgb.2 + (1 - rgb.2) * k)
        }
        return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }
}

// MARK: – Emotes BTTV, FFZ et 7TV
/// Globales (une fois) et par chaîne, gardées le temps de l'app ; nom →
/// image, celles de la chaîne passant devant les globales.
actor TVThirdPartyEmotes {
    static let shared = TVThirdPartyEmotes()

    private var global: [String: String]?
    private var channels: [String: [String: String]] = [:]

    func emotes(channelId: String, login: String) async -> [String: String] {
        if global == nil { global = await Self.globals() }
        if channels[channelId] == nil { channels[channelId] = await Self.channel(id: channelId, login: login) }
        return (global ?? [:]).merging(channels[channelId] ?? [:]) { _, channel in channel }
    }

    private static func globals() async -> [String: String] {
        async let bttv = json("https://api.betterttv.net/3/cached/emotes/global")
        async let ffz = json("https://api.frankerfacez.com/v1/set/global")
        async let stv = json("https://7tv.io/v3/emote-sets/global")
        var out: [String: String] = [:]
        (await bttv as? [[String: Any]] ?? []).forEach { add(bttv: $0, to: &out) }
        addFFZ(sets: (await ffz as? [String: Any])?["sets"] as? [String: Any], to: &out)
        ((await stv as? [String: Any])?["emotes"] as? [[String: Any]] ?? []).forEach { add(stv: $0, to: &out) }
        return out
    }

    private static func channel(id: String, login: String) async -> [String: String] {
        async let bttv = json("https://api.betterttv.net/3/cached/users/twitch/\(id)")
        async let ffz = json("https://api.frankerfacez.com/v1/room/\(login)")
        async let stv = json("https://7tv.io/v3/users/twitch/\(id)")
        var out: [String: String] = [:]
        if let b = await bttv as? [String: Any] {
            for key in ["channelEmotes", "sharedEmotes"] { (b[key] as? [[String: Any]] ?? []).forEach { add(bttv: $0, to: &out) } }
        }
        addFFZ(sets: (await ffz as? [String: Any])?["sets"] as? [String: Any], to: &out)
        let set = (await stv as? [String: Any])?["emote_set"] as? [String: Any]
        (set?["emotes"] as? [[String: Any]] ?? []).forEach { add(stv: $0, to: &out) }
        return out
    }

    private static func add(bttv obj: [String: Any], to out: inout [String: String]) {
        guard let id = obj["id"] as? String, let name = obj["code"] as? String else { return }
        out[name] = "https://cdn.betterttv.net/emote/\(id)/2x"
    }

    private static func addFFZ(sets: [String: Any]?, to out: inout [String: String]) {
        for (_, value) in sets ?? [:] {
            for obj in (value as? [String: Any])?["emoticons"] as? [[String: Any]] ?? [] {
                guard let name = obj["name"] as? String, let urls = obj["urls"] as? [String: Any],
                      let url = (urls["2"] ?? urls["1"]) as? String else { continue }
                out[name] = url.hasPrefix("//") ? "https:\(url)" : url
            }
        }
    }

    private static func add(stv obj: [String: Any], to out: inout [String: String]) {
        guard let name = obj["name"] as? String,
              let host = ((obj["data"] as? [String: Any])?["host"] as? [String: Any])?["url"] as? String else { return }
        out[name] = "https:\(host)/2x.webp"
    }

    private static func json(_ address: String) async -> Any? {
        guard let url = URL(string: address),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}

/// Une ligne IRC de Twitch : « @tags :préfixe COMMANDE #salon :texte ».
struct TVIRCLine {
    var tags: [String: String] = [:]
    var nick: String?
    var command = ""
    var trailing: String?

    init?(_ raw: String) {
        var rest = Substring(raw)
        if rest.hasPrefix("@") {
            guard let space = rest.firstIndex(of: " ") else { return nil }
            for pair in rest[rest.index(after: rest.startIndex) ..< space].split(separator: ";") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                tags[String(kv[0])] = kv.count > 1 ? Self.unescape(String(kv[1])) : ""
            }
            rest = rest[rest.index(after: space)...]
        }
        if rest.hasPrefix(":") {
            guard let space = rest.firstIndex(of: " ") else { return nil }
            let prefix = rest[rest.index(after: rest.startIndex) ..< space]
            nick = prefix.split(separator: "!").first.map(String.init)
            rest = rest[rest.index(after: space)...]
        }
        if let colon = rest.range(of: " :") {
            trailing = String(rest[colon.upperBound...])
            rest = rest[..<colon.lowerBound]
        }
        command = String(rest.split(separator: " ").first ?? "")
        if command.isEmpty { return nil }
    }

    /// Valeurs des tags : « \s » espace, « \: » point-virgule, « \\ » barre.
    private static func unescape(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var out = ""
        var escaping = false
        for c in s {
            if escaping {
                switch c {
                case "s": out.append(" ")
                case ":": out.append(";")
                case "r", "n": break
                default: out.append(c)
                }
                escaping = false
            } else if c == "\\" {
                escaping = true
            } else {
                out.append(c)
            }
        }
        return out
    }
}

// MARK: – Affichage
/// Chat sur le côté droit de l'image : les messages les plus récents en
/// bas, les plus anciens s'effacent en haut. Ne prend jamais le focus.
struct TVChatOverlay: View {
    @ObservedObject var model: TVChatModel
    let waitingText: String

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 12) {
                Spacer(minLength: 0)
                if model.lines.isEmpty && model.waiting {
                    Text(waitingText)
                        .font(.system(size: 24))
                        .foregroundColor(.white.opacity(0.6))
                }
                ForEach(model.lines) { line in
                    TVChatRow(line: line)
                }
            }
            .frame(width: 500, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.horizontal, 30)
            .padding(.vertical, 50)
            .background(Color.black.opacity(0.5))
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                         .init(color: .black, location: 0.3),
                                         .init(color: .black, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .clipped()
        }
        .allowsHitTesting(false)
    }
}

struct TVChatRow: View {
    let line: TVChatLine

    private enum Token { case word(String), emote(url: String, name: String) }

    /// Mot par mot, pour que la ligne se coupe entre les mots et les emotes.
    private var tokens: [Token] {
        line.parts.flatMap { part -> [Token] in
            switch part {
            case .text(let s): return s.split(separator: " ").map { .word(String($0)) }
            case .emote(let url, let name): return [.emote(url: url, name: name)]
            }
        }
    }

    var body: some View {
        TVFlowLayout(spacing: 7, lineSpacing: 4) {
            Text(line.action ? line.name : line.name + ":")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(line.color)
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                switch token {
                case .word(let w):
                    Text(w)
                        .font(.system(size: 24))
                        .foregroundColor(line.action ? line.color : .white)
                case .emote(let url, let name):
                    AsyncImage(url: URL(string: url)) { img in
                        img.resizable().scaledToFit()
                    } placeholder: {
                        Text(name).font(.system(size: 24)).foregroundColor(.white.opacity(0.7))
                    }
                    .frame(height: 34)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Éléments posés à la suite et renvoyés à la ligne quand la place manque,
/// centrés verticalement sur leur ligne (texte et emotes mêlés).
struct TVFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 4

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[(index: Int, size: CGSize)]] {
        var rows: [[(index: Int, size: CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append((i, size))
            x += size.width + spacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 500
        var height: CGFloat = 0
        var widest: CGFloat = 0
        let lines = rows(subviews, width: width)
        for (n, row) in lines.enumerated() {
            var rowWidth: CGFloat = 0
            var rowHeight: CGFloat = 0
            for item in row {
                rowWidth += item.size.width
                rowHeight = max(rowHeight, item.size.height)
            }
            rowWidth += spacing * CGFloat(max(0, row.count - 1))
            widest = max(widest, rowWidth)
            height += rowHeight + (n > 0 ? lineSpacing : 0)
        }
        return CGSize(width: min(width, widest), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var height: CGFloat = 0
            for item in row { height = max(height, item.size.height) }
            var x = bounds.minX
            for item in row {
                subviews[item.index].place(at: CGPoint(x: x, y: y + (height - item.size.height) / 2),
                                           proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += height + lineSpacing
        }
    }
}
