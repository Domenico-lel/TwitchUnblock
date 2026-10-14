import Foundation

// MARK: – Emote cache per channel
actor EmoteService {
    static let shared = EmoteService()
    private init() {}

    private var globalBTTV: [String: TwitchEmote] = [:]
    private var globalFFZ:  [String: TwitchEmote] = [:]
    private var global7TV:  [String: TwitchEmote] = [:]

    // Toutes les sources de canal sont maintenant indexées par channelId (cohérent)
    private var channelBTTV: [String: [String: TwitchEmote]] = [:]
    private var channelFFZ:  [String: [String: TwitchEmote]] = [:]   // clé = channelId (fix!)
    private var channel7TV:  [String: [String: TwitchEmote]] = [:]

    private var twitchById:     [String: TwitchEmote] = [:]
    private var loadedChannels: Set<String> = []

    /// Emotes personnelles BTTV Pro, par identifiant Twitch de leur
    /// propriétaire (annoncées par BTTVLive) ; 500 personnes au plus.
    private var personalBTTV: [String: [String: TwitchEmote]] = [:]
    private var personalOrder: [String] = []

    // MARK: – Load globals once
    func loadGlobals() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadBTTVGlobal() }
            group.addTask { await self.loadFFZGlobal() }
            group.addTask { await self.load7TVGlobal() }
        }
        logger.success("EMOTES", "Emotes globales chargées",
                       "BTTV:\(globalBTTV.count) FFZ:\(globalFFZ.count) 7TV:\(global7TV.count)")
    }

    // MARK: – Load per channel
    func loadChannel(channelId: String, channelName: String) async {
        guard !loadedChannels.contains(channelId) else { return }
        loadedChannels.insert(channelId)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadBTTVChannel(channelId: channelId, channelName: channelName) }
            // FFZ reçoit maintenant les deux : channelId pour stocker, channelName pour l'API
            group.addTask { await self.loadFFZChannel(channelId: channelId, channelName: channelName) }
            group.addTask { await self.load7TVChannel(channelId: channelId) }
        }
        let total = (channelBTTV[channelId]?.count ?? 0)
                  + (channelFFZ[channelId]?.count ?? 0)
                  + (channel7TV[channelId]?.count ?? 0)
        logger.success("EMOTES", "Emotes canal \(channelName) chargées",
                       "BTTV:\(channelBTTV[channelId]?.count ?? 0) " +
                       "FFZ:\(channelFFZ[channelId]?.count ?? 0) " +
                       "7TV:\(channel7TV[channelId]?.count ?? 0) — total:\(total)")
    }

    // MARK: – Register Twitch emote from chat tag
    /// Vide les emotes chargées pour forcer un rechargement complet
    /// (action « Recharger emotes et badges » du menu du chat).
    func reset() {
        globalBTTV.removeAll(); globalFFZ.removeAll(); global7TV.removeAll()
        channelBTTV.removeAll(); channelFFZ.removeAll(); channel7TV.removeAll()
        loadedChannels.removeAll()
        // twitchById est alimenté au fil des messages reçus : on le garde,
        // sinon les emotes Twitch des messages déjà affichés disparaîtraient.
    }

    func registerTwitchEmote(id: String, name: String) {
        if twitchById[id] == nil {
            twitchById[id] = TwitchEmote(
                id: id, name: name,
                url: "https://static-cdn.jtvnw.net/emoticons/v2/\(id)/default/dark/2.0",
                source: .twitch
            )
        }
    }

    // MARK: – Resolve emote by name (channel-first, toutes les sources par channelId)
    /// `userId` : auteur du message, pour ses emotes personnelles BTTV Pro
    /// (après celles de la chaîne, avant les globales).
    func resolve(name: String, channelId: String?, userId: String? = nil) -> TwitchEmote? {
        if let cid = channelId {
            if let e = channelBTTV[cid]?[name] { return e }
            if let e = channelFFZ[cid]?[name]  { return e }   // fix : clé = channelId
            if let e = channel7TV[cid]?[name]  { return e }
        }
        if let uid = userId, let e = personalBTTV[uid]?[name] { return e }
        if let e = globalBTTV[name] { return e }
        if let e = globalFFZ[name]  { return e }
        if let e = global7TV[name]  { return e }
        return nil
    }

    func resolveById(_ id: String) -> TwitchEmote? { twitchById[id] }

    // MARK: – Grouped emotes for the picker
    func groupedEmotes(channelId: String?) -> [(label: String, emotes: [TwitchEmote])] {
        var groups: [(label: String, emotes: [TwitchEmote])] = []

        // ── Emotes du canal (toutes sources) ────────────────────────
        if let cid = channelId {
            var canal: [TwitchEmote] = []
            canal += Array((channel7TV[cid]  ?? [:]).values)
            canal += Array((channelBTTV[cid] ?? [:]).values)
            canal += Array((channelFFZ[cid]  ?? [:]).values)   // fix : clé = channelId
            canal.sort { $0.name.lowercased() < $1.name.lowercased() }
            if !canal.isEmpty {
                // Clé de traduction : le sélecteur l'affiche dans la langue de
                // l'app (les autres onglets sont des noms de marque).
                groups.append(("emotes_channel", canal))
            }
        }

        // ── Globaux par source ───────────────────────────────────────
        let g7tv  = Array(global7TV.values).sorted  { $0.name.lowercased() < $1.name.lowercased() }
        let gBttv = Array(globalBTTV.values).sorted { $0.name.lowercased() < $1.name.lowercased() }
        let gFfz  = Array(globalFFZ.values).sorted  { $0.name.lowercased() < $1.name.lowercased() }

        if !g7tv.isEmpty  { groups.append(("7TV",  g7tv))  }
        if !gBttv.isEmpty { groups.append(("BTTV", gBttv)) }
        if !gFfz.isEmpty  { groups.append(("FFZ",  gFfz))  }

        return groups
    }

    // MARK: – Autocomplétion
    /// Emotes dont le nom commence par `prefix`, puis celles qui le contiennent.
    /// Le préfixe l'emporte : en tapant « Kappa » on veut Kappa avant KappaPride.
    func suggest(prefix: String, channelId: String?, limit: Int = 24) -> [TwitchEmote] {
        let kw = prefix.lowercased()
        guard !kw.isEmpty else { return [] }

        var pool: [String: TwitchEmote] = [:]
        if let cid = channelId {
            for dict in [channel7TV[cid], channelBTTV[cid], channelFFZ[cid]] {
                for (k, v) in dict ?? [:] { pool[k] = v }
            }
        }
        for dict in [global7TV, globalBTTV, globalFFZ, twitchById] {
            for (_, v) in dict where pool[v.name] == nil { pool[v.name] = v }
        }

        var starts: [TwitchEmote] = [], contains: [TwitchEmote] = []
        for emote in pool.values {
            let name = emote.name.lowercased()
            if name.hasPrefix(kw) { starts.append(emote) }
            else if name.contains(kw) { contains.append(emote) }
        }
        let byName: (TwitchEmote, TwitchEmote) -> Bool = { $0.name.lowercased() < $1.name.lowercased() }
        return Array((starts.sorted(by: byName) + contains.sorted(by: byName)).prefix(limit))
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: – BTTV
    private func loadBTTVGlobal() async {
        guard let url = URL(string: "https://api.betterttv.net/3/cached/emotes/global"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        for obj in arr { if let e = bttvEmote(obj, scope: .global) { globalBTTV[e.name] = e } }
    }

    private func loadBTTVChannel(channelId: String, channelName: String) async {
        guard let url = URL(string: "https://api.betterttv.net/3/cached/users/twitch/\(channelId)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var map: [String: TwitchEmote] = [:]
        // channelEmotes : mises en ligne par la chaîne ; sharedEmotes : leur
        // créateur est dans `user`.
        for key in ["channelEmotes", "sharedEmotes"] {
            if let arr = json[key] as? [[String: Any]] {
                for obj in arr {
                    if let e = bttvEmote(obj, scope: .channel, author: channelName) { map[e.name] = e }
                }
            }
        }
        channelBTTV[channelId] = map
    }

    // MARK: – BTTV en direct (BTTVLive)
    func setPersonalBTTV(userId: String, emotes: [[String: Any]]) {
        var map: [String: TwitchEmote] = [:]
        for obj in emotes {
            if var e = bttvEmote(obj, scope: .personal) { e.personal = true; map[e.name] = e }
        }
        guard !map.isEmpty else { return }
        if personalBTTV[userId] == nil { personalOrder.append(userId) }
        personalBTTV[userId] = map
        if personalOrder.count > 500 { personalBTTV[personalOrder.removeFirst()] = nil }
    }

    /// Emote ajoutée ou modifiée (renommée) sur la chaîne pendant le live.
    func upsertChannelBTTV(channelId: String, emote obj: [String: Any]) {
        guard let id = obj["id"] as? String else { return }
        var map = channelBTTV[channelId] ?? [:]
        let old = map.first { $0.value.id == id }
        guard let code = (obj["code"] as? String) ?? old?.key, !code.isEmpty else { return }
        if let old { map[old.key] = nil }
        // Renommage : l'événement ne porte que l'id et le nom, l'auteur connu
        // est gardé.
        map[code] = TwitchEmote(id: id, name: code,
                                url: "https://cdn.betterttv.net/emote/\(id)/2x", source: .bttv,
                                scope: .channel,
                                author: ((obj["user"] as? [String: Any])?["displayName"] as? String) ?? old?.value.author,
                                isModifier: (obj["modifier"] as? Bool) ?? old?.value.isModifier ?? false,
                                largeURL: "https://cdn.betterttv.net/emote/\(id)/3x")
        channelBTTV[channelId] = map
    }

    func removeChannelBTTV(channelId: String, emoteId: String) {
        guard var map = channelBTTV[channelId],
              let key = map.first(where: { $0.value.id == emoteId })?.key else { return }
        map[key] = nil
        channelBTTV[channelId] = map
    }

    /// `author` : repli quand l'emote ne nomme pas son créateur (emotes mises
    /// en ligne par la chaîne elle-même).
    private func bttvEmote(_ obj: [String: Any], scope: EmoteScope, author: String? = nil) -> TwitchEmote? {
        guard let id = obj["id"] as? String, let name = obj["code"] as? String else { return nil }
        let user = obj["user"] as? [String: Any]
        return TwitchEmote(id: id, name: name,
                           url: "https://cdn.betterttv.net/emote/\(id)/2x", source: .bttv,
                           scope: scope,
                           author: (user?["displayName"] as? String) ?? (user?["name"] as? String) ?? author,
                           // c!, w!… : modificateurs, pas des emotes qui se superposent.
                           isModifier: obj["modifier"] as? Bool ?? false,
                           largeURL: "https://cdn.betterttv.net/emote/\(id)/3x")
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: – FFZ
    private func loadFFZGlobal() async {
        guard let url = URL(string: "https://api.frankerfacez.com/v1/set/global"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sets = json["sets"] as? [String: Any] else { return }
        for (_, setValue) in sets {
            guard let setObj = setValue as? [String: Any],
                  let emoticons = setObj["emoticons"] as? [[String: Any]] else { continue }
            for obj in emoticons { if let e = ffzEmote(obj, scope: .global) { globalFFZ[e.name] = e } }
        }
    }

    // Fix : stockage par channelId (API appellée avec channelName)
    private func loadFFZChannel(channelId: String, channelName: String) async {
        guard let url = URL(string: "https://api.frankerfacez.com/v1/room/\(channelName)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sets = json["sets"] as? [String: Any] else { return }
        var map: [String: TwitchEmote] = [:]
        for (_, setValue) in sets {
            guard let setObj = setValue as? [String: Any],
                  let emoticons = setObj["emoticons"] as? [[String: Any]] else { continue }
            for obj in emoticons { if let e = ffzEmote(obj, scope: .channel) { map[e.name] = e } }
        }
        channelFFZ[channelId] = map   // ← stocké par channelId, pas channelName
    }

    /// Les emotes animées sont dans `animated` (WebP) : `urls` n'en garde
    /// qu'une image fixe. `animated` vaut null pour les autres.
    private func ffzEmote(_ obj: [String: Any], scope: EmoteScope) -> TwitchEmote? {
        let urls = obj["urls"] as? [String: Any] ?? [:]
        let anim = obj["animated"] as? [String: Any] ?? [:]
        func link(_ d: [String: Any], _ size: String) -> String? {
            guard let u = d[size] as? String, !u.isEmpty else { return nil }
            return u.hasPrefix("//") ? "https:\(u)" : u
        }
        guard let id   = obj["id"] as? Int,
              let name = obj["name"] as? String,
              let url  = link(anim, "2") ?? link(urls, "2") ?? link(urls, "1") else { return nil }
        return TwitchEmote(id: "\(id)", name: name, url: url, source: .ffz,
                           scope: scope,
                           author: (obj["owner"] as? [String: Any])?["display_name"] as? String,
                           // ffzW, ffzHyper… : effets appliqués à une autre emote.
                           isModifier: obj["modifier"] as? Bool ?? false,
                           largeURL: link(anim, "4") ?? link(urls, "4"))
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: – 7TV
    private func load7TVGlobal() async {
        guard let url = URL(string: "https://7tv.io/v3/emote-sets/global"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let emotes = json["emotes"] as? [[String: Any]] else { return }
        for obj in emotes { if let e = stvEmote(obj, scope: .global) { global7TV[e.name] = e } }
    }

    private func load7TVChannel(channelId: String) async {
        guard let url = URL(string: "https://7tv.io/v3/users/twitch/\(channelId)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let setObj = json["emote_set"] as? [String: Any],
              let emotes = setObj["emotes"] as? [[String: Any]] else { return }
        var map: [String: TwitchEmote] = [:]
        for obj in emotes { if let e = stvEmote(obj, scope: .channel) { map[e.name] = e } }
        channel7TV[channelId] = map
    }

    private func stvEmote(_ obj: [String: Any], scope: EmoteScope) -> TwitchEmote? {
        guard let id   = obj["id"] as? String,
              let name = obj["name"] as? String,
              let data = obj["data"] as? [String: Any],
              let host = (data["host"] as? [String: Any])?["url"] as? String else { return nil }
        // `name` : nom choisi par la chaîne ; `data.name` : nom d'origine.
        let original = data["name"] as? String
        return TwitchEmote(id: id, name: name, url: "https:\(host)/2x.webp", source: .seventv,
                           scope: scope,
                           author: (data["owner"] as? [String: Any])?["display_name"] as? String,
                           originalName: original.flatMap { $0.isEmpty || $0 == name ? nil : $0 },
                           // Drapeau actif dans ce jeu d'emotes (data.flags n'est
                           // qu'une recommandation).
                           zeroWidth: ((obj["flags"] as? Int) ?? 0) & 1 != 0,
                           largeURL: "https:\(host)/4x.webp")
    }
}
