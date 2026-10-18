import CryptoKit
import Foundation

// ═══════════════════════════════════════════════════════════════════════════
//  Chat d'une VOD gardé avec son téléchargement, pour être rejoué hors ligne.
//
//  Les commentaires du passage (GQL `video.comments`, par position : les
//  pages se chevauchent, les doublons sont écartés ; le curseur est refusé
//  par Twitch) sont mis en forme comme dans le chat de VOD — badges, emotes
//  Twitch, 7TV, BTTV, FFZ — puis écrits dans chat.json. Leurs images sont
//  gardées dans le dossier (chat-images/) : sans connexion, tout s'affiche.
// ═══════════════════════════════════════════════════════════════════════════

struct OfflineChat: Codable {
    /// Morceau de message : t (texte), e (emote), m (mention), l (lien).
    struct Token: Codable {
        let k: String
        let v: String
        var u: String? = nil
        var id: String? = nil
        var s: String? = nil
    }
    struct Comment: Codable {
        let id: String
        /// Instant dans la VOD.
        let o: Double
        let uid: String
        let login: String
        let name: String
        let color: String?
        /// `id` : « set/version », `u` : image.
        let badges: [Token]
        let tokens: [Token]
    }
    /// Instant de la VOD où commence la vidéo téléchargée (0 hors ligne).
    var base: Double
    var channelLogin: String
    var comments: [Comment]
    /// Adresse d'origine d'une image → fichier dans chat-images/.
    var images: [String: String]
}

enum VodChatArchive {
    static let fileName = "chat.json"
    static let imagesFolder = "chat-images"

    /// Commentaires de [from, to] (instants de la VOD), écrits dans `folder`.
    /// Nombre de messages gardés ; nil si le chat n'a pas pu venir.
    static func download(vodId: String, from: Double, to: Double, into folder: URL) async -> Int? {
        let owner = await owner(of: vodId)
        // Emotes et badges du canal, comme pour le chat de VOD.
        await EmoteService.shared.loadGlobals()
        if let cid = owner?.id {
            await EmoteService.shared.loadChannel(channelId: cid, channelName: owner?.login ?? "")
            let token = Keychain.loadToken("twitch_token")
            await BadgeService.shared.loadGlobal(token: token)
            await BadgeService.shared.loadChannel(channelId: cid, token: token)
        }

        // Par position, comme le chat de VOD (le curseur est refusé par
        // Twitch) : chaque page repart du dernier instant reçu, les doublons
        // du chevauchement sont écartés, +5 s après une page sans nouveauté.
        var comments: [OfflineChat.Comment] = []
        var seen = Set<String>()
        var position = Int(max(0, from))
        var pages = 0
        var failures = 0
        // Plafond de sécurité (la boucle s'arrête sur la fin voulue) : à 4 000
        // pages, le chat des très longs directs était tronqué en silence.
        while pages < 20_000, Double(position) <= to {
            if Task.isCancelled { return nil }
            guard let page = await VodChatService.commentsPage(videoId: vodId, offset: position) else {
                // Coupure passagère : deux nouveaux essais (2 s, puis 4 s)
                // avant de renoncer au chat.
                failures += 1
                if failures > 2 { return nil }
                try? await Task.sleep(nanoseconds: UInt64(failures) * 2_000_000_000)
                continue
            }
            failures = 0
            pages += 1
            var beyond = false
            var fresh = 0
            var newest = -1.0
            for node in page.nodes {
                let offset = (node["contentOffsetSeconds"] as? Double)
                    ?? Double(node["contentOffsetSeconds"] as? Int ?? 0)
                if offset > to { beyond = true; break }
                guard let id = node["id"] as? String, seen.insert(id).inserted else { continue }
                fresh += 1
                newest = max(newest, offset)
                guard offset >= from,
                      let comment = await comment(node, offset: offset, channelId: owner?.id) else { continue }
                comments.append(comment)
            }
            if beyond || (!page.hasNext && fresh == 0) { break }
            position = fresh > 0 ? max(position + 1, Int(newest)) : position + 5
        }
        comments.sort { $0.o < $1.o }

        let images = await saveImages(of: comments, into: folder.appendingPathComponent(imagesFolder, isDirectory: true))
        let chat = OfflineChat(base: from, channelLogin: owner?.login ?? "", comments: comments, images: images)
        guard let data = try? JSONEncoder().encode(chat),
              (try? data.write(to: folder.appendingPathComponent(fileName), options: .atomic)) != nil else { return nil }
        logger.success("DOWNLOAD", "Chat gardé", "\(comments.count) messages · \(images.count) images")
        return comments.count
    }

