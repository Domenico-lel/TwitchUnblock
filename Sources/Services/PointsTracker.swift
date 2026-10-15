import Foundation

// ═══════════════════════════════════════════════════════════════════════════
//  Points de chaîne gagnés en regardant, et temps regardé, par chaîne :
//  comptés sur cet appareil, affichés dans Réglages → Points de chaîne.
//  - Temps : chaque minute « minute-watched » acceptée par Twitch (celle qui
//    lui fait compter les points), donc seulement avec la session web.
//  - Points : les hausses du solde (points passifs, séries, coffres…), sans
//    les gains de prédictions, que la carte de la prédiction annonce.
// ═══════════════════════════════════════════════════════════════════════════

@MainActor
final class PointsTracker: ObservableObject {
    static let shared = PointsTracker()

    struct Channel: Codable, Identifiable, Equatable {
        var login: String
        var minutes = 0
        var points = 0
        var chests = 0
        var last = Date.distantPast
        var id: String { login }
    }

    /// Ce que rapporte la chaîne regardée en ce moment, depuis son ouverture.
    struct Session: Identifiable, Equatable {
        let login: String
        let start: Date
        var minutes = 0
        var points = 0
        var id: String { login }
    }

    @Published private(set) var channels: [String: Channel] = [:]
    /// Début du comptage (première minute, ou remise à zéro).
    @Published private(set) var since: Date?
    /// Chaînes qui rapportent en ce moment (plusieurs en multi-live).
    @Published private(set) var sessions: [String: Session] = [:]

    /// Gain de prédiction attendu sur une chaîne : retiré de la prochaine
    /// hausse du solde (3 min au plus), qui n'est pas un gain de visionnage.
    private var payouts: [String: (points: Int, until: Date)] = [:]

    private static let key = "points_tracker"
    private struct Saved: Codable { var channels: [String: Channel]; var since: Date? }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            channels = saved.channels
            since = saved.since
        }
    }

    var totalMinutes: Int { channels.values.reduce(0) { $0 + $1.minutes } }
    var totalPoints: Int { channels.values.reduce(0) { $0 + $1.points } }
    var totalChests: Int { channels.values.reduce(0) { $0 + $1.chests } }

    // MARK: Comptage (ChannelPointsService, LiveEventsService)
    /// Présence lancée sur une chaîne : sa session repart de zéro.
    func begin(_ login: String) {
        let k = login.lowercased()
        guard !k.isEmpty else { return }
        sessions[k] = Session(login: k, start: Date())
    }

    /// Chat de la chaîne fermé : plus de session en cours.
    func end(_ login: String) {
        let k = login.lowercased()
        if sessions[k] != nil { sessions[k] = nil }
    }

    /// Une minute acceptée par Twitch.
    func addMinute(_ login: String) {
        let k = login.lowercased()
        update(k) { $0.minutes += 1 }
        sessions[k]?.minutes += 1
    }

    /// Hausse du solde : comptée, moins un gain de prédiction attendu.
    func addGain(_ delta: Int, _ login: String) {
        let k = login.lowercased()
        guard delta > 0 else { return }
        var gain = delta
        if let p = payouts[k] {
            payouts[k] = nil
            if p.until > Date() { gain = max(0, delta - p.points) }
        }
        guard gain > 0 else { return }
        update(k) { $0.points += gain }
        sessions[k]?.points += gain
    }

    /// Coffre réclamé (ses points arrivent par `addGain`).
    func addChest(_ login: String) {
        update(login.lowercased()) { $0.chests += 1 }
    }

    /// Prédiction gagnée sur cette chaîne : son gain n'est pas compté.
    func expectPayout(_ points: Int, _ login: String) {
        let k = login.lowercased()
        guard points > 0, !k.isEmpty else { return }
        payouts[k] = (points, Date().addingTimeInterval(180))
    }

    func reset() {
        channels = [:]
        since = nil
        save()
    }

    // MARK: Stockage
    private func update(_ login: String, _ change: (inout Channel) -> Void) {
        guard !login.isEmpty else { return }
        var c = channels[login] ?? Channel(login: login)
        change(&c)
        c.last = Date()
        channels[login] = c
        if since == nil { since = Date() }
        // Stockage local limité : les 300 chaînes vues le plus récemment.
        if channels.count > 300,
           let oldest = channels.values.min(by: { $0.last < $1.last })?.login {
            channels[oldest] = nil
        }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(Saved(channels: channels, since: since)) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
