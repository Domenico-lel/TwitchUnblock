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

    /// Réponse (ou nouvel état) du développeur pas encore lue.
    var unread: Bool { lastFrom == "a" && updatedAt > seen }
    /// Terminé (fait ou refusé), dernier mot au développeur : plus rien
    /// n'est attendu, il n'est plus relu tout seul. Une réponse de la
    /// personne le remet au suivi (dernier mot à elle).
    var closed: Bool { (status == "done" || status == "refused") && lastFrom == "a" }
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
}
private struct ThreadsResponse: Decodable { let items: [FeedbackState] }
private struct ReplyResponse: Decodable { let item: FeedbackState? }

@MainActor
final class FeedbackStore: ObservableObject {
    static let shared = FeedbackStore()

    @Published private(set) var reports: [MyFeedback] = []
    var unreadCount: Int { reports.filter(\.unread).count }

    private let key = "my_feedback"
    private var checkedAt = Date.distantPast
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
        // terminés : plus de réveil pour eux.
        UserDefaults.standard.set(reports.contains { !$0.closed }, forKey: Self.hasReportsKey)
    }
    nonisolated static let hasReportsKey = "fb_has_reports"

    func add(id: String, token: String, kind: String, text: String) {
        let now = Date().timeIntervalSince1970 * 1000
        reports.insert(MyFeedback(id: id, token: token, at: now, kind: kind,
                                  text: String(text.prefix(200)), updatedAt: now, seen: now), at: 0)
        save()
    }

    func markSeen(_ id: String) {
        guard let i = reports.firstIndex(where: { $0.id == id }) else { return }
        reports[i].seen = Date().timeIntervalSince1970 * 1000
        save()
    }

    /// Adresse d'une photo de la discussion (le jeton du retour en donne l'accès).
    func photoURL(_ r: MyFeedback, _ n: Int) -> URL? {
        var c = URLComponents(string: "\(APIConfig.base)/api/feedback/photo")
        c?.queryItems = [.init(name: "id", value: r.id), .init(name: "n", value: String(n)),
                         .init(name: "token", value: r.token)]
        return c?.url
    }

    /// État des discussions encore suivies, en une requête — au plus une fois
    /// par `minInterval` sans `force`. Un retour terminé (`closed`) n'est plus
    /// relu, sauf s'il est dans `including` (discussion qu'on ouvre, liste
    /// tirée pour rafraîchir). Un retour effacé ou expiré quitte la liste.
    func refresh(force: Bool = false, minInterval: TimeInterval = 180, including: Set<String> = []) async {
        let followed = reports.filter { !$0.closed || including.contains($0.id) }
        guard !followed.isEmpty, force || Date().timeIntervalSince(checkedAt) > minInterval else { return }
        checkedAt = Date()
        let items = followed.map { ["id": $0.id, "token": $0.token] }
        guard let data = await post("/api/feedback/thread", ["items": items]),
              let states = try? JSONDecoder().decode(ThreadsResponse.self, from: data).items
        else { return }
        let byId = Dictionary(states.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let before = Dictionary(reports.map { ($0.id, $0.updatedAt) }, uniquingKeysWith: { a, _ in a })
        reports = reports.compactMap { r in
            guard let st = byId[r.id] else { return r }
            if st.gone == true { return nil }
            return apply(st, to: r)
        }
        save()
        // Réponse (ou nouvel état) du développeur arrivée depuis la dernière
        // lecture : bandeau dans l'app, ou notification. Pas de bandeau si
        // « Mes signalements » est à l'écran : la réponse y est affichée.
        let fresh = reports.filter { $0.unread && $0.updatedAt > (before[$0.id] ?? 0) }
        let inboxOnScreen = inboxViewers > 0 && UIApplication.shared.applicationState == .active
        if !fresh.isEmpty, !inboxOnScreen { notifyTeamUpdates(fresh) }
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
    private func notifyTeamUpdates(_ list: [MyFeedback]) {
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
            InAppNotices.shared.deliver(notice, id: "fb-\(r.id)-\(Int(r.updatedAt))",
                                        userInfo: ["feedback": r.id])
        }
    }

    private func apply(_ st: FeedbackState, to r: MyFeedback) -> MyFeedback {
        var r = r
        if let s = st.status { r.status = s }
        if let u = st.updatedAt { r.updatedAt = u }
        if let l = st.lastFrom { r.lastFrom = l }
        if let t = st.thread { r.thread = t }
        return r
    }

    /// Répond dans la discussion. Rend false si l'envoi a échoué.
    func reply(_ id: String, message: String, photos: [Data]) async -> Bool {
        guard let r = reports.first(where: { $0.id == id }) else { return false }
        let body: [String: Any] = ["id": r.id, "token": r.token, "message": message,
                                   "photos": photos.map { $0.base64EncodedString() }]
        guard let data = await post("/api/feedback/reply", body),
              let item = try? JSONDecoder().decode(ReplyResponse.self, from: data).item,
              let i = reports.firstIndex(where: { $0.id == id }) else { return false }
        reports[i] = apply(item, to: reports[i])
        reports[i].seen = Date().timeIntervalSince1970 * 1000
        save()
        return true
    }

    private func post(_ path: String, _ body: [String: Any]) async -> Data? {
        guard let url = URL(string: APIConfig.base + path),
              let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.httpBody = payload
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else {
            logger.warn("FEEDBACK", "Requête refusée", path)
            return nil
        }
        return data
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
