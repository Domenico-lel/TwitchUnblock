import Foundation
import Combine
import UIKit

final class AppStore: ObservableObject {

    // MARK: – Language
    /// L'anglais par défaut : l'app n'est pas réservée à un public français.
    @Published var lang: Lang = .en {
        didSet { UserDefaults.standard.set(lang.rawValue, forKey: "lang") }
    }

    // MARK: – Twitch Auth
    @Published var twitchToken: String? {
        didSet {
            Keychain.storeToken(twitchToken, for: "twitch_token")
        }
    }
    /// Gardé entre deux lancements : l'envoi de la sauvegarde au passage en
    /// arrière-plan doit savoir pour qui écrire, même avant que l'accueil
    /// n'ait rechargé le profil.
    @Published var twitchUserId: String? {
        didSet {
            if let id = twitchUserId { UserDefaults.standard.set(id, forKey: "twitch_user_id") }
            else { UserDefaults.standard.removeObject(forKey: "twitch_user_id") }
            // Compte de l'app connu ou changé : la session web doit être la sienne.
            if let id = twitchUserId, id != oldValue, twitchWebToken != nil {
                Task { @MainActor [weak self] in await self?.validateWebSession() }
            }
        }
    }

    /// Token de session web (cookie `auth-token` de twitch.tv).
    /// Distinct de `twitchToken` (OAuth/Helix) : indispensable pour l'API GQL
    /// « community points » (solde, coffres, rachats), qui rejette les tokens OAuth custom.
    @Published var twitchWebToken: String? {
        didSet {
            Keychain.storeToken(twitchWebToken, for: "twitch_web_token")
            // Session partie (déconnexion, refus, expiration) : ses catégories
            // suivies ne protègent plus rien du masquage.
            if twitchWebToken == nil { accountFollowedCategoryIds = [] }
        }
    }

    /// La session web a été rejetée par Twitch : elle a été effacée, il faut
    /// se reconnecter. Distinct de « absente » — on ne veut pas harceler
    /// quelqu'un qui ne s'en est jamais servi.
    @Published var webSessionExpired = false

    /// Pseudo du compte d'une session web refusée parce qu'elle n'était pas au
    /// compte de l'app (nil sinon). Les points, drops et prédictions seraient
    /// partis sur un autre compte que les suivis et le chat.
    @Published var webSessionMismatch: String? = nil

    /// Vérifie la session web : effacée si Twitch la refuse, ou si elle est à
    /// un autre compte que celui de l'app. Une panne réseau ne l'efface pas :
    /// couper la session sur un wifi capricieux serait pire que de la laisser
    /// mourir en silence.
    @MainActor
    func validateWebSession() async {
        guard let token = twitchWebToken, !token.isEmpty else { return }
        switch await webSessionIdentity(token: token) {
        case .unknown:
            break
        case .invalid:
            twitchWebToken = nil
            webSessionExpired = true
        case .valid(let id, let login):
            webSessionExpired = false
            if let mine = twitchUserId, !mine.isEmpty, id != mine {
                await refuseWebSession(of: login)
            }
        }
    }

    /// Session web obtenue par la connexion twitch.tv (accueil, réglages,
    /// points). Refusée si elle n'est pas au compte de l'app.
    /// - Returns: false si refusée.
    @MainActor
    @discardableResult
    func adoptWebToken(_ token: String, login webLogin: String?) async -> Bool {
        if let mine = twitchLogin?.lowercased(), !mine.isEmpty,
           let web = webLogin?.lowercased(), !web.isEmpty, web != mine {
            await refuseWebSession(of: webLogin ?? web)
            return false
        }
        if twitchLogin == nil, let l = webLogin { twitchLogin = l }
        webSessionMismatch = nil
        webSessionExpired = false
        twitchWebToken = token
        // Pseudo absent du cookie : vérifié par identifiant.
        if webLogin == nil { await validateWebSession() }
        return twitchWebToken != nil
    }

    /// Session web d'un autre compte : effacée (jeton et cookies twitch.tv),
    /// pour que la prochaine connexion demande le bon compte.
    @MainActor
    private func refuseWebSession(of login: String) async {
        logger.warn("AUTH/WEB", "Session web d'un autre compte refusée",
                    "@\(login) ≠ @\(twitchLogin ?? "?") (compte de l'app)")
        webSessionMismatch = login
        twitchWebToken = nil
        DropsHeartbeat.shared.stop()
        await TwitchWebSession.clear()
    }

    /// Photo de profil du compte connecté, affichée dans l'en-tête.
    @Published var twitchAvatar: String? {
        didSet {
            if let a = twitchAvatar { UserDefaults.standard.set(a, forKey: "twitch_avatar") }
            else { UserDefaults.standard.removeObject(forKey: "twitch_avatar") }
        }
    }

    /// Login IRC (ex: "squeezie") — indispensable pour envoyer des messages en chat
    @Published var twitchLogin: String? {
        didSet {
            if let l = twitchLogin { UserDefaults.standard.set(l, forKey: "twitch_login") }
            else { UserDefaults.standard.removeObject(forKey: "twitch_login") }
        }
    }

    // MARK: – Points
    /// Réclamer automatiquement les coffres bonus dès qu'ils sont disponibles.
    @Published var autoClaimChest: Bool = true {
        didSet { UserDefaults.standard.set(autoClaimChest, forKey: "auto_claim_chest") }
    }

