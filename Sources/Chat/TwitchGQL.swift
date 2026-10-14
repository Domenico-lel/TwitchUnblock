import Foundation

// MARK: – Utilitaire GQL persisted-query (lectures + mutations avec integrity)
// Réutilise le minteur d'integrity (TwitchWebGQL) pour les mutations Kasada-gated.
@MainActor
final class TwitchGQL {
    static let shared = TwitchGQL()
    private init() {}

    private static let webUA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"

    private var integrityTok:    String? = nil
    private var integrityDevice: String  = ""
    private var integrityExpiry: Date    = .distantPast

    private var deviceId: String {
        if let d = UserDefaults.standard.string(forKey: "twitch_device_id") { return d }
        let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        let d = String((0..<32).map { _ in chars.randomElement()! })
        UserDefaults.standard.set(d, forKey: "twitch_device_id")
        return d
    }

    private func persistedBody(_ op: String, _ vars: [String: Any], _ hash: String) -> Data? {
        let body: [[String: Any]] = [[
            "operationName": op,
            "variables": vars,
            "extensions": ["persistedQuery": ["version": 1, "sha256Hash": hash]]
        ]]
        return try? JSONSerialization.data(withJSONObject: body)
    }

    /// Lecture (persisted query). `token` optionnel (nécessaire pour les champs `self`).
    func query(_ op: String, variables: [String: Any], sha256: String,
               token: String? = nil) async -> [String: Any]? {
        guard let url = URL(string: "https://gql.twitch.tv/gql"),
              let payload = persistedBody(op, variables, sha256) else { return nil }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue(kGQLClientID,        forHTTPHeaderField: "Client-ID")
        req.setValue("application/json",  forHTTPHeaderField: "Content-Type")
        req.setValue(deviceId,            forHTTPHeaderField: "X-Device-Id")
        req.setValue(Self.webUA,          forHTTPHeaderField: "User-Agent")
        if let t = token { req.setValue("OAuth \(t)", forHTTPHeaderField: "Authorization") }
        req.httpBody = payload
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return arr.first
    }

    private func validIntegrity(token: String) async -> Bool {
        if integrityTok != nil, integrityExpiry > Date().addingTimeInterval(60), !integrityDevice.isEmpty {
            return true
        }
        guard let mint = await TwitchWebGQL.shared.mintIntegrity(token: token) else { return false }
        integrityTok    = mint.token
        integrityDevice = mint.deviceId.isEmpty ? deviceId : mint.deviceId
        integrityExpiry = mint.expiry
        return true
    }

    /// Mutation persisted-query avec Client-Integrity (comme claim/redeem).
    func mutation(_ op: String, variables: [String: Any], sha256: String,
                  token: String) async -> [String: Any]? {
        guard await validIntegrity(token: token), let it = integrityTok,
              let url = URL(string: "https://gql.twitch.tv/gql"),
              let payload = persistedBody(op, variables, sha256) else { return nil }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue(kGQLClientID,               forHTTPHeaderField: "Client-ID")
        req.setValue("OAuth \(token)",           forHTTPHeaderField: "Authorization")
        req.setValue(integrityDevice,            forHTTPHeaderField: "X-Device-Id")
        req.setValue(it,                         forHTTPHeaderField: "Client-Integrity")
        req.setValue(Self.webUA,                 forHTTPHeaderField: "User-Agent")
        req.setValue("text/plain;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = payload
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = arr.first else { return nil }
        if let errors = first["errors"] as? [[String: Any]], !errors.isEmpty {
            let msgs = errors.compactMap { $0["message"] as? String }.joined(separator: " · ")
            logger.warn("GQL", "Erreurs \(op)", msgs)
            if msgs.lowercased().contains("integrity") { integrityTok = nil; integrityExpiry = .distantPast }
        }
        return first
    }
}

// MARK: – Suivre / Ne plus suivre
@MainActor
final class FollowService: ObservableObject {
    @Published var isFollowing: Bool? = nil   // nil = inconnu / en cours
    @Published var busy = false
    /// Sans session web : suivi gardé sur cet appareil (AppStore.localFollows).
    private(set) var localStore: AppStore? = nil

    /// Pas de compte (ou pas de session web) : on suit la chaîne localement.
    func loadLocal(login: String, store: AppStore) {
        self.login = login.lowercased()
        localStore = store
        isFollowing = store.isLocallyFollowed(login)
    }

