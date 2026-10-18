import Foundation
import SwiftUI
import UIKit
import UserNotifications

// ═══════════════════════════════════════════════════════════════════════════
//  Suivi des retours envoyés depuis l'app (« Mes signalements »).
//
//  À l'envoi, le Worker rend un jeton secret : l'app le garde (avec le
//  dernier état connu) et s'en sert pour relire la discussion, voir où en est
//  le retour (reçu, accepté, en cours, fait, refusé) et répondre. Sans
//  compte : désinstaller l'app perd le suivi, pas le retour.
// ═══════════════════════════════════════════════════════════════════════════

/// Un message de la discussion — ou un changement d'état (`s`).
struct FeedbackMessage: Codable, Hashable {
    let f: String          // « u » : la personne, « a » : le développeur
    var m: String? = nil
    var s: String? = nil
    let at: Double         // millisecondes
    var ph: [Int]? = nil   // numéros des photos jointes

    var fromTeam: Bool { f == "a" }
    var date: Date { Date(timeIntervalSince1970: at / 1000) }
}

struct MyFeedback: Codable, Identifiable, Hashable {
    let id: String
    let token: String
    let at: Double
    var kind: String
    var text: String
    var status: String = "new"
    var updatedAt: Double
    var lastFrom: String = "u"
    var seen: Double
    var thread: [FeedbackMessage]? = nil
    /// Worker qui a reçu le retour (absent pour ceux d'avant) : la discussion
    /// s'y relit, même après être passé par un Worker personnel — qui
    /// répondait « effacé » pour ceux de l'officiel, et l'app les oubliait.
    var base: String? = nil
    /// Discussion fermée par le développeur, ou pleine (100 messages) : plus
    /// de champ de réponse (l'envoi échouait sans dire pourquoi).
    var blocked: Bool? = nil
    var full: Bool? = nil
    var locked: Bool { blocked == true || full == true }

    /// Réponse (ou nouvel état) du développeur pas encore lue. `seen` est
    /// une date du serveur (celle du dernier état vu) : l'horloge de
    /// l'appareil, souvent décalée en sideload, faisait manquer des réponses
    /// ou laissait une pastille rouge pour toujours.
    var unread: Bool { lastFrom == "a" && updatedAt > seen }
    /// Worker à interroger pour ce retour.
    var origin: String { base ?? APIConfig.base }
    /// « Effacé » fait foi : réponse de son propre Worker, ou d'un retour
    /// d'avant sans Worker personnel (tout partait alors à l'officiel).
    func goneIsReliable(from queried: String) -> Bool {
        base.map { $0 == queried } ?? (APIConfig.custom == nil)
    }
    /// Terminé (fait ou refusé), dernier mot au développeur : plus rien
    /// n'est attendu, il n'est plus relu tout seul. Une réponse de la
    /// personne le remet au suivi (dernier mot à elle).
    var closed: Bool { (status == "done" || status == "refused") && lastFrom == "a" }
    /// Terminé depuis moins de 30 jours : relu une fois par jour, le Worker y
    /// ajoute « le correctif est en ligne » à la sortie du correctif.
    var recentlyClosed: Bool { closed && updatedAt > (Date().timeIntervalSince1970 - 30 * 86_400) * 1000 }
    var messages: [FeedbackMessage] { thread ?? [FeedbackMessage(f: "u", m: text, at: at)] }
}

/// État d'un retour tel que le Worker le rend.
private struct FeedbackState: Decodable {
    let id: String
    var gone: Bool? = nil
    var status: String? = nil
    var updatedAt: Double? = nil
    var lastFrom: String? = nil
    var thread: [FeedbackMessage]? = nil
    /// Fermée par le développeur, pleine (absents : ni l'un ni l'autre).
    var closed: Bool? = nil
    var full: Bool? = nil
}
private struct ThreadsResponse: Decodable { let items: [FeedbackState] }
private struct ReplyResponse: Decodable { let item: FeedbackState? }
/// Réponse refusée : discussion fermée (403) ou pleine (409).
private struct ReplyRefusal: Decodable { var closed: Bool? = nil; var full: Bool? = nil }

