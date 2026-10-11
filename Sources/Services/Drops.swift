import Foundation

// ═══════════════════════════════════════════════════════════════════════════
//  Drops Twitch : progression, réclamation, et de quoi les faire avancer.
//
//  Depuis le 2026-10-08, Twitch ne compte les minutes de drops que si la
//  session du compte charge elle-même le flux (segments HLS demandés avec son
//  jeton de lecture). Un « minute-watched » ne suffit plus — il compte encore
//  pour les points de chaîne. Or l'app lit les lives par des proxys au jeton
//  anonyme : sans rien de plus, aucun drop n'avancerait.
//
//  DropsHeartbeat fait donc, pendant un live dont la chaîne a des drops, ce
//  que font les outils de drops : la playlist de la plus petite qualité, relue
//  toutes les 10 s avec le jeton du compte, et une requête HEAD par nouveau
//  segment. Rien n'est téléchargé ni lu.
//
//  Lecture (inventaire, drop en cours) : session web (`auth-token`), sans
//  jeton d'intégrité. Réclamation : jeton d'intégrité (TwitchWebGQL), comme
//  les coffres de points. ⚠️ Non officiel / hors-ToS Twitch — usage perso.
// ═══════════════════════════════════════════════════════════════════════════

// MARK: – Modèles
struct TimedDrop: Identifiable {
    let id: String
    let name: String
    let imageURL: String?
    let requiredMinutes: Int
    let currentMinutes: Int
    let isClaimed: Bool
    /// Donné par Twitch une fois le drop terminé : c'est lui qu'on réclame.
    let dropInstanceID: String?
    let hasPreconditionsMet: Bool

    var progress: Double {
        if isClaimed { return 1 }
        return requiredMinutes > 0 ? min(1, Double(currentMinutes) / Double(requiredMinutes)) : 0
    }
    var canClaim: Bool { !isClaimed && dropInstanceID != nil && currentMinutes >= requiredMinutes }
}

struct DropCampaign: Identifiable {
    let id: String
    let name: String
    let gameName: String
    let boxArtURL: String
    let startAt: Date?
    let endAt: Date?
    /// Pas encore commencée (status UPCOMING).
    let isUpcoming: Bool
    let accountLinkURL: String?
    /// Compte de jeu à lier : sans liaison, Twitch ne donne plus la récompense
    /// (depuis le 2026-10-08). Les badges et emotes Twitch n'en ont pas besoin.
    let needsAccountLink: Bool
    let drops: [TimedDrop]
}

/// Drop crédité en ce moment, et sur quelle chaîne.
struct DropSession {
    let channelName: String?
    let currentMinutes: Int
    let requiredMinutes: Int
}

// MARK: – GQL (session web)
/// Même identifiant d'appareil que les points de chaîne (ChannelPointsService).
private func twitchDeviceId() -> String {
    if let d = UserDefaults.standard.string(forKey: "twitch_device_id") { return d }
    let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    let d = String((0..<32).map { _ in chars.randomElement()! })
    UserDefaults.standard.set(d, forKey: "twitch_device_id")
    return d
}