    // MARK: – Personnalisation chat / lecteur
    /// Afficher le bandeau des messages épinglés.
    @Published var showPinnedMessages: Bool = true {
        didSet { UserDefaults.standard.set(showPinnedMessages, forKey: "cfg_pinned") }
    }
    /// Carte « Drops » en haut du chat quand la chaîne a des drops.
    @Published var showDropsNotice: Bool = true {
        didSet { UserDefaults.standard.set(showDropsNotice, forKey: "cfg_drops_notice") }
    }
    /// Afficher le bouton Suivre / Ne plus suivre.
    @Published var showFollowButton: Bool = true {
        didSet { UserDefaults.standard.set(showFollowButton, forKey: "cfg_follow") }
    }
    /// Afficher le badge de série de visionnage (streak).
    @Published var showWatchStreak: Bool = true {
        didSet { UserDefaults.standard.set(showWatchStreak, forKey: "cfg_streak") }
    }
    /// Afficher les événements live (sondages, prédictions, hype train).
    @Published var showLiveEvents: Bool = true {
        didSet { UserDefaults.standard.set(showLiveEvents, forKey: "cfg_events") }
    }
    /// Activer la détection des raids (bannière + auto-rejoindre).
    @Published var enableRaids: Bool = true {
        didSet { UserDefaults.standard.set(enableRaids, forKey: "cfg_raids") }
    }
    /// En paysage, bandeaux du chat (épinglé, drops, sondages, prédictions,
    /// raid) repliés en une ligne d'icônes au-dessus des messages.
    @Published var landscapeNoticesHidden: Bool = false {
        didSet { UserDefaults.standard.set(landscapeNoticesHidden, forKey: "cfg_land_notices_hidden") }
    }
    /// Vider le cache des emotes/badges en quittant le live (et l'app).
    @Published var autoPurgeImageCache: Bool = true {
        didSet { UserDefaults.standard.set(autoPurgeImageCache, forKey: "cfg_purge_cache") }
    }

    // MARK: – Lecteur
    /// Mode faible latence : demande le flux « low latency » à Twitch et garde
    /// la lecture au plus près du direct.
    @Published var lowLatency: Bool = false {
        didSet { UserDefaults.standard.set(lowLatency, forKey: "cfg_low_latency") }
    }

    /// Vitesse de lecture des VODs (pas des directs, ni des clips qui partent
    /// à 1×), gardée d'une VOD à l'autre. Seule source de vérité : une vitesse
    /// imposée par le lecteur (refus, AirPlay, bord du DVR rattrapé) y est
    /// réécrite. Même nom que le site dans la sauvegarde (« vodSpeed »).
    @Published var vodSpeed: Double = 1 {
        didSet { UserDefaults.standard.set(vodSpeed, forKey: "cfg_vod_speed") }
    }

    /// Qualité préférée au lancement d'un direct, d'une VOD ou d'un clip
    /// (`kQualityPrefs` : « source », une hauteur, « audio ») ; si elle
    /// manque, la plus proche en dessous (preferredQualityKey). Une qualité
    /// choisie dans le lecteur la remplace, comme sur le site. Même nom que
    /// le site dans la sauvegarde (« qualityPref »).
    @Published var preferredQuality: String = "source" {
        didSet { UserDefaults.standard.set(preferredQuality, forKey: "cfg_quality_pref") }
    }
    /// Audio seul préféré : ce que retenaient les versions d'avant (gardé
    /// dans la sauvegarde pour elles).
    var preferAudioOnly: Bool { preferredQuality == "audio" }
    /// Qualité choisie à la main dans le lecteur : elle devient la préférence
    /// (« Auto » ne change rien, l'app ne le propose pas en réglage).
    func rememberQualityChoice(_ q: String, among keys: [String], variants: [String: VariantInfo] = [:]) {
        guard let pref = qualityPreference(for: q, among: keys, variants: variants),
              pref != preferredQuality else { return }
        preferredQuality = pref
        logger.settingChanged("Qualité préférée", value: pref)
    }

    /// Multi-live : le chat du direct qui a le son, à droite de la mosaïque
    /// (écran assez large : iPad, grand iPhone en paysage).
    @Published var multiLiveChat: Bool = true {
        didSet { UserDefaults.standard.set(multiLiveChat, forKey: "cfg_multi_chat") }
    }

    /// Lecteur immersif : commandes par-dessus l'image, comme sur Twitch.
    /// Désactivé = lecteur natif Apple (PiP et plein écran système).
    /// Activé par défaut : c'est le lecteur de l'app, le natif est le repli.
    @Published var immersivePlayer: Bool = true {
        didSet { UserDefaults.standard.set(immersivePlayer, forKey: "cfg_immersive") }
    }

    /// Ordre des sources du direct (« as », « al », « eu », « twitch ») :
    /// getLive les essaie l'une après l'autre (liveSourceSteps, même clé).
    @Published var liveSourceOrder: [String] = kLiveSources {
        didSet { UserDefaults.standard.set(liveSourceOrder, forKey: "liveSourceOrder") }
    }

    /// Monte (−1) ou descend (+1) une source d'un cran.
    func moveLiveSource(_ id: String, by delta: Int) {
        guard let i = liveSourceOrder.firstIndex(of: id), liveSourceOrder.indices.contains(i + delta) else { return }
        liveSourceOrder.swapAt(i, i + delta)
    }

    /// En tête de l'ordre (choisie dans le menu du lecteur).
    func preferLiveSource(_ id: String) {
        liveSourceOrder = [id] + liveSourceOrder.filter { $0 != id }
    }

    /// Audio spatial (AirPods) : « auto » = choix d'iOS (Centre de contrôle),
    /// « off » = jamais spatialisé dans l'app (voir SpatialAudio).
    /// Drops : pendant un live qui en a, la session du compte charge le flux
    /// (voir DropsHeartbeat) ; sans ça, Twitch ne compte rien.
    @Published var dropsProgress: Bool = true {
        didSet { UserDefaults.standard.set(dropsProgress, forKey: "cfg_drops_progress") }
    }