@MainActor
final class FeedbackStore: ObservableObject {
    static let shared = FeedbackStore()

    @Published private(set) var reports: [MyFeedback] = []
    var unreadCount: Int { reports.filter(\.unread).count }

    private let key = "my_feedback"
    private var checkedAt = Date.distantPast
    /// Dernière réponse envoyée d'ici, par retour : une relecture partie
    /// avant ne l'écrase pas.
    private var localEdits: [String: Date] = [:]
    /// « Mes signalements » à l'écran (liste ou discussion) : la réponse s'y
    /// voit déjà, pas de bandeau par-dessus.
    var inboxViewers = 0
    private var foregroundChecks: Task<Void, Never>?

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([MyFeedback].self, from: data) {
            reports = list
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(Array(reports.prefix(50))) {
            UserDefaults.standard.set(data, forKey: key)
        }
        // Des retours encore suivis : iOS réveille aussi l'app pour leurs
        // réponses (LiveNotifier), même sans les notifications de live. Tous
        // terminés depuis plus de 30 jours : plus de réveil pour eux.
        UserDefaults.standard.set(reports.contains { !$0.closed || $0.recentlyClosed }, forKey: Self.hasReportsKey)
    }
    nonisolated static let hasReportsKey = "fb_has_reports"
    /// Dernière relecture des retours terminés (une par jour au plus).
    private static let closedCheckKey = "fb_closed_checked"

    /// `base` : le Worker qui vient de recevoir le retour.
    func add(id: String, token: String, kind: String, text: String, base: String = APIConfig.base) {
        let now = Date().timeIntervalSince1970 * 1000
        // `seen` à 0 : rien du développeur n'est encore arrivé (dernier mot
        // à la personne), et la date du serveur prendra le relais.
        reports.insert(MyFeedback(id: id, token: token, at: now, kind: kind,
                                  text: String(text.prefix(200)), updatedAt: now, seen: 0, base: base), at: 0)
        save()
    }

    func markSeen(_ id: String) {
        guard let i = reports.firstIndex(where: { $0.id == id }) else { return }
        reports[i].seen = reports[i].updatedAt
        save()
    }

    /// Adresse d'une photo de la discussion (le jeton du retour en donne l'accès).
    func photoURL(_ r: MyFeedback, _ n: Int) -> URL? {
        var c = URLComponents(string: "\(r.origin)/api/feedback/photo")
        c?.queryItems = [.init(name: "id", value: r.id), .init(name: "n", value: String(n)),
                         .init(name: "token", value: r.token)]
        return c?.url
    }

