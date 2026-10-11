import Foundation

// ═══════════════════════════════════════════════════════════════════════════
//  Notifications de live instantanées, par ntfy.
//
//  LiveNotifier dépend des réveils qu'iOS accorde à l'app (rares, et jamais
//  après une fermeture forcée), et le push d'Apple demande un compte
//  développeur payant. ntfy, app gratuite de l'App Store, a ce push : l'app
//  crée un sujet secret, l'utilisateur s'y abonne dans ntfy, et le Worker y
//  publie quand une chaîne suivie passe en live (vérifié chaque minute ou
//  deux). Toucher la notification ouvre le direct ici
//  (twitchunblock://live/<chaîne>).
// ═══════════════════════════════════════════════════════════════════════════
enum NtfyNotifier {
    static let enabledKey = "ntfy_enabled"
    private static let topicKey = "ntfy_topic"
    private static let hashKey = "ntfy_hash"
    static let syncedKey = "ntfy_synced"
    static let countKey = "ntfy_channels"
    static let appStoreURL = URL(string: "https://apps.apple.com/app/ntfy/id1625396347")!

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Sujet secret (« tu- » et 24 caractères au hasard), créé une fois.
    static var topic: String {
        let ud = UserDefaults.standard
        if let saved = ud.string(forKey: topicKey), !saved.isEmpty { return saved }
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var random = SystemRandomNumberGenerator()
        let made = "tu-" + String((0 ..< 24).map { _ in chars.randomElement(using: &random) ?? "a" })
        ud.set(made, forKey: topicKey)
        return made
    }

    /// Sujet et chaînes suivies confiés au Worker. false s'ils n'ont pas pu partir.
    static func enable(lang: Lang) async -> Bool {
        UserDefaults.standard.set(true, forKey: enabledKey)
        let ok = await sync(lang: lang, force: true)
        if !ok { UserDefaults.standard.set(false, forKey: enabledKey) }
        return ok
    }

    static func disable() async {
        UserDefaults.standard.set(false, forKey: enabledKey)
        UserDefaults.standard.removeObject(forKey: hashKey)
        _ = await post("/api/push/unsubscribe", ["ntfy": topic])
    }

    /// Chaînes suivies (compte Twitch et appareil) renvoyées au Worker quand
    /// elles changent, et au moins une fois par jour (au-delà de 60 jours sans
    /// nouvelles, le Worker oublie le sujet).
    @discardableResult
    static func sync(lang: Lang, force: Bool = false) async -> Bool {
        guard isEnabled else { return false }
        let ud = UserDefaults.standard
        var channels = ud.stringArray(forKey: "local_follows") ?? []
        if let token = Keychain.loadToken("twitch_token"),
           let userId = ud.string(forKey: "twitch_user_id"), !userId.isEmpty {
            // Liste du compte illisible : rien n'est envoyé, plutôt qu'une liste amputée.
            guard let account = await getFollowedLogins(token: token, userId: userId) else { return false }
            channels += account
        }
        let list = Array(Set(channels.map { $0.lowercased() })).sorted()
        let hash = list.joined(separator: ",")
        let last = ud.double(forKey: syncedKey)
        if !force, hash == ud.string(forKey: hashKey), Date().timeIntervalSince1970 - last < 86400 { return true }
        guard await post("/api/push/subscribe", ["ntfy": topic, "channels": list, "lang": lang.rawValue]) else {
            return false
        }
        ud.set(hash, forKey: hashKey)
        ud.set(Date().timeIntervalSince1970, forKey: syncedKey)
        ud.set(list.count, forKey: countKey)
        return true
    }

    static func sendTest(lang: Lang) async -> Bool {
        await post("/api/push/test", ["ntfy": topic, "lang": lang.rawValue])
    }

    /// Routes du Worker principal (base D1, pas de secours).
    private static func post(_ path: String, _ body: [String: Any]) async -> Bool {
        guard let url = URL(string: kAPIURL + path),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return false }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
}