    /// Drops terminés réclamés automatiquement (lu aussi par DropsHeartbeat).
    @Published var autoClaimDrops: Bool = true {
        didSet { UserDefaults.standard.set(autoClaimDrops, forKey: "cfg_drops_autoclaim") }
    }

    /// Notification quand un drop est prêt ou réclamé (lu par DropsService).
    @Published var dropsNotify: Bool = true {
        didSet { UserDefaults.standard.set(dropsNotify, forKey: "cfg_drops_notify") }
    }

    @Published var spatialAudio: String = "auto" {
        didSet {
            UserDefaults.standard.set(spatialAudio, forKey: SpatialAudio.key)
            if spatialAudio != oldValue {
                NotificationCenter.default.post(name: .tuSpatialAudioChanged, object: nil)
            }
        }
    }

    /// Recadrer la vidéo pour remplir l'écran, au lieu de laisser des bandes
    /// noires. Coupe le haut et le bas : du 16:9 dans un écran de téléphone en
    /// paysage (≈2.16) ne peut pas à la fois tout montrer et tout remplir.
    @Published var fillScreen: Bool = false {
        didSet { UserDefaults.standard.set(fillScreen, forKey: "cfg_fill_screen") }
    }

    /// Place du chat en paysage : colonne, superposé à l'image, ou replié.
    /// Mémorisé, parce qu'on choisit ça une fois puis on n'y revient plus.
    @Published var landscapeChat: LandscapeChat = .column {
        didSet {
            UserDefaults.standard.set(landscapeChat.rawValue, forKey: "cfg_landscape_chat")
            if landscapeChat != .hidden { lastShownLandscapeChat = landscapeChat }
        }
    }
    /// Dernière façon d'afficher le chat en paysage : le double-tap la remet.
    private(set) var lastShownLandscapeChat: LandscapeChat = .column

    /// Chat affiché ↔ masqué en paysage (double-tap sur un direct) ; rend le
    /// nouvel état.
    @discardableResult
    func toggleLandscapeChatVisibility() -> LandscapeChat {
        landscapeChat = landscapeChat == .hidden ? lastShownLandscapeChat : .hidden
        return landscapeChat
    }

    // MARK: – Apparence du chat
    // La bonne taille dépend de l'écran, de la distance de lecture et de la vue
    // de chacun : autant la laisser se régler plutôt que d'en imposer une.
    @Published var chatFontSize: Double = 13 {
        didSet { UserDefaults.standard.set(chatFontSize, forKey: "cfg_chat_font") }
    }
    /// Espace vertical entre deux messages, en points. Chaque message en porte
    /// la moitié en haut et en bas : 8 reproduit l'aspect d'origine.
    @Published var chatSpacing: Double = 8 {
        didSet { UserDefaults.standard.set(chatSpacing, forKey: "cfg_chat_spacing") }
    }
    @Published var chatBadgeScale: Double = 1 {
        didSet { UserDefaults.standard.set(chatBadgeScale, forKey: "cfg_chat_badge") }
    }
    @Published var chatEmoteScale: Double = 1 {
        didSet { UserDefaults.standard.set(chatEmoteScale, forKey: "cfg_chat_emote") }
    }
    @Published var chatTimestamps: Bool = true {
        didSet { UserDefaults.standard.set(chatTimestamps, forKey: "cfg_chat_time") }
    }
    /// Part de la largeur prise par le chat en paysage (colonne ou calque).
    @Published var chatWidthRatio: Double = 0.32 {
        didSet { UserDefaults.standard.set(chatWidthRatio, forKey: "cfg_chat_width") }
    }

    // MARK: – Comportement du chat
    /// Charger les derniers messages du canal à l'arrivée (API tierce
    /// recent-messages.robotty.de : Twitch n'envoie rien d'antérieur au JOIN).
    @Published var chatLoadRecent: Bool = true {
        didSet { UserDefaults.standard.set(chatLoadRecent, forKey: "cfg_chat_recent") }
    }
    /// Proposer emotes et pseudos pendant la frappe.
    @Published var chatAutocomplete: Bool = true {
        didSet { UserDefaults.standard.set(chatAutocomplete, forKey: "cfg_chat_autocomplete") }
    }
    /// Garder les messages supprimés, barrés, au lieu de les faire disparaître.
    @Published var chatShowDeleted: Bool = false {
        didSet { UserDefaults.standard.set(chatShowDeleted, forKey: "cfg_chat_deleted") }
    }

    /// Construit la présentation du chat : les réglages de l'utilisateur pour la
    /// taille, la disposition en cours pour le décor et la transparence.
    func chatStyle(chrome: Bool, translucent: Bool) -> ChatStyle {
        ChatStyle(showsChrome: chrome,
                  showsTimestamp: chatTimestamps,
                  fontSize: CGFloat(chatFontSize),
                  rowPadding: CGFloat(chatSpacing) / 2,
                  badgeScale: CGFloat(chatBadgeScale),
                  emoteScale: CGFloat(chatEmoteScale),
                  translucent: translucent)
    }

    // MARK: – Comptage d'utilisation
    /// Signaler anonymement que cette installation est active.
    /// Voir Sources/Services/UsageService.swift pour ce qui part réellement.
    @Published var shareUsage: Bool = true {
        didSet { UserDefaults.standard.set(shareUsage, forKey: "cfg_share_usage") }
    }

    /// Chaîne à ouvrir dans l'onglet Recherche (depuis le lecteur, l'accueil…).
    /// L'onglet la consomme puis la remet à nil.
    @Published var pendingChannel: String? = nil
    func openChannelPage(_ login: String) {
        let l = login.trimmingCharacters(in: .whitespaces).lowercased()
        guard !l.isEmpty else { return }
        pendingChannel = l
    }