    /// État des discussions encore suivies, en une requête — au plus une fois
    /// par `minInterval` sans `force`. Un retour terminé (`closed`) n'est plus
    /// relu, sauf s'il est dans `including` (discussion qu'on ouvre, liste
    /// tirée pour rafraîchir). Un retour effacé ou expiré quitte la liste.
    func refresh(force: Bool = false, minInterval: TimeInterval = 180, including: Set<String> = []) async {
        // Terminés depuis moins de 30 jours : relus une fois par jour, pour le
        // « correctif en ligne » que le Worker ajoute à la sortie (il n'arrivait
        // jamais : un retour terminé n'était plus relu).
        let now = Date().timeIntervalSince1970
        let closedDue = now - UserDefaults.standard.double(forKey: Self.closedCheckKey) > 86_400
        let followed = reports.filter {
            !$0.closed || including.contains($0.id) || (closedDue && $0.recentlyClosed)
        }
        guard !followed.isEmpty, force || Date().timeIntervalSince(checkedAt) > minInterval else { return }
        checkedAt = Date()
        let started = Date()
        // Chacun à son Worker d'origine, par paquets de 30 : le Worker n'en
        // relit pas plus par appel (au-delà, les plus anciens restaient figés).
        var byId: [String: FeedbackState] = [:]
        var reliablyGone: Set<String> = []
        var reached = false
        for (base, list) in Dictionary(grouping: followed, by: \.origin) {
            for start in stride(from: 0, to: list.count, by: 30) {
                let chunk = Array(list[start ..< min(start + 30, list.count)])
                let items = chunk.map { ["id": $0.id, "token": $0.token] }
                guard let data = await post("/api/feedback/thread", ["items": items], base: base),
                      let states = try? JSONDecoder().decode(ThreadsResponse.self, from: data).items
                else { continue }
                reached = true
                for st in states {
                    byId[st.id] = st
                    if st.gone == true, chunk.first(where: { $0.id == st.id })?.goneIsReliable(from: base) == true {
                        reliablyGone.insert(st.id)
                    }
                }
            }
        }
        guard reached else { return }
        if closedDue, followed.contains(where: { $0.recentlyClosed }) {
            UserDefaults.standard.set(now, forKey: Self.closedCheckKey)
        }
        let before = Dictionary(reports.map { ($0.id, $0.updatedAt) }, uniquingKeysWith: { a, _ in a })
        reports = reports.compactMap { r in
            guard let st = byId[r.id] else { return r }
            if st.gone == true { return reliablyGone.contains(r.id) ? nil : r }
            // Réponse envoyée pendant la relecture : l'état lu est plus ancien
            // (le message disparaissait jusqu'à la relecture suivante).
            if let edited = localEdits[r.id], edited > started { return r }
            return apply(st, to: r)
        }
        save()
        // Réponse (ou nouvel état) du développeur arrivée depuis la dernière
        // lecture : bandeau dans l'app, ou notification. Pas de bandeau si
        // « Mes signalements » est à l'écran : la réponse y est affichée.
        let fresh = reports.filter { $0.unread && $0.updatedAt > (before[$0.id] ?? 0) }
        let inboxOnScreen = inboxViewers > 0 && UIApplication.shared.applicationState == .active
        // Attendu : un réveil en arrière-plan (LiveNotifier) ne se termine
        // qu'une fois les notifications posées — l'état, lui, est déjà noté.
        if !fresh.isEmpty, !inboxOnScreen { await notifyTeamUpdates(fresh) }
    }