    // MARK: Mise en forme (comme VodChatService.build)
    private static func comment(_ node: [String: Any], offset: Double, channelId: String?) async -> OfflineChat.Comment? {
        let commenter = node["commenter"] as? [String: Any]
        let login = commenter?["login"] as? String ?? "inconnu"
        let body = node["message"] as? [String: Any]

        var badges: [OfflineChat.Token] = []
        for b in (body?["userBadges"] as? [[String: Any]] ?? []) {
            guard let set = b["setID"] as? String, !set.isEmpty, let ver = b["version"] as? String else { continue }
            let key = "\(set)/\(ver)"
            let url = await BadgeService.shared.resolve(badgeId: key, channelId: channelId)
            if !url.isEmpty { badges.append(.init(k: "b", v: key, u: url)) }
        }

        var tokens: [OfflineChat.Token] = []
        for f in (body?["fragments"] as? [[String: Any]] ?? []) {
            let text = f["text"] as? String ?? ""
            if let emote = f["emote"] as? [String: Any],
               let eid = (emote["emoteID"] ?? emote["id"]) as? String, !eid.isEmpty {
                tokens.append(.init(k: "e", v: text,
                                    u: "https://static-cdn.jtvnw.net/emoticons/v2/\(eid)/default/dark/2.0",
                                    id: eid, s: EmoteSource.twitch.rawValue))
            } else if !text.isEmpty {
                for token in await tokenizeChatSegment(text, channelId: channelId) {
                    switch token {
                    case .text(let t):    tokens.append(.init(k: "t", v: t))
                    case .mention(let m): tokens.append(.init(k: "m", v: m))
                    case .link(let l):    tokens.append(.init(k: "l", v: l))
                    case .emote(let e):   tokens.append(.init(k: "e", v: e.name, u: e.url, id: e.id, s: e.source.rawValue))
                    case .gif(_, let alt): tokens.append(.init(k: "t", v: alt))
                    }
                }
            }
        }
        guard !tokens.isEmpty else { return nil }
        return OfflineChat.Comment(id: node["id"] as? String ?? UUID().uuidString, o: offset,
                                   uid: commenter?["id"] as? String ?? "", login: login,
                                   name: commenter?["displayName"] as? String ?? login,
                                   color: body?["userColor"] as? String, badges: badges, tokens: tokens)
    }

    // MARK: Images
    /// Badges et emotes, gardés une fois chacun (six à la fois).
    private static func saveImages(of comments: [OfflineChat.Comment], into dir: URL) async -> [String: String] {
        var urls = Set<String>()
        for c in comments {
            for b in c.badges { if let u = b.u { urls.insert(u) } }
            for t in c.tokens where t.k == "e" { if let u = t.u { urls.insert(u) } }
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let list = Array(urls)
        var saved: [String: String] = [:]
        await withTaskGroup(of: (String, String?).self) { group in
            var next = 0
            while next < min(6, list.count) {
                let url = list[next]
                next += 1
                group.addTask { (url, await VodChatArchive.save(url, into: dir)) }
            }
            while let result = await group.next() {
                if let file = result.1 { saved[result.0] = file }
                if next < list.count {
                    let url = list[next]
                    next += 1
                    group.addTask { (url, await VodChatArchive.save(url, into: dir)) }
                }
            }
        }
        return saved
    }

    private static func save(_ url: String, into dir: URL) async -> String? {
        let name = SHA256.hash(data: Data(url.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let dest = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) { return name }
        guard let u = URL(string: url),
              let (data, resp) = try? await URLSession.shared.data(from: u),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              (try? data.write(to: dest, options: .atomic)) != nil else { return nil }
        return name
    }

    // MARK: Propriétaire de la VOD
    private static func owner(of vodId: String) async -> (id: String, login: String)? {
        let q = "query { video(id: \"\(gqlStr(vodId))\") { owner { id login } } }"
        guard let json = await VodChatService.rawGQL(q),
              let owner = ((json["data"] as? [String: Any])?["video"] as? [String: Any])?["owner"] as? [String: Any],
              let id = owner["id"] as? String else { return nil }
        return (id, owner["login"] as? String ?? "")
    }
}