    /// Catégories suivies sur cet appareil (id, nom, jaquette).
    @Published var followedCategories: [TwitchCategory] = [] {
        didSet {
            let list = followedCategories.map { ["id": $0.id, "name": $0.name, "box": $0.boxArtURL] }
            UserDefaults.standard.set(list, forKey: "followed_categories")
        }
    }
    func isCategoryFollowed(_ id: String) -> Bool { followedCategories.contains { $0.id == id } }
    func toggleCategoryFollow(_ c: TwitchCategory) {
        if let i = followedCategories.firstIndex(where: { $0.id == c.id }) { followedCategories.remove(at: i) }
        else {
            followedCategories.insert(TwitchCategory(id: c.id, name: c.name, boxArtURL: c.boxArtURL), at: 0)
            // Suivre une catégorie masquée la réaffiche.
            if hidden.hides(category: c.id) { hidden.unhide(category: c.id) }
        }
    }

    /// Chaînes suivies par le compte Twitch, telles que lues par l'accueil
    /// (non enregistrées) : l'export les ajoute aux suivis de l'appareil.
    var accountFollowLogins: [String] = []
    /// Catégories suivies sur Twitch (session web), telles que lues par
    /// l'accueil et l'onglet Catégories (non enregistrées) : jamais masquées.
    /// Vidées quand la session web disparaît.
    var accountFollowedCategoryIds: Set<String> = []

    /// Chaînes suivies sans compte Twitch (sur cet appareil), en minuscules.
    @Published var localFollows: [String] = [] {
        didSet { UserDefaults.standard.set(localFollows, forKey: "local_follows") }
    }
    func isLocallyFollowed(_ login: String) -> Bool { localFollows.contains(login.lowercased()) }
    func toggleLocalFollow(_ login: String) {
        let l = login.lowercased()
        if let i = localFollows.firstIndex(of: l) { localFollows.remove(at: i) }
        else if !l.isEmpty {
            localFollows.insert(l, at: 0)
            unhideChannel(l)
        }
    }

    /// Streamers épinglés (en minuscules) : en tête des suivis, en live comme
    /// hors ligne, dans l'ordre où on les a épinglés. Sur cet appareil.
    @Published var pinnedStreamers: [String] = [] {
        didSet { UserDefaults.standard.set(pinnedStreamers, forKey: "pinned_streamers") }
    }
    func isPinned(_ login: String) -> Bool { pinnedStreamers.contains(login.lowercased()) }
    /// Rang d'épinglage, nil si la chaîne n'est pas épinglée.
    func pinRank(_ login: String) -> Int? { pinnedStreamers.firstIndex(of: login.lowercased()) }
    func togglePin(_ login: String) {
        let l = login.lowercased()
        if let i = pinnedStreamers.firstIndex(of: l) { pinnedStreamers.remove(at: i) }
        else if !l.isEmpty { pinnedStreamers.append(l) }
    }

    // MARK: – Chaînes et catégories masquées (découverte)
    /// Masquées du top, de la grille des catégories et des lives d'une
    /// catégorie ; la recherche et les pages ouvertes directement montrent
    /// tout. Sur cet appareil, dans la sauvegarde (clé « hidden »).
    @Published var hidden = HiddenContent.load() {
        didSet { if hidden != oldValue { hidden.save() } }
    }

    /// Chaîne suivie (compte ou appareil) ou épinglée : jamais masquée.
    func isFollowedOrPinned(_ login: String) -> Bool {
        let l = login.lowercased()
        return isLocallyFollowed(l) || isPinned(l) || accountFollowLogins.contains(l)
    }
    /// Catégorie suivie, sur cet appareil ou sur Twitch : jamais masquée.
    func followsCategory(_ id: String) -> Bool {
        !id.isEmpty && (isCategoryFollowed(id) || accountFollowedCategoryIds.contains(id))
    }
    /// La chaîne passe le filtre, quelle que soit sa catégorie (lives d'une
    /// catégorie ouverte : elle est consultable même masquée).
    func showsChannel(_ login: String) -> Bool {
        isFollowedOrPinned(login) || !hidden.hides(channel: login)
    }
    /// Un live du top : ni sa chaîne ni sa catégorie ne sont masquées, sauf
    /// si on suit l'une ou l'autre.
    func showsStream(_ s: TwitchStream) -> Bool {
        isFollowedOrPinned(s.userLogin)
            || (!hidden.hides(channel: s.userLogin) && (followsCategory(s.gameId) || !hidden.hides(category: s.gameId)))
    }
    /// Une carte de la grille « Toutes » des catégories.
    func showsCategory(_ c: TwitchCategory) -> Bool {
        followsCategory(c.id) || !hidden.hides(category: c.id)
    }

    func hideChannel(login: String, name: String) {
        guard !isFollowedOrPinned(login) else { return }
        hidden.hide(channel: login, name: name)
        logger.info("MASQUÉS", "Chaîne masquée @\(login.lowercased())", nil)
    }
    func hideCategory(id: String, name: String, box: String) {
        guard !followsCategory(id) else { return }
        hidden.hide(category: id, name: name, box: box)
        logger.info("MASQUÉS", "Catégorie masquée \(id) (\(name))", nil)
    }
    func unhideChannel(_ login: String) {
        guard hidden.hides(channel: login) else { return }
        hidden.unhide(channel: login)
    }
    func unhideCategory(_ id: String) {
        guard hidden.hides(category: id) else { return }
        hidden.unhide(category: id)
    }
    func unhideAll() {
        hidden.unhideAll()
        logger.info("MASQUÉS", "Tout réaffiché", nil)
    }

