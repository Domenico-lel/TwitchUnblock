import Foundation

// MARK: – Fiche d'une emote Twitch
/// Ce que twitch.tv montre d'une emote : son type, sa chaîne (en direct ou
/// non) et les emotes d'abonné du même niveau. Le tag IRC ne donne que l'id,
/// et l'emote peut appartenir à une autre chaîne que celle regardée.
struct TwitchEmoteInfo: Equatable {
    struct Owner: Equatable {
        let login: String
        let displayName: String
        let avatar: String?
        let isLive: Bool
    }
    struct SubEmote: Equatable, Identifiable {
        let id: String
        let token: String
        var url: String { "https://static-cdn.jtvnw.net/emoticons/v2/\(id)/static/dark/2.0" }
    }

    let id: String
    /// GLOBALS, SMILIES, SUBSCRIPTIONS, CHANNEL_POINTS… (brut, tel que Twitch le donne).
    let type: String
    /// Niveau d'abonnement (1, 2 ou 3) d'une emote d'abonné.
    let tier: Int?
    /// STATIC ou ANIMATED.
    let assetType: String?
    let owner: Owner?
    /// Emotes d'abonné du même niveau, celle-ci comprise (Twitch dit
    /// « 63 autres » pour 64 au niveau 1).
    let sameTier: [SubEmote]
}

/// Une requête GQL publique (sans compte) par emote, gardée en mémoire pour
/// la séance. Sans réponse (Twitch bloqué, schéma changé), la fiche reste
/// celle d'avant, sans message d'erreur.
actor EmoteInfoService {
    static let shared = EmoteInfoService()
    private init() {}

    /// Réponses de Twitch, `emote: null` compris (nil gardé), jamais les
    /// erreurs réseau ni GQL : une panne passagère ne doit pas priver la fiche de
    /// ses infos pour toute la séance.
    private var cache: [String: TwitchEmoteInfo?] = [:]
    private var order: [String] = []

    private static let query = """
    query($id: ID!) { emote(id: $id) { id token type subscriptionTier assetType \
    owner { id login displayName profileImageURL(width: 70) stream { id } \
    subscriptionProducts { tier emotes { id token } } } } }
    """

    func twitch(id: String) async -> TwitchEmoteInfo? {
        guard !id.isEmpty else { return nil }
        if let hit = cache[id] { return hit }
        // Les valeurs passent en variables, jamais collées dans le texte
        // (comme gqlRequest de TwitchAPI).
        guard let url = URL(string: "https://gql.twitch.tv/gql"),
              let body = try? JSONSerialization.data(withJSONObject: ["query": Self.query,
                                                                      "variables": ["id": id]]) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue(kGQLClientID, forHTTPHeaderField: "Client-ID")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = json["data"] as? [String: Any] else {
            logger.debug("EMOTES", "Fiche d'emote Twitch indisponible", id)
            return nil
        }
        // `data` présent : Twitch a répondu, même par `emote: null`.
        let info = (d["emote"] as? [String: Any]).flatMap(Self.parse)
        // Erreur partielle (« service timeout »… avec `emote: null`) : réponse
        // rendue mais pas gardée, la prochaine fiche redemandera.
        if (json["errors"] as? [Any])?.isEmpty == false {
            logger.debug("EMOTES", "Fiche d'emote Twitch : erreur GQL", id)
            return info
        }
        if cache[id] == nil { order.append(id) }
        cache.updateValue(info, forKey: id)
        if order.count > 300 { cache[order.removeFirst()] = nil }
        return info
    }

    private static func parse(_ e: [String: Any]) -> TwitchEmoteInfo? {
        guard let id = e["id"] as? String else { return nil }
        // « TIER_1 » → 1 ; les produits d'abonnement disent « 1000 ».
        let tier = (e["subscriptionTier"] as? String).flatMap { t -> Int? in
            guard t.hasPrefix("TIER_") else { return nil }
            return Int(t.dropFirst(5))
        }
        let o = e["owner"] as? [String: Any]
        var owner: TwitchEmoteInfo.Owner? = nil
        var sameTier: [TwitchEmoteInfo.SubEmote] = []
        if let o, let login = o["login"] as? String, !login.isEmpty {
            let avatar = (o["profileImageURL"] as? String).flatMap { $0.hasPrefix("https://") ? $0 : nil }
            owner = TwitchEmoteInfo.Owner(login: login,
                          displayName: (o["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? login,
                          avatar: avatar,
                          isLive: o["stream"] is [String: Any])
            if let tier {
                let products = o["subscriptionProducts"] as? [[String: Any]] ?? []
                let product = products.first { p -> Bool in
                    // Chaîne (« 1000 ») d'après la sonde ; nombre accepté aussi.
                    if let s = p["tier"] as? String { return s == "\(tier)000" }
                    return (p["tier"] as? Int) == tier * 1000
                }
                sameTier = (product?["emotes"] as? [[String: Any]] ?? []).compactMap { x -> TwitchEmoteInfo.SubEmote? in
                    guard let xid = x["id"] as? String, !xid.isEmpty else { return nil }
                    return TwitchEmoteInfo.SubEmote(id: xid, token: x["token"] as? String ?? "")
                }
            }
        }
        return TwitchEmoteInfo(id: id,
                               type: e["type"] as? String ?? "",
                               tier: tier,
                               assetType: e["assetType"] as? String,
                               owner: owner,
                               sameTier: sameTier)
    }
}
