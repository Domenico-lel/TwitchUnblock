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

    /// Dernier envoi au Worker raté (« HTTP 404 », « network »…) ; absent une
    /// fois l'envoi passé.
    static let errorKey = "ntfy_error"

    /// Active ntfy et confie sujet et chaînes suivies au Worker. Reste activé
    /// même s'il ne répond pas (Worker pas encore à jour, réseau…) : l'envoi
    /// est retenté à chaque retour dans l'app. true si c'est déjà parti.
    static func enable(lang: Lang) async -> Bool {
        UserDefaults.standard.set(true, forKey: enabledKey)
        return await sync(lang: lang, force: true)
    }

    static func disable() async {
        UserDefaults.standard.set(false, forKey: enabledKey)
        UserDefaults.standard.removeObject(forKey: hashKey)
        UserDefaults.standard.removeObject(forKey: syncedKey)
        UserDefaults.standard.removeObject(forKey: errorKey)
        _ = await post("/api/push/unsubscribe", ["ntfy": topic])
    }

    /// Activé, mais rien encore d'accepté par le Worker.
    static var isPending: Bool {
        let ud = UserDefaults.standard
        return isEnabled && (ud.string(forKey: errorKey) != nil || ud.double(forKey: syncedKey) == 0)
    }

    /// Le Worker ne connaît pas encore ces notifications (pas encore à jour).
    static var serverNotReady: Bool { UserDefaults.standard.string(forKey: errorKey) == "HTTP 404" }

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
            guard let account = await getFollowedLogins(token: token, userId: userId) else {
                ud.set("twitch", forKey: errorKey)
                return false
            }
            channels += account
        }
        let list = Array(Set(channels.map { $0.lowercased() })).sorted()
        let hash = list.joined(separator: ",")
        let last = ud.double(forKey: syncedKey)
        if !force, hash == ud.string(forKey: hashKey), Date().timeIntervalSince1970 - last < 86400,
           ud.string(forKey: errorKey) == nil { return true }
        let code = await post("/api/push/subscribe", ["ntfy": topic, "channels": list, "lang": lang.rawValue])
        guard code == 200 else {
            ud.set(code.map { "HTTP \($0)" } ?? "network", forKey: errorKey)
            logger.warn("NTFY", "Abonnement refusé par le Worker", code.map { "HTTP \($0)" } ?? "réseau")
            return false
        }
        ud.removeObject(forKey: errorKey)
        ud.set(hash, forKey: hashKey)
        ud.set(Date().timeIntervalSince1970, forKey: syncedKey)
        ud.set(list.count, forKey: countKey)
        return true
    }

    static func sendTest(lang: Lang) async -> Bool {
        await post("/api/push/test", ["ntfy": topic, "lang": lang.rawValue]) == 200
    }

    /// Routes du Worker principal (base D1, pas de secours). Code HTTP, nil
    /// si le Worker n'a pas pu être joint.
    private static func post(_ path: String, _ body: [String: Any]) async -> Int? {
        guard let url = URL(string: kAPIURL + path),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return nil }
        return (resp as? HTTPURLResponse)?.statusCode
    }
}