    /// Accueil : chaînes en grille (cartes) ou en liste (façon Twitch).
    @Published var homeListLayout: Bool = false {
        didSet { UserDefaults.standard.set(homeListLayout, forKey: "cfg_home_list") }
    }
    /// Recherche : raccourcis vers les dernières chaînes ouvertes.
    @Published var showRecentChannels: Bool = true {
        didSet { UserDefaults.standard.set(showRecentChannels, forKey: "cfg_recent") }
    }

    /// Langue du top des lives ; nil = celle de l'appareil.
    @Published var topLang: String? = nil {
        didSet { UserDefaults.standard.set(topLang, forKey: "cfg_top_lang") }
    }

    /// Langue des lives dans les catégories (« fr »…) ; nil = toutes. La
    /// même pour toutes les catégories.
    @Published var categoryLang: String? = nil {
        didSet { UserDefaults.standard.set(categoryLang, forKey: "cfg_category_lang") }
    }

    // MARK: – Apparence
    /// Couleur d'accent, fond, verre liquide : voir Theme.swift. La palette
    /// partagée est remplacée aussitôt, les vues suivent.
    @Published var accent: AccentTheme = Theme.storedAccent {
        didSet {
            UserDefaults.standard.set(accent.rawValue, forKey: Theme.accentKey)
            Theme.palette = Palette(accent: accent, background: background)
        }
    }
    @Published var background: BackgroundTheme = Theme.storedBackground {
        didSet {
            UserDefaults.standard.set(background.rawValue, forKey: Theme.backgroundKey)
            Theme.palette = Palette(accent: accent, background: background)
        }
    }
    @Published var liquidGlass: Bool = Theme.liquidGlass {
        didSet {
            UserDefaults.standard.set(liquidGlass, forKey: Theme.glassKey)
            Theme.liquidGlass = liquidGlass
        }
    }
    /// Change avec le thème : MainTabView reconstruit les onglets dessus.
    var themeID: String { "\(accent.rawValue)-\(background.rawValue)-\(liquidGlass)" }

    // MARK: – Débogage (section temporaire)
    /// Afficher la latence du direct par-dessus le lecteur.
    @Published var showLatency: Bool = false {
        didSet { UserDefaults.standard.set(showLatency, forKey: "dbg_latency") }
    }
    /// Retarder le chat de la latence mesurée, pour qu'il colle à l'image.
    @Published var autoChatDelay: Bool = false {
        didSet { UserDefaults.standard.set(autoChatDelay, forKey: "dbg_chat_delay") }
    }
    /// VODs récentes : remettre le son des passages coupés par Twitch quand
    /// l'original est encore sur le CDN (VodUnmuteLoader).
    @Published var restoreMutedAudio: Bool = true {
        didSet { UserDefaults.standard.set(restoreMutedAudio, forKey: "cfg_restore_muted") }
    }
    /// Retouche de la synchro auto, en secondes (+ = chat plus tard). Le bon
    /// décalage dépend aussi du retard des autres spectateurs, qu'on ne peut
    /// qu'estimer : on laisse corriger d'une seconde ou deux.
    @Published var chatSyncNudge: Double = 0 {
        didSet { UserDefaults.standard.set(chatSyncNudge, forKey: "chat_sync_nudge") }
    }

    // MARK: – History
    @Published var history: [HistoryItem] = [] {
        didSet { persistHistory(); syncDirty = true }
    }

    // MARK: – VOD Progress
    @Published private(set) var vodProgress: [String: Double] = [:]

    // MARK: – Filtres du chat
    @Published var chatHideBots = false {
        didSet { UserDefaults.standard.set(chatHideBots, forKey: "chat_hide_bots") }
    }
    @Published var chatHideCommands = false {
        didSet { UserDefaults.standard.set(chatHideCommands, forKey: "chat_hide_commands") }
    }
    /// Mots masqués (minuscules) : les messages qui les contiennent disparaissent.
    @Published var chatMutedWords: [String] = [] {
        didSet { UserDefaults.standard.set(chatMutedWords, forKey: "chat_muted_words") }
    }
    /// Personnes masquées (logins en minuscules).
    @Published var chatBlockedUsers: [String] = [] {
        didSet { UserDefaults.standard.set(chatBlockedUsers, forKey: "chat_blocked_users") }
    }

    static let knownBots: Set<String> = ["nightbot", "streamelements", "moobot", "fossabot", "streamlabs",
        "wizebot", "soundalerts", "sery_bot", "botisimo", "own3d", "kofistreambot",
        "pokemoncommunitygame", "deepbot", "coebot", "phantombot", "creatisbot", "blerp"]

    /// Vrai si le message doit être masqué (réglages de filtres).
    func isChatFiltered(_ m: ChatMessage) -> Bool {
        let login = m.userName.lowercased()
        guard !login.isEmpty, m.userId != "system" else { return false }
        if login == twitchLogin?.lowercased() { return false }
        if chatBlockedUsers.contains(login) { return true }
        if chatHideBots && Self.knownBots.contains(login) { return true }
        guard chatHideCommands || !chatMutedWords.isEmpty else { return false }
        let text = m.tokens.map { t -> String in
            switch t {
            case .text(let s), .link(let s): return s
            case .mention(let s): return "@" + s
            case .emote(let e): return e.name
            }
        }.joined(separator: " ")
        if chatHideCommands && text.hasPrefix("!") { return true }
        let low = text.lowercased()
        return chatMutedWords.contains { low.contains($0) }
    }

    func toggleBlocked(_ login: String) {
        let l = login.lowercased()
        if let i = chatBlockedUsers.firstIndex(of: l) { chatBlockedUsers.remove(at: i) }
        else { chatBlockedUsers = Array((chatBlockedUsers + [l]).suffix(500)) }
    }

