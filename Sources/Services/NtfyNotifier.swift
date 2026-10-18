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
    /// Dernière liste des chaînes suivies par le compte (repli si Helix ne
    /// répond pas).
    private static let accountCacheKey = "ntfy_account_follows"
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
        UserDefaults.standard.removeObject(forKey: unsubPendingKey)
        // Réveils d'iOS : le sujet y est renvoyé au Worker (LiveNotifier).
        LiveNotifier.schedule()
        return await sync(lang: lang, force: true)
    }

    static func disable() async {
        UserDefaults.standard.set(false, forKey: enabledKey)
        UserDefaults.standard.removeObject(forKey: hashKey)
        UserDefaults.standard.removeObject(forKey: syncedKey)
        UserDefaults.standard.removeObject(forKey: errorKey)
        UserDefaults.standard.removeObject(forKey: countKey)
        UserDefaults.standard.set(true, forKey: unsubPendingKey)
        await retryUnsubscribe()
    }

    /// Désabonnement pas encore confirmé par le Worker (hors ligne…) : renvoyé
    /// à chaque retour dans l'app. Raté une fois, le Worker publiait encore
    /// jusqu'à 60 jours (notifications en double avec celles de l'app).
    private static let unsubPendingKey = "ntfy_unsub_pending"

    static func retryUnsubscribe() async {
        let ud = UserDefaults.standard
        guard ud.bool(forKey: unsubPendingKey), !isEnabled else { return }
        guard let code = await post("/api/push/unsubscribe", ["ntfy": topic]) else { return }
        // 200, ou un refus qui ne changera pas (route absente, sujet inconnu).
        if code == 200 || ((400 ..< 500).contains(code) && code != 429) {
            ud.removeObject(forKey: unsubPendingKey)
        }
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
        guard isEnabled else { await retryUnsubscribe(); return false }
        let ud = UserDefaults.standard
        var channels = ud.stringArray(forKey: "local_follows") ?? []
        if let token = Keychain.loadToken("twitch_token"),
           let userId = ud.string(forKey: "twitch_user_id"), !userId.isEmpty {
            if let account = await getFollowedLogins(token: token, userId: userId) {
                ud.set(account, forKey: accountCacheKey)
                channels += account
            } else if let cached = ud.stringArray(forKey: accountCacheKey) {
                // Liste du compte illisible (jeton expiré, réseau) : la dernière
                // connue part à sa place. Rien n'était envoyé, et sans retour
                // dans l'app le Worker oubliait le sujet au bout de 60 jours.
                logger.warn("NTFY", "Chaînes suivies du compte illisibles : dernière liste connue", "\(cached.count)")
                channels += cached
            } else {
                // Jamais lue : rien n'est envoyé, plutôt qu'une liste amputée.
                ud.set("twitch", forKey: errorKey)
                return false
            }
        }
        // Moins celles coupées dans « Chaînes notifiées » (le hachage change :
        // la nouvelle liste part au prochain appel). Ordre gardé (suivis de
        // l'appareil, puis du compte, les plus récents d'abord) et 500 au
        // plus : le Worker n'en garde pas davantage, et le tri alphabétique
        // laissait de côté toutes les chaînes de la fin de l'alphabet.
        let muted = NotifChannels.muted
        var seen = Set<String>()
        let all = channels.map { $0.lowercased() }.filter { !muted.contains($0) && seen.insert($0).inserted }
        if all.count > 500 {
            logger.warn("NTFY", "Plus de 500 chaînes suivies : les 500 premières seulement", "\(all.count)")
        }
        let list = Array(all.prefix(500))
        // La langue en fait partie : changée, la liste repart tout de suite
        // (sinon les notifications gardaient l'ancienne langue jusqu'à 24 h).
        // Le schéma de TU Test aussi : le lien de clic suit dès sa mise à jour.
        let hash = lang.rawValue + "|" + (kAppURLScheme == "twitchunblock" ? "" : kAppURLScheme + "|")
            + list.joined(separator: ",")
        let last = ud.double(forKey: syncedKey)
        if !force, hash == ud.string(forKey: hashKey), Date().timeIntervalSince1970 - last < 86400,
           ud.string(forKey: errorKey) == nil { return true }
        // Coupé pendant la lecture des suivis (jusqu'à 10 pages) : rien à envoyer.
        guard isEnabled else { return false }
        // `scheme` : lien de clic des notifications (celui de TU Test diffère).
        let code = await post("/api/push/subscribe", ["ntfy": topic, "channels": list, "lang": lang.rawValue,
                                                      "scheme": kAppURLScheme])
        // Coupé pendant l'envoi : le désabonnement a pu arriver avant cet
        // abonnement, et le Worker publiait encore 60 jours. Il est renvoyé.
        guard isEnabled else {
            UserDefaults.standard.set(true, forKey: unsubPendingKey)
            await retryUnsubscribe()
            return false
        }
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

    enum TestResult {
        case sent, limited, failed

        /// Texte affiché sous le bouton.
        var textKey: String {
            switch self {
            case .sent: return "ntfy_test_sent"
            case .limited: return "ntfy_limited"
            case .failed: return "ntfy_failed"
            }
        }
    }

    /// Notification de test. `limited` : le Worker a répondu, mais ntfy.sh
    /// refuse les messages pour l'instant (limite d'envoi atteinte).
    static func sendTest(lang: Lang) async -> TestResult {
        guard let (code, data) = await send("/api/push/test", ["ntfy": topic, "lang": lang.rawValue,
                                                               "scheme": kAppURLScheme]) else { return .failed }
        if code == 200 { return .sent }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return json?["limit"] as? Bool == true ? .limited : .failed
    }

    private static func post(_ path: String, _ body: [String: Any]) async -> Int? {
        await send(path, body)?.code
    }

    /// Routes du Worker principal (base D1, pas de secours). Code HTTP et
    /// corps, nil si le Worker n'a pas pu être joint.
    private static func send(_ path: String, _ body: [String: Any]) async -> (code: Int, data: Data)? {
        guard let url = URL(string: APIConfig.base + path),
              let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = payload
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return nil }
        return (http.statusCode, data)
    }
}