    private var channelId = ""
    private var login = ""

    private static let hashStatus   = "1131e2a2138f219d96db8deda8eb06b217c0669e4fd33b8bed47623fc9764b33"
    private static let hashFollow   = "800e7346bdf7e5278a3c1d3f21b2b56e2639928f86815677a7126b093b2fdd08"
    private static let hashUnfollow = "f7dae976ebf41c755ae2d758546bfd176b4eeb856656098bb40e0a672ca0d880"

    /// Autre chaîne (page de chaîne) : plus rien d'affiché ni de modifiable
    /// tant que son statut n'est pas lu.
    func reset() {
        isFollowing = nil
        login = ""; channelId = ""
        localStore = nil
    }

    func load(login: String, channelId: String, token: String?) async {
        let wanted = login.lowercased()
        self.login = wanted; self.channelId = channelId
        localStore = nil
        isFollowing = nil
        guard let token = token, !login.isEmpty else { return }
        guard let res  = await TwitchGQL.shared.query("FollowButton_User",
                            variables: ["login": wanted], sha256: Self.hashStatus, token: token),
              // Réponse d'une chaîne quittée entre-temps : ignorée.
              self.login == wanted, localStore == nil,
              let data = res["data"] as? [String: Any],
              let user = data["user"] as? [String: Any] else { return }
        // user.self.follower est non-null si on suit la chaîne.
        let follower = (user["self"] as? [String: Any])?["follower"]
        isFollowing = follower != nil && !(follower is NSNull)
        logger.debug("FOLLOW", "Statut @\(self.login)", isFollowing == true ? "suivi" : "non suivi")
    }

    /// Ne plus suivre, après confirmation : jamais un abonnement, même si le
    /// statut a été relu entre le toucher et la confirmation. Selon le mode
    /// chargé : suivi de l'appareil, ou compte Twitch (session web).
    func unfollow(token: String?) async {
        if let localStore {
            guard localStore.isLocallyFollowed(login) else { isFollowing = false; return }
            localStore.toggleLocalFollow(login)
            isFollowing = localStore.isLocallyFollowed(login)
            logger.info("FOLLOW", "Suivi local retiré @\(login)", nil)
            return
        }
        guard let token, !token.isEmpty, !channelId.isEmpty, isFollowing == true, !busy else { return }
        busy = true; defer { busy = false }
        await sendUnfollow(token: token)
    }

    private func sendUnfollow(token: String) async {
        let target = channelId, who = login
        let res = await TwitchGQL.shared.mutation("FollowButton_UnfollowUser",
                    variables: ["input": ["targetID": target]],
                    sha256: Self.hashUnfollow, token: token)
        if let d = res?["data"] as? [String: Any], let u = d["unfollowUser"], !(u is NSNull),
           res?["errors"] == nil {
            logger.success("FOLLOW", "Ne suit plus @\(who)", nil)
            // Réponse arrivée après un changement de chaîne : pas sur son état.
            if isCurrent(target) { isFollowing = false }
        } else { logger.warn("FOLLOW", "Unfollow échoué @\(who)", nil) }
    }

    /// La chaîne visée par une mutation est-elle toujours celle affichée ?
    private func isCurrent(_ target: String) -> Bool {
        channelId == target && localStore == nil
    }

    func toggle(token: String?) async {
        if let localStore, token == nil {
            localStore.toggleLocalFollow(login)
            isFollowing = localStore.isLocallyFollowed(login)
            logger.info("FOLLOW", isFollowing == true ? "Suivi local @\(login)" : "Suivi local retiré @\(login)", nil)
            return
        }
        guard let token = token, let current = isFollowing, !busy, !channelId.isEmpty else { return }
        busy = true; defer { busy = false }
        if current {
            await sendUnfollow(token: token)
        } else {
            let target = channelId, who = login
            let res = await TwitchGQL.shared.mutation("FollowButton_FollowUser",
                        variables: ["input": ["disableNotifications": false, "targetID": target]],
                        sha256: Self.hashFollow, token: token)
            if let d = res?["data"] as? [String: Any], d["followUser"] != nil, res?["errors"] == nil {
                logger.success("FOLLOW", "Suit @\(who)", nil)
                if isCurrent(target) { isFollowing = true }
            } else { logger.warn("FOLLOW", "Follow échoué @\(who)", nil) }
        }
    }
}