    /// Mots surlignés dans le chat (en plus des mentions), en minuscules.
    @Published var chatHighlightWords: [String] = [] {
        didSet { UserDefaults.standard.set(chatHighlightWords, forKey: "chat_highlight_words") }
    }

    // MARK: – Init
    init() {
        let ud = UserDefaults.standard
        chatHighlightWords = ud.stringArray(forKey: "chat_highlight_words") ?? []
        chatHideBots       = ud.bool(forKey: "chat_hide_bots")
        chatHideCommands   = ud.bool(forKey: "chat_hide_commands")
        chatMutedWords     = ud.stringArray(forKey: "chat_muted_words") ?? []
        chatBlockedUsers   = ud.stringArray(forKey: "chat_blocked_users") ?? []
        if let l = ud.string(forKey: "lang"), let parsed = Lang(rawValue: l) { lang = parsed }
        twitchToken = Keychain.loadToken("twitch_token")
        twitchUserId = ud.string(forKey: "twitch_user_id")
        twitchWebToken = Keychain.loadToken("twitch_web_token")
        twitchLogin = ud.string(forKey: "twitch_login")
        twitchAvatar = ud.string(forKey: "twitch_avatar")
        autoClaimChest = ud.object(forKey: "auto_claim_chest") as? Bool ?? true
        showPinnedMessages = ud.object(forKey: "cfg_pinned") as? Bool ?? true
        showDropsNotice    = ud.object(forKey: "cfg_drops_notice") as? Bool ?? true
        showFollowButton   = ud.object(forKey: "cfg_follow") as? Bool ?? true
        showWatchStreak    = ud.object(forKey: "cfg_streak") as? Bool ?? true
        showLiveEvents     = ud.object(forKey: "cfg_events") as? Bool ?? true
        enableRaids        = ud.object(forKey: "cfg_raids")  as? Bool ?? true
        landscapeNoticesHidden = ud.bool(forKey: "cfg_land_notices_hidden")
        autoPurgeImageCache = ud.object(forKey: "cfg_purge_cache") as? Bool ?? true
        // Actif par défaut depuis la 1.2.21 (direct à quelques secondes au lieu
        // d'une vingtaine) ; qui l'a coupé à la main le garde coupé.
        lowLatency         = ud.object(forKey: "cfg_low_latency") as? Bool ?? true
        vodSpeed           = VodSpeed.nearest(ud.object(forKey: "cfg_vod_speed") as? Double ?? 1)
        multiLiveChat      = ud.object(forKey: "cfg_multi_chat") as? Bool ?? true
        immersivePlayer    = ud.object(forKey: "cfg_immersive")   as? Bool ?? true
        // Ordre des sources ; avant lui, une seule source préférée
        // (« liveSource »), mise en tête. Réécrit pour getLive.
        liveSourceOrder    = liveSourceSteps().filter { $0 != "worker" }
        ud.set(liveSourceOrder, forKey: "liveSourceOrder")
        spatialAudio       = ud.string(forKey: SpatialAudio.key) == "off" ? "off" : "auto"
        dropsProgress      = ud.object(forKey: "cfg_drops_progress")  as? Bool ?? true
        autoClaimDrops     = ud.object(forKey: "cfg_drops_autoclaim") as? Bool ?? true
        dropsNotify        = ud.object(forKey: "cfg_drops_notify")    as? Bool ?? true
        fillScreen         = ud.object(forKey: "cfg_fill_screen") as? Bool ?? false
        landscapeChat      = LandscapeChat(rawValue: ud.string(forKey: "cfg_landscape_chat") ?? "")
                             ?? .column
        if landscapeChat != .hidden { lastShownLandscapeChat = landscapeChat }
        chatFontSize       = ud.object(forKey: "cfg_chat_font")    as? Double ?? 13
        chatSpacing        = ud.object(forKey: "cfg_chat_spacing") as? Double ?? 8
        chatBadgeScale     = ud.object(forKey: "cfg_chat_badge")   as? Double ?? 1
        chatEmoteScale     = ud.object(forKey: "cfg_chat_emote")   as? Double ?? 1
        chatTimestamps     = ud.object(forKey: "cfg_chat_time")    as? Bool   ?? true
        chatWidthRatio     = ud.object(forKey: "cfg_chat_width")   as? Double ?? 0.32
        chatLoadRecent     = ud.object(forKey: "cfg_chat_recent")       as? Bool ?? true
        chatAutocomplete   = ud.object(forKey: "cfg_chat_autocomplete") as? Bool ?? true
        chatShowDeleted    = ud.object(forKey: "cfg_chat_deleted")      as? Bool ?? false
        shareUsage         = ud.object(forKey: "cfg_share_usage") as? Bool ?? true
        topLang            = ud.string(forKey: "cfg_top_lang")
        categoryLang       = ud.string(forKey: "cfg_category_lang").flatMap { TopLanguage.codes.contains($0) ? $0 : nil }
        localFollows       = ud.stringArray(forKey: "local_follows") ?? []
        pinnedStreamers    = ud.stringArray(forKey: "pinned_streamers") ?? []
        followedCategories = (ud.array(forKey: "followed_categories") as? [[String: String]] ?? []).compactMap { d in
            guard let id = d["id"] else { return nil }
            return TwitchCategory(id: id, name: d["name"] ?? "", boxArtURL: d["box"] ?? "")
        }
        // Le tutoriel est pour le tout premier lancement : une installation qui
        // a déjà servi (mise à jour) ne le voit pas.
        if ud.object(forKey: "onboarding_done") == nil && ud.integer(forKey: "launch_count") > 0 {
            ud.set(true, forKey: "onboarding_done")
        }
        homeListLayout     = ud.bool(forKey: "cfg_home_list")
        showRecentChannels = ud.object(forKey: "cfg_recent") as? Bool ?? true
        // Qualité préférée ; avant elle, seul l'audio seul était retenu.
        if let pref = ud.string(forKey: "cfg_quality_pref"), kQualityPrefs.contains(pref) {
            preferredQuality = pref
        } else {
            preferredQuality = ud.bool(forKey: "cfg_audio_only") ? "audio" : "source"
            ud.set(preferredQuality, forKey: "cfg_quality_pref")
        }
        showLatency        = ud.object(forKey: "dbg_latency")    as? Bool ?? false
        autoChatDelay      = ud.object(forKey: "dbg_chat_delay") as? Bool ?? false
        chatSyncNudge      = ud.double(forKey: "chat_sync_nudge")
        restoreMutedAudio  = ud.object(forKey: "cfg_restore_muted") as? Bool ?? true
        if let data = ud.data(forKey: "twitch_vod_history"),
           let decoded = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            history = decoded
        }
        if let data = ud.data(forKey: "vod_progress_all"),
           let decoded = try? JSONDecoder().decode([String: Double].self, from: data) {
            vodProgress = decoded
        }
        // Le chargement initial n'est pas un changement à envoyer.
        syncDirty = false
        // Filet de sécurité pendant une longue lecture : au plus un envoi par
        // `syncEvery`, et seulement s'il y a du neuf.
        syncTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flushToCloud() }
        }
    }

    // MARK: – Translation
    func t(_ key: String) -> String { translate(key, lang) }

    // MARK: – Auth
    /// Nouveau jeton après une connexion. S'il change, l'identité gardée
    /// (id, pseudo, avatar) est oubliée : sinon, en se connectant à un autre
    /// compte, le nouveau jeton partait avec l'ancien id — sauvegarde et chat
    /// visaient le mauvais compte.
    func adoptToken(_ token: String) {
        if token != twitchToken {
            twitchUserId = nil
            twitchLogin  = nil
            twitchAvatar = nil
        }
        let isNew = token != twitchToken
        twitchToken = token
        // Compté tout de suite comme compte, sans attendre l'heure suivante :
        // le Worker reprend l'historique anonyme de l'appareil et l'efface.
        if isNew {
            let enabled = shareUsage
            Task { await UsageService.shared.ping(enabled: enabled, force: true) }
        }
    }

    func logout() {
        twitchToken    = nil
        twitchWebToken = nil
        webSessionMismatch = nil
        Task { await TwitchWebSession.clear() }
        twitchUserId   = nil
        twitchLogin    = nil   // ← nettoyage complet
        twitchAvatar   = nil
        // La prochaine connexion demandera le compte au lieu de reprendre
        // celui dont Safari se souvient (TwitchAuthManager).
        UserDefaults.standard.set(true, forKey: TwitchAuthManager.privateSessionKey)
    }

    // MARK: – History management
    func saveToHistory(_ item: HistoryItem) {
        var filtered = history.filter { $0.term.lowercased() != item.term.lowercased() }
        filtered.insert(item, at: 0)
        // 50 : l'historique mélange chaînes et VODs, 20 faisait disparaître les
        // VODs vues dès qu'on enchaînait quelques recherches de streamers.
        history = Array(filtered.prefix(50))
    }

    func removeFromHistory(term: String) {
        history.removeAll { $0.term == term }
    }

    func clearChannelHistory() {
        history = history.filter { $0.type == .vod }
    }

    private func persistHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: "twitch_vod_history")
        }
    }

    // MARK: – VOD progress
    func getVodProgress(_ vodId: String) -> Double { vodProgress[vodId] ?? 0 }

    func setVodProgress(_ vodId: String, time: Double) {
        // Le lecteur appelle ceci toutes les 0,5 s : chaque appel réencodait
        // tout le dictionnaire dans UserDefaults et republiait le store (donc
        // redessinait l'interface). Écart de 5 s minimum, sauf saut (reprise
        // DVR, retour au début).
        if let old = vodProgress[vodId], abs(time - old) < 5 { return }
        vodProgress[vodId] = time
        // Borné aux 500 VODs les plus récentes (identifiants croissants).
        if vodProgress.count > 500 {
            let keep = Set(vodProgress.keys.sorted { (Int($0) ?? 0) > (Int($1) ?? 0) }.prefix(500))
            vodProgress = vodProgress.filter { keep.contains($0.key) }
        }
        persistProgress()
        syncDirty = true
    }

    private func persistProgress() {
        if let data = try? JSONEncoder().encode(vodProgress) {
            UserDefaults.standard.set(data, forKey: "vod_progress_all")
        }
    }

    // MARK: – Cloud Sync
    //
    // Sauvegarde partagée avec le site, sur le Worker (KV Cloudflare). Le KV
    // gratuit n'offre que 1 000 écritures par jour au total : un changement
    // ne fait que marquer la sauvegarde « à envoyer », et l'envoi part à la
    // fermeture d'une vidéo, au passage en arrière-plan, sinon au plus toutes
    // les 10 minutes — jamais si rien n'a changé depuis le dernier envoi.

    private var syncDirty = false
    private var lastSyncedBody: Data?
    private var lastSyncAt  = Date.distantPast
    private var lastPullAt  = Date.distantPast
    private var syncTimer: Timer?
    private let syncEvery: TimeInterval = 600
    private let pullEvery: TimeInterval = 600

    /// Relit la sauvegarde si la dernière lecture date de plus de 10 minutes.
    /// Une lecture ne coûte presque rien (100 000 par jour en gratuit).
    func refreshFromCloudIfStale(userId: String? = nil) async {
        guard let id = userId ?? twitchUserId, !id.isEmpty,
              Date().timeIntervalSince(lastPullAt) > pullEvery else { return }
        await pullFromCloud(userId: id)
    }

    func pullFromCloud(userId: String) async {
        lastPullAt = Date()
        // Le Worker exige le jeton Twitch du propriétaire de la sauvegarde.
        guard let token = twitchToken,
              let url = URL(string: "\(APIConfig.base)/api/sync/get?userId=\(userId)") else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: request),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        var remote: [HistoryItem] = []
        if let raw = json["history"],
           let histData = try? JSONSerialization.data(withJSONObject: raw),
           let items = try? JSONDecoder().decode([LossyDecodable<HistoryItem>].self, from: histData) {
            remote = items.compactMap(\.value)
        }
        var remoteProgress: [String: Double] = [:]
        for (id, value) in json["progress"] as? [String: Any] ?? [:] {
            // Borné : une valeur aberrante venue du serveur faisait planter
            // la conversion en Int de la bibliothèque.
            if let n = value as? NSNumber, n.doubleValue.isFinite, n.doubleValue > 0 {
                remoteProgress[id] = min(n.doubleValue, 7 * 24 * 3600)
            }
        }

        await MainActor.run {
            // Fusion, pas remplacement : ce qui a été vu ici depuis le dernier
            // envoi ne doit pas disparaître. Le plus récent d'abord ; les
            // éléments sans date (anciens, venus du site) en fin de liste.
            let known = Set(history.map { $0.term.lowercased() })
            let added = remote.filter { !known.contains($0.term.lowercased()) }
            if !added.isEmpty {
                let merged = (history + added).enumerated()
                    .sorted { a, b in
                        a.element.addedAt != b.element.addedAt
                            ? a.element.addedAt > b.element.addedAt
                            : a.offset < b.offset
                    }
                    .map(\.element)
                history = Array(merged.prefix(50))
            }
            // Progression : la position la plus avancée l'emporte.
            var changed = false
            for (id, t) in remoteProgress where t > (vodProgress[id] ?? 0) {
                vodProgress[id] = t
                changed = true
            }
            if changed { persistProgress() }
            logger.syncPull(items: added.count)
        }
    }

    /// Envoie la sauvegarde si elle a changé. `force` ignore l'intervalle
    /// minimal — pour la fermeture d'une vidéo et le passage en arrière-plan.
    func flushToCloud(force: Bool = false) {
        guard syncDirty, let userId = twitchUserId, !userId.isEmpty, let token = twitchToken else { return }
        guard force || Date().timeIntervalSince(lastSyncAt) >= syncEvery else { return }

        // Seule la progression des VODs de l'historique part : le Worker garde
        // déjà les autres (il fusionne), inutile d'alourdir chaque envoi.
        let vodIds = Set(history.filter { $0.type == .vod }.map(\.term))
        let progress = vodProgress.filter { vodIds.contains($0.key) }.mapValues { $0.rounded() }
        guard let histData = try? JSONEncoder().encode(history),
              let histJSON = try? JSONSerialization.jsonObject(with: histData),
              let body = try? JSONSerialization.data(
                  withJSONObject: ["userId": userId, "data": ["history": histJSON, "progress": progress]],
                  options: [.sortedKeys]),
              let url = URL(string: "\(APIConfig.base)/api/sync/post") else { return }

        syncDirty = false
        guard body != lastSyncedBody else { return }
        lastSyncAt = Date()

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = body

        // Laisse à l'envoi le temps de finir si l'app vient de passer en
        // arrière-plan : sans ça, iOS peut la suspendre en pleine requête.
        // Boîte de référence plutôt qu'une `var` capturée : les deux blocs
        // sont `@Sendable` dans les SDK récents, où muter une variable
        // capturée ne compile pas.
        let request = req   // une `var` capturée par un Task ne compile pas
        let bg = BackgroundTaskBox()
        bg.id = UIApplication.shared.beginBackgroundTask(withName: "sync") { bg.end() }
        Task {
            let ok = ((try? await URLSession.shared.data(for: request))?.1 as? HTTPURLResponse)
                .map { (200..<300).contains($0.statusCode) } ?? false
            await MainActor.run {
                // Retenu comme envoyé seulement si le Worker l'a accepté :
                // sinon le prochain passage réessaie au lieu d'oublier.
                if ok { self.lastSyncedBody = body } else { self.syncDirty = true }
                bg.end()
            }
        }
        logger.syncPush(items: history.count)
    }
}