    /// App au premier plan : relue toutes les minutes. Avant, rien ne se
    /// relisait tant qu'on restait dans l'app — la réponse n'arrivait qu'en
    /// ouvrant « Mes signalements », ou en revenant dans l'app 3 min après.
    /// Sans retour encore suivi (aucun, ou tous terminés), `refresh` ne fait
    /// aucune requête.
    func startForegroundChecks() {
        guard foregroundChecks == nil else { return }
        foregroundChecks = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.refresh(minInterval: 50)
            }
        }
    }

    func stopForegroundChecks() {
        foregroundChecks?.cancel()
        foregroundChecks = nil
    }

    /// Un avis par retour mis à jour par le développeur : bandeau dans l'app,
    /// ou notification (InAppNotices) ; le toucher ouvre « Mes signalements ».
    /// Identifiant = retour + date : la même mise à jour n'est jamais
    /// annoncée deux fois.
    private func notifyTeamUpdates(_ list: [MyFeedback]) async {
        let lang = Lang(rawValue: UserDefaults.standard.string(forKey: "lang") ?? "en") ?? .en
        for r in list.prefix(3) {
            let notice: InAppNotice
            if let m = r.messages.last(where: { $0.fromTeam })?.m, !m.isEmpty {
                notice = InAppNotice(kind: .feedback, title: translate("fb_notif_reply", lang), body: m)
            } else {
                notice = InAppNotice(kind: .feedback, title: translate("fb_notif_status", lang),
                                     body: translate("fb_status_line", lang)
                                        .replacingOccurrences(of: "{s}", with: translate("fb_status_\(r.status)", lang)))
            }
            await InAppNotices.shared.deliverNow(notice, id: "fb-\(r.id)-\(Int(r.updatedAt))",
                                                 userInfo: ["feedback": r.id])
        }
    }

    private func apply(_ st: FeedbackState, to r: MyFeedback) -> MyFeedback {
        var r = r
        if let s = st.status { r.status = s }
        if let u = st.updatedAt { r.updatedAt = u }
        if let l = st.lastFrom { r.lastFrom = l }
        if let t = st.thread { r.thread = t }
        r.blocked = st.closed == true ? true : nil
        r.full = st.full == true ? true : nil
        return r
    }

    /// Répond dans la discussion. Rend false si l'envoi a échoué.
    func reply(_ id: String, message: String, photos: [Data]) async -> Bool {
        guard let r = reports.first(where: { $0.id == id }) else { return false }
        let body: [String: Any] = ["id": r.id, "token": r.token, "message": message,
                                   "photos": photos.map { $0.base64EncodedString() }]
        let (answer, status) = await send("/api/feedback/reply", body, base: r.origin)
        // Fermée par le développeur, ou pleine, entre-temps : gardé avec le
        // retour, la vue retire le champ de réponse et dit pourquoi.
        if status == 403 || status == 409, let answer,
           let refusal = try? JSONDecoder().decode(ReplyRefusal.self, from: answer),
           refusal.closed == true || refusal.full == true,
           let i = reports.firstIndex(where: { $0.id == id }) {
            if refusal.closed == true { reports[i].blocked = true } else { reports[i].full = true }
            save()
            return false
        }
        guard status == 200, let data = answer,
              let item = try? JSONDecoder().decode(ReplyResponse.self, from: data).item,
              let i = reports.firstIndex(where: { $0.id == id }) else { return false }
        reports[i] = apply(item, to: reports[i])
        reports[i].seen = reports[i].updatedAt
        localEdits[id] = Date()
        save()
        return true
    }

    private func post(_ path: String, _ body: [String: Any], base: String = APIConfig.base) async -> Data? {
        let (data, status) = await send(path, body, base: base)
        return status == 200 ? data : nil
    }

    /// Corps et code HTTP de la réponse (nil, nil : pas de réponse).
    private func send(_ path: String, _ body: [String: Any], base: String = APIConfig.base) async -> (Data?, Int?) {
        guard let url = URL(string: base + path),
              let payload = try? JSONSerialization.data(withJSONObject: body) else { return (nil, nil) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.httpBody = payload
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let status = (resp as? HTTPURLResponse)?.statusCode else {
            logger.warn("FEEDBACK", "Requête refusée", "\(path) · réseau")
            return (nil, nil)
        }
        if status != 200 { logger.warn("FEEDBACK", "Requête refusée", "\(path) · HTTP \(status)") }
        return (data, status)
    }
}

extension UIImage {
    /// JPEG d'une capture jointe à un retour : 1600 px au plus, ~470 Ko au
    /// plus (le Worker refuse au-delà de ~500 Ko).
    func feedbackJPEG() -> Data? {
        var side: CGFloat = 1600
        var quality: CGFloat = 0.8
        var last: Data? = nil
        for _ in 0..<6 {
            let scale = min(1, side / max(size.width, size.height, 1))
            let target = CGSize(width: max(1, (size.width * scale).rounded()),
                                height: max(1, (size.height * scale).rounded()))
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            let img = UIGraphicsImageRenderer(size: target, format: format).image { _ in
                draw(in: CGRect(origin: .zero, size: target))
            }
            last = img.jpegData(compressionQuality: quality)
            if let d = last, d.count < 470_000 { return d }
            side *= 0.8
            quality = max(0.5, quality - 0.1)
        }
        return last.flatMap { $0.count < 520_000 ? $0 : nil }
    }
}
