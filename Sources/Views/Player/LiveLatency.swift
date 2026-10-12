import AVFoundation

// MARK: – Mode faible latence (direct)
//
// Avant, le seul rattrapage partait au-delà de 30 s de retard, au plus une
// fois par minute : en lecture normale (10-20 s de retard), le mode ne
// faisait donc rien. Comme Twitch, on tient maintenant le bord du direct en
// continu :
//   • retard un peu au-dessus de la cible → lecture à ×1,1 jusqu'à la cible
//     (imperceptible, et sans recharger quoi que ce soit) ;
//   • grosse dérive (coupure, pause longue) → saut près du bord ;
//   • sinon, vitesse normale.
// La cible ne descend jamais sous le recul recommandé par le flux : plus près,
// AVPlayer joue dans des segments pas encore chargés et cale en boucle.
//
// Plancher : le retard affiché (heure − horodatage du segment lu) ne passe
// jamais sous 4 s — en dessous, la lecture cale (retour d'utilisateurs). Ce
// retard, c'est notre distance au bord jouable plus le délai de Twitch avant
// de publier un segment, qui change d'une chaîne à l'autre : la cible sur le
// bord est relevée d'autant, et un passage sous le seuil recule aussitôt.
struct LiveLatencyController {
    private var lastSeek = Date.distantPast
    private var lastFloorSeek = Date.distantPast
    private(set) var speedingUp = false
    /// Retard affiché minimal (s).
    static let minDelay: Double = 4
    /// Distance au bord jouable qu'il faut garder pour rester au-dessus de
    /// `minDelay`, d'après le dernier retard mesuré (0 tant qu'on ne sait pas).
    private(set) var floorBehind: Double = 0

    /// Retard visé par rapport au bord jouable. Le recul recommandé par AVPlayer
    /// vaut trois fois la durée cible de la playlist : 18 s sur une playlist
    /// Twitch d'origine (cible plafonnée à 8 s), 6 s sur une playlist réécrite
    /// (LivePlaylistLoader, relue toutes les 2 s : cible 4 s).
    static func target(for item: AVPlayerItem) -> Double {
        let rec = item.recommendedTimeOffsetFromLive
        let r = rec.isValid && rec.isNumeric ? rec.seconds : 6
        return min(8, max(3.5, r - 2))
    }

    /// Recul à garder sur le bord jouable : la cible du flux, ou plus pour
    /// tenir le plancher du retard affiché.
    func minBehind(for item: AVPlayerItem) -> Double { max(Self.target(for: item), floorBehind) }

    /// `behind` : secondes entre la position et le bord jouable (fin de la
    /// plage cherchable). `total` : retard affiché (heure − horodatage du
    /// segment lu), nil sans horodatage. À appeler deux fois par seconde environ.
    mutating func adjust(player: AVPlayer, item: AVPlayerItem, behind: Double, total: Double? = nil, enabled: Bool) {
        guard enabled, player.timeControlStatus == .playing, behind.isFinite else {
            if speedingUp { speedingUp = false; if player.rate > 1.01 { player.rate = 1 } }
            return
        }
        if let total, total.isFinite, total > 0 {
            // Délai de publication de Twitch = retard total − distance au bord.
            let publish = max(0, total - behind)
            floorBehind = min(10, max(0, Self.minDelay + 0.5 - publish))
            if total < Self.minDelay - 0.2, Date().timeIntervalSince(lastFloorSeek) > 8 {
                // Trop près : on recule tout de suite au-dessus du plancher.
                lastFloorSeek = Date()
                speedingUp = false
                player.rate = 1
                let back = CMTime(seconds: Self.minDelay + 0.5 - total, preferredTimescale: 600)
                player.seek(to: player.currentTime() - back,
                            toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
                logger.debug("LIVE", "Plancher du direct", String(format: "%.1f s de retard", total))
                return
            }
        }
        let target = minBehind(for: item)
        if behind > target + 15, Date().timeIntervalSince(lastSeek) > 20 {
            // Grosse dérive : on recolle d'un coup, au recul recommandé.
            lastSeek = Date()
            speedingUp = false
            logger.debug("LIVE", "Rattrapage du direct", String(format: "%.0f s de retard", behind))
            if let edge = item.seekableTimeRanges.last?.timeRangeValue.end, edge.isNumeric {
                player.seek(to: edge - CMTime(seconds: target, preferredTimescale: 600),
                            toleranceBefore: .positiveInfinity, toleranceAfter: .positiveInfinity)
            }
            player.rate = 1
        } else if behind > target + 2.5 {
            if !speedingUp || abs(player.rate - 1.1) > 0.01 { player.rate = 1.1 }
            speedingUp = true
        } else if speedingUp && behind <= target + 0.5 {
            speedingUp = false
            player.rate = 1
        }
    }
}

// MARK: – Synchro du chat
//
// Le retard à appliquer au chat, c'est notre retard sur le direct tel que le
// voient les autres spectateurs — ceux qui écrivent.
//
// La distance à la fin de la plage cherchable (`behind`) n'y suffisait pas.
// AVPlayer ne recharge la liste de lecture que toutes les quelques secondes
// (6 s sur Twitch) : entre deux rechargements, le bord qu'il connaît vieillit.
// Le retard mesuré dessinait donc des dents de scie de plusieurs secondes et
// restait en dessous de la réalité, les spectateurs de Twitch jouant les
// segments à mesure qu'ils sont produits. D'où un chat encore en avance.
//
// On part maintenant de la latence totale (heure − horodatage du segment lu,
// EXT-X-PROGRAM-DATE-TIME), qui reste lisse, et on en retire l'âge du bord le
// plus frais vu dans la dernière minute (mesuré juste après un rechargement).
// Le délai qu'une chaîne ajoute à sa diffusion, subi par tout le monde, est
// compté des deux côtés et s'annule dans la soustraction.
struct LiveSyncEstimator {
    private var samples: [(at: Date, edge: Double)] = []

    mutating func reset() { samples.removeAll() }

    /// `latency` : heure − horodatage du segment lu (nil sans horodatage).
    /// `behind` : secondes entre la position et la fin de la plage cherchable.
    mutating func offset(latency: Double?, behind: Double) -> Double {
        guard behind.isFinite else { return 0 }
        guard let latency, latency.isFinite, latency > 0 else { return max(0, behind) }
        let now = Date()
        // Âge du bord connu d'AVPlayer. Les valeurs absurdes (horodatage d'une
        // coupure pub, horloge qui saute) sont écartées.
        let edge = latency - behind
        if edge > -5, edge < 120 { samples.append((now, edge)) }
        samples.removeAll { now.timeIntervalSince($0.at) > 60 }
        // Pas encore assez de recul : l'ancien calcul, en attendant.
        guard samples.count >= 6 else { return max(0, behind) }
        // Bas de la fourchette plutôt que le minimum : une seule mesure
        // aberrante décalerait sinon le chat pendant une minute entière.
        let sorted = samples.map(\.edge).sorted()
        let freshest = sorted[sorted.count / 10]
        return max(0, latency - freshest)
    }
}