/// Tâche d'arrière-plan à clore une seule fois, quel que soit le premier
/// des deux à finir : la requête, ou le délai accordé par iOS.
final class BackgroundTaskBox {
    var id: UIBackgroundTaskIdentifier = .invalid
    // Pas d'annotation d'acteur : appelé depuis le délai d'expiration d'iOS,
    // dont l'isolation varie selon la version du SDK. Toujours sur le fil
    // principal en pratique (délai d'expiration, MainActor.run).
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// Vitesses de lecture proposées pour les VODs : la même liste que le site.
/// Plafond à 2× : sans playlist I-frame (Twitch n'en publie pas), AVPlayer ne
/// garantit pas mieux.
enum VodSpeed {
    static let all: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    /// Cran le plus proche (valeur venue d'une sauvegarde, d'AirPlay…).
    static func nearest(_ v: Double) -> Double {
        guard v.isFinite, v > 0 else { return 1 }
        return all.min { abs($0 - v) < abs($1 - v) } ?? 1
    }

    /// « 1,5× » : virgule en français, espagnol et russe, point en anglais.
    static func label(_ v: Double, _ lang: Lang) -> String {
        var s = String(format: "%g", v)
        if lang != .en { s = s.replacingOccurrences(of: ".", with: ",") }
        return s + "×"
    }
}