/// Requête GQL au nom du compte (`token` : session web) ; sans `token`, une
/// requête publique. `integrity` pour les opérations protégées.
private func webGQL(_ body: Any, token: String?,
                    integrity: TwitchWebGQL.Integrity? = nil) async -> [String: Any]? {
    guard let url = URL(string: "https://gql.twitch.tv/gql"),
          let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
    var req = URLRequest(url: url, timeoutInterval: 15)
    req.httpMethod = "POST"
    req.setValue(kGQLClientID, forHTTPHeaderField: "Client-ID")
    req.setValue("text/plain;charset=UTF-8", forHTTPHeaderField: "Content-Type")
    if let token, !token.isEmpty { req.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization") }
    // Le jeton d'intégrité est lié à l'identifiant d'appareil qui l'a obtenu.
    let device = integrity.map { $0.deviceId }.flatMap { $0.isEmpty ? nil : $0 } ?? twitchDeviceId()
    req.setValue(device, forHTTPHeaderField: "X-Device-Id")
    if let integrity { req.setValue(integrity.token, forHTTPHeaderField: "Client-Integrity") }
    req.httpBody = payload
    guard let (data, resp) = try? await URLSession.shared.data(for: req),
          (resp as? HTTPURLResponse)?.statusCode == 200,
          let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
    // Requête persistée : un tableau d'une réponse ; requête écrite : un objet.
    return (obj as? [[String: Any]])?.first ?? (obj as? [String: Any])
}

/// Messages d'erreur GQL, en une ligne (vide s'il n'y en a pas).
private func gqlErrors(_ json: [String: Any]?) -> String {
    ((json?["errors"] as? [[String: Any]]) ?? []).compactMap { $0["message"] as? String }.joined(separator: " · ")
}

private func isoDate(_ s: String?) -> Date? {
    guard let s else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
}

// MARK: – Inventaire et réclamation
@MainActor
final class DropsService: ObservableObject {
    static let shared = DropsService()
    private init() {}

    @Published private(set) var campaigns: [DropCampaign] = []
    @Published private(set) var session: DropSession? = nil
    @Published private(set) var isLoading = false
    @Published private(set) var loaded = false
    @Published private(set) var failed = false
    @Published private(set) var claiming: Set<String> = []
    /// Toutes les campagnes ouvertes (tableau de bord des drops) ; l'inventaire
    /// ne donne que celles où l'on a déjà commencé.
    @Published private(set) var available: [DropCampaign] = []
    @Published private(set) var availableLoading = false
    @Published private(set) var availableLoaded = false
    @Published private(set) var availableFailed = false
    /// Résultat de la dernière réclamation (affiché en haut de l'écran Drops).
    @Published var notice: (text: String, ok: Bool)? = nil

    private var integrity: TwitchWebGQL.Integrity?

    // Persisted query du site (DropsPage_ClaimDropRewards).
    private static let claimHash = "a455deea71bdc9015b78eb49f4acfbce8baa7ccbedd28e549bb025bd0f751930"

    private static let inventoryQuery = """
    query { currentUser { inventory { dropCampaignsInProgress {
      id name status startAt endAt accountLinkURL
      self { isAccountConnected }
      game { displayName boxArtURL(width: 144, height: 192) }
      timeBasedDrops {
        id name requiredMinutesWatched
        benefitEdges { benefit { name imageAssetURL } }
        self { hasPreconditionsMet currentMinutesWatched isClaimed dropInstanceID }
      }
    } } } }
    """

    /// Relit l'inventaire ; réclame ce qui est terminé si `autoClaim`.
    func refresh(token: String, autoClaim: Bool) async {
        isLoading = true
        defer { isLoading = false }
        let json = await webGQL(["query": Self.inventoryQuery], token: token)
        guard let data = json?["data"] as? [String: Any] else {
            logger.warn("DROPS", "Inventaire indisponible", gqlErrors(json))
            failed = true
            return
        }
        failed = false
        loaded = true
        let inventory = (data["currentUser"] as? [String: Any])?["inventory"] as? [String: Any]
        campaigns = (inventory?["dropCampaignsInProgress"] as? [[String: Any]] ?? [])
            .compactMap(Self.campaign)
            .sorted { ($0.endAt ?? .distantFuture) < ($1.endAt ?? .distantFuture) }
        logger.debug("DROPS", "\(campaigns.count) campagne(s) en cours", nil)

        if let channel = DropsHeartbeat.shared.channelId {
            await refreshSession(token: token, channelId: channel)
        } else {
            session = nil
        }

        guard autoClaim else { return }
        var claimedSome = false
        for c in campaigns where !c.needsAccountLink {
            for d in c.drops where d.canClaim {
                if await claim(d, token: token) { claimedSome = true }
            }
        }
        // Une réclamation se vérifie dans l'inventaire (Twitch peut répondre
        // « éligible » sans rien donner à un compte non lié).
        if claimedSome { await refresh(token: token, autoClaim: false) }
    }

    // Même champ que la page des drops de twitch.tv (ViewerDropsDashboard),
    // protégé par le jeton d'intégrité.
    private static let dashboardQuery = """
    query { currentUser { dropCampaigns {
      id name status startAt endAt accountLinkURL
      self { isAccountConnected }
      game { displayName boxArtURL(width: 144, height: 192) }
      timeBasedDrops { id name requiredMinutesWatched benefitEdges { benefit { name imageAssetURL } } }
    } } }
    """

    /// Campagnes ouvertes ou à venir, de tous les jeux. Sans jeton d'intégrité
    /// d'abord ; avec si Twitch en demande un (WebView éphémère, ~5 s).
    func refreshAvailable(token: String) async {
        guard !availableLoading else { return }
        availableLoading = true
        defer { availableLoading = false }
        let body: [String: Any] = ["query": Self.dashboardQuery]
        var json = await webGQL(body, token: token)
        if gqlErrors(json).lowercased().contains("integrity"),
           let it = await validIntegrity(token: token) {
            json = await webGQL(body, token: token, integrity: it)
            if gqlErrors(json).lowercased().contains("integrity") {
                // Jeton refusé : un neuf, une seule fois.
                integrity = nil
                if let fresh = await validIntegrity(token: token) {
                    json = await webGQL(body, token: token, integrity: fresh)
                }
            }
        }
        guard let user = (json?["data"] as? [String: Any])?["currentUser"] as? [String: Any],
              let list = user["dropCampaigns"] as? [[String: Any]] else {
            logger.warn("DROPS", "Campagnes ouvertes indisponibles", gqlErrors(json))
            availableFailed = true
            return
        }
        availableFailed = false
        availableLoaded = true
        available = list.compactMap(Self.campaign)
            .filter { $0.endAt.map { $0 > Date() } ?? true }
            .sorted {
                // En cours d'abord, puis par jeu.
                if $0.isUpcoming != $1.isUpcoming { return !$0.isUpcoming }
                return $0.gameName.localizedCaseInsensitiveCompare($1.gameName) == .orderedAscending
            }
        logger.debug("DROPS", "\(available.count) campagne(s) ouverte(s)", nil)
    }

    /// Drop crédité en ce moment sur la chaîne regardée.
    private func refreshSession(token: String, channelId: String) async {
        let q = """
        query($c: ID!) { currentUser { dropCurrentSession(channelID: $c) {
          channel { displayName } currentMinutesWatched requiredMinutesWatched dropID } } }
        """
        let json = await webGQL(["query": q, "variables": ["c": channelId]], token: token)
        guard let data = json?["data"] as? [String: Any],
              let s = (data["currentUser"] as? [String: Any])?["dropCurrentSession"] as? [String: Any],
              s["dropID"] is String else { session = nil; return }
        session = DropSession(
            channelName: (s["channel"] as? [String: Any])?["displayName"] as? String,
            currentMinutes: s["currentMinutesWatched"] as? Int ?? 0,
            requiredMinutes: s["requiredMinutesWatched"] as? Int ?? 0)
    }

    /// Jeton d'intégrité valide (WebView éphémère si besoin), gardé jusqu'à
    /// une minute de son expiration.
    func validIntegrity(token: String) async -> TwitchWebGQL.Integrity? {
        if let i = integrity, i.expiry > Date().addingTimeInterval(60) { return i }
        integrity = await TwitchWebGQL.shared.mintIntegrity(token: token)
        return integrity
    }

    private enum ClaimResult { case ok, integrity, failed(String) }

    /// Réclame un drop terminé. true si Twitch l'a accordé.
    @discardableResult
    func claim(_ drop: TimedDrop, token: String) async -> Bool {
        guard let instance = drop.dropInstanceID, !claiming.contains(drop.id) else { return false }
        claiming.insert(drop.id)
        defer { claiming.remove(drop.id) }
        logger.info("DROPS", "Réclamation…", drop.name)
        let body: [[String: Any]] = [[
            "operationName": "DropsPage_ClaimDropRewards",
            "variables": ["input": ["dropInstanceID": instance]],
            "extensions": ["persistedQuery": ["version": 1, "sha256Hash": Self.claimHash]],
        ]]
        var result = await sendClaim(body, token: token)
        if case .integrity = result {
            // Jeton d'intégrité refusé : un neuf, une seule fois.
            integrity = nil
            result = await sendClaim(body, token: token)
        }
        let lang = Lang(rawValue: UserDefaults.standard.string(forKey: "lang") ?? "en") ?? .en
        switch result {
        case .ok:
            logger.success("DROPS", "🎁 Drop réclamé", drop.name)
            notice = (translate("drops_claim_ok", lang).replacingOccurrences(of: "{d}", with: drop.name), true)
            return true
        case .integrity, .failed:
            notice = (translate("drops_claim_fail", lang), false)
            return false
        }
    }

    private func sendClaim(_ body: Any, token: String) async -> ClaimResult {
        guard let it = await validIntegrity(token: token) else { return .failed("intégrité indisponible") }
        guard let json = await webGQL(body, token: token, integrity: it) else { return .failed("réseau") }
        let errors = gqlErrors(json)
        if !errors.isEmpty {
            logger.warn("DROPS", "Réclamation refusée", errors)
            return errors.lowercased().contains("integrity") ? .integrity : .failed(errors)
        }
        let status = ((json["data"] as? [String: Any])?["claimDropRewards"] as? [String: Any])?["status"] as? String
        // ELIGIBLE_FOR_ALL : accordé ; DROP_INSTANCE_ALREADY_CLAIMED : déjà fait.
        if status == "ELIGIBLE_FOR_ALL" || status == "DROP_INSTANCE_ALREADY_CLAIMED" { return .ok }
        logger.warn("DROPS", "Réclamation refusée", status ?? "réponse vide")
        return .failed(status ?? "null")
    }

    nonisolated private static func campaign(_ c: [String: Any]) -> DropCampaign? {
        guard let id = c["id"] as? String else { return nil }
        let game = c["game"] as? [String: Any]
        let drops: [TimedDrop] = (c["timeBasedDrops"] as? [[String: Any]] ?? []).compactMap { d in
            guard let dropId = d["id"] as? String else { return nil }
            let me = d["self"] as? [String: Any]
            let edges = d["benefitEdges"] as? [[String: Any]] ?? []
            let benefit = edges.first?["benefit"] as? [String: Any]
            return TimedDrop(
                id: dropId,
                name: benefit?["name"] as? String ?? d["name"] as? String ?? "",
                imageURL: benefit?["imageAssetURL"] as? String,
                requiredMinutes: d["requiredMinutesWatched"] as? Int ?? 0,
                currentMinutes: me?["currentMinutesWatched"] as? Int ?? 0,
                isClaimed: me?["isClaimed"] as? Bool ?? false,
                dropInstanceID: me?["dropInstanceID"] as? String,
                hasPreconditionsMet: me?["hasPreconditionsMet"] as? Bool ?? true)
        }
        let link = c["accountLinkURL"] as? String
        let connected = (c["self"] as? [String: Any])?["isAccountConnected"] as? Bool ?? true
        return DropCampaign(
            id: id,
            name: c["name"] as? String ?? "",
            gameName: game?["displayName"] as? String ?? "",
            boxArtURL: game?["boxArtURL"] as? String ?? "",
            startAt: isoDate(c["startAt"] as? String),
            endAt: isoDate(c["endAt"] as? String),
            isUpcoming: (c["status"] as? String) == "UPCOMING",
            accountLinkURL: link,
            needsAccountLink: !connected && !(link ?? "").contains("twitch.tv"),
            drops: drops)
    }
}

// MARK: – Progression pendant un live
@MainActor
final class DropsHeartbeat: ObservableObject {
    static let shared = DropsHeartbeat()
    private init() {}

    /// Où en est la progression, pour la page Drops (pseudo de la chaîne).
    enum Status: Equatable {
        case idle
        case checking(String)
        case noDrops(String)
        case active(String)
        case failing(String)
    }
    @Published private(set) var status: Status = .idle

    /// Chaîne dont le flux est « regardé » pour les drops (nil : à l'arrêt).
    private(set) var channelId: String? = nil
    private var task: Task<Void, Never>? = nil
    /// Segments déjà demandés (les 256 derniers).
    private var seen: [String] = []

    func start(login: String, token: String) {
        stop()
        let login = login.lowercased()
        status = .checking(login)
        task = Task { [weak self] in await self?.run(login: login, token: token) }
    }

    func stop() {
        task?.cancel()
        task = nil
        channelId = nil
        seen.removeAll()
        status = .idle
    }

    private enum Poll { case ok, expired, offline }

    private func run(login: String, token: String) async {
        var variant: URL? = nil
        var lastCheck = Date.distantPast
        var lastInventory = Date()
        var failures = 0
        while !Task.isCancelled {
            // Campagnes de la chaîne : au départ, puis toutes les 10 min (des
            // drops peuvent commencer en cours de live).
            if channelId == nil, Date().timeIntervalSince(lastCheck) > 600 {
                lastCheck = Date()
                let found = await Self.dropsChannelId(login)
                guard !Task.isCancelled else { return }   // arrêté entre-temps
                if let id = found {
                    channelId = id
                    status = .active(login)
                    logger.success("DROPS", "Drops sur \(login)", "progression : HEAD des segments toutes les 10 s")
                } else {
                    status = .noDrops(login)
                    logger.debug("DROPS", "Pas de drops sur \(login)", nil)
                }
            }
            if channelId != nil {
                if variant == nil {
                    variant = await Self.lowestVariant(login: login, token: token)
                    guard !Task.isCancelled else { return }
                    failures = variant == nil ? failures + 1 : 0
                    // Plusieurs échecs de suite : jeton anonyme ou session web
                    // expirée, à signaler sur la page Drops.
                    status = failures > 2 ? .failing(login) : .active(login)
                }
                if let v = variant {
                    switch await poll(v) {
                    case .ok: break
                    case .expired: variant = nil   // jeton expiré (~20 min) : un neuf
                    case .offline:
                        logger.info("DROPS", "Live terminé", login)
                        channelId = nil
                        status = .idle
                        return
                    }
                }
                // Inventaire toutes les 5 min : drops terminés réclamés si l'option est active.
                if Date().timeIntervalSince(lastInventory) > 300 {
                    lastInventory = Date()
                    let auto = UserDefaults.standard.object(forKey: "cfg_drops_autoclaim") as? Bool ?? true
                    await DropsService.shared.refresh(token: token, autoClaim: auto)
                }
            }
            let pause: UInt64 = channelId == nil ? 60 : (failures > 2 ? 60 : 10)
            try? await Task.sleep(nanoseconds: pause * 1_000_000_000)
        }
    }

    /// Relit la playlist et « demande » chaque nouveau segment, en HEAD.
    private func poll(_ variant: URL) async -> Poll {
        guard let (data, resp) = try? await URLSession.shared.data(from: variant) else { return .ok }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return .offline }
        guard code == 200 else { return .expired }
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        var fresh: [URL] = []
        for (i, line) in lines.enumerated() where line.hasPrefix("#EXTINF") && i + 1 < lines.count {
            let uri = lines[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !uri.isEmpty, !uri.hasPrefix("#"), !seen.contains(uri),
                  let url = URL(string: uri, relativeTo: variant)?.absoluteURL else { continue }
            seen.append(uri)
            fresh.append(url)
        }
        if seen.count > 256 { seen.removeFirst(seen.count - 256) }
        for url in fresh {
            var req = URLRequest(url: url, timeoutInterval: 10)
            req.httpMethod = "HEAD"
            let status = ((try? await URLSession.shared.data(for: req))?.1 as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 { return .expired }
        }
        return .ok
    }

    /// Identifiant de la chaîne si elle a des campagnes de drops, nil sinon.
    private static func dropsChannelId(_ login: String) async -> String? {
        let q = "query($l: String!) { user(login: $l) { id channel { viewerDropCampaigns { id } } } }"
        guard let json = await webGQL(["query": q, "variables": ["l": login]], token: nil),
              let user = (json["data"] as? [String: Any])?["user"] as? [String: Any],
              let id = user["id"] as? String,
              let list = (user["channel"] as? [String: Any])?["viewerDropCampaigns"] as? [Any],
              !list.isEmpty else { return nil }
        return id
    }

    /// Plus petite qualité du live, lue avec un jeton de lecture lié au compte.
    private static func lowestVariant(login: String, token: String) async -> URL? {
        guard let pat = await playbackToken(login: login, token: token),
              var comps = URLComponents(string: "https://usher.ttvnw.net/api/channel/hls/\(login).m3u8")
        else { return nil }
        comps.queryItems = [
            .init(name: "allow_source",     value: "true"),
            .init(name: "allow_audio_only", value: "true"),
            .init(name: "sig",              value: pat.signature),
            .init(name: "token",            value: pat.value),
        ]
        guard let url = comps.url,
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else {
            logger.warn("DROPS", "Liste maîtresse indisponible", login)
            return nil
        }
        // La dernière variante de la liste : la plus légère (audio seul).
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        var last: String? = nil
        for (i, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF") && i + 1 < lines.count {
            last = lines[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return last.flatMap { URL(string: $0, relativeTo: url)?.absoluteURL }
    }

    /// Jeton de lecture au nom du compte. Sans jeton d'intégrité d'abord ; si
    /// Twitch en exige un, avec.
    private static func playbackToken(login: String, token: String) async -> (value: String, signature: String)? {
        let q = """
        query($l: String!) { streamPlaybackAccessToken(channelName: $l,
          params: {platform: "web", playerBackend: "mediaplayer", playerType: "site"}) { value signature } }
        """
        let body: [String: Any] = ["query": q, "variables": ["l": login]]
        var json = await webGQL(body, token: token)
        if gqlErrors(json).lowercased().contains("integrity"),
           let it = await DropsService.shared.validIntegrity(token: token) {
            json = await webGQL(body, token: token, integrity: it)
        }
        guard let pat = (json?["data"] as? [String: Any])?["streamPlaybackAccessToken"] as? [String: Any],
              let value = pat["value"] as? String,
              let signature = pat["signature"] as? String else {
            logger.warn("DROPS", "Jeton de lecture indisponible", gqlErrors(json))
            return nil
        }
        // Un jeton anonyme (« user_id »: null) ne ferait rien avancer.
        guard value.range(of: #""user_id":\d"#, options: .regularExpression) != nil else {
            logger.warn("DROPS", "Jeton de lecture anonyme", "session web expirée ?")
            return nil
        }
        return (value, signature)
    }
}
