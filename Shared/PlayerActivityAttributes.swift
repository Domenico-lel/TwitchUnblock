import Foundation
import ActivityKit

// ═══════════════════════════════════════════════════════════════════════════
//  Live Activity du lecteur : ce que l'app envoie, ce que l'extension
//  TwitchUnblockWidgets dessine sur l'écran verrouillé et dans la Dynamic
//  Island. Ce fichier est compilé dans les DEUX cibles (dossier Shared) :
//  iOS ne relie l'activité à sa vue que si le type est le même des deux côtés.
// ═══════════════════════════════════════════════════════════════════════════
@available(iOS 16.1, *)
struct PlayerActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var game: String
        /// Spectateurs déjà mis en forme (« 12.3k ») : l'extension n'a pas le
        /// code de l'app.
        var viewers: String
        var isPlaying: Bool
        /// Direct : début de la diffusion, pour une durée qui défile seule.
        /// VOD : début « virtuel » de la lecture (heure de la mise à jour moins
        /// la position), pour une barre qui avance seule tant qu'on ne met pas
        /// en pause — sans mise à jour à chaque seconde.
        var startedAt: Date?
        /// VOD : position au moment de la mise à jour (affichée en pause).
        var position: Double
        /// VOD : durée totale ; 0 pour un direct.
        var duration: Double
        /// VOD lue à une autre vitesse que 1× (nil sinon). Facultatif : une
        /// activité lancée par une version précédente doit encore se décoder.
        var rate: Double? = nil
        /// Activité reprise pour une autre chaîne pendant que l'app était en
        /// arrière-plan (raid suivi écran verrouillé, par exemple) : iOS n'y
        /// laisse pas en démarrer une nouvelle. Chaîne, nature et libellé du
        /// direct à afficher à la place de ceux du départ ; nil sinon.
        var shownChannel: String? = nil
        var shownIsLive: Bool? = nil
        var shownLiveLabel: String? = nil

        /// Vitesse de lecture effective (1 par défaut).
        var playbackRate: Double {
            guard let rate, rate.isFinite, rate > 0 else { return 1 }
            return rate
        }
    }

    /// Chaîne regardée. Changer de chaîne crée une nouvelle activité (app au
    /// premier plan ; sinon celle-ci est reprise, voir `shownChannel`).
    var channel: String
    var isLive: Bool
    /// « EN DIRECT », « LIVE NOW »… dans la langue choisie dans l'app.
    var liveLabel: String
}

@available(iOS 16.1, *)
extension PlayerActivityAttributes {
    /// Ce qu'affiche l'activité dans l'état `s` : la chaîne, la nature et le
    /// libellé du direct de l'état quand elle a été reprise pour une autre
    /// chaîne, sinon ceux du départ.
    func channel(in s: ContentState) -> String { s.shownChannel ?? channel }
    func isLive(in s: ContentState) -> Bool { s.shownIsLive ?? isLive }
    func liveLabel(in s: ContentState) -> String { s.shownLiveLabel ?? liveLabel }
}
